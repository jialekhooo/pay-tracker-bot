"""Run the bots and the calendar feed together as one always-on web service.

The pay tracker polls in the background while FastAPI serves each user's
private .ics subscription, so a single deployment keeps reminders and calendar
sync alive. The day planner rides along in the same machine when its own token
is set, keeping its plans in a separate database.
"""

from __future__ import annotations

import logging
import os
import shutil
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Response
from telegram.ext import Application

from planner.bot import build_application as build_planner

from .bot import build_application
from .feed import feed_body

logger = logging.getLogger(__name__)


TOKEN_FILE = os.environ.get("PAYBOT_TOKEN_FILE", ".paybot-token")


def bot_token() -> str | None:
    """The bot token from the environment, falling back to a token file."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if token:
        return token
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            return handle.read().strip() or None
    except OSError:
        return None


def database_path() -> str:
    """Prefer the mounted volume so shifts survive a redeploy."""
    default = "/data/paybot.sqlite3" if os.path.isdir("/data") else "paybot.sqlite3"
    path = os.environ.get("PAYBOT_DB", default)
    seed = os.environ.get("PAYBOT_SEED_DB", "paybot-seed.sqlite3")
    if not os.path.exists(path) and os.path.exists(seed):
        shutil.copyfile(seed, path)
        logger.info("Seeded %s from %s", path, seed)
    return path


def feed_base_url() -> str | None:
    if os.environ.get("PAYBOT_FEED_URL"):
        return os.environ["PAYBOT_FEED_URL"]
    app_name = os.environ.get("FLY_APP_NAME")
    return f"https://{app_name}.fly.dev" if app_name else None


def planner_database_path() -> str:
    """The planner keeps its plans beside the shifts, on the same volume."""
    default = "/data/planner.sqlite3" if os.path.isdir("/data") else "planner.sqlite3"
    return os.environ.get("PLANNER_DB", default)


async def _start(application: Application) -> None:
    await application.initialize()
    await application.start()
    await application.updater.start_polling(drop_pending_updates=True)


async def _stop(application: Application) -> None:
    await application.updater.stop()
    await application.stop()
    await application.shutdown()


@asynccontextmanager
async def lifespan(app: FastAPI):
    token = bot_token()
    if not token:
        raise RuntimeError("Set TELEGRAM_BOT_TOKEN before starting the service.")
    application = build_application(token, database_path(), feed_base_url())
    app.state.storage = application.bot_data["storage"]
    running = [application]
    planner_token = os.environ.get("PLANNER_BOT_TOKEN")
    if planner_token:
        running.append(build_planner(planner_token, planner_database_path()))
    for bot in running:
        await _start(bot)
    logger.info("%d bot(s) polling; calendar feed at %s", len(running), feed_base_url())
    try:
        yield
    finally:
        for bot in running:
            await _stop(bot)


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/{token}.ics")
async def calendar_feed(token: str) -> Response:
    body = feed_body(app.state.storage, token)
    if body is None:
        raise HTTPException(status_code=404, detail="Unknown calendar feed")
    return Response(
        content=body,
        media_type="text/calendar; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="shifts.ics"'},
    )
