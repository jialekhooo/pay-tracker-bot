"""Turn stored shifts into calendar entries (.ics file and Google Calendar links)."""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Iterable
from urllib.parse import quote

from .pay import format_hours
from .schedule import span
from .storage import ShiftRecord

PRODID = "-//pay-tracker-bot//EN"


def _stamp(moment: datetime) -> str:
    return moment.strftime("%Y%m%dT%H%M%S")


def _escape(text: str) -> str:
    """Escape the characters iCalendar treats specially."""
    for old, new in (("\\", "\\\\"), (";", "\\;"), (",", "\\,"), ("\n", "\\n")):
        text = text.replace(old, new)
    return text


def _fold(line: str) -> list[str]:
    """iCalendar lines must be at most 75 octets; continuations start with a space."""
    chunks = [line[:73]]
    remainder = line[73:]
    while remainder:
        chunks.append(" " + remainder[:72])
        remainder = remainder[72:]
    return chunks


def event_title(record: ShiftRecord) -> str:
    return record.event if not record.location else f"{record.event} @ {record.location}"


def description(record: ShiftRecord) -> str:
    parts = [f"{format_hours(record.hours)}h", f"{record.currency} {record.pay:,.2f}"]
    if record.break_hours > 0:
        parts.append(
            f"{format_hours(record.break_hours)}h "
            f"{'paid' if record.break_paid else 'unpaid'} break"
        )
    return " · ".join(parts) + f" (shift #{record.id})"


def to_ics(records: Iterable[ShiftRecord], now: datetime | None = None) -> str:
    """A VCALENDAR of the shifts, in floating local time so any calendar app works."""
    created = _stamp(now or datetime.now())
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        f"PRODID:{PRODID}",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:Work shifts",
        "REFRESH-INTERVAL;VALUE=DURATION:PT1H",
        "X-PUBLISHED-TTL:PT1H",
    ]
    for record in records:
        start, end = span(record.day, record.start, record.end)
        lines.extend(
            [
                "BEGIN:VEVENT",
                f"UID:shift-{record.id}-{record.day.isoformat()}@pay-tracker-bot",
                f"DTSTAMP:{created}Z",
                f"DTSTART:{_stamp(start)}",
                f"DTEND:{_stamp(end)}",
                f"SUMMARY:{_escape(event_title(record))}",
                f"DESCRIPTION:{_escape(description(record))}",
            ]
        )
        if record.location:
            lines.append(f"LOCATION:{_escape(record.location)}")
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    return "\r\n".join(folded for line in lines for folded in _fold(line)) + "\r\n"


def google_link(record: ShiftRecord, utc_offset_minutes: int) -> str:
    """A "add to Google Calendar" URL; Google wants the times in UTC."""
    start, end = span(record.day, record.start, record.end)
    offset = timedelta(minutes=utc_offset_minutes)
    params = [
        ("action", "TEMPLATE"),
        ("text", event_title(record)),
        ("dates", f"{_stamp(start - offset)}Z/{_stamp(end - offset)}Z"),
        ("details", description(record)),
        ("location", record.location),
    ]
    query = "&".join(f"{key}={quote(value, safe='')}" for key, value in params if value)
    return f"https://calendar.google.com/calendar/render?{query}"
