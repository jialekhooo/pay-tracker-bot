"""Link a HowMuch account with the HowMuch Telegram bot (@paytracker1_bot).

The app asks for a one-time code and opens the bot with it; the bot confirms the code here.
After that the bot can add shifts to the account and read what is owed and what is coming up.
Bot routes need the shared HOWMUCH_BOT_SECRET (header X-HowMuch-Bot); without it they are off.
"""
from __future__ import annotations
import hmac
import os
import secrets
import time
import uuid
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo
import simplejson as json
from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field
from .auth import authenticated_account
from .database import limit

router = APIRouter()
BOT_USERNAME = os.environ.get('HOWMUCH_BOT_USERNAME', 'paytracker1_bot')
CODE_SECONDS = 15 * 60

SCHEMA = """
CREATE TABLE IF NOT EXISTS telegram_links (
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
 telegram_user_id INTEGER NOT NULL UNIQUE, username TEXT NOT NULL DEFAULT '', linked INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS telegram_link_codes (
 code TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE, expires INTEGER NOT NULL
);
"""


def db_for(request):
    db = request.app.state.storage._conn
    db.executescript(SCHEMA)
    return db


def status(db, account_id):
    row = db.execute('SELECT username, linked FROM telegram_links WHERE account_id=?', (account_id,)).fetchone()
    return {'linked': bool(row), 'username': row['username'] if row else '', 'linkedAt': row['linked'] if row else 0,
            'bot': BOT_USERNAME}


# MARK: - App routes (signed-in account)

@router.get('/telegram')
async def get_link(request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    return status(db_for(request), account['account_id'])


@router.post('/telegram/link')
async def new_code(request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    limit(request, 'telegram-code', maximum=20, key=account['account_id'])
    db = db_for(request)
    code = secrets.token_urlsafe(12)  # 16 characters from [A-Za-z0-9_-], as Telegram's start parameter needs
    now = int(time.time())
    with db:
        db.execute('DELETE FROM telegram_link_codes WHERE account_id=? OR expires<?', (account['account_id'], now))
        db.execute('INSERT INTO telegram_link_codes VALUES(?,?,?)', (code, account['account_id'], now + CODE_SECONDS))
    return {'url': f'https://t.me/{BOT_USERNAME}?start=link-{code}', 'expires': now + CODE_SECONDS}


@router.delete('/telegram')
async def unlink_account(request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    db = db_for(request)
    with db:
        db.execute('DELETE FROM telegram_links WHERE account_id=?', (account['account_id'],))
    return status(db, account['account_id'])


# MARK: - Bot routes (shared secret)

def require_bot(secret: str | None):
    expected = os.environ.get('HOWMUCH_BOT_SECRET', '')
    if not expected or not secret or not hmac.compare_digest(secret, expected):
        raise HTTPException(403, 'Not allowed.')


class BotUser(BaseModel):
    telegramUserId: int = Field(gt=0)


class BotLink(BotUser):
    code: str = Field(min_length=8, max_length=64)
    username: str = Field(default='', max_length=64)


def linked_account(db, telegram_user_id):
    row = db.execute('SELECT a.* FROM telegram_links t JOIN accounts a ON a.account_id=t.account_id '
                     'WHERE t.telegram_user_id=?', (telegram_user_id,)).fetchone()
    if not row:
        raise HTTPException(404, 'This Telegram account is not linked to HowMuch.')
    return row


@router.post('/bot/link')
async def bot_link(payload: BotLink, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    require_bot(x_howmuch_bot)
    limit(request, 'telegram-link', maximum=10, key=str(payload.telegramUserId))  # stops guessing codes
    db = db_for(request)
    now = int(time.time())
    with db:
        row = db.execute('SELECT account_id FROM telegram_link_codes WHERE code=? AND expires>=?', (payload.code, now)).fetchone()
        if not row:
            raise HTTPException(404, 'That link has expired. Open HowMuch → Settings → Telegram and tap Link Telegram again.')
        db.execute('DELETE FROM telegram_link_codes WHERE code=?', (payload.code,))
        # One Telegram account per HowMuch account, and the other way round: a new link replaces the old one.
        db.execute('DELETE FROM telegram_links WHERE account_id=? OR telegram_user_id=?', (row['account_id'], payload.telegramUserId))
        db.execute('INSERT INTO telegram_links VALUES(?,?,?,?)', (row['account_id'], payload.telegramUserId, payload.username, now))
    account = db.execute('SELECT display_name FROM accounts WHERE account_id=?', (row['account_id'],)).fetchone()
    return {'linked': True, 'displayName': account['display_name'] if account else ''}


@router.post('/bot/unlink')
async def bot_unlink(payload: BotUser, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    require_bot(x_howmuch_bot)
    db = db_for(request)
    with db:
        removed = db.execute('DELETE FROM telegram_links WHERE telegram_user_id=?', (payload.telegramUserId,)).rowcount
    return {'unlinked': bool(removed)}


@router.post('/bot/status')
async def bot_status(payload: BotUser, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    require_bot(x_howmuch_bot)
    db = db_for(request)
    row = db.execute('SELECT a.display_name FROM telegram_links t JOIN accounts a ON a.account_id=t.account_id '
                     'WHERE t.telegram_user_id=?', (payload.telegramUserId,)).fetchone()
    return {'linked': bool(row), 'displayName': row['display_name'] if row else ''}


class BotShift(BaseModel):
    event: str = Field(min_length=1, max_length=120)
    location: str = Field(default='', max_length=1000)
    day: date
    startMinute: int = Field(ge=0, lt=1440)
    endMinute: int = Field(ge=0, lt=1440)
    breakMinutes: int | None = Field(default=None, ge=0, lt=1440)
    paidBreak: bool = False
    rate: Decimal | None = Field(default=None, ge=0, le=1000000)
    fixedPay: Decimal | None = Field(default=None, ge=0, le=1000000000)


class BotShifts(BotUser):
    shifts: list[BotShift] = Field(min_length=1, max_length=30)


def money(value: Decimal) -> Decimal:
    return value.quantize(Decimal('.01'), rounding=ROUND_HALF_UP)


def due_date(day: date, event: str, shifts) -> date:
    """The app's default: the Friday on or after two weeks past the event's last date."""
    days = [date.fromisoformat(s['day']) for s in shifts if s['event'].lower() == event.lower()]
    last = max([day, *days])
    two_weeks = last + timedelta(days=14)
    return two_weeks + timedelta(days=(4 - two_weeks.weekday()) % 7)


def make_shift(item: BotShift, data) -> dict:
    """A shift as the app would save it, using the account's rates, break and overtime."""
    rules = data.get('rules') or {}
    prefs = data.get('preferences') or {}
    event = item.event.strip()
    duration = (item.endMinute - item.startMinute) % 1440 or 1440
    if item.breakMinutes is not None:
        breaks, paid_break = item.breakMinutes, item.paidBreak
    else:
        breaks, paid_break = int(prefs.get('defaultBreakMinutes') or 0), bool(prefs.get('defaultBreakPaid'))
    if breaks >= duration:
        breaks = 0
    fixed = item.fixedPay is not None
    rate = Decimal(0) if fixed else (item.rate if item.rate is not None else
                                     Decimal(str((prefs.get('eventRates') or {}).get(event.lower(), rules.get('rate', 15)))))
    multiplier = Decimal(str(rules.get('overtimeMultiplier', '1.5')))
    threshold = None if fixed or rules.get('overtimeAfter') is None else Decimal(str(rules['overtimeAfter']))
    hours = Decimal(duration - (0 if paid_break else breaks)) / 60
    if fixed:
        pay = money(item.fixedPay)
    elif threshold is None or hours <= threshold:
        pay = money(hours * rate)
    else:
        pay = money(threshold * rate + (hours - threshold) * rate * multiplier)
    shift = {'id': str(uuid.uuid4()), 'event': event, 'location': item.location.strip(), 'day': item.day.isoformat(),
             'startMinute': item.startMinute, 'endMinute': item.endMinute, 'breakMinutes': breaks, 'paidBreak': paid_break,
             'rate': rate, 'pay': pay, 'currency': rules.get('currency', 'SGD'), 'paid': False,
             'paymentDue': due_date(item.day, event, data.get('shifts', [])).isoformat(), 'overtimeMultiplier': multiplier}
    if fixed:
        shift['fixedPay'] = money(item.fixedPay)
    if threshold is not None:
        shift['overtimeAfter'] = threshold
    return shift


def span(shift, zone):
    start = datetime.combine(date.fromisoformat(shift['day']), datetime.min.time(), zone) + timedelta(minutes=shift['startMinute'])
    length = (shift['endMinute'] - shift['startMinute']) % 1440 or 1440
    return start, start + timedelta(minutes=length)


@router.post('/bot/shifts')
async def bot_add_shifts(payload: BotShifts, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    """Add shifts sent in Telegram to the linked account, exactly as if they were added in the app."""
    require_bot(x_howmuch_bot)
    db = db_for(request)
    account = linked_account(db, payload.telegramUserId)
    limit(request, 'telegram-shifts', maximum=60, key=account['account_id'])
    from .documents import Document, read_document, commit_document
    storage = request.app.state.storage
    current = read_document(storage, account)
    data = json.loads(json.dumps(current['data'], use_decimal=True), use_decimal=True)
    zone = ZoneInfo(current.get('timezone') or 'Asia/Singapore')
    added = [make_shift(item, data) for item in payload.shifts]
    clashes = []
    for shift in added:
        start, end = span(shift, zone)
        for other in data.get('shifts', []):
            other_start, other_end = span(other, zone)
            if start < other_end and other_start < end:
                clashes.append({'event': shift['event'], 'with': other['event'], 'day': other['day'],
                                'startMinute': other['startMinute'], 'endMinute': other['endMinute']})
    data['shifts'] = data.get('shifts', []) + added
    model = Document.model_validate(data)
    commit_document(storage, account, model, current['timezone'], current)
    return {'added': [{k: s[k] for k in ('id', 'event', 'location', 'day', 'startMinute', 'endMinute', 'breakMinutes', 'pay', 'currency')}
                      for s in added], 'clashes': clashes}


class BotShiftIds(BotUser):
    ids: list[uuid.UUID] = Field(min_length=1, max_length=30)


def change_shifts(request, payload: BotShiftIds, change):
    """Apply `change(shift) -> shift | None` (None removes it) to the listed shifts of the linked account."""
    db = db_for(request)
    account = linked_account(db, payload.telegramUserId)
    from .documents import Document, read_document, commit_document
    storage = request.app.state.storage
    current = read_document(storage, account)
    data = json.loads(json.dumps(current['data'], use_decimal=True), use_decimal=True)
    wanted = {str(i) for i in payload.ids}
    kept, changed = [], 0
    for shift in data.get('shifts', []):
        if shift['id'] in wanted:
            changed += 1
            shift = change(shift)
            if shift is None:
                continue
        kept.append(shift)
    if not changed:
        raise HTTPException(404, 'Those shifts are no longer in HowMuch.')
    data['shifts'] = kept
    data['claims'] = [c for c in data.get('claims', []) if c['shiftID'] in {s['id'] for s in kept}]
    commit_document(storage, account, Document.model_validate(data), current['timezone'], current)
    return {'changed': changed}


@router.post('/bot/shifts/undo')
async def bot_undo_shifts(payload: BotShiftIds, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    """Undo: remove shifts the bot just added."""
    require_bot(x_howmuch_bot)
    return change_shifts(request, payload, lambda shift: None)


@router.post('/bot/shifts/paid')
async def bot_mark_paid(payload: BotShiftIds, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    require_bot(x_howmuch_bot)
    return change_shifts(request, payload, lambda shift: {**shift, 'paid': True})


class BotSummary(BotUser):
    days: int = Field(default=14, ge=1, le=60)


@router.post('/bot/summary')
async def bot_summary(payload: BotSummary, request: Request, x_howmuch_bot: str | None = Header(default=None)):
    """What the linked account is owed and what is coming up, from the app's records."""
    require_bot(x_howmuch_bot)
    db = db_for(request)
    account = linked_account(db, payload.telegramUserId)
    from .documents import read_document
    current = read_document(request.app.state.storage, account)
    zone = ZoneInfo(current.get('timezone') or 'Asia/Singapore')
    now = datetime.now(zone)
    owed: dict[str, dict] = {}
    upcoming = []
    for shift in current['data'].get('shifts', []):
        start, end = span(shift, zone)
        total = Decimal(str(shift['pay'])) + Decimal(str(shift.get('extra') or 0))
        if end <= now and not shift['paid']:
            entry = owed.setdefault(shift['currency'], {'currency': shift['currency'], 'amount': Decimal(0), 'shifts': 0})
            entry['amount'] += total; entry['shifts'] += 1
        elif start >= now - timedelta(hours=12) and start <= now + timedelta(days=payload.days) and end > now:
            upcoming.append({'event': shift['event'], 'location': shift.get('location', ''), 'day': shift['day'],
                             'startMinute': shift['startMinute'], 'endMinute': shift['endMinute'], 'pay': total,
                             'currency': shift['currency'], 'start': start.isoformat()})
    upcoming.sort(key=lambda s: s['start'])
    return {'displayName': account['display_name'], 'owed': sorted(owed.values(), key=lambda o: o['currency']),
            'upcoming': upcoming[:20]}
