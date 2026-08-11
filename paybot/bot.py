"""Telegram bot that logs shifts and calculates pay."""

from __future__ import annotations

import csv
import io
import logging
import os
from dataclasses import replace
from decimal import Decimal, InvalidOperation

from telegram import Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .parsing import Break, ParseError, Shift, parse_shifts
from .pay import RateConfig, calculate_pay, round_money
from .storage import Storage

logger = logging.getLogger(__name__)

HELP_TEXT = """*Pay tracker*

Log a shift by sending:
`<date> <start> <end> <event name>`

Examples:
`12/8 6pm-11.30pm Wedding gig`
`2026-08-12 18:00 23:30 Wedding gig`
`today 9am to 5pm Roadshow`

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

Commands:
/rate — show your current rates
/rate <amount> — set your default hourly rate
/rate <event name> <amount> — set a rate for one event name
/clearrate <event name> — remove an event rate
/currency <code> — set the currency label
/overtime <hours> <multiplier> — e.g. `/overtime 8 1.5` (`/overtime off` to disable)
/break <hours> paid|unpaid — default break when you don't mention one (`/break off`)
/list [YYYY-MM] — recent shifts
/total [YYYY-MM] — total pay (defaults to this month)
/delete <id> — delete a shift
/export [YYYY-MM] — CSV of your shifts
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
        f"{shift.event} — {hours.normalize()}h @ {_money(rate, currency)}/h = "
        f"{_money(pay, currency)}"
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
    total_pay = Decimal("0")
    for line, result in parsed:
        if isinstance(result, ParseError):
            failed.append(f"• {line} — {result}")
            continue
        shift = _apply_default_break(result, config)
        shift_id, hours, pay, rate = _store_shift(storage, user_id, shift, config)
        total_pay += pay
        logged.append(_summarise(shift, shift_id, hours, pay, rate, config.currency))

    reply: list[str] = []
    if logged:
        reply.append(f"Logged {len(logged)} shift{'s' if len(logged) > 1 else ''}:")
        reply.extend(logged)
        if len(logged) > 1:
            reply.append(f"Total: {_money(total_pay, config.currency)}")
    if failed:
        reply.append("Could not read:")
        reply.extend(failed)
        reply.append("Send /help to see the accepted formats.")
    await update.message.reply_text("\n".join(reply))


async def list_shifts(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    month = context.args[0] if context.args else None
    records = storage.list_shifts(update.effective_user.id, month=month, limit=20)
    if not records:
        await update.message.reply_text("No shifts logged yet.")
        return
    lines = [
        f"#{r.id} {r.day.isoformat()} "
        f"{r.start.strftime('%H:%M')}–{r.end.strftime('%H:%M')} "
        f"{r.event} — {_money(r.pay, r.currency)}"
        for r in records
    ]
    await update.message.reply_text("\n".join(lines))


async def total(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    month = context.args[0] if context.args else None
    records = storage.list_shifts(user_id, month=month)
    if not records:
        await update.message.reply_text("No shifts logged for that period.")
        return
    currency_code = records[0].currency
    hours = sum((r.hours for r in records), Decimal("0"))
    pay = sum((r.pay for r in records), Decimal("0"))
    label = month or "all time"
    await update.message.reply_text(
        f"{label}: {len(records)} shifts, {hours.normalize()}h, "
        f"total {_money(pay, currency_code)}"
    )


async def delete_shift(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    if not context.args or not context.args[0].lstrip("#").isdigit():
        await update.message.reply_text("Usage: /delete <id>")
        return
    shift_id = int(context.args[0].lstrip("#"))
    if storage.delete_shift(update.effective_user.id, shift_id):
        await update.message.reply_text(f"Deleted shift #{shift_id}.")
    else:
        await update.message.reply_text(f"No shift #{shift_id} found.")


async def export(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    month = context.args[0] if context.args else None
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


def build_application(token: str, db_path: str) -> Application:
    application = Application.builder().token(token).build()
    application.bot_data["storage"] = Storage(db_path)

    application.add_handler(CommandHandler(["start", "help"], start))
    application.add_handler(CommandHandler("rate", rate))
    application.add_handler(CommandHandler("clearrate", clear_rate))
    application.add_handler(CommandHandler("currency", currency))
    application.add_handler(CommandHandler("overtime", overtime))
    application.add_handler(CommandHandler("break", break_default))
    application.add_handler(CommandHandler("log", log_shift))
    application.add_handler(CommandHandler("list", list_shifts))
    application.add_handler(CommandHandler("total", total))
    application.add_handler(CommandHandler("delete", delete_shift))
    application.add_handler(CommandHandler("export", export))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, log_shift))
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
