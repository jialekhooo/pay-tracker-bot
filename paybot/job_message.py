"""Read a whole forwarded job post (WhatsApp, Telegram, email) into shifts.

A Python port of JobMessageParser in ios/Sources/HowMuchCore/JobMessage.swift. `parse_message`
is the bot's entry point: one-line shift commands still go through parsing.parse_shifts, and
anything else is read as a whole post.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field, replace
from datetime import date, time, timedelta
from decimal import Decimal, InvalidOperation

from .parsing import Break, ParseError, Shift, parse_shifts
from .pay import round_money

MAXIMUM_LENGTH = 5000
MAXIMUM_DATES = 100


@dataclass(frozen=True)
class JobDate:
    day: date
    start_minute: int
    end_minute: int


@dataclass
class PastedJob:
    event: str | None = None
    location: str | None = None
    rate: Decimal | None = None
    fixed_pay: Decimal | None = None
    currency: str | None = None
    break_minutes: int | None = None
    break_paid: bool | None = None
    # The job brief, when the message states it. Only shifts sent on to the HowMuch app keep it.
    call_minute: int | None = None
    dress_code: str | None = None
    contact: str | None = None
    dates: list[JobDate] = field(default_factory=list)
    lump_sum: Decimal | None = None
    no_time: list[date] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    @property
    def name(self) -> str:
        if self.event:
            return self.event
        if self.location:
            return self.location.split(",")[0].strip()
        return ""


@dataclass
class _Item:
    days: list[date]
    time: tuple[int, int] | None


@dataclass
class _Found:
    start: int
    end: int
    days: list[date]


@dataclass(frozen=True)
class _Clock:
    hour: int
    minute: int
    twenty_four: bool


def _lower(text: str) -> str:
    # Positions in the lowered line must match the original, so nothing may change length.
    return "".join(c.lower() if len(c.lower()) == 1 else c for c in text)


def _blank(text: str, start: int, end: int) -> str:
    return text[:start] + " " * (end - start) + text[end:]


# Emoji and pictographs, with joiners and variation selectors. Keycaps are left alone.
_DECORATION = re.compile(
    "[‼⁉™ℹ←-⇿⌀-⏿Ⓜ■-➿⤀-⥿"
    "⬀-⯿〰〽㊗㊙️‍\U0001f000-\U0001faff\U000e0020-\U000e007f]"
)


def _strip_edges(value: str, extra: str = "") -> str:
    def trims(char: str) -> bool:
        return bool(_DECORATION.fullmatch(char)) or char.isspace() or char in extra

    begin, end = 0, len(value)
    while begin < end and trims(value[begin]):
        begin += 1
    while end > begin and trims(value[end - 1]):
        end -= 1
    return value[begin:end]


def _clean(value: str) -> str | None:
    return _strip_edges(value, " ,.;-") or None


_LINE_EDGE = re.compile(r"^[\s\-•*>·]+|[\s\-•*>·]+$")
_PIN = re.compile("^[\U0001f4cd\U0001f4cc]️?\\s*(.+)$")
_LABEL = re.compile(r"^([A-Za-z][A-Za-z ]{0,20}?)\s*:\s*(.*)$")
_DAY_PREFIX = re.compile(
    r"^((?:\d{1,2}(?:st|nd|rd|th)?\s*(?:,|&|and|-|to|/)\s*)*\d{1,2}(?:st|nd|rd|th)?)\s*:(?!\d)\s*(.+)$",
    re.IGNORECASE,
)
_GREETING = re.compile(
    r"^(hi|hello|hey|dear|urgent|good\s+(morning|afternoon|evening)|thank|thanks|pm|dm|whatsapp|text"
    r"|looking|hiring|need|needed|seeking|urgently|anyone|available|calling)\b",
    re.IGNORECASE,
)
_RECRUITING = re.compile(r"\b(needed|wanted|required|hiring|urgent|urgently)\b", re.IGNORECASE)
_FOR = re.compile(r"\bfor\b", re.IGNORECASE)

_LABELS = {
    "location": ("location", "venue", "place", "loc", "where", "site"),
    "address": ("address", "addr"),
    "event": ("event", "event name", "job", "project", "show", "campaign", "brand", "client", "title"),
    "role": ("role", "position", "job scope", "scope"),
    "schedule": ("date", "dates", "day", "days", "time", "timing", "timings", "schedule", "when",
                 "working hours", "hours", "shift", "shifts"),
    "break": ("break", "breaks", "lunch", "lunch break", "meal break"),
    "pay": ("pay", "rate", "pay rate", "salary", "wage", "wages", "remuneration", "payment"),
    "call": ("reporting time", "report time", "call time"),
    "dress": ("attire", "dress code", "dresscode"),
    "contact": ("contact", "contact person", "contact no", "pic", "poc", "phone", "tel", "hp", "mobile"),
}
_LABEL_OF = {key: kind for kind, keys in _LABELS.items() for key in keys}
# Other details like these are deliberately not used.
_IGNORED_LABELS = frozenset((
    "name", "email", "remarks", "remark", "note", "notes", "requirements", "requirement",
    "meal", "meals", "gender", "age", "pax", "headcount", "deadline",
))
BRIEF_TEXT_LIMIT = 120
_CALL_TIME = re.compile(r"\b(\d{4}|\d{1,2}(?:[:.]\d{2})?)\s*(am|pm)?\b", re.IGNORECASE)


def _call_time(value: str) -> tuple[int, bool] | None:
    """One clock time, such as "8.30am" or "0830", and whether it was bare. "30 mins before" is not one."""
    lower = value.lower()
    if any(word in lower for word in ("before", "prior", "min", "hour", "hr")):
        return None
    match = _CALL_TIME.search(lower)
    clock = _clock(match.group(1)) if match else None
    if clock is None:
        return None
    if match.group(2) is None or clock.twenty_four:
        return clock.hour * 60 + clock.minute, not clock.twenty_four
    if not 1 <= clock.hour <= 12:
        return None
    return (clock.hour % 12 + (12 if match.group(2).lower() == "pm" else 0)) * 60 + clock.minute, False


def _normalized(text: str) -> str:
    for old, new in (("\r\n", "\n"), ("\r", "\n"), ("–", "-"), ("—", "-"), (" ", " "),
                     ("：", ":"), ("*", ""), ("_", " ")):
        text = text.replace(old, new)
    return text


def _label(line: str) -> tuple[str, str] | None:
    match = _LABEL.match(line)
    if match is None:
        return None
    key = match.group(1).lower().strip()
    value = match.group(2).strip()
    kind = _LABEL_OF.get(key)
    if kind is not None:
        return ("ignored", value) if not value else (kind, value)
    return ("ignored", value) if key in _IGNORED_LABELS else None


def _day_prefix(line: str) -> tuple[list[int], str] | None:
    """'19th:', '21,22nd:', '12 & 13:', '21-22:' at the start of a line. '10:00' is never a day."""
    match = _DAY_PREFIX.match(line)
    if match is None:
        return None
    days: list[int] = []
    range_next = False
    for token in re.findall(r"\d+|-|\bto\b|(?<=\d)to\b", match.group(1).lower()):
        if not token.isdigit():
            range_next = True
            continue
        value = int(token)
        if range_next and days and days[-1] < value <= days[-1] + 31:
            days.extend(range(days[-1] + 1, value + 1))
        else:
            days.append(value)
        range_next = False
    valid = [day for day in days if 1 <= day <= 31]
    return (valid, match.group(2)) if valid else None


def _is_recruiting_only(line: str) -> bool:
    return _RECRUITING.search(line) is not None and _FOR.search(line) is None


def _is_intro(line: str) -> bool:
    return _GREETING.search(line) is not None or _is_recruiting_only(line)


_BREAK_UNITS = "h|hr|hrs|hour|hours|m|min|mins|minutes"
_BREAK_LENGTH = re.compile(rf"(\d+(?:\.\d+)?)\s*({_BREAK_UNITS})\b")
_BREAK_IN_LINE = re.compile(
    r"(?:(un\s*paid|paid)\s+)?"
    rf"(\d+(?:\.\d+)?\s*(?:{_BREAK_UNITS}))\s*"
    r"(?:(un\s*paid|paid)\s*)?(?:lunch\s*|meal\s*)?break(?:\s+(un\s*paid|paid)\b)?"
)
_PAID_WORD = re.compile(r"\b(un\s*paid|paid)\b")


def _break_length(text: str) -> int | None:
    match = _BREAK_LENGTH.search(text.lower())
    if match is None:
        return None
    value = float(match.group(1))
    minutes = int((value * 60 if match.group(2).startswith("h") else value) + 0.5)
    return minutes if 1 <= minutes < 720 else None


def _is_paid(marker: str | None) -> bool | None:
    return None if marker is None else not marker.startswith("un")


_MONEY = (
    r"(?:(sgd|s\$|usd|myr|rm|\$)\s*)?((?:\d{1,3}(?:,\d{3})+|\d{1,5})(?:\.\d{1,2})?)(?![\d,]*\d)\s*(sgd)?"
)
_LUMP_BEFORE = r"(?:flat|lump\s*sum|total)\s*(?:of\s*)?"
# (pattern, kind, needs a currency symbol): a bare number is pay only when its unit says so.
_PAY_PATTERNS = (
    (re.compile(_MONEY + r"\s*(?:/\s*|per\s+|an?\s+|p/)(?:h|hr|hrs|hour)\b"), "hourly", False),
    (re.compile(_MONEY + r"\s*(?:hourly|ph)\b"), "hourly", False),
    (re.compile(_MONEY + r"\s*(?:/\s*|per\s+|a\s+)(?:day|d|shift)\b"), "day", False),
    (re.compile(_MONEY + r"\s*(?:flat|lump\s*sum|total|nett|net|in\s+total)\b"), "flat", True),
    # The bot's own one-line format has always taken "200 flat" and "200 fixed" with no currency.
    (re.compile(_MONEY + r"\s*(?:flat|fixed|lump[\s-]*sum)\b"), "flat", False),
    (re.compile(_LUMP_BEFORE + _MONEY), "flat", True),
)
_CURRENCIES = {"sgd": "SGD", "s$": "SGD", "usd": "USD", "myr": "MYR", "rm": "MYR"}


def _read_pay(line: str) -> tuple[str, tuple[str, Decimal, str | None] | None]:
    for pattern, kind, needs_symbol in _PAY_PATTERNS:
        match = pattern.search(line)
        if match is None:
            continue
        try:
            amount = Decimal(match.group(2).replace(",", ""))
        except InvalidOperation:
            continue
        symbol = match.group(1) or match.group(3)
        if symbol is None and needs_symbol:
            continue
        return _blank(line, match.start(), match.end()), (kind, amount, _CURRENCIES.get(symbol or ""))
    return line, None


_MONTHS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
_MONTH = r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)(?:uary|ruary|ch|il|e|y|ust|t|tember|ober|ember|\.)?"
_DAY = r"(\d{1,2})(?:st|nd|rd|th)?"
_JOINER = r"\s*(?:-|to|till|until|&|and|,|/)\s*"

_WEEKDAYS_BETWEEN = re.compile(
    r"\(?\b(?:mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sun)(?:day|sday|nesday|rsday|urday)?\b\.?\)?"
)
_WEEKDAY_WORDS = re.compile(
    r"\(?\b(mon|monday|tue|tues|tuesday|wed|weds|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)\b\)?"
)
_ISO_DATE = re.compile(r"\b(\d{4})-(\d{1,2})-(\d{1,2})\b")
_DAY_MONTH = re.compile(
    r"\b" + _DAY + "((?:" + _JOINER + _DAY + r")*)\s*(?:of\s+)?" + _MONTH + r"\b(?:\s*,?\s*(20\d{2})\b)?"
)
# The list stops before a number that is really a time ("Nov 15, 10-6pm", "Nov 15, 10:00").
_MONTH_DAY = re.compile(
    r"\b" + _MONTH + r"\s+" + _DAY + r"\b((?:" + _JOINER + _DAY
    + r"\b(?!\s*(?:[:.]\d{2}|(?:-|to)\s*\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm|noon))))*)(?:\s*,?\s*(20\d{2})\b)?"
)
_DAY_SLASH_MONTH = re.compile(r"(?<![\d/.$])(\d{1,2})(?:\s*-\s*(\d{1,2}))?/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])")
_RELATIVE = re.compile(r"\b(today|tonight|tomorrow|tmr|tmrw|tml)\b")
_LONE_WEEKDAY = re.compile(r"\b(mon|tue|wed|thu|fri|sat|sun)(?:day|sday|nesday|rsday|urday|s|t|r|rs)?\b")
_RANGE_BETWEEN = re.compile(r"^\s*(-|to|till|until)\s*$")


def _make_date(year: int, month: int, day: int) -> date | None:
    if not 2000 <= year <= 2100:
        return None
    try:
        return date(year, month, day)
    except ValueError:
        return None


def _expand(listed: str, month: int, year: int | None, today: date) -> list[date] | None:
    """'13-14', '13, 14 & 16' or '12' as dates of one month."""
    days: list[int] = []
    range_next = False
    for token in re.findall(r"\d+|-|to|till|until|,|&|and|/", listed.lower()):
        if not token.isdigit():
            range_next = token in ("-", "to", "till", "until")
            continue
        value = int(token)
        # Days in a list only go forwards; anything else isn't part of the date list.
        if days and value <= days[-1]:
            break
        if range_next and days and value - days[-1] <= 31:
            days.extend(range(days[-1] + 1, value + 1))
        else:
            days.append(value)
        range_next = False
    if not days:
        return None
    if year is None:
        first = _make_date(today.year, month, days[0])
        if first is None:
            return None
        # A date more than two months ago most likely means next year.
        year = today.year + 1 if first < today - timedelta(days=60) else today.year
    dates = [_make_date(year, month, day) for day in days]
    return None if None in dates else dates  # type: ignore[return-value]


def _read_dates(line: str, today: date) -> tuple[str, list[date]]:
    # Weekdays between the days ("Sat 21 & Sun 22 Nov", "21 (Sat), 22 (Sun) Nov") are blanked out
    # for reading dates, keeping every position the same; a weekday alone still means the next one.
    dated = _WEEKDAYS_BETWEEN.sub(lambda m: " " * len(m.group(0)), line)
    found: list[_Found] = []

    def scan(pattern: re.Pattern[str], text: str, build) -> None:
        for match in pattern.finditer(text):
            if any(item.start < match.end() and match.start() < item.end for item in found):
                continue
            days = build(match)
            if days:
                found.append(_Found(match.start(), match.end(), days))

    def iso(match: re.Match[str]) -> list[date] | None:
        day = _make_date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
        return [day] if day else None

    def day_month(match: re.Match[str]) -> list[date] | None:
        month = _MONTHS.index(match.group(4)) + 1
        year = int(match.group(5)) if match.group(5) else None
        return _expand(dated[match.start():match.start(4)], month, year, today)

    def month_day(match: re.Match[str]) -> list[date] | None:
        month = _MONTHS.index(match.group(1)) + 1
        year = int(match.group(5)) if match.group(5) else None
        return _expand(match.group(2) + (match.group(3) or ""), month, year, today)

    def slash(match: re.Match[str]) -> list[date] | None:
        first, month = int(match.group(1)), int(match.group(3))
        if not 1 <= month <= 12:
            return None
        year = int(match.group(4)) if match.group(4) else None
        if year is not None and year < 100:
            year += 2000
        last = int(match.group(2)) if match.group(2) else first
        return _expand(f"{first}-{last}", month, year, today)

    def relative(match: re.Match[str]) -> list[date]:
        return [today if match.group(1) in ("today", "tonight") else today + timedelta(days=1)]

    def lone_weekday(match: re.Match[str]) -> list[date]:
        target = ("mon", "tue", "wed", "thu", "fri", "sat", "sun").index(match.group(1))
        return [today + timedelta(days=(target - today.weekday()) % 7)]

    scan(_ISO_DATE, dated, iso)
    scan(_DAY_MONTH, dated, day_month)
    scan(_MONTH_DAY, dated, month_day)
    scan(_DAY_SLASH_MONTH, dated, slash)
    scan(_RELATIVE, dated, relative)
    if not found:
        scan(_LONE_WEEKDAY, line, lone_weekday)

    # "30 Nov - 2 Dec" or "12/8 to 14/8": two single dates joined by a range word.
    found.sort(key=lambda item: item.start)
    merged: list[_Found] = []
    for item in found:
        previous = merged[-1] if merged else None
        if (
            previous is not None and len(previous.days) == 1 and len(item.days) == 1
            and _RANGE_BETWEEN.match(dated[previous.end:item.start])
            and 0 < (item.days[0] - previous.days[0]).days <= 31
        ):
            span = (item.days[0] - previous.days[0]).days
            merged[-1] = _Found(previous.start, item.end, [previous.days[0] + timedelta(days=n) for n in range(span + 1)])
        else:
            merged.append(item)
    for item in found:
        line = _blank(line, item.start, item.end)
    # Remove weekday words such as "(Wed)" so they are not read as names.
    line = _WEEKDAY_WORDS.sub(lambda m: " " * len(m.group(0)), line)
    return line, [day for item in merged for day in item.days]


_TOKEN = r"(\d{4}|\d{1,2}(?:[:.]\d{2})?)\s*(am|pm|a\.m\.|p\.m\.|noon)?"
_TIME_PATTERNS = (
    re.compile(r"(?<![\d/.$])" + _TOKEN + r"\s*(?:hrs?|h)?\s*(?:-|to|till|until)\s*" + _TOKEN + r"\s*(?:hrs?|h\b)?"),
    re.compile(r"(?<![\d/.$])(\d{1,2}:\d{2})()\s+(\d{1,2}:\d{2})()"),
)


def _clock(text: str | None) -> _Clock | None:
    if not text:
        return None
    if len(text) == 4 and text.isdigit():
        value = int(text)
        hour, minute = value // 100, value % 100
        return _Clock(hour % 24, minute, True) if hour <= 24 and minute < 60 else None
    parts = [int(part) for part in re.split(r"[:.]", text) if part.isdigit()]
    if not parts or parts[0] > 24:
        return None
    hour = parts[0]
    minute = parts[1] if len(parts) > 1 else 0
    if minute >= 60:
        return None
    # "06:00" or "06.30" (a leading zero) is written on a 24-hour clock, so it's the morning.
    twenty_four = hour > 12 or (":" in text and hour == 0) or (text.startswith("0") and len(text) > 1)
    return _Clock(hour % 24, minute, twenty_four)


def _minutes(clock: _Clock, pm: bool | None) -> int | None:
    if pm is None or clock.twenty_four:
        return clock.hour * 60 + clock.minute
    if clock.hour > 12:
        return None
    return (clock.hour % 12 + (12 if pm else 0)) * 60 + clock.minute


def _resolve(start: _Clock, start_suffix: str | None, end: _Clock, end_suffix: str | None) -> tuple[int, int] | None:
    def meridiem(suffix: str | None) -> bool | None:
        if not suffix:
            return None
        return suffix == "noon" or suffix.startswith("p")

    start_pm, end_pm = meridiem(start_suffix), meridiem(end_suffix)
    if start_pm is None and end_pm is not None and not start.twenty_four:
        # "9-5pm" starts in the morning; "6-11pm" starts in the evening.
        same, finish = _minutes(start, end_pm), _minutes(end, end_pm)
        start_pm = end_pm if same is not None and finish is not None and same < finish else not end_pm
    if end_pm is None and start_pm is not None and not end.twenty_four:
        same, begin = _minutes(end, start_pm), _minutes(start, start_pm)
        end_pm = start_pm if same is not None and begin is not None and same > begin else not start_pm
    first, last = _minutes(start, start_pm), _minutes(end, end_pm)
    if first is None or last is None:
        return None
    if start_pm is None and end_pm is None and not start.twenty_four and not end.twenty_four:
        # Plain "9-6" or "2-10": assume daytime work.
        # Except "6-12", which would otherwise run 18:00 to the next noon.
        if start.hour < 7 and end.hour != 12:
            first += 12 * 60
        # "6-2" is 18:00 to 02:00 overnight, not 18:00 to 14:00.
        if last <= first and last + 12 * 60 < 24 * 60 and last + 12 * 60 > first:
            last += 12 * 60
    if first == last or not (0 <= first < 1440 and 0 <= last < 1440):
        return None
    return first, last


def _read_time(line: str) -> tuple[str, tuple[int, int] | None]:
    for pattern in _TIME_PATTERNS:
        match = pattern.search(line)
        if match is None:
            continue
        first, second = _clock(match.group(1)), _clock(match.group(3))
        if first is None or second is None:
            continue
        resolved = _resolve(first, match.group(2) or None, second, match.group(4) or None)
        if resolved is None:
            continue
        return _blank(line, match.start(), match.end()), resolved
    return line, None


_AT = re.compile(r"(\s@\s*|@|\s+at\s+)", re.IGNORECASE)
_HIRING = re.compile(r"^.*?\b(?:wanted|needed|hiring|required|looking)\s+for\s+", re.IGNORECASE)
_FILLER = re.compile(
    r"\b(from|on|hrs?|h|daily|each day|shift|shifts|and|available|anyone|need|needed|looking|pax|for|hi|hello|hey|free)\b"
    r"|[()\[\]?!,&:]",
    re.IGNORECASE,
)


def _letters(text: str) -> int:
    return sum(char.isalpha() for char in text)


def _leftover(lower: str, original: str) -> tuple[str | None, str | None]:
    """The name and venue in what was not read as dates, times or pay, in the original capitals."""
    kept = "".join(" " if low == " " and char != " " else char for low, char in zip(lower, original))
    name, venue = kept, None
    at = _AT.search(kept)
    if at is not None:
        name, venue = kept[:at.start()], _clean(kept[at.end():])
    elif "|" in kept:
        # "Event crew for AI pop up | 19, 21 Nov | New Bahru": name first, venue last.
        parts = [part for part in (_clean(piece) for piece in kept.split("|")) if part]
        if len(parts) > 1:
            name, venue = parts[0], parts[-1]
    # "Event crew wanted for AI pop up" is about the AI pop up: drop the recruiting words in front.
    hiring = _HIRING.search(name)
    if hiring is not None and _letters(name[hiring.end():]) >= 3:
        name = name[hiring.end():]
    words = " ".join(_FILLER.sub(" ", name).split())
    return (_clean(words) if _letters(words) >= 3 else None), venue


def _heading(line: str) -> tuple[str, str | None] | None:
    """A short heading such as 'Nike Pop-up'. Greetings, questions, sentences and numbers are not."""
    if (
        len(line) > 60 or re.search(r"\d", line) or line.endswith("?")
        or _GREETING.search(line) or _is_recruiting_only(line)
    ):
        return None
    name, venue = _leftover(_lower(line), line)
    return None if name is None else (name, venue)


def parse_job_message(text: str, today: date | None = None) -> PastedJob:
    today = today or date.today()
    job = PastedJob()
    address: str | None = None
    role: str | None = None
    title: str | None = None
    title_venue: str | None = None
    only_intro_so_far = True
    items: list[_Item] = []
    flat: Decimal | None = None
    day_times: list[tuple[list[int], tuple[int, int]]] = []
    call_is_bare = False

    for raw in _normalized(text[:MAXIMUM_LENGTH]).split("\n"):
        line = _LINE_EDGE.sub("", raw)
        if not line:
            continue
        may_be_heading = only_intro_so_far
        if not _is_intro(line):
            only_intro_so_far = False
        content = line
        pin = _PIN.match(line)
        if pin is not None:
            if job.location is None:
                job.location = _clean(pin.group(1))
            continue
        prefix = _day_prefix(line)
        if prefix is not None:
            rest, listed = _read_dates(_lower(prefix[1]), today)
            if not listed:
                _, clock_range = _read_time(rest)
                if clock_range is not None:
                    day_times.append((prefix[0], clock_range))
                    continue
        labelled = _label(line)
        if labelled is not None:
            kind, value = labelled
            if kind == "location":
                job.location = job.location if job.location is not None else _clean(value)
                continue
            if kind == "address":
                address = address if address is not None else _clean(value)
                continue
            if kind == "event":
                job.event = job.event if job.event is not None else _clean(value)
                continue
            if kind == "role":
                role = role if role is not None else _clean(value)
                continue
            if kind == "ignored":
                continue
            if kind == "call":
                call = _call_time(value) if job.call_minute is None else None
                if call is not None:
                    job.call_minute, call_is_bare = call
                continue
            if kind == "dress":
                job.dress_code = job.dress_code if job.dress_code is not None else value.strip()
                continue
            if kind == "contact":
                job.contact = f"{job.contact} {value.strip()}" if job.contact else value.strip()
                continue
            if kind == "break":
                if job.break_minutes is None:
                    job.break_minutes = _break_length(value)
                    paid = _PAID_WORD.search(value.lower())
                    job.break_paid = _is_paid(paid.group(1)) if paid else None
                continue
            content = value
        lower, pay = _read_pay(_lower(content))
        if pay is not None:
            kind, amount, currency = pay
            if kind == "hourly":
                job.rate = job.rate if job.rate is not None else amount
            elif kind == "day":
                job.fixed_pay = job.fixed_pay if job.fixed_pay is not None else amount
            else:
                flat = flat if flat is not None else amount
            job.currency = job.currency or currency
        if job.break_minutes is None:
            found_break = _BREAK_IN_LINE.search(lower)
            if found_break is not None:
                job.break_minutes = _break_length(found_break.group(2))
                job.break_paid = _is_paid(found_break.group(1) or found_break.group(3) or found_break.group(4))
                lower = lower.replace(found_break.group(0), " " * len(found_break.group(0)))
        lower, days = _read_dates(lower, today)
        lower, clock_range = _read_time(lower)
        if not days and clock_range is None:
            # Only lines with numbers left unread are skipped; a break already read is not.
            if pay is None and re.search(r"\d", lower):
                job.skipped.append(line)
            if may_be_heading and title is None and not items and pay is None and content == line:
                heading = _heading(line)
                if heading is not None:
                    title, title_venue = heading
            continue
        items.append(_Item(days, clock_range))
        name, venue = _leftover(lower, content)
        if job.location is None and venue:
            job.location = venue
        if job.event is None and name:
            job.event = name

    # Day times that match no listed date are treated as a time on its own line.
    listed_days = {day.day for item in items for day in item.days}
    for days_of_month, clock_range in day_times:
        if not any(day in listed_days for day in days_of_month):
            items.append(_Item([], clock_range))
    # Dates listed without times take the nearest time given on its own line.
    lone_times = [(index, item.time) for index, item in enumerate(items) if not item.days and item.time]
    seen: set[tuple[date, int, int]] = set()
    for index, item in enumerate(items):
        if not item.days:
            continue
        after = next((clock for at, clock in lone_times if at > index), None)
        before = next((clock for at, clock in reversed(lone_times) if at < index), None)
        fallback = item.time or after or before
        for day in item.days:
            # A time written for this day of the month ("21,22nd: 9am - 6pm") wins over the shared one.
            own = next((clock for days_of_month, clock in reversed(day_times) if day.day in days_of_month), None)
            clock_range = own or fallback
            if clock_range is None:
                job.no_time.append(day)
                continue
            key = (day, *clock_range)
            if key in seen or len(job.dates) >= MAXIMUM_DATES:
                continue
            seen.add(key)
            job.dates.append(JobDate(day, *clock_range))
    job.dates.sort(key=lambda slot: (slot.day, slot.start_minute))

    if job.event is None:
        job.event = title
    if job.location is None:
        job.location = title_venue
    if job.event is None:
        job.event = role
    if address:
        if not job.location:
            job.location = address
        elif job.location.lower() not in address.lower():
            job.location = f"{job.location}, {address}"
    if flat is not None and job.fixed_pay is None and job.rate is None:
        count = max(len(job.dates), 1)
        job.fixed_pay = round_money(flat / count)
        if count > 1:
            job.lump_sum = flat
    if job.location and len(job.location) > 1000:
        job.location = job.location[:1000]
    if job.event and len(job.event) > 120:
        job.event = job.event[:120]
    # A bare "5.30" for a 6pm job means 17:30: the call comes before the start.
    if call_is_bare and job.call_minute is not None and job.call_minute < 720 and job.dates \
            and job.call_minute + 720 <= job.dates[0].start_minute:
        job.call_minute += 720
    job.dress_code = job.dress_code[:BRIEF_TEXT_LIMIT] if job.dress_code else None
    job.contact = job.contact[:BRIEF_TEXT_LIMIT] if job.contact else None
    return job


def _clock_time(minute: int) -> time:
    return time(minute // 60, minute % 60)


def _short_day(day: date) -> str:
    return f"{day.day} {day.strftime('%b')}"


def job_shifts(job: PastedJob, default_break_paid: bool = False) -> list[tuple[str, Shift | ParseError]]:
    """One shift per date, plus an entry for anything that stops a date from being logged."""
    results: list[tuple[str, Shift | ParseError]] = []
    if job.no_time:
        results.append((", ".join(_short_day(day) for day in job.no_time), ParseError("No time found for this.")))
    if not job.dates:
        return results
    days = ", ".join(_short_day(slot.day) for slot in job.dates)
    if not job.name:
        return [*results, (days, ParseError("No event name found. Add a line like `Event: Roadshow`."))]
    pay_is_fixed = job.fixed_pay is not None
    pay = job.fixed_pay if pay_is_fixed else job.rate
    for index, slot in enumerate(job.dates):
        amount = pay
        if job.lump_sum is not None and index == len(job.dates) - 1:
            # The last date takes the leftover cents, so the shares add up exactly.
            amount = job.lump_sum - job.fixed_pay * (len(job.dates) - 1)
        shift = Shift(
            day=slot.day,
            start=_clock_time(slot.start_minute),
            end=_clock_time(slot.end_minute),
            event=job.name,
            location=job.location or "",
            rate_override=amount,
            pay_is_fixed=pay_is_fixed,
            call_minute=job.call_minute,
            dress_code=job.dress_code,
            contact=job.contact,
        )
        if job.break_minutes is not None:
            paid = default_break_paid if job.break_paid is None else job.break_paid
            shift = shift.with_break(Break(hours=job.break_minutes / 60, paid=paid))
        results.append((_short_day(slot.day), shift))
    return results


_WEEKDAY = r"(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?"
_WEEKDAY_BY_DATE = re.compile(rf"\b{_WEEKDAY}\b\.?,?\s*\(?\d|\d\s*\(\s*{_WEEKDAY}\s*\)", re.IGNORECASE)


def _is_command(line: str, today: date) -> bool:
    """A line the one-line reader understood fully. It reads one date and takes weekday words as the name."""
    return _WEEKDAY_BY_DATE.search(line) is None and len(parse_job_message(line, today).dates) <= 1


def _without_emoji(shift: Shift) -> Shift:
    return replace(
        shift,
        event=_strip_edges(shift.event) or shift.event,
        location=_strip_edges(shift.location) or shift.location,
    )


def parse_message(
    text: str, today: date | None = None, default_break_paid: bool = False
) -> list[tuple[str, Shift | ParseError]]:
    """Read a Telegram message: one shift per line if that's what it is, otherwise a whole job post."""
    today = today or date.today()
    lines = parse_shifts(text, today, default_break_paid)
    commands = [
        result for line, result in lines if isinstance(result, Shift) and _is_command(line, today)
    ]
    if len(commands) == len(lines):
        return [(line, _without_emoji(result)) for line, result in lines]
    # Two differently named shifts are a batch with a mistake in it, not one job.
    if len({shift.event.casefold() for shift in commands}) > 1:
        return lines
    job = parse_job_message(text, today)
    read = job_shifts(job, default_break_paid)
    if read:
        return read
    if len(lines) == 1 or any(isinstance(result, Shift) for _, result in lines):
        return lines
    return [("That message", ParseError("No date and time found in it."))]
