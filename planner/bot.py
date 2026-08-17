"""Telegram bot that plans the day: timed blocks, tasks, agenda and reminders."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from html import escape
from typing import Awaitable, Callable

from telegram import BotCommand, Update
from telegram.constants import ParseMode
from telegram.error import TelegramError
from telegram.ext import (
    Application,
    ApplicationBuilder,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .agenda import DAY_END, DAY_START, clashing, free_gaps, local_now, local_today
from .parsing import Entry, ParseError, parse_date, parse_entries, parse_entry, parse_time
from .storage import DEFAULT_AGENDA_AT, DEFAULT_UTC_OFFSET_MINUTES, Plan, Storage

logger = logging.getLogger(__name__)

DB_PATH = os.environ.get("PLANNER_DB", "planner.sqlite3")
NUDGE_AHEAD = timedelta(minutes=30)

Handler = Callable[[Update, ContextTypes.DEFAULT_TYPE], Awaitable[None]]


@dataclass(frozen=True)
class Command:
    names: tuple[str, ...]
    usage: str
    summary: str
    handler: Handler
    section: str


SAMPLE = (
    "Send your plans, one per line:\n\n"
    "<code>9am-11am Gym\n"
    "12.30pm lunch with Ada\n"
    "tomorrow 1400-1600 project review\n"
    "buy milk</code>\n\n"
    "A line with times becomes a block in your day, one without becomes a task."
)


def _storage(context: ContextTypes.DEFAULT_TYPE) -> Storage:
    return context.application.bot_data["storage"]


def _offset(storage: Storage, user_id: int) -> int:
    reminder = storage.get_reminder(user_id)
    return DEFAULT_UTC_OFFSET_MINUTES if reminder is None else reminder.utc_offset_minutes


def _today(storage: Storage, user_id: int) -> date:
    return local_today(_offset(storage, user_id))


def _aligned(rows: list[tuple[str, ...]]) -> list[str]:
    """Pad the columns so a monospace block lines up."""
    widths = [max(len(row[column]) for row in rows) for column in range(len(rows[0]))]
    return [
        "  ".join(cell.ljust(widths[column]) for column, cell in enumerate(row)).rstrip()
        for row in rows
    ]


def _block(lines: list[str]) -> str:
    return "<pre>" + "\n".join(escape(line) for line in lines) + "</pre>"


async def _send_html(update: Update, lines: list[str]) -> None:
    await update.message.reply_text("\n".join(lines).strip(), parse_mode=ParseMode.HTML)


def _clock(plan: Plan) -> str:
    if plan.start is None:
        return "—"
    if plan.end is None:
        return plan.start.strftime("%H:%M")
    return f"{plan.start.strftime('%H:%M')}–{plan.end.strftime('%H:%M')}"


def _plan_rows(plans: list[Plan], clashes: set[int]) -> list[tuple[str, ...]]:
    return [
        (
            f"#{plan.id}",
            "✔" if plan.done else "·",
            _clock(plan),
            plan.title,
            "clash" if plan.id in clashes and not plan.done else "",
        )
        for plan in plans
    ]


def _day_label(day: date, today: date) -> str:
    if day == today:
        return f"Today · {day.strftime('%a %d %b')}"
    if day == today + timedelta(days=1):
        return f"Tomorrow · {day.strftime('%a %d %b')}"
    return day.strftime("%a %d %b %Y")


def _gaps_line(plans: list[Plan], day: date, today: date, now: datetime) -> str | None:
    after = now.time() if day == today else None
    if after and after >= DAY_END:
        return None
    gaps = free_gaps([p for p in plans if not p.done], day, after=after)
    if not gaps:
        return (
            f"No free time left between {DAY_START.strftime('%H:%M')} "
            f"and {DAY_END.strftime('%H:%M')}."
        )
    shown = ", ".join(f"{start.strftime('%H:%M')}–{end.strftime('%H:%M')}" for start, end in gaps)
    return f"Free  {shown}"


async def _show_day(update: Update, context: ContextTypes.DEFAULT_TYPE, day: date) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    today = _today(storage, user_id)
    now = local_now(_offset(storage, user_id))
    plans = storage.plans_on(user_id, day)
    heading = f"🗓 <b>{escape(_day_label(day, today))}</b>"
    if not plans:
        await _send_html(update, [heading, "Nothing planned yet — send me a line to add one."])
        return
    lines = [heading, _block(_aligned(_plan_rows(plans, clashing(plans))))]
    left = sum(1 for plan in plans if not plan.done)
    lines.append(f"{len(plans)} planned · <b>{left} left</b>")
    gaps = _gaps_line(plans, day, today, now)
    if gaps:
        lines.append(gaps)
    await _send_html(update, lines)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await _send_html(
        update,
        [
            "👋 <b>Your day planner</b>",
            SAMPLE,
            "Then <code>/today</code> for the plan, <code>/done 3</code> to tick something off, "
            "<code>/commands</code> for everything else.",
        ],
    )


async def commands(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    lines = ["📋 <b>Commands</b>"]
    for section in ("Planning", "Your day", "Reminders", "Help"):
        rows = [
            (command.usage, command.summary)
            for command in COMMANDS
            if command.section == section
        ]
        if rows:
            lines.append(f"\n<b>{section}</b>")
            lines.append(_block(_aligned(rows)))
    await _send_html(update, lines)


def _added_lines(entries: list[tuple[int, Entry]], today: date) -> list[str]:
    rows = [
        (
            f"#{ref}",
            _day_label(entry.day, today).split(" · ")[0],
            _clock(Plan(ref, entry.day, entry.title, entry.start, entry.end, False)),
            entry.title,
        )
        for ref, entry in entries
    ]
    return [_block(_aligned(rows))]


async def add(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Store every line of the message as a block or a task."""
    storage = _storage(context)
    user_id = update.effective_user.id
    today = _today(storage, user_id)
    text = " ".join(context.args) if context.args else (update.message.text or "")
    results = parse_entries(text, today=today)
    if not results:
        await _send_html(update, ["I didn't catch a plan there.", SAMPLE])
        return

    stored: list[tuple[int, Entry]] = []
    problems: list[str] = []
    for line, outcome in results:
        if isinstance(outcome, ParseError):
            problems.append(f"{line} — {outcome}")
            continue
        ref = storage.add_plan(user_id, outcome.day, outcome.title, outcome.start, outcome.end)
        stored.append((ref, outcome))

    lines: list[str] = []
    if stored:
        lines.append(f"✅ <b>Added {len(stored)}</b>")
        lines.extend(_added_lines(stored, today))
        days = {entry.day for _, entry in stored}
        for day in sorted(days):
            plans = storage.plans_on(user_id, day)
            clashes = clashing(plans) & {ref for ref, _ in stored}
            if clashes:
                lines.append(
                    f"⚠️ Clash on {escape(_day_label(day, today))} — "
                    f"{', '.join(f'#{ref}' for ref in sorted(clashes))} overlap something else."
                )
    if problems:
        lines.append("⚠️ <b>Couldn't read</b>")
        lines.append(_block(problems))
    await _send_html(update, lines)


async def today(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    await _show_day(update, context, _today(storage, update.effective_user.id))


async def tomorrow(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    await _show_day(
        update, context, _today(storage, update.effective_user.id) + timedelta(days=1)
    )


async def day_plan(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """The plan for any date: /day friday, /day 14/8."""
    storage = _storage(context)
    user_id = update.effective_user.id
    if not context.args:
        await _show_day(update, context, _today(storage, user_id))
        return
    try:
        day = parse_date(" ".join(context.args), _today(storage, user_id))
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    await _show_day(update, context, day)


async def week(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """The next seven days, day by day."""
    storage = _storage(context)
    user_id = update.effective_user.id
    start_day = _today(storage, user_id)
    plans = storage.plans_between(user_id, start_day, start_day + timedelta(days=6))
    if not plans:
        await update.message.reply_text("Nothing planned in the next 7 days.")
        return
    clashes = clashing(plans)
    lines = ["🗓 <b>Next 7 days</b>"]
    for offset in range(7):
        day = start_day + timedelta(days=offset)
        of_the_day = [plan for plan in plans if plan.day == day]
        if not of_the_day:
            continue
        lines.append(f"\n<b>{escape(_day_label(day, start_day))}</b>")
        lines.append(_block(_aligned(_plan_rows(of_the_day, clashes))))
    left = sum(1 for plan in plans if not plan.done)
    lines.append(f"{len(plans)} planned · <b>{left} left</b>")
    await _send_html(update, lines)


async def todo(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Everything still open, whenever it was planned for."""
    storage = _storage(context)
    user_id = update.effective_user.id
    plans = storage.open_plans(user_id)
    if not plans:
        await update.message.reply_text("Nothing outstanding — all done. 🎉")
        return
    today_local = _today(storage, user_id)
    rows = [
        (
            f"#{plan.id}",
            _day_label(plan.day, today_local).split(" · ")[0],
            _clock(plan),
            plan.title,
            "overdue" if plan.day < today_local else "",
        )
        for plan in plans
    ]
    await _send_html(
        update,
        ["📝 <b>Still to do</b>", _block(_aligned(rows)), f"<b>{len(plans)} open</b>"],
    )


def _numbers(args: list[str]) -> list[int]:
    return [int(arg.lstrip("#")) for arg in args if arg.lstrip("#").isdigit()]


async def _mark(update: Update, context: ContextTypes.DEFAULT_TYPE, done: bool) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    refs = _numbers(context.args or [])
    if not refs:
        await update.message.reply_text(
            "Give me the number, e.g. /done 3" if done else "Give me the number, e.g. /undone 3"
        )
        return
    changed = [ref for ref in refs if storage.set_done(user_id, ref, done)]
    missing = sorted(set(refs) - set(changed))
    word = "Done" if done else "Reopened"
    lines = []
    if changed:
        titles = [storage.get_plan(user_id, ref) for ref in changed]
        rows = [
            (f"#{plan.id}", plan.title) for plan in titles if plan is not None
        ]
        lines += [f"{'✅' if done else '↩️'} <b>{word}</b>", _block(_aligned(rows))]
    if missing:
        lines.append(f"No plan numbered {', '.join(f'#{ref}' for ref in missing)}.")
    left = len(storage.open_plans(user_id))
    lines.append(f"<b>{left} open</b> in total")
    await _send_html(update, lines)


async def done(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await _mark(update, context, True)


async def undone(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await _mark(update, context, False)


async def move(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Reschedule a plan: /move 3 tomorrow 4pm-5pm."""
    storage = _storage(context)
    user_id = update.effective_user.id
    args = context.args or []
    refs = _numbers(args[:1])
    if not refs or len(args) < 2:
        await update.message.reply_text("Use: /move 3 tomorrow 4pm-5pm")
        return
    ref = refs[0]
    plan = storage.get_plan(user_id, ref)
    if plan is None:
        await update.message.reply_text(f"No plan numbered #{ref}.")
        return
    today_local = _today(storage, user_id)
    try:
        entry = parse_entry(f"{' '.join(args[1:])} {plan.title}", today=today_local)
    except ParseError as exc:
        await update.message.reply_text(str(exc))
        return
    storage.move_plan(user_id, ref, entry.day, entry.start, entry.end)
    moved = storage.get_plan(user_id, ref)
    if moved is None:
        await update.message.reply_text(f"No plan numbered #{ref}.")
        return
    await _send_html(
        update,
        [
            "🔁 <b>Moved</b>",
            _block(
                _aligned(
                    [
                        (
                            f"#{moved.id}",
                            _day_label(moved.day, today_local).split(" · ")[0],
                            _clock(moved),
                            moved.title,
                        )
                    ]
                )
            ),
        ],
    )


async def delete(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    storage = _storage(context)
    user_id = update.effective_user.id
    refs = _numbers(context.args or [])
    if not refs:
        await update.message.reply_text("Give me the number, e.g. /delete 3")
        return
    removed = [
        plan
        for plan in (storage.get_plan(user_id, ref) for ref in refs)
        if plan is not None and storage.delete_plan(user_id, plan.id)
    ]
    if not removed:
        await update.message.reply_text("Nothing matched those numbers.")
        return
    rows = [(f"#{plan.id}", _clock(plan), plan.title) for plan in removed]
    await _send_html(update, ["🗑 <b>Deleted</b>", _block(_aligned(rows))])


async def clear(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Wipe a day (or everything) once you confirm it."""
    storage = _storage(context)
    user_id = update.effective_user.id
    args = [arg for arg in (context.args or [])]
    confirmed = bool(args) and args[-1].lower() == "confirm"
    if confirmed:
        args = args[:-1]
    today_local = _today(storage, user_id)
    day: date | None = None
    if args and args[0].lower() != "all":
        try:
            day = parse_date(" ".join(args), today_local)
        except ParseError as exc:
            await update.message.reply_text(str(exc))
            return
    scope = _day_label(day, today_local) if day else "everything"
    if not confirmed:
        await update.message.reply_text(
            f"This deletes {scope}. Send the same command with 'confirm' to go ahead."
        )
        return
    removed = storage.delete_plans(user_id, day)
    await _send_html(update, [f"🗑 Cleared <b>{escape(scope)}</b> — {removed} removed."])


async def free(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Where the gaps are in a day."""
    storage = _storage(context)
    user_id = update.effective_user.id
    today_local = _today(storage, user_id)
    day = today_local
    if context.args:
        try:
            day = parse_date(" ".join(context.args), today_local)
        except ParseError as exc:
            await update.message.reply_text(str(exc))
            return
    plans = storage.plans_on(user_id, day)
    now = local_now(_offset(storage, user_id))
    gaps = _gaps_line(plans, day, today_local, now)
    await _send_html(
        update,
        [
            f"🕳 <b>{escape(_day_label(day, today_local))}</b>",
            gaps or "The day is over — nothing free left.",
        ],
    )


async def reminders(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """/reminders on|off|08:00 [+8] — the morning agenda and 30-minute heads-ups."""
    storage = _storage(context)
    user_id = update.effective_user.id
    chat_id = update.effective_chat.id
    current = storage.get_reminder(user_id)
    agenda_at = current.agenda_at if current else DEFAULT_AGENDA_AT
    offset = current.utc_offset_minutes if current else DEFAULT_UTC_OFFSET_MINUTES
    enabled = current.enabled if current else False
    args = [arg.lower() for arg in (context.args or [])]

    if not args:
        state = "on" if enabled else "off"
        await _send_html(
            update,
            [
                f"⏰ Reminders are <b>{state}</b> — agenda at "
                f"{agenda_at.strftime('%H:%M')} (UTC{offset // 60:+d}), "
                "plus a nudge 30 minutes before each timed plan.",
                "Change with <code>/reminders on</code>, <code>/reminders 07:30 +8</code> "
                "or <code>/reminders off</code>.",
            ],
        )
        return

    for arg in args:
        if arg == "on":
            enabled = True
        elif arg == "off":
            enabled = False
        elif arg.startswith(("+", "-")) and arg[1:].replace(":", "").isdigit():
            hours, _, minutes = arg[1:].partition(":")
            total = int(hours) * 60 + int(minutes or 0)
            offset = total if arg[0] == "+" else -total
        else:
            try:
                agenda_at = parse_time(arg)
                enabled = True
            except ParseError:
                await update.message.reply_text(f"I didn't understand {arg!r}.")
                return

    storage.save_reminder(user_id, chat_id, agenda_at, offset, enabled)
    state = "on" if enabled else "off"
    await _send_html(
        update,
        [
            f"⏰ Reminders <b>{state}</b> — agenda at {agenda_at.strftime('%H:%M')} "
            f"(UTC{offset // 60:+d})."
        ],
    )


def _agenda_lines(plans: list[Plan], day: date) -> list[str]:
    rows = [(_clock(plan), plan.title) for plan in plans]
    return [
        f"☀️ <b>{escape(day.strftime('%A %d %b'))}</b>",
        _block(_aligned(rows)),
        f"<b>{len(plans)} planned</b>",
    ]


async def tick(context: ContextTypes.DEFAULT_TYPE) -> None:
    """Once a minute: send the morning agenda and any 30-minute heads-up that is due."""
    storage: Storage = context.application.bot_data["storage"]
    for reminder in storage.enabled_reminders():
        now = local_now(reminder.utc_offset_minutes)
        day = now.date()
        plans = [plan for plan in storage.plans_on(reminder.user_id, day) if not plan.done]
        if plans and now.time() >= reminder.agenda_at and reminder.last_sent_on != day:
            await _send(context, reminder.chat_id, _agenda_lines(plans, day))
            storage.mark_agenda_sent(reminder.user_id, day)
        for plan in storage.pending_nudges(reminder.user_id, day):
            due = datetime.combine(day, plan.start or time())
            if now >= due - NUDGE_AHEAD:
                storage.mark_nudged(reminder.user_id, plan.id)
                if now <= due:
                    await _send(
                        context,
                        reminder.chat_id,
                        [
                            f"⏰ <b>{escape(plan.title)}</b> at "
                            f"{(plan.start or time()).strftime('%H:%M')} "
                            f"— in {int((due - now).total_seconds() // 60)} min."
                        ],
                    )


async def _send(context: ContextTypes.DEFAULT_TYPE, chat_id: int, lines: list[str]) -> None:
    try:
        await context.bot.send_message(
            chat_id, "\n".join(lines).strip(), parse_mode=ParseMode.HTML
        )
    except TelegramError:
        logger.exception("Could not send a reminder to chat %s", chat_id)


async def unknown(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text("I don't know that one — /commands lists them all.")


COMMANDS: tuple[Command, ...] = (
    Command(("plan", "add"), "/plan <line>", "Add a block or a task", add, "Planning"),
    Command(("move",), "/move 3 tomorrow 4pm", "Reschedule a plan", move, "Planning"),
    Command(("done",), "/done 3", "Tick a plan off", done, "Planning"),
    Command(("undone", "reopen"), "/undone 3", "Put it back on the list", undone, "Planning"),
    Command(("delete", "del"), "/delete 3", "Remove a plan", delete, "Planning"),
    Command(("clear",), "/clear [day|all]", "Wipe a day (asks first)", clear, "Planning"),
    Command(("today",), "/today", "Today's plan", today, "Your day"),
    Command(("tomorrow",), "/tomorrow", "Tomorrow's plan", tomorrow, "Your day"),
    Command(("day", "on"), "/day <date>", "Any day's plan", day_plan, "Your day"),
    Command(("week",), "/week", "The next 7 days", week, "Your day"),
    Command(("todo", "open"), "/todo", "Everything still open", todo, "Your day"),
    Command(("free", "gaps"), "/free [date]", "Where your free time is", free, "Your day"),
    Command(
        ("reminders", "remind"),
        "/reminders on|off|08:00",
        "Morning agenda + 30-min nudges",
        reminders,
        "Reminders",
    ),
    Command(("commands", "cmds"), "/commands", "This list", commands, "Help"),
    Command(("help", "start"), "/help", "How to plan your day", start, "Help"),
)


async def _publish_commands(application: Application) -> None:
    await application.bot.set_my_commands(
        [BotCommand(command.names[0], command.summary) for command in COMMANDS]
    )


def build_application(token: str, db_path: str = DB_PATH) -> Application:
    application = ApplicationBuilder().token(token).post_init(_publish_commands).build()
    application.bot_data["storage"] = Storage(db_path)
    for command in COMMANDS:
        application.add_handler(CommandHandler(list(command.names), command.handler))
    application.add_handler(MessageHandler(filters.COMMAND, unknown))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, add))
    if application.job_queue is not None:
        application.job_queue.run_repeating(tick, interval=60, first=10)
    return application


def main() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if not token:
        raise SystemExit("Set TELEGRAM_BOT_TOKEN to your @BotFather token.")
    build_application(token).run_polling()


if __name__ == "__main__":
    main()
