"""JSON API behind the Telegram Mini App dashboard.

The frontend (``static/webapp``) is a Telegram Web App: it opens inside
Telegram, signs every request with the ``initData`` Telegram hands it, and we
verify that signature here with the bot token before touching a user's data.
"""

from __future__ import annotations

import calendar
import csv
import hashlib
import hmac
import io
import json
import logging
import re
import time as time_module
from base64 import b64decode
from binascii import Error as Base64Error
from dataclasses import replace
from datetime import date as date_cls
from datetime import datetime, timedelta
from datetime import time as time_cls
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qsl

import httpx
from fastapi import APIRouter, Header, HTTPException, Request, Response
from pydantic import BaseModel

from .bot import earned_by, worked_by
from .feed import issue_token
from .parsing import ParseError, parse_time
from .pay import calculate_pay, round_money
from .reminders import (
    DEFAULT_SEND_AT,
    DEFAULT_UTC_OFFSET_MINUTES,
    format_offset,
    local_clock,
    parse_offset,
)
from .schedule import find_clashes, span
from .storage import ShiftRecord, Storage

INIT_DATA_MAX_AGE_SECONDS = 24 * 60 * 60

router = APIRouter(prefix="/webapp/api")

_MONTH_NAMES = list(calendar.month_name)

logger = logging.getLogger(__name__)


def parse_init_data(init_data: str, bot_token: str) -> dict | None:
    """The Telegram user encoded in ``initData``, once its signature checks out.

    See https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
    """
    try:
        pairs = dict(parse_qsl(init_data, strict_parsing=True))
    except ValueError:
        return None
    received_hash = pairs.pop("hash", None)
    if not received_hash:
        return None
    data_check_string = "\n".join(f"{key}={value}" for key, value in sorted(pairs.items()))
    secret_key = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    computed_hash = hmac.new(
        secret_key, data_check_string.encode(), hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(computed_hash, received_hash):
        return None
    auth_date = pairs.get("auth_date")
    if not auth_date or not auth_date.isdigit():
        return None
    if time_module.time() - int(auth_date) > INIT_DATA_MAX_AGE_SECONDS:
        return None
    try:
        user = json.loads(pairs.get("user", ""))
    except json.JSONDecodeError:
        return None
    if not isinstance(user, dict) or "id" not in user:
        return None
    return user


def _authed_user_info(request: Request, authorization: str | None) -> tuple[Storage, dict]:
    """Like _authed_user, but also returns the raw Telegram user dict (e.g. for username)."""
    storage: Storage | None = getattr(request.app.state, "storage", None)
    bot_token: str | None = getattr(request.app.state, "bot_token", None)
    if storage is None or not bot_token:
        raise HTTPException(status_code=503, detail="The dashboard isn't ready yet")
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Telegram init data")
    scheme, _, init_data = authorization.partition(" ")
    if scheme.lower() != "tma" or not init_data:
        raise HTTPException(status_code=401, detail="Missing Telegram init data")
    user = parse_init_data(init_data, bot_token)
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid Telegram init data")
    return storage, user


def _authed_user(request: Request, authorization: str | None) -> tuple[Storage, int]:
    storage, user = _authed_user_info(request, authorization)
    return storage, int(user["id"])


def _offset(storage: Storage, user_id: int) -> int:
    reminder = storage.get_reminder(user_id)
    return reminder.utc_offset_minutes if reminder else DEFAULT_UTC_OFFSET_MINUTES


def _month_label(month: str) -> str:
    year, index = month.split("-")
    return f"{_MONTH_NAMES[int(index)]} {year}"


def _num(value: Decimal) -> str:
    return str(round_money(value))


async def _fetch_avatar(bot_token: str, user_id: int) -> tuple[bytes, str] | None:
    """The user's Telegram profile photo via the Bot API.

    More reliable than initData's ``photo_url`` field, which is frequently
    missing (older clients, or the user's "who can see my photo" privacy setting).
    """
    api = f"https://api.telegram.org/bot{bot_token}"
    async with httpx.AsyncClient(timeout=10.0) as client:
        photos_resp = await client.get(
            f"{api}/getUserProfilePhotos", params={"user_id": user_id, "limit": 1}
        )
        photos = photos_resp.json()
        if not photos.get("ok") or not photos["result"]["photos"]:
            logger.info("No avatar for user %s: %s", user_id, photos)
            return None
        file_id = photos["result"]["photos"][0][-1]["file_id"]  # largest size
        file_resp = await client.get(f"{api}/getFile", params={"file_id": file_id})
        file_info = file_resp.json()
        if not file_info.get("ok"):
            logger.info("getFile failed for user %s: %s", user_id, file_info)
            return None
        file_path = file_info["result"]["file_path"]
        image_resp = await client.get(f"https://api.telegram.org/file/bot{bot_token}/{file_path}")
        if image_resp.status_code != 200:
            return None
        content_type = "image/jpeg" if file_path.endswith((".jpg", ".jpeg")) else "image/png"
        return image_resp.content, content_type


_USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{5,32}$")
_OG_IMAGE_RE = re.compile(r'<meta\s+property="og:image"\s+content="([^"]+)"')


async def _fetch_public_avatar(username: str) -> tuple[bytes, str] | None:
    """The photo shown on a user's public t.me/<username> page, if they have one.

    This is a plain, unauthenticated public webpage — the same preview anyone
    gets from sharing a t.me link — so it's a legitimate fallback for users whose
    "who can see my photo" setting blocks the Bot API from seeing it directly.
    """
    if not _USERNAME_RE.fullmatch(username):
        return None
    async with httpx.AsyncClient(timeout=10.0, follow_redirects=True) as client:
        page_resp = await client.get(f"https://t.me/{username}")
        if page_resp.status_code != 200:
            logger.info("t.me/%s returned %s", username, page_resp.status_code)
            return None
        match = _OG_IMAGE_RE.search(page_resp.text)
        if not match:
            logger.info("No og:image on t.me/%s", username)
            return None
        image_resp = await client.get(match.group(1))
        if image_resp.status_code != 200:
            return None
        content_type = image_resp.headers.get("content-type", "image/jpeg").split(";")[0]
        if not content_type.startswith("image/"):
            return None
        return image_resp.content, content_type


@router.get("/avatar")
async def avatar(request: Request, authorization: str | None = Header(default=None)) -> Response:
    storage, user = _authed_user_info(request, authorization)
    user_id = int(user["id"])
    custom = storage.get_avatar(user_id)
    if custom is not None:
        content, content_type = custom
        return Response(
            content=content, media_type=content_type, headers={"Cache-Control": "private, max-age=3600"}
        )
    bot_token = request.app.state.bot_token
    try:
        result = await _fetch_avatar(bot_token, user_id)
        if result is None:
            if user.get("username"):
                result = await _fetch_public_avatar(user["username"])
            else:
                logger.info("No username for user %s; skipping public avatar fallback", user_id)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Couldn't reach Telegram") from exc
    if result is None:
        raise HTTPException(status_code=404, detail="No profile photo")
    content, content_type = result
    return Response(content=content, media_type=content_type, headers={"Cache-Control": "private, max-age=3600"})


_MAX_AVATAR_BYTES = 2 * 1024 * 1024
_ALLOWED_AVATAR_TYPES = {"image/jpeg", "image/png", "image/webp"}
_DATA_URL_RE = re.compile(r"data:(image/[\w.+-]+);base64,(.+)", re.DOTALL)


class AvatarUpload(BaseModel):
    data_url: str


@router.post("/avatar")
async def upload_avatar(
    payload: AvatarUpload, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    """Stores a user-picked image so the mini app can show it without needing
    Telegram's Bot API access, which some users' privacy settings block."""
    storage, user_id = _authed_user(request, authorization)
    match = _DATA_URL_RE.fullmatch(payload.data_url)
    if not match:
        raise HTTPException(status_code=400, detail="Expected a base64 image data URL")
    content_type = match.group(1)
    if content_type not in _ALLOWED_AVATAR_TYPES:
        raise HTTPException(status_code=400, detail="Only JPEG, PNG or WebP images are supported")
    encoded = match.group(2)
    if len(encoded) > _MAX_AVATAR_BYTES * 4 // 3 + 8:
        raise HTTPException(status_code=400, detail="Image is too large (max 2 MB)")
    try:
        image_bytes = b64decode(encoded, validate=True)
    except (Base64Error, ValueError) as exc:
        raise HTTPException(status_code=400, detail="Invalid image data") from exc
    if len(image_bytes) > _MAX_AVATAR_BYTES:
        raise HTTPException(status_code=400, detail="Image is too large (max 2 MB)")
    storage.save_avatar(user_id, image_bytes, content_type)
    return {"ok": True}


@router.delete("/avatar", status_code=204)
async def remove_avatar(
    request: Request, authorization: str | None = Header(default=None)
) -> Response:
    storage, user_id = _authed_user(request, authorization)
    storage.delete_avatar(user_id)
    return Response(status_code=204)


class ShiftUpdate(BaseModel):
    """A partial edit from the mini app's shift editor — unset fields are left alone."""

    event: str | None = None
    location: str | None = None
    rate: str | None = None
    start: str | None = None
    end: str | None = None
    day: str | None = None
    break_hours: str | None = None
    break_paid: bool | None = None
    payment_due: str | None = None
    paid: bool | None = None


class ShiftCreate(BaseModel):
    """A new shift logged from the mini app's "+" button."""

    event: str
    location: str = ""
    day: str
    start: str
    end: str
    rate: str | None = None
    break_hours: str | None = None
    break_paid: bool = False
    payment_due: str | None = None


class ShiftBulkEntry(BaseModel):
    """One date within a bulk create — each can have its own timing."""

    day: str
    start: str
    end: str


class ShiftBulkCreate(BaseModel):
    """Several shifts for the same event logged in one go — same rate/location, one row
    per date (each with its own timing), so a multi-day booking doesn't mean retyping
    everything each time."""

    event: str
    location: str = ""
    shifts: list[ShiftBulkEntry]
    rate: str | None = None
    break_hours: str | None = None
    break_paid: bool = False
    payment_due: str | None = None


class SettingsUpdate(BaseModel):
    """A partial edit from the mini app's Settings tab — unset fields are left alone."""

    display_name: str | None = None
    default_rate: str | None = None
    currency: str | None = None


class ReminderUpdate(BaseModel):
    """The day-before reminder, edited as a whole from the Settings tab."""

    enabled: bool
    send_at: str | None = None
    utc_offset: str | None = None


def _payment_status(state: str, paid: bool) -> str:
    """A shift's payment status is only ever "pending"/"completed" once it has actually
    happened — a shift that hasn't started (or is still running) is always "upcoming",
    whatever a stale ``paid`` flag might say."""
    if state != "done":
        return "upcoming"
    return "payment_completed" if paid else "pending_payment"


def _event_payment_status(shifts_json: list[dict]) -> str:
    """One status for a whole event: completed once nothing finished is left unpaid."""
    statuses = {s["payment_status"] for s in shifts_json}
    if statuses <= {"upcoming"}:
        return "upcoming"
    if "pending_payment" in statuses:
        return "pending_payment"
    return "payment_completed"


def _next_friday_on_or_after(day: date_cls) -> date_cls:
    """Rolls a date forward to the next Friday, or leaves it if it's already one."""
    return day + timedelta(days=(4 - day.weekday()) % 7)


def _default_payment_due(storage: Storage, user_id: int, event: str, day: date_cls) -> date_cls:
    """Two weeks after the last day of this same event, rounded forward to the nearest
    Friday — payouts are almost always weekly, on a Friday, after the whole gig wraps up."""
    return _default_payment_due_for_days(storage, user_id, event, [day])


def _default_payment_due_for_days(
    storage: Storage, user_id: int, event: str, days: list[date_cls]
) -> date_cls:
    """Same as ``_default_payment_due``, but for a batch of shifts created together — the
    due date is anchored to whichever of them (new or already booked) falls last."""
    last_day = max(days + [r.day for r in storage.shifts_for_event(user_id, event)])
    return _next_friday_on_or_after(last_day + timedelta(days=14))


def _shift_json(record: ShiftRecord, now: datetime | None = None) -> dict:
    data = {
        "id": record.id,
        "day": record.day.isoformat(),
        "weekday": record.day.strftime("%a"),
        "date_label": record.day.strftime("%d %b"),
        "start": record.start.strftime("%H:%M"),
        "end": record.end.strftime("%H:%M"),
        "event": record.event,
        "location": record.location,
        "hours": str(record.hours),
        "pay": _num(record.pay),
        "rate": _num(record.pay / record.hours) if record.hours else "0.00",
        "currency": record.currency,
        "break_hours": str(record.break_hours),
        "break_paid": record.break_paid,
        "payment_due": record.payment_due.isoformat() if record.payment_due else None,
        "paid": record.paid,
    }
    if now is not None:
        state = worked_by(record, now).state
        data["state"] = state
        data["payment_status"] = _payment_status(state, record.paid)
    return data


def _tally_json(label: str, records: list[ShiftRecord], now) -> dict:
    """A block of shifts scored against the clock: earned so far vs. still to come."""
    tally = earned_by(records, now)
    return {
        "label": label,
        "earned": _num(tally.pay),
        "hours": str(tally.hours),
        "finished": tally.finished,
        "to_come": _num(tally.booked_pay),
        "booked": tally.booked,
        "projected": _num(tally.pay + tally.booked_pay),
        "shifts": [
            {
                **_shift_json(item.record),
                "state": item.state,
                "payment_status": _payment_status(item.state, item.record.paid),
                "earned_hours": str(item.hours),
                "earned_pay": _num(item.pay),
            }
            for item in tally.shifts
        ],
    }


def _all_time_json(records: list[ShiftRecord], now) -> dict:
    """Same earned-vs-to-come split as a tally block, but across every shift ever logged."""
    tally = earned_by(records, now)
    return {
        "label": "All time",
        "earned": _num(tally.pay),
        "hours": str(tally.hours),
        "finished": tally.finished,
        "to_come": _num(tally.booked_pay),
        "booked": tally.booked,
        "projected": _num(tally.pay + tally.booked_pay),
        "shifts": len(records),
    }


@router.get("/summary")
async def summary(request: Request, authorization: str | None = Header(default=None)) -> dict:
    storage, user_id = _authed_user(request, authorization)
    config = storage.get_config(user_id)
    now = local_clock(_offset(storage, user_id))
    today = now.date()
    monday = today - timedelta(days=today.weekday())
    sunday = monday + timedelta(days=6)
    month_key = today.strftime("%Y-%m")

    today_records = storage.shifts_between(user_id, today, today)
    week_records = storage.shifts_between(user_id, monday, sunday)
    month_records = storage.list_shifts(user_id, month=month_key)

    summaries = storage.month_summaries(user_id)
    all_records = storage.list_shifts(user_id)

    upcoming = storage.shifts_between(user_id, today, today + timedelta(days=14))
    clashing = _clashing_ids(upcoming)

    return {
        "currency": config.currency,
        "now": now.isoformat(),
        "today": _tally_json("Today", today_records, now),
        "week": _tally_json(f"Week of {monday.strftime('%d %b')}", week_records, now),
        "month": _tally_json(_month_label(month_key), month_records, now),
        "all_time": _all_time_json(all_records, now),
        "upcoming": [
            {**_shift_json(record, now), "clash": record.id in clashing} for record in upcoming
        ],
        "months": [
            {
                "month": s.month,
                "label": _month_label(s.month),
                "shifts": s.shifts,
                "hours": str(s.hours),
                "pay": _num(s.pay),
                "currency": s.currency,
            }
            for s in summaries
        ],
    }


def _clashing_ids(records: list[ShiftRecord]) -> set[int]:
    clashing: set[int] = set()
    for index, record in enumerate(records):
        for other in find_clashes(records[index + 1 :], record.day, record.start, record.end):
            clashing.update({record.id, other.id})
    return clashing


def _clash_summaries(
    storage: Storage,
    user_id: int,
    day: date_cls,
    start: time_cls,
    end: time_cls,
    exclude_id: int | None = None,
) -> list[dict]:
    """Other booked shifts that overlap this slot, for warning the user at save time."""
    nearby = storage.shifts_between(user_id, day - timedelta(days=1), day + timedelta(days=1))
    if exclude_id is not None:
        nearby = [r for r in nearby if r.id != exclude_id]
    return [
        {
            "id": c.id,
            "event": c.event,
            "day": c.day.isoformat(),
            "start": c.start.strftime("%H:%M"),
            "end": c.end.strftime("%H:%M"),
        }
        for c in find_clashes(nearby, day, start, end)
    ]


_UPCOMING_SPANS = {"7": 6, "14": 14, "30": 30}
_UPCOMING_ALL_DAYS = 3650  # ~10 years; effectively "everything booked ahead"


@router.get("/upcoming/{scope}")
async def upcoming_shifts(
    scope: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    now = local_clock(_offset(storage, user_id))
    today = now.date()
    if scope == "tomorrow":
        first = last = today + timedelta(days=1)
        label = "Tomorrow"
    elif scope == "all":
        first, last = today, today + timedelta(days=_UPCOMING_ALL_DAYS)
        label = "All upcoming"
    elif scope in _UPCOMING_SPANS:
        first, last = today, today + timedelta(days=_UPCOMING_SPANS[scope])
        label = f"Next {scope} days"
    else:
        raise HTTPException(
            status_code=400, detail="Unknown range, expected tomorrow/7/14/30/all"
        )
    records = storage.shifts_between(user_id, first, last)
    clashing = _clashing_ids(records)
    currency = records[0].currency if records else storage.get_config(user_id).currency
    return {
        "scope": scope,
        "label": label,
        "currency": currency,
        "shifts": [{**_shift_json(r, now), "clash": r.id in clashing} for r in records],
    }


@router.get("/month/{month}")
async def month_shifts(
    month: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    if not re.fullmatch(r"\d{4}-\d{2}", month):
        raise HTTPException(status_code=400, detail="Invalid month, expected YYYY-MM")
    storage, user_id = _authed_user(request, authorization)
    now = local_clock(_offset(storage, user_id))
    records = storage.list_shifts(user_id, month=month)
    pay = sum((r.pay for r in records), Decimal("0"))
    hours = sum((r.hours for r in records), Decimal("0"))
    currency = records[0].currency if records else storage.get_config(user_id).currency
    return {
        "month": month,
        "label": _month_label(month),
        "currency": currency,
        "pay": _num(pay),
        "hours": str(hours),
        "shifts": [_shift_json(r, now) for r in records],
    }


@router.get("/week/{start}")
async def week_shifts(
    start: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    try:
        monday = date_cls.fromisoformat(start)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid date, expected YYYY-MM-DD") from exc
    storage, user_id = _authed_user(request, authorization)
    now = local_clock(_offset(storage, user_id))
    sunday = monday + timedelta(days=6)
    records = storage.shifts_between(user_id, monday, sunday)
    pay = sum((r.pay for r in records), Decimal("0"))
    hours = sum((r.hours for r in records), Decimal("0"))
    currency = records[0].currency if records else storage.get_config(user_id).currency
    return {
        "start": monday.isoformat(),
        "label": f"Week of {monday.strftime('%d %b')}",
        "currency": currency,
        "pay": _num(pay),
        "hours": str(hours),
        "shifts": [_shift_json(r, now) for r in records],
    }


@router.get("/day/{day}")
async def day_shifts(
    day: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    try:
        target = date_cls.fromisoformat(day)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid date, expected YYYY-MM-DD") from exc
    storage, user_id = _authed_user(request, authorization)
    now = local_clock(_offset(storage, user_id))
    records = storage.shifts_between(user_id, target, target)
    pay = sum((r.pay for r in records), Decimal("0"))
    hours = sum((r.hours for r in records), Decimal("0"))
    currency = records[0].currency if records else storage.get_config(user_id).currency
    return {
        "day": target.isoformat(),
        "label": target.strftime("%a, %d %b"),
        "currency": currency,
        "pay": _num(pay),
        "hours": str(hours),
        "shifts": [_shift_json(r, now) for r in records],
    }


@router.patch("/shifts/{shift_id}")
async def update_shift(
    shift_id: int,
    payload: ShiftUpdate,
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    record = storage.get_shift(user_id, shift_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Shift not found")
    config = storage.get_config(user_id)

    fields: dict[str, object] = {}
    event = record.event
    if payload.event is not None:
        event = payload.event.strip()
        if not event:
            raise HTTPException(status_code=400, detail="Event name can't be empty")
        fields["event"] = event

    if payload.location is not None:
        fields["location"] = payload.location.strip()

    break_hours = record.break_hours
    if payload.break_hours is not None:
        try:
            break_hours = Decimal(payload.break_hours)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid break hours") from exc
        if break_hours < 0:
            raise HTTPException(status_code=400, detail="Break hours can't be negative")
    break_paid = record.break_paid if payload.break_paid is None else payload.break_paid

    hours = record.hours
    durational_change = (
        payload.start is not None
        or payload.end is not None
        or payload.break_hours is not None
        or payload.break_paid is not None
    )
    if durational_change:
        try:
            start = parse_time(payload.start) if payload.start is not None else record.start
            end = parse_time(payload.end) if payload.end is not None else record.end
        except ParseError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        begins, ends = span(record.day, start, end)
        worked = Decimal((ends - begins).total_seconds()) / Decimal(3600)
        if not break_paid:
            worked -= break_hours
        hours = max(worked, Decimal("0"))
        fields["start_time"] = start.isoformat(timespec="minutes")
        fields["end_time"] = end.isoformat(timespec="minutes")
        fields["hours"] = str(hours)
        fields["break_hours"] = str(break_hours)
        fields["break_paid"] = int(break_paid)

    if payload.day is not None:
        try:
            fields["day"] = date_cls.fromisoformat(payload.day).isoformat()
        except ValueError as exc:
            raise HTTPException(
                status_code=400, detail="Invalid date, expected YYYY-MM-DD"
            ) from exc

    if payload.rate is not None:
        try:
            rate = Decimal(payload.rate)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid rate") from exc
        if rate < 0:
            raise HTTPException(status_code=400, detail="Rate can't be negative")
        fields["pay"] = str(calculate_pay(float(hours), event, config, rate))
    elif "hours" in fields:
        # the time or break changed but not the rate — keep the same hourly rate, new hours
        old_rate = record.pay / record.hours if record.hours else config.rate_for(record.event)
        fields["pay"] = str(calculate_pay(float(hours), event, config, round_money(old_rate)))

    if payload.payment_due is not None:
        try:
            fields["payment_due"] = date_cls.fromisoformat(payload.payment_due).isoformat()
        except ValueError as exc:
            raise HTTPException(
                status_code=400, detail="Invalid date, expected YYYY-MM-DD"
            ) from exc

    if payload.paid is not None:
        fields["paid"] = int(payload.paid)

    if not fields:
        raise HTTPException(status_code=400, detail="Nothing to update")

    storage.update_shift(user_id, shift_id, **fields)
    updated = storage.get_shift(user_id, shift_id)
    clashes: list[dict] = []
    if durational_change or payload.day is not None:
        final_day = date_cls.fromisoformat(payload.day) if payload.day is not None else record.day
        final_start = start if durational_change else record.start
        final_end = end if durational_change else record.end
        clashes = _clash_summaries(
            storage, user_id, final_day, final_start, final_end, exclude_id=shift_id
        )
    return {
        **_shift_json(updated, local_clock(_offset(storage, user_id))),
        "clashes": clashes,
    }


@router.post("/shifts")
async def create_shift(
    payload: ShiftCreate, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    config = storage.get_config(user_id)

    event = payload.event.strip()
    if not event:
        raise HTTPException(status_code=400, detail="Event name can't be empty")

    try:
        day = date_cls.fromisoformat(payload.day)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid date, expected YYYY-MM-DD") from exc

    try:
        start = parse_time(payload.start)
        end = parse_time(payload.end)
    except ParseError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    if payload.break_hours is not None:
        try:
            break_hours = Decimal(payload.break_hours)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid break hours") from exc
        break_paid = payload.break_paid
    else:
        # no break given — fall back to the user's /break default, same as logging by text
        break_hours = config.default_break_hours
        break_paid = config.default_break_paid
    if break_hours < 0:
        raise HTTPException(status_code=400, detail="Break hours can't be negative")

    if payload.payment_due is not None:
        try:
            payment_due = date_cls.fromisoformat(payload.payment_due)
        except ValueError as exc:
            raise HTTPException(
                status_code=400, detail="Invalid date, expected YYYY-MM-DD"
            ) from exc
    else:
        # left unset — two weeks after the last day of this same event, on a Friday
        payment_due = _default_payment_due(storage, user_id, event, day)

    begins, ends = span(day, start, end)
    worked = Decimal((ends - begins).total_seconds()) / Decimal(3600)
    if not break_paid:
        worked -= break_hours
    hours = max(worked, Decimal("0"))

    rate_override = None
    if payload.rate:
        try:
            rate_override = Decimal(payload.rate)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid rate") from exc
        if rate_override < 0:
            raise HTTPException(status_code=400, detail="Rate can't be negative")

    pay = calculate_pay(float(hours), event, config, rate_override)
    shift_id = storage.add_shift(
        user_id=user_id,
        day=day,
        start=start,
        end=end,
        event=event,
        location=payload.location.strip(),
        break_hours=break_hours,
        break_paid=break_paid,
        hours=hours,
        pay=pay,
        currency=config.currency,
        payment_due=payment_due,
    )
    clashes = _clash_summaries(storage, user_id, day, start, end, exclude_id=shift_id)
    return {
        **_shift_json(storage.get_shift(user_id, shift_id), local_clock(_offset(storage, user_id))),
        "clashes": clashes,
    }


_BULK_CREATE_MAX_DAYS = 60


@router.post("/shifts/bulk")
async def create_shifts_bulk(
    payload: ShiftBulkCreate, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    config = storage.get_config(user_id)

    event = payload.event.strip()
    if not event:
        raise HTTPException(status_code=400, detail="Event name can't be empty")

    if not payload.shifts:
        raise HTTPException(status_code=400, detail="Pick at least one date")
    if len(payload.shifts) > _BULK_CREATE_MAX_DAYS:
        raise HTTPException(
            status_code=400, detail=f"Too many dates at once (max {_BULK_CREATE_MAX_DAYS})"
        )

    entries: list[tuple[date_cls, time_cls, time_cls]] = []
    seen: set[tuple[str, str, str]] = set()
    for entry in payload.shifts:
        key = (entry.day, entry.start, entry.end)
        if key in seen:
            continue
        seen.add(key)
        try:
            day = date_cls.fromisoformat(entry.day)
        except ValueError as exc:
            raise HTTPException(
                status_code=400, detail="Invalid date, expected YYYY-MM-DD"
            ) from exc
        try:
            start = parse_time(entry.start)
            end = parse_time(entry.end)
        except ParseError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        entries.append((day, start, end))
    if not entries:
        raise HTTPException(status_code=400, detail="Pick at least one date")

    spans = [span(day, start, end) for day, start, end in entries]
    for i, (a_start, a_end) in enumerate(spans):
        for b_start, b_end in spans[i + 1 :]:
            if a_start < b_end and b_start < a_end:
                raise HTTPException(
                    status_code=400, detail="Two of these dates overlap — adjust their times"
                )

    if payload.break_hours is not None:
        try:
            break_hours = Decimal(payload.break_hours)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid break hours") from exc
        break_paid = payload.break_paid
    else:
        break_hours = config.default_break_hours
        break_paid = config.default_break_paid
    if break_hours < 0:
        raise HTTPException(status_code=400, detail="Break hours can't be negative")

    if payload.payment_due is not None:
        try:
            payment_due = date_cls.fromisoformat(payload.payment_due)
        except ValueError as exc:
            raise HTTPException(
                status_code=400, detail="Invalid date, expected YYYY-MM-DD"
            ) from exc
    else:
        # left unset — two weeks after the last day of the whole batch, on a Friday
        payment_due = _default_payment_due_for_days(
            storage, user_id, event, [day for day, _, _ in entries]
        )

    rate_override = None
    if payload.rate:
        try:
            rate_override = Decimal(payload.rate)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid rate") from exc
        if rate_override < 0:
            raise HTTPException(status_code=400, detail="Rate can't be negative")

    now = local_clock(_offset(storage, user_id))
    created: list[dict] = []
    clashes: list[dict] = []
    for day, start, end in entries:
        begins, ends = span(day, start, end)
        worked = Decimal((ends - begins).total_seconds()) / Decimal(3600)
        if not break_paid:
            worked -= break_hours
        hours = max(worked, Decimal("0"))
        pay = calculate_pay(float(hours), event, config, rate_override)
        shift_id = storage.add_shift(
            user_id=user_id,
            day=day,
            start=start,
            end=end,
            event=event,
            location=payload.location.strip(),
            break_hours=break_hours,
            break_paid=break_paid,
            hours=hours,
            pay=pay,
            currency=config.currency,
            payment_due=payment_due,
        )
        created.append(_shift_json(storage.get_shift(user_id, shift_id), now))
        clashes.extend(_clash_summaries(storage, user_id, day, start, end, exclude_id=shift_id))
    return {"created": created, "clashes": clashes}


@router.delete("/shifts/{shift_id}", status_code=204)
async def delete_shift(
    shift_id: int, request: Request, authorization: str | None = Header(default=None)
) -> Response:
    storage, user_id = _authed_user(request, authorization)
    if not storage.delete_shift(user_id, shift_id):
        raise HTTPException(status_code=404, detail="Shift not found")
    return Response(status_code=204)


@router.get("/payments/due")
async def payments_due(
    request: Request, authorization: str | None = Header(default=None)
) -> dict:
    """Unpaid shifts whose payment due date has arrived — surfaced by the mini app so it
    can prompt the user to confirm marking them as paid."""
    storage, user_id = _authed_user(request, authorization)
    now = local_clock(_offset(storage, user_id))
    records = storage.due_payments(user_id, now.date())
    return {"shifts": [_shift_json(r, now) for r in records]}


@router.get("/search")
async def search_shifts(
    q: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    keyword = q.strip()
    if not keyword:
        return {"query": "", "shifts": []}
    now = local_clock(_offset(storage, user_id))
    records = storage.search_shifts(user_id, keyword)
    return {"query": keyword, "shifts": [_shift_json(r, now) for r in records]}


@router.get("/events")
async def events(request: Request, authorization: str | None = Header(default=None)) -> dict:
    storage, user_id = _authed_user(request, authorization)
    now = local_clock(_offset(storage, user_id))
    summaries = storage.event_summaries(user_id)
    all_records = storage.list_shifts(user_id)
    first_days: dict[str, date_cls] = {}
    for record in all_records:
        key = record.event.lower()
        first_days[key] = min(first_days.get(key, record.day), record.day)
    return {
        "currency": storage.get_config(user_id).currency,
        "all_time": _all_time_json(all_records, now),
        "events": [
            {
                "event": s.event,
                "shifts": s.shifts,
                "hours": str(s.hours),
                "pay": _num(s.pay),
                "currency": s.currency,
                "first_day": first_days[s.event.lower()].isoformat(),
            }
            for s in summaries
        ]
    }


@router.get("/event/{event}")
async def event_shifts(
    event: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    records = storage.shifts_for_event(user_id, event)
    if not records:
        raise HTTPException(status_code=404, detail="No shifts logged for this event")
    now = local_clock(_offset(storage, user_id))
    pay = sum((r.pay for r in records), Decimal("0"))
    hours = sum((r.hours for r in records), Decimal("0"))
    shifts_json = [_shift_json(r, now) for r in records]
    return {
        "event": records[0].event,
        "label": records[0].event,
        "currency": records[0].currency,
        "pay": _num(pay),
        "hours": str(hours),
        "payment_status": _event_payment_status(shifts_json),
        "shifts": shifts_json,
    }


@router.post("/event/{event}/mark-paid")
async def mark_event_paid(
    event: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    """Marks every shift for this event as paid in one action — most gigs pay out as a
    single lump sum for the whole booking, not shift by shift."""
    storage, user_id = _authed_user(request, authorization)
    updated = storage.mark_event_paid(user_id, event)
    if not updated:
        raise HTTPException(status_code=404, detail="No shifts logged for this event")
    return {"event": event, "updated": updated}


def _calendar_url(request: Request, storage: Storage, user_id: int) -> str | None:
    base_url = getattr(request.app.state, "feed_base_url", None)
    if not base_url:
        return None
    token = issue_token(storage, user_id)
    return f"{base_url.rstrip('/')}/{token}.ics"


def _webcal_url(calendar_url: str | None) -> str | None:
    """webcal:// hands the URL straight to the OS's Calendar app for subscribing,
    instead of the browser just downloading the file."""
    if not calendar_url:
        return None
    return re.sub(r"^https?://", "webcal://", calendar_url)


@router.get("/export/csv")
async def export_csv(request: Request, authorization: str | None = Header(default=None)) -> Response:
    """Downloads every logged shift in a spreadsheet-friendly CSV file."""
    storage, user_id = _authed_user(request, authorization)
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(
        [
            "Shift ID",
            "Date",
            "Start",
            "End",
            "Event",
            "Location",
            "Hours",
            "Break hours",
            "Paid break",
            "Pay",
            "Currency",
        ]
    )
    for record in storage.list_shifts(user_id):
        writer.writerow(
            [
                record.id,
                record.day.isoformat(),
                record.start.strftime("%H:%M"),
                record.end.strftime("%H:%M"),
                record.event,
                record.location,
                str(record.hours),
                str(record.break_hours),
                "Yes" if record.break_paid else "No",
                _num(record.pay),
                record.currency,
            ]
        )
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="howmuch-shifts.csv"'},
    )


def _settings_json(request: Request, storage: Storage, user_id: int) -> dict:
    config = storage.get_config(user_id)
    reminder = storage.get_reminder(user_id)
    send_at = reminder.send_at if reminder else time_cls.fromisoformat(DEFAULT_SEND_AT)
    offset = reminder.utc_offset_minutes if reminder else DEFAULT_UTC_OFFSET_MINUTES
    calendar_url = _calendar_url(request, storage, user_id)
    return {
        "display_name": config.display_name,
        "default_rate": _num(config.default_rate),
        "currency": config.currency,
        "has_custom_avatar": storage.get_avatar(user_id) is not None,
        "reminders": {
            "enabled": bool(reminder.enabled) if reminder else False,
            "send_at": send_at.strftime("%H:%M"),
            "utc_offset_minutes": offset,
            "utc_offset_label": format_offset(offset),
        },
        "calendar_url": calendar_url,
        "webcal_url": _webcal_url(calendar_url),
    }


@router.get("/settings")
async def get_settings(request: Request, authorization: str | None = Header(default=None)) -> dict:
    storage, user_id = _authed_user(request, authorization)
    return _settings_json(request, storage, user_id)


@router.patch("/settings")
async def update_settings(
    payload: SettingsUpdate, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    config = storage.get_config(user_id)
    changes: dict[str, object] = {}
    if payload.display_name is not None:
        changes["display_name"] = payload.display_name.strip()[:60]
    if payload.default_rate is not None:
        try:
            rate = Decimal(payload.default_rate)
        except InvalidOperation as exc:
            raise HTTPException(status_code=400, detail="Invalid rate") from exc
        if rate < 0:
            raise HTTPException(status_code=400, detail="Rate can't be negative")
        changes["default_rate"] = rate
    if payload.currency is not None:
        code = payload.currency.strip().upper()
        if not code:
            raise HTTPException(status_code=400, detail="Currency can't be empty")
        changes["currency"] = code
    if changes:
        storage.save_config(user_id, replace(config, **changes))
    return _settings_json(request, storage, user_id)


@router.patch("/reminders")
async def update_reminders(
    payload: ReminderUpdate, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    existing = storage.get_reminder(user_id)
    send_at = existing.send_at if existing else time_cls.fromisoformat(DEFAULT_SEND_AT)
    offset = existing.utc_offset_minutes if existing else DEFAULT_UTC_OFFSET_MINUTES
    if payload.send_at is not None:
        try:
            send_at = time_cls.fromisoformat(payload.send_at)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Invalid time, expected HH:MM") from exc
    if payload.utc_offset is not None:
        try:
            offset = parse_offset(payload.utc_offset)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    storage.save_reminder(user_id, user_id, send_at, offset, payload.enabled)
    return _settings_json(request, storage, user_id)


@router.post("/calendar/rotate")
async def rotate_calendar_link(
    request: Request, authorization: str | None = Header(default=None)
) -> dict:
    storage, user_id = _authed_user(request, authorization)
    base_url = getattr(request.app.state, "feed_base_url", None)
    if not base_url:
        raise HTTPException(status_code=503, detail="The calendar feed isn't set up")
    token = issue_token(storage, user_id, refresh=True)
    calendar_url = f"{base_url.rstrip('/')}/{token}.ics"
    return {"calendar_url": calendar_url, "webcal_url": _webcal_url(calendar_url)}
