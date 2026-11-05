"""The iOS service owns this database; it never opens a bot database."""
from __future__ import annotations
import hashlib
import secrets
import time
from pathlib import Path
import simplejson as json
from fastapi import HTTPException, Request, Response
from .work_storage import Storage

SCHEMA = """
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS accounts (
 id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL UNIQUE,
 apple_sub TEXT NOT NULL UNIQUE, email TEXT, display_name TEXT NOT NULL DEFAULT '',
 created INTEGER NOT NULL, apple_refresh TEXT
);
CREATE TABLE IF NOT EXISTS auth_challenges (
 challenge_hash TEXT PRIMARY KEY, nonce_hash TEXT NOT NULL, expires INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS auth_sessions (
 session_id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 access_hash TEXT NOT NULL UNIQUE, refresh_hash TEXT NOT NULL UNIQUE, revoke_hash TEXT NOT NULL UNIQUE,
 access_expires INTEGER NOT NULL, refresh_expires INTEGER NOT NULL,
 device_id TEXT NOT NULL, created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS documents (
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 revision INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL, updated INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS auth_limits (
 bucket TEXT PRIMARY KEY, window INTEGER NOT NULL, requests INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS push_devices (
 device_id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 session_id TEXT NOT NULL REFERENCES auth_sessions(session_id) ON DELETE CASCADE,
 token TEXT NOT NULL, environment TEXT NOT NULL, updated INTEGER NOT NULL,
 UNIQUE(token,environment)
);
CREATE TABLE IF NOT EXISTS notification_jobs (
 job_id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 kind TEXT NOT NULL, shift_id TEXT, fire_at INTEGER NOT NULL, expires INTEGER NOT NULL,
 title TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
 next_attempt INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS notification_due ON notification_jobs(status,fire_at,next_attempt);
CREATE TABLE IF NOT EXISTS notification_deliveries (
 job_id TEXT NOT NULL REFERENCES notification_jobs(job_id) ON DELETE CASCADE,
 device_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
 last_error TEXT NOT NULL DEFAULT '', PRIMARY KEY(job_id,device_id)
);
CREATE TABLE IF NOT EXISTS receipt_photos (
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 receipt_id TEXT NOT NULL, encrypted BLOB NOT NULL, byte_count INTEGER NOT NULL,
 created INTEGER NOT NULL, PRIMARY KEY(account_id,receipt_id)
);
CREATE TABLE IF NOT EXISTS travel_usage (day INTEGER PRIMARY KEY, requests INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS travel_estimates (
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 shift_id TEXT NOT NULL, fingerprint TEXT NOT NULL, checked INTEGER NOT NULL DEFAULT 0,
 retry_at INTEGER NOT NULL DEFAULT 0, estimate TEXT, error TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(account_id,shift_id)
);
CREATE TABLE IF NOT EXISTS calendar_links (
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE, token_hash TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS apple_revocations (
 token_hash TEXT PRIMARY KEY, encrypted_token TEXT NOT NULL, created INTEGER NOT NULL
);
"""

class AppStorage(Storage):
    def __init__(self, path: str | Path):
        super().__init__(path)
        self._conn.execute('PRAGMA journal_mode=WAL')
        self._conn.executescript(SCHEMA)
        for table in ('shifts','cab_claims'):
            columns={r['name'] for r in self._conn.execute(f'PRAGMA table_info({table})')}
            if 'ios_uuid' not in columns:
                self._conn.execute(f'ALTER TABLE {table} ADD COLUMN ios_uuid TEXT')
            self._conn.execute(f'CREATE UNIQUE INDEX IF NOT EXISTS {table}_ios_uuid ON {table}(user_id,ios_uuid)')
        self._conn.commit()
        from .payment_detection import PaymentStore
        PaymentStore(self)
        from .live_activity import ensure_schema
        ensure_schema(self._conn)
        from . import pay_in
        pay_in.ensure_schema(self._conn)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def json_response(value, status_code=200):
    return Response(json.dumps(value, use_decimal=True, separators=(',',':')), status_code=status_code,
                    media_type='application/json',headers={'Cache-Control':'no-store'})


def limit(request: Request, name: str, maximum=40):
    db=request.app.state.storage._conn
    peer=request.client.host if request.client else 'unknown'
    bucket=digest(name+':'+peer)
    window=int(time.time())//600
    with db:
        db.execute('DELETE FROM auth_limits WHERE window<?',(window,))
        row=db.execute('INSERT INTO auth_limits VALUES(?,?,1) ON CONFLICT(bucket) DO UPDATE SET '
                       'requests=CASE WHEN window=excluded.window THEN requests+1 ELSE 1 END,window=excluded.window '
                       'RETURNING requests',(bucket,window)).fetchone()
    if row['requests']>maximum:
        raise HTTPException(429,'Too many attempts. Please try again later.')
