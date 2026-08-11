"""A tiny HTTP server serving each user a private, always-current .ics feed.

Calendar apps (Google, Apple, Outlook) poll a subscription URL and keep the
events in sync, so shifts logged or deleted in Telegram show up without any
re-import. Apps that read your phone's calendars — TimeTree among them — then
pick the shifts up from there.
"""

from __future__ import annotations

import logging
import secrets
import threading
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .calendar_export import to_ics
from .storage import Storage

logger = logging.getLogger(__name__)

PAST_DAYS = 90
FUTURE_DAYS = 400


def issue_token(storage: Storage, user_id: int, refresh: bool = False) -> str:
    """The user's feed token, creating (or rotating) it when needed."""
    token = None if refresh else storage.get_feed_token(user_id)
    if token is None:
        token = secrets.token_urlsafe(24)
        storage.save_feed_token(user_id, token)
    return token


def feed_body(storage: Storage, token: str, today: date | None = None) -> str | None:
    """The .ics for the feed's owner, or None when the token is unknown."""
    user_id = storage.user_for_feed_token(token)
    if user_id is None:
        return None
    today = today or date.today()
    records = storage.shifts_between(
        user_id, today - timedelta(days=PAST_DAYS), today + timedelta(days=FUTURE_DAYS)
    )
    return to_ics(records)


class _Handler(BaseHTTPRequestHandler):
    storage: Storage

    def do_GET(self) -> None:  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        token = self.path.strip("/").removesuffix(".ics")
        body = feed_body(self.storage, token) if token else None
        if body is None:
            self.send_error(404, "Unknown calendar feed")
            return
        payload = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/calendar; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Disposition", 'attachment; filename="shifts.ics"')
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args) -> None:
        logger.info("feed %s", fmt % args)


def serve(storage: Storage, port: int) -> ThreadingHTTPServer:
    """Start the feed server on a daemon thread and return it."""
    handler = type("FeedHandler", (_Handler,), {"storage": storage})
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True, name="ics-feed").start()
    logger.info("Calendar feed listening on port %s", port)
    return server
