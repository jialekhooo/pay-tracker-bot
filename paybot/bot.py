"""Telegram bot that logs shifts and calculates pay."""

from __future__ import annotations

import calendar
import csv
import io
import logging
import os
import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, InvalidOperation

from telegram import BotCommand, Update
from telegram.constants import ParseMode
from telegram.error import TelegramError
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .calendar_export import event_title, google_link, to_ics
from .feed import issue_token, serve
from .parsing import Break, ParseError, Shift, parse_shifts, parse_time
from .pay import RateConfig, calculate_pay, format_hours, round_money
from .reminders import (
    DEFAULT_SEND_AT,
    DEFAULT_UTC_OFFSET_MINUTES,
    due_reminders,
    format_offset,
    local_clock,
    local_today,
    parse_offset,
)
from .schedule import find_clashes, span
from .storage import ShiftRecord, Storage

logger = logging.getLogger(__name__)

HELP_TEXT = """*Pay tracker*

To log, simply key in *event name*, *date + time*, *location* and *pay rate*:
```
Wedding gig 12/8 6pm-11.30pm 25/h @ Marina Bay Sands
```
→ 5.5h × SGD 25 = SGD 137.50

Location is optional — write it after `@` or `at`.

The order doesn't matter and the rate is optional (your saved rate is used):
`12/8 6pm-11.30pm Wedding gig`
`2026-08-12 18:00 23:30 Wedding gig 25/h`
`Roadshow today 9am to 5pm`
`28/9 0700 - 1900 SuperReturn @ MBS 20/h`

Send several lines at once to log a batch, and add `15/h` in a line to
override the rate for that shift:
```
13/8 8.30am - 8pm 15/h Hermes Private Sale
14/8 9am - 8pm 15/h Hermes Private Sale
```

Breaks — add them anywhere in the message:
`today 9am-6pm 1h unpaid break Roadshow` (deducted)
`today 9am-6pm 1 hour paid break Roadshow` (not deducted)
`today 9am-6pm 30min break Roadshow` (uses your /break default)
`today 9am-6pm no break Roadshow`

Send /commands for everything the bot can do.
"""


def _storage(context: ContextTypes.DEFAULT_TYPE) -> Storage:
    return context.application.bot_data["storage"]


def _offset(storage: Storage, user_id: int) -> int:
    """The user's timezone offset in minutes, defaulting to UTC+8."""
    reminder = storage.get_reminder(user_id)
    return reminder.utc_offset_minutes if reminder else DEFAULT_UTC_OFFSET_MINUTES


def _today(storage: Storage, user_id: int) -> date:
    return local_today(_offset(storage, user_id))


def _money(amount: Decimal, currency: str) -> str:
    return f"{currency} {round_money(amount):,.2f}"


def _decimal(raw: str) -> Decimal:
    try:
        value = Decimal(raw.replace(",", ""))
    except InvalidOperation as exc:
        raise ParseError(f"{raw!r} is not a number.") from exc
    if value < 0:
        raise ParseError("Value cannot be negative.")
    return value


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(HELP_TEXT, parse_mode=ParseMode.MARKDOWN)


async def rate(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    config = storage.get_config(user_id)
    args = context.args

    if not args:
        lines = [f"Default rate: {_money(config.default_rate, config.currency)}/hour"]
        for event, value in sorted(config.event_rates.items()):
            lines.append(f"• {event}: {_money(value, config.currency)}/hour")
        if config.overtime_after_hours is not None:
            lines.append(
                f"Overtime: ×{config.overtime_multiplier} after "
                f"{config.overtime_after_hours} hours"
            )
        if config.default_break_hours > 0:
            lines.append(
                f"Default break: {format_hours(config.default_break_hours)}h "
                f"({'paid' if config.default_break_paid else 'unpaid'})"
            )
        await update.message.reply_text("\n".join(lines))
        return

    try:
        amount = _decimal(args[-1])
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return

    if len(args) == 1:
        config = replace(config, default_rate=amount)
        storage.save_config(user_id, config)
        await update.message.reply_text(
            f"Default rate set to {_money(amount, config.currency)}/hour."
        )
        return

    event = " ".join(args[:-1]).strip().lower()
    rates = dict(config.event_rates)
    rates[event] = amount
    config = replace(config, event_rates=rates)
    storage.save_config(user_id, config)
    await update.message.reply_text(
        f"Rate for “{event}” set to {_money(amount, config.currency)}/hour."
    )


async def clear_rate(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    event = " ".join(context.args).strip().lower()
    if not event:
        await update.message.reply_text("Usage: /clearrate <event name>")
        return
    config = storage.get_config(user_id)
    rates = dict(config.event_rates)
    if rates.pop(event, None) is None:
        await update.message.reply_text(f"No rate stored for “{event}”.")
        return
    storage.save_config(user_id, replace(config, event_rates=rates))
    await update.message.reply_text(f"Removed the rate for “{event}”.")


async def currency(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    if not context.args:
        await update.message.reply_text("Usage: /currency SGD")
        return
    code = context.args[0].upper()
    config = storage.get_config(user_id)
    storage.save_config(user_id, replace(config, currency=code))
    await update.message.reply_text(f"Currency set to {code}.")


async def overtime(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    config = storage.get_config(user_id)
    args = context.args
    if len(args) == 1 and args[0].lower() == "off":
        storage.save_config(user_id, replace(config, overtime_after_hours=None))
        await update.message.reply_text("Overtime disabled.")
        return
    if len(args) != 2:
        await update.message.reply_text("Usage: /overtime <hours> <multiplier>, or /overtime off")
        return
    try:
        hours, multiplier = _decimal(args[0]), _decimal(args[1])
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    storage.save_config(
        user_id,
        replace(config, overtime_after_hours=hours, overtime_multiplier=multiplier),
    )
    await update.message.reply_text(f"Overtime: ×{multiplier} after {hours} hours.")


async def break_default(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    config = storage.get_config(user_id)
    args = context.args
    if len(args) == 1 and args[0].lower() in {"off", "none", "0"}:
        storage.save_config(user_id, replace(config, default_break_hours=Decimal("0")))
        await update.message.reply_text("Default break removed.")
        return
    if len(args) != 2 or args[1].lower() not in {"paid", "unpaid"}:
        await update.message.reply_text("Usage: /break <hours> paid|unpaid, or /break off")
        return
    try:
        hours = _decimal(args[0])
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    paid = args[1].lower() == "paid"
    storage.save_config(
        user_id,
        replace(config, default_break_hours=hours, default_break_paid=paid),
    )
    await update.message.reply_text(
        f"Default break: {format_hours(hours)}h ({'paid' if paid else 'unpaid'}). "
        "Say “no break” in a message to skip it."
    )


def _store_shift(
    storage: Storage, user_id: int, shift: Shift, config: RateConfig
) -> tuple[int, Decimal, Decimal, Decimal]:
    hours = Decimal(str(shift.hours))
    rate = (
        shift.rate_override
        if shift.rate_override is not None
        else config.rate_for(shift.event)
    )
    pay = calculate_pay(shift.hours, shift.event, config, shift.rate_override)
    shift_id = storage.add_shift(
        user_id=user_id,
        day=shift.day,
        start=shift.start,
        end=shift.end,
        event=shift.event,
        location=shift.location,
        break_hours=Decimal(str(shift.rest.hours)),
        break_paid=shift.rest.paid,
        hours=hours,
        pay=pay,
        currency=config.currency,
    )
    return shift_id, hours, pay, rate


def _apply_default_break(shift: Shift, config: RateConfig) -> Shift:
    if shift.break_specified or config.default_break_hours <= 0:
        return shift
    return shift.with_break(
        Break(hours=float(config.default_break_hours), paid=config.default_break_paid)
    )


def _summarise(
    shift: Shift,
    shift_id: int,
    hours: Decimal,
    pay: Decimal,
    rate: Decimal,
    currency: str,
) -> str:
    line = (
        f"#{shift_id} {shift.day.isoformat()} "
        f"{shift.start.strftime('%H:%M')}–{shift.end.strftime('%H:%M')} "
        f"{shift.event}{' @ ' + shift.location if shift.location else ''} — "
        f"{format_hours(hours)}h @ {_money(rate, currency)}/h = {_money(pay, currency)}"
    )
    if shift.rest.hours:
        kind = "paid" if shift.rest.paid else "unpaid"
        line += f" ({format_hours(Decimal(str(shift.rest.hours)))}h {kind} break)"
    return line


async def log_shift(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    text = update.message.text or ""
    if text.startswith("/log"):
        text = text[len("/log") :]
    config = storage.get_config(user_id)

    parsed = parse_shifts(
        text, today=_today(storage, user_id), default_break_paid=config.default_break_paid
    )
    if not parsed:
        await update.message.reply_text(
            "Send a shift, e.g. 13/8 8.30am-8pm 15/h Hermes Private Sale"
        )
        return

    logged: list[str] = []
    failed: list[str] = []
    warnings: list[str] = []
    total_pay = Decimal("0")
    for line, result in parsed:
        if isinstance(result, ParseError):
            failed.append(f"• {line} — {result}")
            continue
        shift = _apply_default_break(result, config)
        clashes = find_clashes(
            storage.shifts_between(
                user_id, shift.day - timedelta(days=1), shift.day + timedelta(days=1)
            ),
            shift.day,
            shift.start,
            shift.end,
        )
        shift_id, hours, pay, rate = _store_shift(storage, user_id, shift, config)
        total_pay += pay
        logged.append(_summarise(shift, shift_id, hours, pay, rate, config.currency))
        for clash in clashes:
            warnings.append(
                f"⚠️ #{shift_id} {shift.event} clashes with #{clash.id} {clash.event} "
                f"({clash.day.isoformat()} {clash.start.strftime('%H:%M')}–"
                f"{clash.end.strftime('%H:%M')})"
            )

    reply: list[str] = []
    if logged:
        reply.append(f"Logged {len(logged)} shift{'s' if len(logged) > 1 else ''}:")
        reply.extend(logged)
        if len(logged) > 1:
            reply.append(f"Total: {_money(total_pay, config.currency)}")
    if warnings:
        reply.append("Double booking:")
        reply.extend(warnings)
        reply.append("Use /delete <id> to drop the one you don't want.")
    if failed:
        reply.append("Could not read:")
        reply.extend(failed)
        reply.append("Send /help to see the accepted formats.")
    await update.message.reply_text("\n".join(reply))


_FIELDS = {
    "location": "location",
    "loc": "location",
    "place": "location",
    "venue": "location",
    "rate": "rate",
    "pay": "rate",
    "name": "name",
    "event": "name",
    "title": "name",
    "time": "time",
    "times": "time",
    "hours": "time",
}

_EDIT_PATTERNS: dict[str, tuple[re.Pattern[str], ...]] = {
    "location": (
        re.compile(r"^(?P<target>.+?)\s*(?:@|=)\s*(?P<value>.+)$"),
        re.compile(r"^(?P<target>.+?)\s*\bat\b\s*(?P<value>.+)$", re.IGNORECASE),
    ),
    "rate": (
        re.compile(
            r"^(?P<target>.+?)\s*(?:=|\bto\b)?\s*(?:\$|\b(?-i:[A-Z]{3})\s*)?"
            r"(?P<value>\d+(?:\.\d+)?)\s*(?:/\s*h(?:r|our)?|per\s+hour)?$",
            re.IGNORECASE,
        ),
    ),
    "name": (
        re.compile(r"^(?P<target>.+?)\s*(?:=|->)\s*(?P<value>.+)$"),
        re.compile(r"^(?P<target>.+?)\s*\bto\b\s*(?P<value>.+)$", re.IGNORECASE),
    ),
    "time": (
        re.compile(
            r"^(?P<target>.+?)\s*(?:=|\bto\b)?\s*(?P<value>\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?"
            r"\s*(?:-|–|—|to|till|until)\s*\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?)$",
            re.IGNORECASE,
        ),
    ),
}

_TARGET_ID_RE = re.compile(r"^#?(?P<id>\d+)$")

EDIT_USAGE = (
    "Backfill details on shifts you already logged:\n"
    "`/add location Hermes Private Sale @ MBS`\n"
    "`/add rate Hermes Private Sale 18`\n"
    "`/add name Hermes Private Sale = Hermes PS`\n"
    "`/add time Hermes Private Sale 9am-8pm`\n"
    "Use a shift number to change just one: `/add time #12 9am-8pm`."
)


def parse_edit(text: str) -> tuple[str, str, str] | None:
    """Read `<field> <event or #id> <value>` into (field, target, value)."""
    head, _, rest = text.strip().partition(" ")
    field = _FIELDS.get(head.lower())
    if field is None or not rest.strip():
        return None
    for pattern in _EDIT_PATTERNS[field]:
        match = pattern.match(rest.strip())
        if match is None:
            continue
        target = match.group("target").strip(" ,;=-")
        value = match.group("value").strip()
        if target and value:
            return field, target, value
    return None


def _rehours(record: ShiftRecord, start: time, end: time) -> Decimal:
    """Paid hours for a new time range, keeping the shift's unpaid break."""
    begins, ends = span(record.day, start, end)
    worked = Decimal((ends - begins).total_seconds()) / Decimal(3600)
    if not record.break_paid:
        worked -= record.break_hours
    return max(worked, Decimal("0"))


def _edit_record(
    record: ShiftRecord, field: str, value: str, config: RateConfig
) -> dict[str, object]:
    """Columns to write for one shift, recalculating pay when it changes."""
    if field == "location":
        return {"location": value}
    if field == "name":
        return {"event": value}
    if field == "rate":
        rate = Decimal(value)
        return {"pay": str(calculate_pay(float(record.hours), record.event, config, rate))}
    parts = re.split(r"\s*(?:-|–|—|to|till|until)\s*", value, maxsplit=1)
    start, end = parse_time(parts[0]), parse_time(parts[1])
    hours = _rehours(record, start, end)
    old_rate = record.pay / record.hours if record.hours else config.rate_for(record.event)
    return {
        "start_time": start.isoformat(timespec="minutes"),
        "end_time": end.isoformat(timespec="minutes"),
        "hours": format_hours(hours),
        "pay": str(calculate_pay(float(hours), record.event, config, round_money(old_rate))),
    }


async def add_detail(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Backfill a detail — location, rate, name or time — on shifts already logged."""
    parsed = parse_edit(" ".join(context.args))
    if parsed is None:
        await update.message.reply_text(EDIT_USAGE, parse_mode=ParseMode.MARKDOWN)
        return
    field, target, value = parsed
    storage = _storage(context)
    user_id = update.effective_user.id
    by_id = _TARGET_ID_RE.match(target)
    if by_id:
        record = storage.get_shift(user_id, int(by_id.group("id")))
        records = [record] if record else []
    else:
        records = storage.find_shifts(user_id, target)
    if not records:
        await update.message.reply_text(f"No shifts matching {target!r} — check /list.")
        return

    config = storage.get_config(user_id)
    try:
        changes = [(r, _edit_record(r, field, value, config)) for r in records]
    except (ParseError, InvalidOperation) as exc:
        await update.message.reply_text(f"Could not read {value!r}: {exc}")
        return
    for record, fields in changes:
        storage.update_shift(user_id, record.id, **fields)

    updated = [storage.get_shift(user_id, r.id) for r, _ in changes]
    lines = [f"Updated {len(updated)} shift{'s' if len(updated) != 1 else ''}:"]
    lines.extend(_shift_line(r) for r in updated[:10] if r)
    if len(updated) > 10:
        lines.append(f"…and {len(updated) - 10} more.")
    await update.message.reply_text("\n".join(lines))


_MONTH_NAMES = {
    name.lower(): index
    for index, name in enumerate(calendar.month_name[1:], start=1)
} | {
    name.lower(): index
    for index, name in enumerate(calendar.month_abbr[1:], start=1)
}


def parse_month(args: list[str], today: date | None = None) -> str | None:
    """Normalise `/list aug`, `/list 8`, `/list 2026-08` to a YYYY-MM key."""
    if not args:
        return None
    today = today or date.today()
    text = " ".join(args).strip().lower()
    if re.fullmatch(r"\d{4}-\d{2}", text):
        return text
    if text == "this month":
        return today.strftime("%Y-%m")
    if text == "last month":
        first = today.replace(day=1)
        return (first - timedelta(days=1)).strftime("%Y-%m")
    words = text.split()
    month = _MONTH_NAMES.get(words[0])
    if month is None and words[0].isdigit() and 1 <= int(words[0]) <= 12:
        month = int(words[0])
    if month is None:
        raise ParseError(f"Could not read a month from {text!r}. Try `2026-08` or `aug`.")
    year = int(words[1]) if len(words) > 1 and words[1].isdigit() else today.year
    return f"{year:04d}-{month:02d}"


def _shift_line(record: ShiftRecord) -> str:
    return (
        f"#{record.id} {record.day.isoformat()} "
        f"{record.start.strftime('%H:%M')}–{record.end.strftime('%H:%M')} "
        f"{record.event}{' @ ' + record.location if record.location else ''} — "
        f"{format_hours(record.hours)}h — {_money(record.pay, record.currency)}"
    )


def _month_label(month: str) -> str:
    year, index = month.split("-")
    return f"{calendar.month_name[int(index)]} {year}"


async def list_shifts(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    try:
        month = parse_month(context.args, today=_today(storage, update.effective_user.id))
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    records = storage.list_shifts(
        update.effective_user.id, month=month, limit=None if month else 20
    )
    if not records:
        await update.message.reply_text(
            f"No shifts logged for {_month_label(month)}." if month else "No shifts logged yet."
        )
        return
    lines = [_shift_line(r) for r in records]
    if month:
        hours = sum((r.hours for r in records), Decimal("0"))
        pay = sum((r.pay for r in records), Decimal("0"))
        lines.insert(0, _month_label(month))
        lines.append(
            f"Total: {len(records)} shifts, {format_hours(hours)}h, "
            f"{_money(pay, records[0].currency)}"
        )
    await update.message.reply_text("\n".join(lines))


async def months(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Month-by-month summary, or every shift in one month."""
    if context.args:
        await list_shifts(update, context)
        return
    storage = _storage(context)
    summaries = storage.month_summaries(update.effective_user.id)
    if not summaries:
        await update.message.reply_text("No shifts logged yet.")
        return
    lines = [
        f"{_month_label(s.month)} — {s.shifts} shifts, "
        f"{format_hours(s.hours)}h, {_money(s.pay, s.currency)}"
        for s in summaries
    ]
    grand_total = sum((s.pay for s in summaries), Decimal("0"))
    lines.append(f"All time: {_money(grand_total, summaries[0].currency)}")
    lines.append("Send /month 2026-08 (or /month aug) to see that month's shifts.")
    await update.message.reply_text("\n".join(lines))


async def reminders(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Turn the day-before reminder on/off and set when it arrives."""
    storage = _storage(context)
    user_id = update.effective_user.id
    existing = storage.get_reminder(user_id)
    args = [a.lower() for a in context.args]

    if not args:
        if existing is None or not existing.enabled:
            await update.message.reply_text(
                "Reminders are off. Send /reminders on to get a message the evening "
                "before each shift (default 20:00, UTC+8), or /reminders 19:30 +8."
            )
            return
        await update.message.reply_text(
            f"Reminders on at {existing.send_at.strftime('%H:%M')} "
            f"({format_offset(existing.utc_offset_minutes)}), for the next day's shifts."
        )
        return

    send_at = existing.send_at if existing else time.fromisoformat(DEFAULT_SEND_AT)
    offset = existing.utc_offset_minutes if existing else DEFAULT_UTC_OFFSET_MINUTES
    enabled = True
    for arg in args:
        if arg == "off":
            enabled = False
        elif arg == "on":
            continue
        elif arg.startswith(("+", "-")):
            try:
                offset = parse_offset(arg)
            except ValueError as exc:
                await update.message.reply_text(str(exc))
                return
        else:
            try:
                send_at = parse_time(arg)
            except ParseError as exc:
                await update.message.reply_text(str(exc))
                return

    storage.save_reminder(user_id, update.effective_chat.id, send_at, offset, enabled)
    if not enabled:
        await update.message.reply_text("Reminders off.")
        return
    await update.message.reply_text(
        f"Reminders on — I'll message you at {send_at.strftime('%H:%M')} "
        f"({format_offset(offset)}) with the shifts you have the next day."
    )


async def send_due_reminders(context: ContextTypes.DEFAULT_TYPE) -> None:
    """Job: message each user whose reminder time has arrived."""
    storage: Storage = context.application.bot_data["storage"]
    now_utc = datetime.now(timezone.utc).replace(tzinfo=None)
    for reminder, day in due_reminders(storage.enabled_reminders(), now_utc):
        records = storage.shifts_between(reminder.user_id, day, day)
        storage.mark_reminder_sent(reminder.user_id, day - timedelta(days=1))
        if not records:
            continue
        lines = [f"Tomorrow ({day.strftime('%a %d %b')}) you're working:"]
        lines.extend(
            f"  {r.start.strftime('%H:%M')}–{r.end.strftime('%H:%M')} {r.event}"
            f"{' @ ' + r.location if r.location else ''}"
            for r in records
        )
        try:
            await context.bot.send_message(reminder.chat_id, "\n".join(lines))
        except TelegramError:
            logger.exception("Could not send the reminder to chat %s", reminder.chat_id)


async def upcoming(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Show the shifts already booked from today onwards, flagging any clashes."""
    storage = _storage(context)
    user_id = update.effective_user.id
    days = 14
    if context.args and context.args[0].isdigit():
        days = max(1, min(int(context.args[0]), 365))
    today = _today(storage, user_id)
    records = storage.shifts_between(user_id, today, today + timedelta(days=days - 1))
    if not records:
        await update.message.reply_text(f"Nothing booked in the next {days} days.")
        return

    clashing: set[int] = set()
    for index, record in enumerate(records):
        for other in find_clashes(records[index + 1 :], record.day, record.start, record.end):
            clashing.update({record.id, other.id})
    lines = [f"Booked in the next {days} days:"]
    current_day: date | None = None
    for record in records:
        if record.day != current_day:
            current_day = record.day
            lines.append(record.day.strftime("%a %d %b"))
        flag = " ⚠️ clash" if record.id in clashing else ""
        lines.append(
            f"  #{record.id} {record.start.strftime('%H:%M')}–"
            f"{record.end.strftime('%H:%M')} {record.event}"
            f"{' @ ' + record.location if record.location else ''}{flag}"
        )
    await update.message.reply_text("\n".join(lines))


async def total(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    today = _today(storage, user_id)
    try:
        month = parse_month(context.args, today=today)
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    month = month or today.strftime("%Y-%m")
    records = storage.list_shifts(user_id, month=month)
    if not records:
        await update.message.reply_text(
            f"No shifts logged for {_month_label(month)}.\n"
            f"{_totals_line(storage, user_id, None, storage.get_config(user_id).currency)}"
        )
        return
    currency_code = records[0].currency
    hours = sum((r.hours for r in records), Decimal("0"))
    pay = sum((r.pay for r in records), Decimal("0"))
    summaries = storage.month_summaries(user_id)
    grand_total = sum((s.pay for s in summaries), Decimal("0"))
    lines = [_month_label(month), *(_shift_line(r) for r in records)]
    lines.append(
        f"Total: {len(records)} shifts, {format_hours(hours)}h, {_money(pay, currency_code)}"
    )
    lines.append(f"All time: {_money(grand_total, currency_code)}")
    await update.message.reply_text("\n".join(lines))


@dataclass(frozen=True)
class Worked:
    """One shift measured against the clock: what it has paid out so far."""

    record: ShiftRecord
    hours: Decimal
    pay: Decimal
    state: str  # "done", "running" or "upcoming"


@dataclass(frozen=True)
class Earned:
    """Pay counted up to a moment in time, splitting off what is still to come."""

    pay: Decimal
    hours: Decimal
    finished: int
    in_progress: ShiftRecord | None
    booked_pay: Decimal
    booked: int
    shifts: list[Worked]


def worked_by(record: ShiftRecord, now: datetime) -> Worked:
    """A finished shift pays in full, a running one pro-rata, a future one nothing yet."""
    start, end = span(record.day, record.start, record.end)
    if end <= now:
        return Worked(record, record.hours, record.pay, "done")
    if start >= now:
        return Worked(record, Decimal("0"), Decimal("0"), "upcoming")
    elapsed = Decimal(str((now - start).total_seconds()))
    total = Decimal(str((end - start).total_seconds()))
    done = elapsed / total
    return Worked(record, record.hours * done, record.pay * done, "running")


def earned_by(records: list[ShiftRecord], now: datetime) -> Earned:
    """Count finished shifts in full and the one running now pro-rata."""
    pay = hours = booked_pay = Decimal("0")
    finished = booked = 0
    running: ShiftRecord | None = None
    worked = [worked_by(record, now) for record in records]
    for item in worked:
        pay += item.pay
        hours += item.hours
        booked_pay += item.record.pay - item.pay
        if item.state == "done":
            finished += 1
        elif item.state == "running":
            running = item.record
        else:
            booked += 1
    return Earned(pay, hours, finished, running, booked_pay, booked, worked)


def _hourly(record: ShiftRecord) -> Decimal:
    return record.pay / record.hours if record.hours else Decimal("0")


def _breakdown_line(item: Worked, now: datetime, currency: str) -> str:
    """One shift spelled out, so the arithmetic behind the total is visible."""
    record = item.record
    when = (
        f"#{record.id} {record.day.strftime('%a %d %b')} "
        f"{record.start.strftime('%H:%M')}–{record.end.strftime('%H:%M')} {record.event}"
    )
    rate = f"{_money(_hourly(record), currency)}/h"
    if item.state == "done":
        return f"  {when}: {format_hours(record.hours)}h × {rate} = {_money(item.pay, currency)}"
    if item.state == "running":
        return (
            f"  {when}: running — {format_hours(item.hours)}h of "
            f"{format_hours(record.hours)}h up to {now.strftime('%H:%M')} × {rate} = "
            f"{_money(item.pay, currency)} of {_money(record.pay, currency)}"
        )
    return (
        f"  {when}: not started — {format_hours(record.hours)}h × {rate} = "
        f"{_money(record.pay, currency)} to come"
    )


def _earnings_block(
    label: str, records: list[ShiftRecord], now: datetime, currency: str
) -> list[str]:
    if not records:
        return [f"{label}: nothing logged."]
    tally = earned_by(records, now)
    counted = tally.finished + (1 if tally.in_progress else 0)
    lines = [
        f"{label}: {_money(tally.pay, currency)} so far "
        f"({counted} shift{'' if counted == 1 else 's'}, {format_hours(tally.hours)}h)"
    ]
    lines += [_breakdown_line(item, now, currency) for item in tally.shifts]
    if tally.booked_pay > 0:
        remaining = tally.booked + (1 if tally.in_progress else 0)
        lines.append(
            f"  still to come: {_money(tally.booked_pay, currency)} "
            f"({remaining} shift{'' if remaining == 1 else 's'}) → "
            f"{_money(tally.pay + tally.booked_pay, currency)} projected"
        )
    return lines


async def earnings(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """How much has been earned so far this week and this month."""
    storage = _storage(context)
    user_id = update.effective_user.id
    now = local_clock(_offset(storage, user_id))
    today = now.date()
    currency = storage.get_config(user_id).currency
    scope = " ".join(context.args).strip().lower()
    monday = today - timedelta(days=today.weekday())

    if scope in ("today", "day"):
        records = storage.shifts_between(user_id, today, today)
        lines = [f"Earnings as of {now.strftime('%a %d %b %H:%M')}"]
        lines += _earnings_block(f"Today ({today.strftime('%a %d %b')})", records, now, currency)
        await update.message.reply_text("\n".join(lines))
        return

    if scope in ("", "week", "this week", "month", "this month"):
        week = storage.shifts_between(user_id, monday, monday + timedelta(days=6))
        month = storage.list_shifts(user_id, month=today.strftime("%Y-%m"))
        lines = [f"Earnings as of {now.strftime('%a %d %b %H:%M')}"]
        if scope in ("", "week", "this week"):
            lines += _earnings_block(
                f"This week (from {monday.strftime('%d %b')})", week, now, currency
            )
        if scope in ("", "month", "this month"):
            lines += _earnings_block(_month_label(today.strftime("%Y-%m")), month, now, currency)
        await update.message.reply_text("\n".join(lines))
        return

    if scope == "last week":
        start = monday - timedelta(days=7)
        records = storage.shifts_between(user_id, start, start + timedelta(days=6))
        label = f"Week of {start.strftime('%d %b')}"
        await update.message.reply_text("\n".join(_earnings_block(label, records, now, currency)))
        return

    try:
        month = parse_month(context.args, today=today)
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    records = storage.list_shifts(user_id, month=month)
    await update.message.reply_text(
        "\n".join(_earnings_block(_month_label(month), records, now, currency))
    )


def _totals_line(storage: Storage, user_id: int, month: str | None, currency: str) -> str:
    """Recomputed totals so the user sees numbers drop after a delete."""
    lines = []
    if month:
        records = storage.list_shifts(user_id, month=month)
        pay = sum((r.pay for r in records), Decimal("0"))
        hours = sum((r.hours for r in records), Decimal("0"))
        lines.append(
            f"{_month_label(month)} now: {len(records)} shifts, "
            f"{format_hours(hours)}h, {_money(pay, currency)}"
        )
    summaries = storage.month_summaries(user_id)
    grand_total = sum((s.pay for s in summaries), Decimal("0"))
    lines.append(f"All time now: {_money(grand_total, currency)}")
    return "\n".join(lines)


async def delete_shift(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    config = storage.get_config(user_id)
    ids = [arg.lstrip("#") for arg in context.args]
    if not ids or not all(i.isdigit() for i in ids):
        await update.message.reply_text("Usage: /delete <id> [id ...], or /clear <month>")
        return

    deleted: list[str] = []
    missing: list[str] = []
    months_touched: set[str] = set()
    for shift_id in (int(i) for i in ids):
        record = storage.get_shift(user_id, shift_id)
        if record is None or not storage.delete_shift(user_id, shift_id):
            missing.append(f"#{shift_id}")
            continue
        months_touched.add(record.day.strftime("%Y-%m"))
        deleted.append(
            f"#{shift_id} {record.day.isoformat()} {record.event}"
            f"{' @ ' + record.location if record.location else ''} "
            f"(−{_money(record.pay, record.currency)})"
        )

    reply: list[str] = []
    if deleted:
        reply.append(f"Deleted {len(deleted)} shift{'s' if len(deleted) > 1 else ''}:")
        reply.extend(deleted)
        month = months_touched.pop() if len(months_touched) == 1 else None
        reply.append(_totals_line(storage, user_id, month, config.currency))
    if missing:
        reply.append(f"Not found: {', '.join(missing)}")
    await update.message.reply_text("\n".join(reply))


async def clear_shifts(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Delete every shift, or every shift in one month, after a confirmation."""
    storage = _storage(context)
    user_id = update.effective_user.id
    config = storage.get_config(user_id)
    args = [a for a in context.args if a.lower() != "confirm"]
    confirmed = any(a.lower() == "confirm" for a in context.args)
    try:
        month = parse_month(args, today=_today(storage, user_id))
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return

    scope = _month_label(month) if month else "all months"
    pending = storage.list_shifts(user_id, month=month)
    if not pending:
        await update.message.reply_text(f"Nothing logged for {scope}.")
        return
    if not confirmed:
        pay = sum((r.pay for r in pending), Decimal("0"))
        await update.message.reply_text(
            f"This deletes {len(pending)} shifts ({_money(pay, config.currency)}) "
            f"from {scope}.\nSend `/clear {' '.join(args) + ' ' if args else ''}confirm` "
            "to go ahead."
        )
        return

    removed = storage.delete_shifts(user_id, month=month)
    await update.message.reply_text(
        f"Deleted {removed} shifts from {scope}.\n"
        f"{_totals_line(storage, user_id, month, config.currency)}"
    )


async def export(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    try:
        month = parse_month(context.args, today=_today(storage, update.effective_user.id))
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    records = storage.list_shifts(update.effective_user.id, month=month)
    if not records:
        await update.message.reply_text("Nothing to export.")
        return
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(
        [
            "id",
            "date",
            "start",
            "end",
            "event",
            "location",
            "break_hours",
            "break_paid",
            "hours",
            "pay",
            "currency",
        ]
    )
    for r in records:
        writer.writerow(
            [
                r.id,
                r.day.isoformat(),
                r.start.strftime("%H:%M"),
                r.end.strftime("%H:%M"),
                r.event,
                r.location,
                r.break_hours,
                "paid" if r.break_paid else "unpaid",
                r.hours,
                r.pay,
                r.currency,
            ]
        )
    data = io.BytesIO(buffer.getvalue().encode("utf-8"))
    data.name = f"shifts-{month or 'all'}.csv"
    await update.message.reply_document(document=data, filename=data.name)


def _calendar_records(
    storage: Storage, user_id: int, args: list[str]
) -> tuple[list[ShiftRecord], str]:
    """Shifts for /calendar: specific ids, a month, or everything from today on."""
    if args and all(arg.startswith("#") and arg[1:].isdigit() for arg in args):
        records = [storage.get_shift(user_id, int(arg[1:])) for arg in args]
        return [r for r in records if r is not None], "selected shifts"
    if args and args[0].lower() == "all":
        return storage.list_shifts(user_id), "all shifts"
    today = _today(storage, user_id)
    month = parse_month(args, today=today)
    if month:
        return storage.list_shifts(user_id, month=month), _month_label(month)
    return storage.shifts_between(user_id, today, today + timedelta(days=365)), "upcoming shifts"


async def calendar_export(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Send the shifts as a .ics file plus one-tap Google Calendar links."""
    storage = _storage(context)
    user_id = update.effective_user.id
    try:
        records, scope = _calendar_records(storage, user_id, list(context.args))
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    if not records:
        await update.message.reply_text(
            f"No shifts to add for {scope}. Try /calendar aug, /calendar all, or /calendar #12."
        )
        return

    offset = _offset(storage, user_id)
    data = io.BytesIO(to_ics(records).encode("utf-8"))
    data.name = "shifts.ics"
    lines = [
        f"{len(records)} shift{'s' if len(records) > 1 else ''} from {scope} — open the "
        "file to add them to Apple/Google Calendar, or tap a link:"
    ]
    for record in records[:10]:
        lines.append(
            f"• [{record.day.strftime('%a %d %b')} "
            f"{record.start.strftime('%H:%M')}–{record.end.strftime('%H:%M')} "
            f"{event_title(record)}]({google_link(record, offset)})"
        )
    if len(records) > 10:
        lines.append(f"…and {len(records) - 10} more in the file.")
    await update.message.reply_document(document=data, filename=data.name)
    await update.message.reply_text(
        "\n".join(lines),
        parse_mode=ParseMode.MARKDOWN,
        disable_web_page_preview=True,
    )


async def calendar_link(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Give the user a personal subscription URL their calendar app keeps in sync."""
    storage = _storage(context)
    base_url = context.application.bot_data.get("feed_base_url")
    if not base_url:
        await update.message.reply_text(
            "No calendar feed is running for this bot. Set PAYBOT_FEED_URL (and "
            "PAYBOT_FEED_PORT) when starting it, then try again — /calendar still "
            "sends you a one-off .ics file."
        )
        return

    refresh = any(a.lower() in {"new", "reset", "rotate"} for a in context.args)
    token = issue_token(storage, update.effective_user.id, refresh=refresh)
    url = f"{base_url.rstrip('/')}/{token}.ics"
    await update.message.reply_text(
        ("New link — the old one stops working:\n" if refresh else "")
        + f"`{url}`\n\n"
        "Subscribe once and every shift you log shows up automatically:\n"
        "• iPhone: Settings → Calendar → Accounts → Add Account → Other → "
        "Add Subscribed Calendar → paste the link\n"
        "• Google Calendar (web): Other calendars → + → From URL → paste\n"
        "• TimeTree: sync the calendar above into TimeTree "
        "(Settings → Calendar sync), it reads your phone's calendars\n\n"
        "Keep the link private — anyone with it can see your shifts "
        "(`/calendarlink new` replaces it).",
        parse_mode=ParseMode.MARKDOWN,
        disable_web_page_preview=True,
    )


@dataclass(frozen=True)
class Command:
    """One bot command: how it's registered, listed and described."""

    names: tuple[str, ...]
    usage: str
    summary: str
    handler: Callable[[Update, ContextTypes.DEFAULT_TYPE], Awaitable[None]]

    @property
    def name(self) -> str:
        return self.names[0]


def commands_text() -> str:
    lines = ["*Commands*"]
    for title, section in SECTIONS:
        lines.append(f"\n_{title}_")
        for command in section:
            aliases = ", ".join(f"/{alias}" for alias in command.names[1:])
            suffix = f" (also {aliases})" if aliases else ""
            lines.append(f"`{command.usage}` — {command.summary}{suffix}")
    lines.append("\nTo log a shift just send it as a message — /help shows the format.")
    return "\n".join(lines)


async def commands(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(commands_text(), parse_mode=ParseMode.MARKDOWN)


async def unknown(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    command = update.message.text.split()[0]
    await update.message.reply_text(
        f"{command} isn't a command — send /commands to see what I understand."
    )


SECTIONS: tuple[tuple[str, tuple[Command, ...]], ...] = (
    (
        "Logging",
        (
            Command(
                ("log",), "/log <shift>",
                "Log a shift (or just send it as a message)", log_shift,
            ),
            Command(
                ("add", "set", "edit"), "/add location|rate|name|time <event> <value>",
                "Backfill a detail on every shift of an event", add_detail,
            ),
            Command(
                ("delete", "del"), "/delete <id> [id ...]",
                "Delete shifts and show the new totals", delete_shift,
            ),
            Command(
                ("clear",), "/clear [month]",
                "Delete a whole month, or everything", clear_shifts,
            ),
        ),
    ),
    (
        "Your shifts",
        (
            Command(
                ("earnings", "earned"), "/earnings [today|week|month|aug]",
                "Pay earned so far, with a per-shift breakdown", earnings,
            ),
            Command(
                ("total",), "/total [month]",
                "A month's shifts plus month and all-time pay", total,
            ),
            Command(
                ("list",), "/list [month]",
                "Recent shifts, or every shift in a month", list_shifts,
            ),
            Command(
                ("month", "months"), "/month [month]",
                "Summary per month, or one month's shifts", months,
            ),
            Command(
                ("upcoming", "schedule"), "/upcoming [days]",
                "What you're booked for (next 14 days)", upcoming,
            ),
            Command(
                ("calendar", "ics"), "/calendar [month|all|#id]",
                "Add shifts to your calendar (.ics + links)", calendar_export,
            ),
            Command(
                ("calendarlink", "subscribe"), "/calendarlink [new]",
                "A calendar subscription link that stays in sync", calendar_link,
            ),
            Command(
                ("export",), "/export [YYYY-MM]",
                "Download your shifts as CSV", export,
            ),
        ),
    ),
    (
        "Settings",
        (
            Command(
                ("rate",), "/rate [event] [amount]",
                "Show rates, or set the default/event rate", rate,
            ),
            Command(
                ("clearrate",), "/clearrate <event>",
                "Remove an event rate", clear_rate,
            ),
            Command(
                ("currency",), "/currency <code>",
                "Set the currency label", currency,
            ),
            Command(
                ("overtime",), "/overtime <hours> <multiplier>",
                "e.g. /overtime 8 1.5 (/overtime off)", overtime,
            ),
            Command(
                ("break",), "/break <hours> paid|unpaid",
                "Default break when none is mentioned", break_default,
            ),
            Command(
                ("reminders", "reminder"), "/reminders on|off|20:00 [+8]",
                "Message the evening before a shift", reminders,
            ),
        ),
    ),
    (
        "Help",
        (
            Command(
                ("commands", "cmds"), "/commands",
                "This list of commands", commands,
            ),
            Command(
                ("help", "start"), "/help",
                "How to log shifts", start,
            ),
        ),
    ),
)


async def _publish_commands(application: Application) -> None:
    """Show a tidy command menu in Telegram's ⌘ button."""
    menu = [
        BotCommand(command.name, command.summary)
        for _, commands_in_section in SECTIONS
        for command in commands_in_section
    ]
    try:
        await application.bot.set_my_commands(menu)
    except TelegramError:
        logger.exception("Could not publish the command menu")


def build_application(
    token: str, db_path: str, feed_base_url: str | None = None
) -> Application:
    application = Application.builder().token(token).post_init(_publish_commands).build()
    application.bot_data["storage"] = Storage(db_path)
    application.bot_data["feed_base_url"] = feed_base_url

    for _, commands_in_section in SECTIONS:
        for command in commands_in_section:
            application.add_handler(CommandHandler(list(command.names), command.handler))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, log_shift))
    application.add_handler(MessageHandler(filters.COMMAND, unknown))
    application.job_queue.run_repeating(send_due_reminders, interval=60, first=10)
    return application


def main() -> None:
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s - %(message)s", level=logging.INFO
    )
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if not token:
        raise SystemExit("Set TELEGRAM_BOT_TOKEN before starting the bot.")
    db_path = os.environ.get("PAYBOT_DB", "paybot.sqlite3")
    feed_base_url = os.environ.get("PAYBOT_FEED_URL")
    application = build_application(token, db_path, feed_base_url)
    feed_port = os.environ.get("PAYBOT_FEED_PORT")
    if feed_port:
        serve(application.bot_data["storage"], int(feed_port))
    application.run_polling()


if __name__ == "__main__":
    main()
