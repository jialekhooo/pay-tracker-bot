"""Parsing of free-form shift entries like "12/8 6pm-11.30pm Wedding gig"."""

from __future__ import annotations

import re
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta
from decimal import Decimal, InvalidOperation


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
    rate_override: Decimal | None = None

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


_RATE_RE = re.compile(
    r"""
    (?:\$|[A-Z]{3}\s*)?
    (?P<amount>\d+(?:\.\d+)?)
    \s*(?:/|\s+per\s+)\s*
    (?:h|hr|hrs|hour|hourly)\b
    """,
    re.IGNORECASE | re.VERBOSE,
)


def extract_rate(text: str) -> tuple[str, Decimal | None]:
    """Pull an inline hourly rate (e.g. "15/h", "$20 per hour") out of the message."""
    match = _RATE_RE.search(text)
    if not match:
        return text, None
    try:
        rate = Decimal(match.group("amount"))
    except InvalidOperation:
        return text, None
    return text[: match.start()] + " " + text[match.end() :], rate


_DATE_CANDIDATE_RE = re.compile(
    r"""
    \b(?:
        today|yesterday|tomorrow
        | \d{4}[-/]\d{1,2}[-/]\d{1,2}
        | \d{1,2}[-/]\d{1,2}(?:[-/]\d{2,4})?
        | \d{1,2}\s+[A-Za-z]{3,9}(?:\s+\d{4})?
    )\b
    """,
    re.IGNORECASE | re.VERBOSE,
)

_TIME_RANGE_RE = re.compile(
    r"""
    \b(?P<start>\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?)
    \s*(?:-|–|—|to|till|until|\s)\s*
    (?P<end>\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?)\b
    """,
    re.IGNORECASE | re.VERBOSE,
)


def _parse_anywhere(text: str, today: date) -> tuple[date, time, time, str]:
    """Find the date, the time range and the event name wherever they appear."""
    for date_match in _DATE_CANDIDATE_RE.finditer(text):
        try:
            day = parse_date(date_match.group(0), today)
        except ParseError:
            continue
        remainder = text[: date_match.start()] + "\x00" + text[date_match.end() :]
        for time_match in _TIME_RANGE_RE.finditer(remainder):
            try:
                start = parse_time(time_match.group("start"))
                end = parse_time(time_match.group("end"))
            except ParseError:
                continue
            event = remainder[: time_match.start()] + " " + remainder[time_match.end() :]
            event = re.sub(r"\s{2,}", " ", event.replace("\x00", " ")).strip(" ,;-–—")
            if event:
                return day, start, end, event
    raise ParseError(
        "Send it as: <event> <date> <start>-<end> <rate>, "
        "e.g. `Wedding gig 12/8 6pm-11.30pm 25/h`."
    )


def parse_shift(
    text: str, today: date | None = None, default_break_paid: bool = False
) -> Shift:
    """Parse a line holding a date, a time range and an event name, in any order."""
    today = today or date.today()
    text, rate_override = extract_rate(text)
    text, rest = extract_break(text, default_paid=default_break_paid)
    tokens = _split_tokens(text)
    day: date | None = None
    start: time | None = None
    end: time | None = None
    event = ""
    if len(tokens) >= 4:
        try:
            day = parse_date(tokens[0], today)
            start = parse_time(tokens[1])
            end = parse_time(tokens[2])
            event = " ".join(tokens[3:]).strip(" ,;-")
        except ParseError:
            day = None
    if day is None or start is None or end is None or not event:
        day, start, end, event = _parse_anywhere(text, today)
    shift = Shift(day=day, start=start, end=end, event=event, rate_override=rate_override)
    return shift if rest is None else shift.with_break(rest)


def parse_shifts(
    text: str, today: date | None = None, default_break_paid: bool = False
) -> list[tuple[str, Shift | ParseError]]:
    """Parse one shift per non-empty line, keeping per-line errors."""
    results: list[tuple[str, Shift | ParseError]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip().lstrip("-\u2022*").strip()
        if not line:
            continue
        try:
            results.append((line, parse_shift(line, today, default_break_paid)))
        except ParseError as exc:
            results.append((line, exc))
    return results
