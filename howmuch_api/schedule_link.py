"""Link for the owner's personal schedule bot (their own assistant on Telegram).

/schedulelink in the HowMuch bot (once it's linked to the app) asks POST /v1/bot/schedule-link for a key
(`hms_…`, only its SHA-256 is stored; a new key replaces the old, `revoke` removes it). With that key the
schedule bot can, for that one account only:

  GET   /v1/schedule/shifts            upcoming shifts (and the last day's), so they count as busy time
  POST  /v1/schedule/shifts            add shifts: {"shifts": [...]} already read by the schedule bot, or {"text": ...}
                                       written like in the HowMuch bot and read by its parser
  PATCH /v1/schedule/shifts/{id}       move or rename one; pay is worked out again with the account's rates
  POST  /v1/schedule/shifts/paid       mark shifts paid
  POST  /v1/schedule/shifts/undo       remove shifts

It can't reach payments, mailboxes, claims, friends or settings.
"""
from __future__ import annotations

import secrets
import time
import uuid
from datetime import date, datetime, timedelta
from decimal import Decimal
from zoneinfo import ZoneInfo

import simplejson as json
from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field, field_validator

from .database import digest, limit
from .telegram_link import (BotShift, BotUser, add_shifts, change_account_shifts, db_for, linked_account, make_shift,
                            require_bot, span)

router = APIRouter()
PREFIX = 'hms_'  # "HowMuch schedule": recognisable if pasted in the wrong place

SCHEMA = """
CREATE TABLE IF NOT EXISTS schedule_links (
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 token_hash TEXT NOT NULL UNIQUE, created INTEGER NOT NULL
);
"""


def db(request):
    conn = db_for(request)
    conn.executescript(SCHEMA)
    return conn


# MARK: - Issuing (from the HowMuch bot, shared secret)

class ScheduleLinkRequest(BotUser):
    revoke: bool = False


@router.post('/bot/schedule-link')
async def bot_schedule_link(payload: ScheduleLinkRequest, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    require_bot(x_howmuch_bot)
    conn = db(request)
    account = linked_account(conn, payload.telegramUserId)
    limit(request, 'schedule-link', maximum=20, key=account['account_id'])
    with conn:
        if payload.revoke:
            gone = conn.execute('DELETE FROM schedule_links WHERE account_id=?', (account['account_id'],)).rowcount
            return {'revoked': bool(gone)}
        key = PREFIX + secrets.token_urlsafe(32)
        conn.execute('INSERT INTO schedule_links VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET '
                     'token_hash=excluded.token_hash, created=excluded.created',
                     (account['account_id'], digest(key), int(time.time())))
    return {'key': key}


# MARK: - Schedule bot routes (bearer key)

def key_account(request: Request, authorization: str | None, name: str = 'schedule', maximum: int = 120):
    limit(request, name, maximum=maximum)
    raw = (authorization or '').removeprefix('Bearer ').strip()
    if not raw.startswith(PREFIX) or len(raw) > 100:
        raise HTTPException(401, 'Not linked.')
    conn = db(request)
    account = conn.execute('SELECT a.* FROM schedule_links s JOIN accounts a ON a.account_id=s.account_id '
                           'WHERE s.token_hash=?', (digest(raw),)).fetchone()
    if not account:
        raise HTTPException(401, 'Not linked.')
    limit(request, name, maximum=maximum, key=account['account_id'])
    return account


def _document(request, account):
    from .documents import read_document
    current = read_document(request.app.state.storage, account)
    data = json.loads(json.dumps(current['data'], use_decimal=True), use_decimal=True)
    return current, data, ZoneInfo(current.get('timezone') or 'Asia/Singapore')


def _public(shift, zone) -> dict:
    start, end = span(shift, zone)
    return {'id': shift['id'], 'event': shift['event'], 'location': shift.get('location', ''), 'day': shift['day'],
            'startMinute': shift['startMinute'], 'endMinute': shift['endMinute'],
            'pay': Decimal(str(shift['pay'])) + Decimal(str(shift.get('extra') or 0)), 'currency': shift['currency'],
            'paid': bool(shift.get('paid')), 'start': start.isoformat(), 'end': end.isoformat()}


@router.get('/schedule/shifts')
async def list_shifts(request: Request, days: int = 30, authorization: str | None = Header(default=None)):
    account = key_account(request, authorization)
    _, data, zone = _document(request, account)
    now = datetime.now(zone)
    days = max(1, min(days, 90))
    out = []
    for shift in data.get('shifts', []):
        start, end = span(shift, zone)
        if end > now - timedelta(days=1) and start < now + timedelta(days=days):
            out.append(_public(shift, zone))
    out.sort(key=lambda s: s['start'])
    return {'shifts': out[:200], 'timezone': str(zone)}


class NewShifts(BaseModel):
    shifts: list[BotShift] | None = Field(default=None, min_length=1, max_length=30)
    text: str | None = Field(default=None, min_length=1, max_length=2000)


@router.post('/schedule/shifts')
async def add_new(payload: NewShifts, request: Request, authorization: str | None = Header(default=None)):
    """Adds shifts with the account's rates, breaks and due dates, as the app would."""
    account = key_account(request, authorization, 'schedule-write', 60)
    if payload.shifts:
        items = payload.shifts
    elif payload.text:
        from paybot.howmuch_link import shift_payload
        from paybot.parsing import ParseError, parse_shifts
        _, data, zone = _document(request, account)
        prefs = data.get('preferences') or {}
        results = parse_shifts(payload.text, datetime.now(zone).date(), bool(prefs.get('defaultBreakPaid')))
        problems = [{'line': line, 'error': str(result)} for line, result in results if isinstance(result, ParseError)]
        if problems or not results:
            raise HTTPException(422, {'message': "Couldn't read that as a shift.", 'problems': problems})
        if len(results) > 30:
            raise HTTPException(422, {'message': 'Send at most 30 shifts at once.', 'problems': []})
        items = [BotShift(**shift_payload(shift)) for _, shift in results]
    else:
        raise HTTPException(422, {'message': 'Send shifts or text.', 'problems': []})
    added = add_shifts(request, account, items)
    current, data, zone = _document(request, account)
    ids = {a['id'] for a in added['added']}
    added['added'] = [_public(s, zone) for s in data.get('shifts', []) if s['id'] in ids]
    return added


class ShiftEdit(BaseModel):
    day: date | None = None
    startMinute: int | None = Field(default=None, ge=0, lt=1440)
    endMinute: int | None = Field(default=None, ge=0, lt=1440)
    event: str | None = Field(default=None, min_length=1, max_length=120)
    location: str | None = Field(default=None, max_length=1000)

    @field_validator('event')
    @classmethod
    def event_has_text(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError('The event name is blank.')
        return value


@router.patch('/schedule/shifts/{shift_id}')
async def edit_shift(shift_id: uuid.UUID, edit: ShiftEdit, request: Request, authorization: str | None = Header(default=None)):
    """Move or rename a shift. Hours and pay are worked out again with the account's rates; its id, paid
    status, break and any extras stay."""
    account = key_account(request, authorization, 'schedule-write', 60)
    from .documents import Document, commit_document
    current, data, zone = _document(request, account)
    shifts = data.get('shifts', [])
    old = next((s for s in shifts if s['id'] == str(shift_id)), None)
    if not old:
        raise HTTPException(404, 'That shift is no longer in HowMuch.')
    fixed = old.get('fixedPay') is not None
    item = BotShift(event=edit.event or old['event'], location=old.get('location', '') if edit.location is None else edit.location,
                    day=edit.day or date.fromisoformat(old['day']),
                    startMinute=old['startMinute'] if edit.startMinute is None else edit.startMinute,
                    endMinute=old['endMinute'] if edit.endMinute is None else edit.endMinute,
                    breakMinutes=int(old.get('breakMinutes') or 0), paidBreak=bool(old.get('paidBreak')),
                    rate=None if fixed else Decimal(str(old.get('rate', 0))),
                    fixedPay=Decimal(str(old['fixedPay'])) if fixed else None)
    others = {**data, 'shifts': [s for s in shifts if s['id'] != old['id']]}
    made = make_shift(item, others)
    new = {**old, **made, 'id': old['id'], 'paid': old.get('paid', False)}
    if not fixed:
        new.pop('fixedPay', None)
    if 'overtimeAfter' not in made:
        new.pop('overtimeAfter', None)
    data['shifts'] = [new if s['id'] == old['id'] else s for s in shifts]
    commit_document(request.app.state.storage, account, Document.model_validate(data), current['timezone'], current)
    start, end = span(new, zone)
    clashes = [{'event': s['event'], 'day': s['day'], 'startMinute': s['startMinute'], 'endMinute': s['endMinute']}
               for s in others['shifts'] if span(s, zone)[0] < end and start < span(s, zone)[1]]
    return {'shift': _public(new, zone), 'clashes': clashes}


class ShiftIds(BaseModel):
    ids: list[uuid.UUID] = Field(min_length=1, max_length=30)


@router.post('/schedule/shifts/paid')
async def mark_paid(payload: ShiftIds, request: Request, authorization: str | None = Header(default=None)):
    account = key_account(request, authorization, 'schedule-write', 60)
    return change_account_shifts(request, account, payload.ids, lambda shift: {**shift, 'paid': True})


@router.post('/schedule/shifts/undo')
async def remove(payload: ShiftIds, request: Request, authorization: str | None = Header(default=None)):
    account = key_account(request, authorization, 'schedule-write', 60)
    return change_account_shifts(request, account, payload.ids, lambda shift: None)
