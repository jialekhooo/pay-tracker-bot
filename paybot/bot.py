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
from .parsing import Break, ParseError, Shift, parse_shifts, parse_time
from .pay import RateConfig, calculate_pay, round_money
from .reminders import (
    DEFAULT_SEND_AT,
    DEFAULT_UTC_OFFSET_MINUTES,
    due_reminders,
    format_offset,
    parse_offset,
)
from .schedule import find_clashes
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
                f"Default break: {config.default_break_hours.normalize()}h "
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
        f"Default break: {hours.normalize()}h ({'paid' if paid else 'unpaid'}). "
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
        f"{hours.normalize()}h @ {_money(rate, currency)}/h = {_money(pay, currency)}"
    )
    if shift.rest.hours:
        kind = "paid" if shift.rest.paid else "unpaid"
        line += f" ({Decimal(str(shift.rest.hours)).normalize()}h {kind} break)"
    return line


async def log_shift(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    text = update.message.text or ""
    if text.startswith("/log"):
        text = text[len("/log") :]
    config = storage.get_config(user_id)

    parsed = parse_shifts(text, default_break_paid=config.default_break_paid)
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
        f"{record.hours.normalize()}h — {_money(record.pay, record.currency)}"
    )


def _month_label(month: str) -> str:
    year, index = month.split("-")
    return f"{calendar.month_name[int(index)]} {year}"


async def list_shifts(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    try:
        month = parse_month(context.args)
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
            f"Total: {len(records)} shifts, {hours.normalize()}h, "
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
        f"{round_money(s.hours).normalize()}h, {_money(s.pay, s.currency)}"
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
    today = date.today()
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
    try:
        month = parse_month(context.args)
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    month = month or date.today().strftime("%Y-%m")
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
        f"Total: {len(records)} shifts, {hours.normalize()}h, {_money(pay, currency_code)}"
    )
    lines.append(f"All time: {_money(grand_total, currency_code)}")
    await update.message.reply_text("\n".join(lines))


def _totals_line(storage: Storage, user_id: int, month: str | None, currency: str) -> str:
    """Recomputed totals so the user sees numbers drop after a delete."""
    lines = []
    if month:
        records = storage.list_shifts(user_id, month=month)
        pay = sum((r.pay for r in records), Decimal("0"))
        hours = sum((r.hours for r in records), Decimal("0"))
        lines.append(
            f"{_month_label(month)} now: {len(records)} shifts, "
            f"{hours.normalize()}h, {_money(pay, currency)}"
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
        month = parse_month(args)
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
        month = parse_month(context.args)
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
    month = parse_month(args)
    if month:
        return storage.list_shifts(user_id, month=month), _month_label(month)
    today = date.today()
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

    reminder = storage.get_reminder(user_id)
    offset = reminder.utc_offset_minutes if reminder else DEFAULT_UTC_OFFSET_MINUTES
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


def build_application(token: str, db_path: str) -> Application:
    application = Application.builder().token(token).post_init(_publish_commands).build()
    application.bot_data["storage"] = Storage(db_path)

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
    build_application(token, db_path).run_polling()


if __name__ == "__main__":
    main()
