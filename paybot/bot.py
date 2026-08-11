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

from .parsing import ParseError, parse_shift
from .pay import calculate_pay, round_money
from .storage import Storage

logger = logging.getLogger(__name__)

HELP_TEXT = """*Pay tracker*

Log a shift by sending:
`<date> <start> <end> <event name>`

Examples:
`12/8 6pm-11.30pm Wedding gig`
`2026-08-12 18:00 23:30 Wedding gig`
`today 9am to 5pm Roadshow`

Commands:
/rate — show your current rates
/rate <amount> — set your default hourly rate
/rate <event name> <amount> — set a rate for one event name
/clearrate <event name> — remove an event rate
/currency <code> — set the currency label
/overtime <hours> <multiplier> — e.g. `/overtime 8 1.5` (`/overtime off` to disable)
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


async def log_shift(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    text = update.message.text or ""
    if text.startswith("/log"):
        text = text[len("/log") :]
    try:
        shift = parse_shift(text)
    except ParseError as exc:
        await update.message.reply_text(
            f"{exc}\n\nSend /help to see the accepted formats.",
        )
        return

    config = storage.get_config(user_id)
    hours = Decimal(str(shift.hours))
    pay = calculate_pay(shift.hours, shift.event, config)
    shift_id = storage.add_shift(
        user_id=user_id,
        day=shift.day,
        start=shift.start,
        end=shift.end,
        event=shift.event,
        hours=hours,
        pay=pay,
        currency=config.currency,
    )
    await update.message.reply_text(
        f"Logged #{shift_id}: {shift.event}\n"
        f"{shift.day.isoformat()} "
        f"{shift.start.strftime('%H:%M')}–{shift.end.strftime('%H:%M')} "
        f"({hours.normalize()}h @ {_money(config.rate_for(shift.event), config.currency)}/h)\n"
        f"Pay: {_money(pay, config.currency)}"
    )


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
    writer.writerow(["id", "date", "start", "end", "event", "hours", "pay", "currency"])
    for r in records:
        writer.writerow(
            [
                r.id,
                r.day.isoformat(),
                r.start.strftime("%H:%M"),
                r.end.strftime("%H:%M"),
                r.event,
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
