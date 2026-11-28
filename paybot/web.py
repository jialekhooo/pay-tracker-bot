from __future__ import annotations

import asyncio
import logging
import os
import shutil
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import FastAPI, HTTPException, Response
from fastapi.staticfiles import StaticFiles

from .bot import _publish_commands, build_application
from .feed import feed_body
from .webapp import router as webapp_router

logging.basicConfig(format="%(asctime)s %(levelname)s %(name)s - %(message)s", level=logging.INFO)
# httpx logs each request URL at INFO, and Telegram API URLs contain the bot token.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logger = logging.getLogger(__name__)

STATIC_DIR = Path(__file__).parent / "static" / "webapp"

TOKEN_FILE = os.environ.get("PAYBOT_TOKEN_FILE", ".paybot-token")


def bot_token() -> str | None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if token:
        return token
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            return handle.read().strip() or None
    except OSError:
        return None


def database_path() -> str:
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


def webapp_url() -> str | None:
    if os.environ.get("PAYBOT_WEBAPP_URL"):
        return os.environ["PAYBOT_WEBAPP_URL"]
    base = feed_base_url()
    return f"{base.rstrip('/')}/webapp" if base else None


@asynccontextmanager
async def lifespan(app: FastAPI):
    token = bot_token()
    if not token:
        raise RuntimeError("Set TELEGRAM_BOT_TOKEN before starting the service.")
    application = build_application(token, database_path(), feed_base_url(), webapp_url())
    app.state.storage = application.bot_data["storage"]
    app.state.bot_token = token
    app.state.feed_base_url = feed_base_url()
    await application.initialize()
    await _publish_commands(application)
    await application.start()
    await application.updater.start_polling(drop_pending_updates=True)
    logger.info("Bot polling; calendar feed at %s; mini app at %s", feed_base_url(), webapp_url())
    from .gmail_payments import poll_mailboxes
    payment_poll = asyncio.create_task(poll_mailboxes(app.state.storage))
    try:
        yield
    finally:
        payment_poll.cancel()
        with suppress(asyncio.CancelledError):
            await payment_poll
        await application.updater.stop()
        await application.stop()
        await application.shutdown()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)
app.include_router(webapp_router)
if STATIC_DIR.is_dir():
    app.mount("/webapp", StaticFiles(directory=STATIC_DIR, html=True), name="webapp")


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/{token}.ics")
async def calendar_feed(token: str) -> Response:
    body = feed_body(app.state.storage, token)
    if body is None:
        raise HTTPException(status_code=404, detail="Unknown calendar feed")
    return Response(content=body, media_type="text/calendar; charset=utf-8")
