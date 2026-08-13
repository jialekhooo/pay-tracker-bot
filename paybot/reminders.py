"""Day-before reminders for booked shifts."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Iterable

from .storage import Reminder

DEFAULT_SEND_AT = "20:00"
DEFAULT_UTC_OFFSET_MINUTES = 480  # UTC+8


def local_now(reminder: Reminder, now_utc: datetime) -> datetime:
    return now_utc + timedelta(minutes=reminder.utc_offset_minutes)


def local_clock(utc_offset_minutes: int, now_utc: datetime | None = None) -> datetime:
    """The current time in the user's timezone — the server clock runs on UTC."""
    now = now_utc or datetime.now(timezone.utc).replace(tzinfo=None)
    return now + timedelta(minutes=utc_offset_minutes)


def local_today(utc_offset_minutes: int, now_utc: datetime | None = None) -> date:
    """The current date in the user's timezone."""
    return local_clock(utc_offset_minutes, now_utc).date()


def due(reminder: Reminder, now_utc: datetime) -> date | None:
    """The day to remind about, or None when this reminder isn't due yet."""
    now = local_now(reminder, now_utc)
    if not reminder.enabled or reminder.last_sent_on == now.date():
        return None
    if (now.hour, now.minute) < (reminder.send_at.hour, reminder.send_at.minute):
        return None
    return now.date() + timedelta(days=1)


def due_reminders(
    reminders: Iterable[Reminder], now_utc: datetime
) -> list[tuple[Reminder, date]]:
    pairs = ((reminder, due(reminder, now_utc)) for reminder in reminders)
    return [(reminder, day) for reminder, day in pairs if day is not None]


def parse_offset(raw: str) -> int:
    """Read a timezone offset such as "+8", "8", "-5.5" or "+05:30" as minutes."""
    text = raw.strip().lstrip("+")
    sign = -1 if text.startswith("-") else 1
    text = text.lstrip("-")
    if ":" in text:
        hours, minutes = text.split(":", 1)
    elif "." in text:
        hours, fraction = text.split(".", 1)
        minutes = str(int(round(float(f"0.{fraction}") * 60)))
    else:
        hours, minutes = text, "0"
    if not hours.isdigit() or not minutes.isdigit():
        raise ValueError(f"Could not read a timezone offset from {raw!r}.")
    total = sign * (int(hours) * 60 + int(minutes))
    if not -12 * 60 <= total <= 14 * 60:
        raise ValueError(f"{raw!r} is not a valid timezone offset.")
    return total


def format_offset(minutes: int) -> str:
    sign = "-" if minutes < 0 else "+"
    hours, remainder = divmod(abs(minutes), 60)
    return f"UTC{sign}{hours}" + (f":{remainder:02d}" if remainder else "")
