"""In-house error tracking: server errors and the app's crash and hang reports, kept for 30 days.

No third party sees them. Reports are not tied to an account: the app sends Apple's MetricKit
diagnostics (crashes, hangs, CPU and disk exceptions) with the app version and device model, and the
server records any unhandled error with the route that failed. Read them with:

    fly ssh console -a howmuch-ios -C "python -m howmuch_api.diagnostics"
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
import traceback
from collections import Counter

from fastapi import APIRouter, HTTPException, Request

from .database import limit

router = APIRouter()
KEEP_SECONDS = 30 * 24 * 3600
MAX_BODY = 256_000
KINDS = {'crash', 'hang', 'cpu', 'disk', 'launch'}

SCHEMA = """
CREATE TABLE IF NOT EXISTS diagnostics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created INTEGER NOT NULL,
  source TEXT NOT NULL,          -- 'app' or 'server'
  kind TEXT NOT NULL,            -- crash, hang, cpu, disk, launch, or the server's error type
  version TEXT NOT NULL DEFAULT '',
  device TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL,         -- one line: the signal or exception, or the failing route
  detail TEXT NOT NULL DEFAULT '' -- the top of the call stack, trimmed
);
CREATE INDEX IF NOT EXISTS diagnostics_created ON diagnostics(created);
"""


def ensure_schema(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)


def _clip(value, size: int) -> str:
    return str(value or '')[:size]


def _record(db: sqlite3.Connection, source: str, kind: str, version: str, device: str, summary: str, detail: str) -> None:
    now = int(time.time())
    with db:
        db.execute('DELETE FROM diagnostics WHERE created<?', (now - KEEP_SECONDS,))
        db.execute('INSERT INTO diagnostics(created,source,kind,version,device,summary,detail) VALUES(?,?,?,?,?,?,?)',
                   (now, source, _clip(kind, 40), _clip(version, 40), _clip(device, 60), _clip(summary, 300), _clip(detail, 4000)))


def record_server_error(db: sqlite3.Connection, route: str, error: BaseException) -> None:
    """An unhandled error on the server: its type, the route (never the raw URL, which can hold tokens) and the stack."""
    stack = ''.join(traceback.format_exception(type(error), error, error.__traceback__)[-12:])
    _record(db, 'server', type(error).__name__, os.environ.get('FLY_IMAGE_REF', '')[-40:], '', route, stack)


@router.post('/diagnostics')
async def app_diagnostics(request: Request) -> dict:
    """Crash and hang reports from the app (MetricKit). Not signed in, so they stay apart from any account."""
    limit(request, 'diagnostics', maximum=30)
    raw = await request.body()
    if len(raw) > MAX_BODY:
        raise HTTPException(413)
    try:
        report = json.loads(raw)
        items = report['items']
        assert isinstance(items, list)
    except (ValueError, KeyError, AssertionError, TypeError):
        raise HTTPException(400, 'Expected {"version", "device", "items": [...]}')
    db = request.app.state.storage._conn
    saved = 0
    for item in items[:20]:
        if not isinstance(item, dict) or item.get('kind') not in KINDS:
            continue
        _record(db, 'app', item['kind'], _clip(report.get('version'), 40), _clip(report.get('device'), 60),
                _clip(item.get('summary'), 300), _clip(item.get('detail'), 4000))
        saved += 1
    return {'saved': saved}


def summary(db: sqlite3.Connection, days: int = 7) -> str:
    """What went wrong lately, grouped so repeats show as one line with a count."""
    since = int(time.time()) - days * 24 * 3600
    rows = db.execute('SELECT source,kind,version,summary,created FROM diagnostics WHERE created>=? ORDER BY created DESC', (since,)).fetchall()
    if not rows:
        return f'No errors, crashes or hangs in the last {days} days.'
    groups = Counter((r[0], r[1], r[2], r[3]) for r in rows)
    lines = [f'{len(rows)} reports in the last {days} days:']
    for (source, kind, version, text), count in groups.most_common(30):
        lines.append(f'{count:>4} × {source:6} {kind:12} {version:12} {text}')
    return '\n'.join(lines)


if __name__ == '__main__':
    connection = sqlite3.connect(os.environ.get('HOWMUCH_DB', '/data/howmuch-ios.sqlite3'))
    ensure_schema(connection)
    print(summary(connection))
