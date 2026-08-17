"""Parsing of free-form plan lines like "9am-11am Gym" or "tomorrow 3pm dentist"."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta


class ParseError(ValueError):
    pass


@dataclass(frozen=True)
class Entry:
    """One thing to do: timed when it has a start, a plain task when it doesn't."""

    day: date
    title: str
    start: time | None = None
    end: time | None = None

    @property
    def timed(self) -> bool:
        return self.start is not None


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

_WEEKDAYS = {
    "mon": 0, "monday": 0,
    "tue": 1, "tues": 1, "tuesday": 1,
    "wed": 2, "weds": 2, "wednesday": 2,
    "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
    "fri": 4, "friday": 4,
    "sat": 5, "saturday": 5,
    "sun": 6, "sunday": 6,
}

_MILITARY_TIME = r"(?:[01]\d|2[0-3])[0-5]\d"

_MILITARY_TIME_RE = re.compile(r"^(?P<hour>\d{2})(?P<minute>\d{2})\s*(?:h|hrs|hours)?$", re.I)

_TIME_RE = re.compile(r"^(?P<hour>\d{1,2})(?:[:.](?P<minute>\d{2}))?\s*(?P<ampm>am|pm)?$", re.I)

_DATE_CANDIDATE_RE = re.compile(
    r"""
    \b(?:
        today|tonight|tomorrow|yesterday
        | (?:next\s+|this\s+)?(?:mon|tues?|weds?|thur?s?|fri|sat|sun)(?:day)?
        | \d{4}[-/]\d{1,2}[-/]\d{1,2}
        | \d{1,2}[-/]\d{1,2}(?:[-/]\d{2,4})?
        | \d{1,2}\s+[A-Za-z]{3,9}(?:\s+\d{4})?
    )\b
    """,
    re.IGNORECASE | re.VERBOSE,
)

_TIME_RANGE_RE = re.compile(
    rf"""
    \b(?P<start>{_MILITARY_TIME}|\d{{1,2}}(?:[:.]\d{{2}})?\s*(?:am|pm)?)
    \s*(?:-|–|—|to|till|until)\s*
    (?P<end>{_MILITARY_TIME}|\d{{1,2}}(?:[:.]\d{{2}})?\s*(?:am|pm)?)\b
    """,
    re.IGNORECASE | re.VERBOSE,
)

_SINGLE_TIME_RE = re.compile(
    rf"""
    (?:\bat\s+)?
    \b(?P<at>{_MILITARY_TIME}h?|\d{{1,2}}(?:[:.]\d{{2}})?\s*(?:am|pm)|\d{{1,2}}[:.]\d{{2}})\b
    """,
    re.IGNORECASE | re.VERBOSE,
)


def parse_date(token: str, today: date) -> date:
    """A date written as a word, a weekday or numbers."""
    lowered = " ".join(token.strip().lower().split())
    if lowered in {"today", "tonight"}:
        return today
    if lowered == "tomorrow":
        return today + timedelta(days=1)
    if lowered == "yesterday":
        return today - timedelta(days=1)
    weekday = lowered.removeprefix("next ").removeprefix("this ").strip()
    if weekday in _WEEKDAYS:
        ahead = (_WEEKDAYS[weekday] - today.weekday()) % 7
        if ahead == 0 and lowered.startswith("next "):
            ahead = 7
        return today + timedelta(days=ahead)
    for fmt in _DATE_FORMATS:
        try:
            parsed = datetime.strptime(token.strip(), fmt)
        except ValueError:
            continue
        if "%y" not in fmt.lower():
            guess = parsed.date().replace(year=today.year)
            return guess
        return parsed.date()
    raise ParseError(f"Could not read a date from {token!r}.")


def parse_time(token: str) -> time:
    """A time written as 0900, 9am, 9.30pm or 21:30."""
    text = token.strip().rstrip("h")
    military = _MILITARY_TIME_RE.match(text)
    if military:
        hour, minute = int(military.group("hour")), int(military.group("minute"))
        if not (0 <= hour <= 23 and 0 <= minute <= 59):
            raise ParseError(f"{token!r} is not a valid time.")
        return time(hour, minute)
    match = _TIME_RE.match(text)
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


def _tidy(text: str) -> str:
    return re.sub(r"\s{2,}", " ", text).strip(" ,;-–—")


def _take_date(text: str, today: date) -> tuple[str, date | None]:
    for match in _DATE_CANDIDATE_RE.finditer(text):
        try:
            day = parse_date(match.group(0), today)
        except ParseError:
            continue
        return text[: match.start()] + " " + text[match.end() :], day
    return text, None


def _take_times(text: str) -> tuple[str, time | None, time | None]:
    span = _TIME_RANGE_RE.search(text)
    if span:
        try:
            start = parse_time(span.group("start"))
            end = parse_time(span.group("end"))
        except ParseError:
            start = end = None
        if start is not None and end is not None:
            return text[: span.start()] + " " + text[span.end() :], start, end
    point = _SINGLE_TIME_RE.search(text)
    if point:
        try:
            start = parse_time(point.group("at"))
        except ParseError:
            return text, None, None
        return text[: point.start()] + " " + text[point.end() :], start, None
    return text, None, None


def parse_entry(text: str, today: date | None = None) -> Entry:
    """Read one line: a title, plus a date and times wherever they sit in it."""
    today = today or date.today()
    rest, day = _take_date(text, today)
    rest, start, end = _take_times(rest)
    title = _tidy(rest.replace("  ", " "))
    title = re.sub(r"^(?:at|on|from)\b\s*", "", title, flags=re.IGNORECASE).strip(" ,;-–—")
    if not title:
        raise ParseError("Tell me what the plan is, e.g. `9am-11am Gym`.")
    return Entry(day=day or today, title=title, start=start, end=end)


def parse_entries(text: str, today: date | None = None) -> list[tuple[str, Entry | ParseError]]:
    """One plan per non-empty line, keeping each line's error to itself."""
    results: list[tuple[str, Entry | ParseError]] = []
    for raw in text.splitlines():
        line = raw.strip().lstrip("-•*").strip()
        if not line:
            continue
        try:
            results.append((line, parse_entry(line, today)))
        except ParseError as exc:
            results.append((line, exc))
    return results
