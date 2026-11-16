"""Live Activity push-to-start for the shift card on the Lock Screen.

The app registers a push-to-start token per signed-in session, plus an update token for
each running card. Around a shift's start the server starts the card without the app being
opened, and before iOS's 8-hour Live Activity limit it starts a fresh card and ends the old one.
"""
from __future__ import annotations
import json
import logging
import time
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import httpx
from fastapi import APIRouter, Header, Request, Response
from pydantic import BaseModel, Field
from .auth import authenticated_account, bundle_id
from .documents import NotificationPreferences

router = APIRouter(prefix='/devices')
logger = logging.getLogger(__name__)

LEAD = 30 * 60                    # start the card this long before the shift (it counts down to the start)
RENEW = 7 * 3600 + 45 * 60         # replace it before iOS ends it at 8 hours
MIN_REMAINING = 10 * 60            # not worth starting a card for the last few minutes
RETRY = 120

SCHEMA = """
CREATE TABLE IF NOT EXISTS live_start_tokens (
 session_id TEXT PRIMARY KEY REFERENCES auth_sessions(session_id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 token TEXT NOT NULL, environment TEXT NOT NULL, updated INTEGER NOT NULL, retry_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS live_plans (
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 shift_id TEXT NOT NULL, start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, state TEXT NOT NULL,
 PRIMARY KEY(account_id, shift_id)
);
CREATE TABLE IF NOT EXISTS live_segments (
 session_id TEXT NOT NULL REFERENCES auth_sessions(session_id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 shift_id TEXT NOT NULL, started INTEGER NOT NULL, token TEXT, environment TEXT,
 ended INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(session_id, shift_id, started)
);
"""


def ensure_schema(db):
    db.executescript(SCHEMA)
    # Added after the first release: the card details last pushed to each running card.
    if 'pushed_state' not in {row[1] for row in db.execute('PRAGMA table_info(live_segments)')}:
        db.execute('ALTER TABLE live_segments ADD COLUMN pushed_state TEXT')
        db.commit()
    # Added with the countdown before a shift: whether a card started early has been told the shift began.
    if 'went_live' not in {row[1] for row in db.execute('PRAGMA table_info(live_segments)')}:
        db.execute('ALTER TABLE live_segments ADD COLUMN went_live INTEGER NOT NULL DEFAULT 0')
        db.commit()


def _plan_state(db, account_id, shift_id):
    row = db.execute('SELECT state FROM live_plans WHERE account_id=? AND shift_id=?', (account_id, shift_id)).fetchone()
    return row['state'] if row else None


class StartToken(BaseModel):
    token: str = Field(min_length=32, max_length=512, pattern=r'^[0-9a-fA-F]+$')
    environment: str = Field(pattern=r'^(sandbox|production)$')


class ActivityToken(StartToken):
    shiftID: str = Field(pattern=r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')


def _configured(environment):
    from .push import configured
    return configured(environment)


@router.put('/live-start')
async def register_start_token(payload: StartToken, request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    db = request.app.state.storage._conn
    with db:
        db.execute('DELETE FROM live_start_tokens WHERE session_id=? OR (token=? AND environment=?)',
                   (account['session_id'], payload.token.lower(), payload.environment))
        if not _configured(payload.environment):
            return {'registered': False}
        db.execute('INSERT INTO live_start_tokens(session_id,account_id,token,environment,updated) VALUES(?,?,?,?,?)',
                   (account['session_id'], account['account_id'], payload.token.lower(), payload.environment, int(time.time())))
    return {'registered': True}


@router.delete('/live-start', status_code=204)
async def unregister_start_token(request: Request, authorization: str | None = Header(default=None)):
    """Kept for older builds, which sent this whenever iOS hadn't handed them the start token yet, including
    every time iOS woke the app in the background. That wiped the token, so the next shift's card never
    started. The token now stays; the synced Lock Screen setting decides (see rebuild_plans), and signing
    out removes the token with its session."""
    authenticated_account(request, authorization)
    return Response(status_code=204)


@router.put('/live-activity')
async def register_activity_token(payload: ActivityToken, request: Request, authorization: str | None = Header(default=None)):
    """A running card's update token. Also tells the server the card already exists, so it doesn't start another."""
    account = authenticated_account(request, authorization)
    now = int(time.time())
    shift_id = payload.shiftID.upper()
    db = request.app.state.storage._conn
    with db:
        if db.execute('SELECT 1 FROM live_segments WHERE session_id=? AND shift_id=? AND token=?',
                      (account['session_id'], shift_id, payload.token.lower())).fetchone():
            return {'registered': True}
        latest = db.execute('SELECT * FROM live_segments WHERE session_id=? AND shift_id=? ORDER BY started DESC LIMIT 1',
                            (account['session_id'], shift_id)).fetchone()
        if latest and latest['token'] is None and now - latest['started'] < RENEW:
            db.execute('UPDATE live_segments SET token=?,environment=? WHERE session_id=? AND shift_id=? AND started=?',
                       (payload.token.lower(), payload.environment, account['session_id'], shift_id, latest['started']))
        else:
            # A card the app started shows the shift as the app last saw it, which the server's plan reflects.
            db.execute('INSERT OR IGNORE INTO live_segments(session_id,account_id,shift_id,started,token,environment,pushed_state) VALUES(?,?,?,?,?,?,?)',
                       (account['session_id'], account['account_id'], shift_id, now, payload.token.lower(), payload.environment,
                        _plan_state(db, account['account_id'], shift_id)))
    return {'registered': True}


def rebuild_plans(storage, account, data, timezone_name, now=None):
    """Recompute when each shift's card should appear, from the account's latest data."""
    now = int(time.time()) if now is None else now
    zone = ZoneInfo(timezone_name)
    prefs = (data.get('preferences') or {}).get('notifications') or {}
    # Names on the Lock Screen follow the same privacy choice as job notifications.
    details = NotificationPreferences.model_validate(prefs).showDetails
    # Settings → Live shift → Show on Lock Screen, synced with the account: off means no cards at all.
    live = (data.get('preferences') or {}).get('liveShift') or {}
    shifts = [] if live.get('lockScreen') is False else data.get('shifts', [])
    rows = []
    for shift in shifts:
        day = datetime.fromisoformat(shift['day']).replace(tzinfo=zone)
        start = day + timedelta(minutes=shift['startMinute'])
        end = day + timedelta(minutes=shift['endMinute'], days=1 if shift['endMinute'] <= shift['startMinute'] else 0)
        # Finished shifts stay for a day so their card isn't mistaken for a deleted shift's.
        if end.timestamp() <= now - 86400:
            continue
        shift_id = str(shift['id']).upper()
        account_id = account['account_id'].lower()
        link = f'howmuch://widget/{{}}?account={account_id}&id={shift_id}'
        state = {
            'event': shift['event'] if details else 'Your shift',
            'location': (shift.get('location') or '').split(',')[0].strip() if details else '',
            'startTime': start.timestamp(), 'endTime': end.timestamp(),
            'pay': float(shift['pay'])+float(shift.get('extra') or 0), 'currency': shift['currency'],
            'shiftURL': link.format('shift'), 'finishURL': link.format('finish'),
        }
        rows.append((account['account_id'], shift_id, int(start.timestamp()), int(end.timestamp()), json.dumps(state)))
    db = storage._conn
    with db:
        db.execute('DELETE FROM live_plans WHERE account_id=?', (account['account_id'],))
        db.executemany('INSERT INTO live_plans VALUES(?,?,?,?,?)', rows)


def _stale_date(state, now):
    """iOS redraws the card at its stale date: at the start while counting down to it, then at the end."""
    return int(state['startTime']) if now < state['startTime'] else int(state['endTime'])


def _payload(event, state, now, plan=None, account_id=None):
    aps = {'timestamp': now, 'event': event, 'content-state': state}
    if event == 'start':
        minutes = max(1, round((state['startTime'] - now) / 60))
        aps.update({'attributes-type': 'LiveShiftAttributes',
                    'attributes': {'shiftID': plan['shift_id'], 'accountID': account_id},
                    'stale-date': _stale_date(state, now),
                    'alert': {'title': state['event'],
                              'body': f'Starts in {minutes} min.' if now < state['startTime'] else 'Your shift is live on the Lock Screen.'}})
    elif event == 'update':
        aps['stale-date'] = _stale_date(state, now)
    else:
        aps['dismissal-date'] = now
    return {'aps': aps}


async def _send(client, token, environment, payload):
    from .push import provider_token
    host = 'https://api.sandbox.push.apple.com' if environment == 'sandbox' else 'https://api.push.apple.com'
    response = await client.post(host + '/3/device/' + token, json=payload, headers={
        'authorization': 'bearer ' + provider_token(environment),
        'apns-topic': bundle_id() + '.push-type.liveactivity', 'apns-push-type': 'liveactivity',
        'apns-priority': '10', 'apns-id': str(uuid.uuid4())})
    if response.status_code == 200:
        return 'sent'
    reason = ''
    try: reason = response.json().get('reason', '')
    except ValueError: pass
    return 'invalid' if response.status_code == 410 or reason in ('Unregistered', 'BadDeviceToken', 'ExpiredToken') else 'retry'


async def deliver(storage, client=None, now=None):
    """Start, renew and end shift cards. Returns how many start pushes were sent."""
    if not _configured('production') and not _configured('sandbox'):
        return 0
    now = int(time.time()) if now is None else now
    db = storage._conn
    owned = client is None
    client = client or httpx.AsyncClient(http2=True, timeout=15)
    started = 0
    try:
        due = db.execute(
            'SELECT p.*, t.session_id, t.token AS start_token, t.environment FROM live_plans p '
            'JOIN live_start_tokens t ON t.account_id=p.account_id '
            'JOIN auth_sessions s ON s.session_id=t.session_id AND s.refresh_expires>? '
            'WHERE p.start_at-?<=? AND p.end_at-?>? AND t.retry_at<=?',
            (now, LEAD, now, MIN_REMAINING, now, now)).fetchall()
        for plan in due:
            latest = db.execute('SELECT * FROM live_segments WHERE session_id=? AND shift_id=? ORDER BY started DESC LIMIT 1',
                                (plan['session_id'], plan['shift_id'])).fetchone()
            if latest and now - latest['started'] < RENEW:
                continue
            if not _configured(plan['environment']):
                continue
            state = json.loads(plan['state'])
            try:
                status = await _send(client, plan['start_token'], plan['environment'],
                                     _payload('start', state, now, plan, plan['account_id'].lower()))
            except (httpx.HTTPError, ValueError):
                status = 'retry'
            # The session may have signed out while the push was in flight.
            if not db.execute('SELECT 1 FROM live_start_tokens WHERE session_id=? AND token=?',
                              (plan['session_id'], plan['start_token'])).fetchone():
                continue
            with db:
                if status == 'sent':
                    started += 1
                    db.execute('INSERT OR IGNORE INTO live_segments(session_id,account_id,shift_id,started,pushed_state) VALUES(?,?,?,?,?)',
                               (plan['session_id'], plan['account_id'], plan['shift_id'], now, plan['state']))
                elif status == 'invalid':
                    db.execute('DELETE FROM live_start_tokens WHERE session_id=?', (plan['session_id'],))
                else:
                    db.execute('UPDATE live_start_tokens SET retry_at=? WHERE session_id=?', (now + RETRY, plan['session_id']))
            if status == 'sent' and latest and latest['token'] and not latest['ended']:
                await _end(db, client, latest, now)
        # End cards replaced by a renewal, and cards for shifts that were deleted.
        open_cards = db.execute('SELECT * FROM live_segments WHERE token IS NOT NULL AND ended=0 AND started>?',
                                (now - 2 * 86400,)).fetchall()
        for segment in open_cards:
            replaced = db.execute('SELECT 1 FROM live_segments WHERE session_id=? AND shift_id=? AND started>?',
                                  (segment['session_id'], segment['shift_id'], segment['started'])).fetchone()
            deleted = not db.execute('SELECT 1 FROM live_plans WHERE account_id=? AND shift_id=?',
                                     (segment['account_id'], segment['shift_id'])).fetchone()
            if replaced or deleted:
                await _end(db, client, segment, now)
                continue
            # The shift was edited (times, pay, name) while its card is showing, or a card started early has
            # reached the shift's start: push the details again so it switches from "starts at" to time left.
            state = _plan_state(db, segment['account_id'], segment['shift_id'])
            start_at = int(json.loads(state)['startTime']) if state else 0
            going_live = bool(state) and segment['started'] < start_at <= now and not segment['went_live']
            if state and (state != segment['pushed_state'] or going_live) and _configured(segment['environment'] or 'production'):
                try:
                    status = await _send(client, segment['token'], segment['environment'] or 'production',
                                         _payload('update', json.loads(state), now))
                except (httpx.HTTPError, ValueError):
                    continue
                with db:
                    if status == 'sent':
                        db.execute('UPDATE live_segments SET pushed_state=?, went_live=? WHERE session_id=? AND shift_id=? AND started=?',
                                   (state, int(start_at <= now), segment['session_id'], segment['shift_id'], segment['started']))
                    elif status == 'invalid':
                        db.execute('UPDATE live_segments SET ended=1 WHERE session_id=? AND shift_id=? AND started=?',
                                   (segment['session_id'], segment['shift_id'], segment['started']))
        with db:
            db.execute('DELETE FROM live_segments WHERE started<?', (now - 3 * 86400,))
    finally:
        if owned:
            await client.aclose()
    return started


async def _end(db, client, segment, now):
    if not _configured(segment['environment'] or 'production'):
        return
    plan = db.execute('SELECT state FROM live_plans WHERE account_id=? AND shift_id=?', (segment['account_id'], segment['shift_id'])).fetchone()
    state = json.loads(plan['state']) if plan else {
        'event': 'Shift removed', 'location': '', 'startTime': float(now), 'endTime': float(now + 60), 'pay': 0.0, 'currency': 'SGD',
        'shiftURL': 'howmuch://widget/open', 'finishURL': 'howmuch://widget/open'}
    try:
        status = await _send(client, segment['token'], segment['environment'] or 'production', _payload('end', state, now))
    except (httpx.HTTPError, ValueError):
        return
    if status in ('sent', 'invalid'):
        with db:
            db.execute('UPDATE live_segments SET ended=1 WHERE session_id=? AND shift_id=? AND started=?',
                       (segment['session_id'], segment['shift_id'], segment['started']))
