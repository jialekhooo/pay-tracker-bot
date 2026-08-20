"""JSON API behind the Telegram Mini App dashboard.

The frontend (``static/webapp``) is a Telegram Web App: it opens inside
Telegram, signs every request with the ``initData`` Telegram hands it, and we
verify that signature here with the bot token before touching a user's data.
"""

from __future__ import annotations

import calendar
import hashlib
import hmac
import json
import re
import time as time_module
from datetime import date as date_cls
from datetime import timedelta
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qsl

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel

from .bot import earned_by
from .parsing import ParseError, parse_time
from .pay import calculate_pay, round_money
from .reminders import DEFAULT_UTC_OFFSET_MINUTES, local_clock
from .schedule import find_clashes, span
from .storage import ShiftRecord, Storage

INIT_DATA_MAX_AGE_SECONDS = 24 * 60 * 60

router = APIRouter(prefix="/webapp/api")

_MONTH_NAMES = list(calendar.month_name)


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


def _authed_user(request: Request, authorization: str | None) -> tuple[Storage, int]:
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
    return storage, int(user["id"])


def _offset(storage: Storage, user_id: int) -> int:
    reminder = storage.get_reminder(user_id)
    return reminder.utc_offset_minutes if reminder else DEFAULT_UTC_OFFSET_MINUTES


def _month_label(month: str) -> str:
    year, index = month.split("-")
    return f"{_MONTH_NAMES[int(index)]} {year}"


def _num(value: Decimal) -> str:
    return str(round_money(value))


class ShiftUpdate(BaseModel):
    """A partial edit from the mini app's shift editor — unset fields are left alone."""

    event: str | None = None
    location: str | None = None
    rate: str | None = None
    start: str | None = None
    end: str | None = None
    day: str | None = None


def _shift_json(record: ShiftRecord) -> dict:
    return {
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
    }


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
                "earned_hours": str(item.hours),
                "earned_pay": _num(item.pay),
            }
            for item in tally.shifts
        ],
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
    all_time_pay = sum((s.pay for s in summaries), Decimal("0"))
    all_time_hours = sum((s.hours for s in summaries), Decimal("0"))
    all_time_shifts = sum((s.shifts for s in summaries), 0)

    upcoming = storage.shifts_between(user_id, today, today + timedelta(days=14))
    clashing: set[int] = set()
    for index, record in enumerate(upcoming):
        for other in find_clashes(upcoming[index + 1 :], record.day, record.start, record.end):
            clashing.update({record.id, other.id})

    return {
        "currency": config.currency,
        "now": now.isoformat(),
        "today": _tally_json("Today", today_records, now),
        "week": _tally_json(f"Week of {monday.strftime('%d %b')}", week_records, now),
        "month": _tally_json(_month_label(month_key), month_records, now),
        "all_time": {
            "earned": _num(all_time_pay),
            "hours": str(all_time_hours),
            "shifts": all_time_shifts,
        },
        "upcoming": [
            {**_shift_json(record), "clash": record.id in clashing} for record in upcoming
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


@router.get("/month/{month}")
async def month_shifts(
    month: str, request: Request, authorization: str | None = Header(default=None)
) -> dict:
    if not re.fullmatch(r"\d{4}-\d{2}", month):
        raise HTTPException(status_code=400, detail="Invalid month, expected YYYY-MM")
    storage, user_id = _authed_user(request, authorization)
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
        "shifts": [_shift_json(r) for r in records],
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

    hours = record.hours
    if payload.start is not None or payload.end is not None:
        try:
            start = parse_time(payload.start) if payload.start is not None else record.start
            end = parse_time(payload.end) if payload.end is not None else record.end
        except ParseError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        begins, ends = span(record.day, start, end)
        worked = Decimal((ends - begins).total_seconds()) / Decimal(3600)
        if not record.break_paid:
            worked -= record.break_hours
        hours = max(worked, Decimal("0"))
        fields["start_time"] = start.isoformat(timespec="minutes")
        fields["end_time"] = end.isoformat(timespec="minutes")
        fields["hours"] = str(hours)

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
        # the time changed but not the rate — keep the same hourly rate, new hours
        old_rate = record.pay / record.hours if record.hours else config.rate_for(record.event)
        fields["pay"] = str(calculate_pay(float(hours), event, config, round_money(old_rate)))

    if not fields:
        raise HTTPException(status_code=400, detail="Nothing to update")

    storage.update_shift(user_id, shift_id, **fields)
    updated = storage.get_shift(user_id, shift_id)
    return _shift_json(updated)
