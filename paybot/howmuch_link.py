"""Talk to the HowMuch iPhone app's server for Telegram accounts linked to a HowMuch account.

Linking starts in the app (Settings → Telegram → Link Telegram), which opens this bot with
`/start link-<code>`. The bot confirms the code with the server, then sends shifts to the
account and reads what is owed and what is coming up. Nothing here works without
HOWMUCH_BOT_SECRET, which the server shares.
"""
from __future__ import annotations

import os
import time as time_module
from dataclasses import dataclass
from decimal import Decimal

import httpx

from .parsing import Shift

DEFAULT_API = "https://howmuch-ios.fly.dev"
STATUS_SECONDS = 60


class LinkError(Exception):
    """A message to show the person, e.g. an expired code or the server being unreachable."""


@dataclass(frozen=True)
class Added:
    id: str
    event: str
    location: str
    day: str
    start_minute: int
    end_minute: int
    break_minutes: int
    pay: Decimal
    currency: str


def shift_payload(shift: Shift) -> dict:
    """A parsed Telegram shift in the form the server adds to the app."""
    payload: dict = {
        "event": shift.event,
        "location": shift.location,
        "day": shift.day.isoformat(),
        "startMinute": shift.start.hour * 60 + shift.start.minute,
        "endMinute": shift.end.hour * 60 + shift.end.minute,
    }
    if shift.break_specified:
        payload["breakMinutes"] = round(shift.rest.hours * 60)
        payload["paidBreak"] = shift.rest.paid
    if shift.pay_is_fixed and shift.rate_override is not None:
        payload["fixedPay"] = str(shift.rate_override)
    elif shift.rate_override is not None:
        payload["rate"] = str(shift.rate_override)
    return payload


class HowMuchLink:
    def __init__(self, secret: str, base_url: str = DEFAULT_API, client: httpx.AsyncClient | None = None) -> None:
        self._secret = secret
        self._base = base_url.rstrip("/")
        self._client = client or httpx.AsyncClient(timeout=15)
        self._status: dict[int, tuple[bool, str, float]] = {}

    @classmethod
    def from_env(cls) -> "HowMuchLink | None":
        secret = os.environ.get("HOWMUCH_BOT_SECRET", "").strip()
        if not secret:
            return None
        return cls(secret, os.environ.get("HOWMUCH_API_URL", DEFAULT_API))

    async def _post(self, path: str, body: dict) -> dict:
        try:
            response = await self._client.post(self._base + path, json=body, headers={"X-HowMuch-Bot": self._secret})
        except httpx.HTTPError as error:
            raise LinkError("Couldn't reach HowMuch right now. Please try again in a minute.") from error
        if response.status_code >= 400:
            try:
                detail = response.json().get("detail")
            except ValueError:
                detail = None
            raise LinkError(detail if isinstance(detail, str) else "HowMuch couldn't do that. Please try again.")
        return response.json()

    async def linked(self, telegram_user_id: int) -> bool:
        cached = self._status.get(telegram_user_id)
        if cached and time_module.monotonic() - cached[2] < STATUS_SECONDS:
            return cached[0]
        try:
            result = await self._post("/v1/bot/status", {"telegramUserId": telegram_user_id})
        except LinkError:
            return False  # if the server can't be reached, the bot keeps working on its own records
        self._remember(telegram_user_id, bool(result.get("linked")), result.get("displayName", ""))
        return bool(result.get("linked"))

    def _remember(self, telegram_user_id: int, linked: bool, name: str = "") -> None:
        self._status[telegram_user_id] = (linked, name, time_module.monotonic())

    async def link(self, telegram_user_id: int, code: str, username: str) -> str:
        result = await self._post("/v1/bot/link", {"telegramUserId": telegram_user_id, "code": code, "username": username or ""})
        name = result.get("displayName", "")
        self._remember(telegram_user_id, True, name)
        return name

    async def unlink(self, telegram_user_id: int) -> bool:
        result = await self._post("/v1/bot/unlink", {"telegramUserId": telegram_user_id})
        self._remember(telegram_user_id, False)
        return bool(result.get("unlinked"))

    async def add_shifts(self, telegram_user_id: int, shifts: list[Shift]) -> tuple[list[Added], list[dict]]:
        try:
            result = await self._post("/v1/bot/shifts", {"telegramUserId": telegram_user_id,
                                                         "shifts": [shift_payload(s) for s in shifts]})
        except LinkError:
            self._status.pop(telegram_user_id, None)  # recheck the link next time (it may have been removed in the app)
            raise
        added = [Added(a.get("id", ""), a["event"], a.get("location", ""), a["day"], a["startMinute"], a["endMinute"],
                       a.get("breakMinutes", 0), Decimal(str(a["pay"])), a["currency"]) for a in result["added"]]
        return added, result.get("clashes", [])

    async def undo(self, telegram_user_id: int, ids: list[str]) -> int:
        return (await self._post("/v1/bot/shifts/undo", {"telegramUserId": telegram_user_id, "ids": ids}))["changed"]

    async def mark_paid(self, telegram_user_id: int, ids: list[str]) -> int:
        return (await self._post("/v1/bot/shifts/paid", {"telegramUserId": telegram_user_id, "ids": ids}))["changed"]

    async def summary(self, telegram_user_id: int, days: int = 14) -> dict:
        return await self._post("/v1/bot/summary", {"telegramUserId": telegram_user_id, "days": days})
