"""Parsing of free-form shift entries like "12/8 6pm-11.30pm Wedding gig"."""

from __future__ import annotations

import re
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta


class ParseError(ValueError):
    pass


@dataclass(frozen=True)
class Break:
    hours: float
    paid: bool

    @property
    def unpaid_hours(self) -> float:
        return 0.0 if self.paid else self.hours


NO_BREAK = Break(hours=0.0, paid=True)


@dataclass(frozen=True)
class Shift:
    day: date
    start: time
    end: time
    event: str
    rest: Break = NO_BREAK
    break_specified: bool = False

    @property
    def gross_hours(self) -> float:
        start_dt = datetime.combine(self.day, self.start)
        end_dt = datetime.combine(self.day, self.end)
        if end_dt <= start_dt:
            end_dt += timedelta(days=1)
        return (end_dt - start_dt).total_seconds() / 3600

    @property
    def hours(self) -> float:
        """Paid hours: elapsed time minus any unpaid break."""
        return max(self.gross_hours - self.rest.unpaid_hours, 0.0)

    def with_break(self, rest: Break) -> "Shift":
        return replace(self, rest=rest, break_specified=True)


_DATE_FORMATS = (
    "%Y-%m-%d",
    "%Y/%m/%d",
    "%d-%m-%Y",
    "%d/%m/%Y",
    "%d-%m-%y",
    "%d/%m/%y",
    "%d-%m",
    "%d/%m",
    "%d %b %Y",
    "%d %B %Y",
    "%d %b",
    "%d %B",
)

_TIME_RE = re.compile(
    r"^(?P<hour>\d{1,2})(?:[:.](?P<minute>\d{2}))?\s*(?P<ampm>am|pm)?$",
    re.IGNORECASE,
)

_RANGE_SEPARATORS = ("-", "–", "—", "to", "till", "until")


def parse_date(token: str, today: date) -> date:
    lowered = token.strip().lower()
    if lowered == "today":
        return today
    if lowered == "yesterday":
        return today - timedelta(days=1)
    if lowered == "tomorrow":
        return today + timedelta(days=1)
    for fmt in _DATE_FORMATS:
        try:
            parsed = datetime.strptime(token, fmt)
        except ValueError:
            continue
        if "%y" not in fmt.lower():
            return parsed.date().replace(year=today.year)
        return parsed.date()
    raise ParseError(f"Could not read a date from {token!r}.")


def parse_time(token: str) -> time:
    match = _TIME_RE.match(token.strip())
    if not match:
        raise ParseError(f"Could not read a time from {token!r}.")
    hour = int(match.group("hour"))
    minute = int(match.group("minute") or 0)
    ampm = (match.group("ampm") or "").lower()
    if ampm:
        if not 1 <= hour <= 12:
            raise ParseError(f"{token!r} is not a valid 12-hour time.")
        hour = hour % 12 + (12 if ampm == "pm" else 0)
    if hour == 24 and minute == 0:
        hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ParseError(f"{token!r} is not a valid time.")
    return time(hour, minute)


def _split_tokens(text: str) -> list[str]:
    """Split into [date, start, end, *event] without breaking up an ISO date."""
    parts = text.strip().split(maxsplit=1)
    if len(parts) < 2:
        return parts
    date_token, remainder = parts
    for separator in _RANGE_SEPARATORS:
        if separator.isalpha():
            remainder = re.sub(rf"\s+{separator}\s+", " ", remainder, flags=re.IGNORECASE)
        else:
            remainder = remainder.replace(separator, " ")
    return [date_token, *remainder.split()]


_NO_BREAK_RE = re.compile(r"\b(?:no|without|zero)\s+break\b", re.IGNORECASE)

_BREAK_RE = re.compile(
    r"""
    \b(?:with\s+)?
    (?:(?P<paid_before>un\s*paid|paid)\s+)?
    (?:break\s+of\s+)?
    (?P<amount>\d+(?:[.:]\d+)?)\s*
    (?P<unit>hours|hour|hrs|hr|h|minutes|minute|mins|min|m)\b
    \s*(?:(?P<paid_after>un\s*paid|paid)\s*)?
    (?:\s*break)
    \s*(?P<paid_trailing>un\s*paid|paid)?\b
    """,
    re.IGNORECASE | re.VERBOSE,
)

_MINUTE_UNITS = {"minutes", "minute", "mins", "min", "m"}


def _break_hours(amount: str, unit: str) -> float:
    if ":" in amount:
        hours, minutes = amount.split(":", 1)
        return int(hours) + int(minutes) / 60
    value = float(amount)
    return value / 60 if unit.lower() in _MINUTE_UNITS else value


def extract_break(text: str, default_paid: bool = False) -> tuple[str, Break | None]:
    """Pull a break phrase (e.g. "1h unpaid break") out of the message."""
    no_break = _NO_BREAK_RE.search(text)
    if no_break:
        return _NO_BREAK_RE.sub(" ", text, count=1), NO_BREAK
    match = _BREAK_RE.search(text)
    if not match:
        return text, None
    marker = (
        match.group("paid_before") or match.group("paid_after") or match.group("paid_trailing")
    )
    paid = default_paid if marker is None else not marker.lower().replace(" ", "").startswith("un")
    rest = Break(hours=_break_hours(match.group("amount"), match.group("unit")), paid=paid)
    return text[: match.start()] + " " + text[match.end() :], rest


def parse_shift(
    text: str, today: date | None = None, default_break_paid: bool = False
) -> Shift:
    """Parse "<date> <start> <end> <event name>" with forgiving formats."""
    today = today or date.today()
    text, rest = extract_break(text, default_paid=default_break_paid)
    tokens = _split_tokens(text)
    if len(tokens) < 4:
        raise ParseError(
            "Send it as: <date> <start> <end> <event>, e.g. `12/8 6pm-11.30pm Wedding gig`."
        )
    day = parse_date(tokens[0], today)
    start = parse_time(tokens[1])
    end = parse_time(tokens[2])
    event = " ".join(tokens[3:]).strip(" ,;-")
    if not event:
        raise ParseError("Please include an event name.")
    shift = Shift(day=day, start=start, end=end, event=event)
    return shift if rest is None else shift.with_break(rest)
