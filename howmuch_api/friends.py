"""Friends: visit each other's Penny and say hi.

Each account has a friend code (PENNY-K7Q2MX). Sending someone's code asks to be friends; they become
friends when the other person sends yours back or accepts. Friends see only Penny's card (name, look,
stage, level, mood, streak and badges) — never shifts, pay, payers or places. Saying hi is once per
friend per day; it notifies the friend and both earn coins.
"""
from __future__ import annotations
import hashlib
import re
import secrets
import time
from datetime import datetime
from html import escape
from zoneinfo import ZoneInfo
import simplejson as json
from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field, field_validator
from .auth import authenticated_account
from .database import limit
from .pet_codes import gift_coins

router = APIRouter()
page = APIRouter()
HELLO_COINS = 2
ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'  # no 0/O or 1/I to misread
ITEM = re.compile(r'^[a-z0-9-]{1,40}$')
MOODS = {'thriving', 'happy', 'okay', 'hungry', 'sad', 'worried'}

SCHEMA = """
CREATE TABLE IF NOT EXISTS friend_codes (
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE, code TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS friend_requests (
 from_account TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 to_account TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 created INTEGER NOT NULL, PRIMARY KEY(from_account, to_account)
);
CREATE TABLE IF NOT EXISTS friendships (
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 friend_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 created INTEGER NOT NULL, PRIMARY KEY(account_id, friend_id)
);
CREATE TABLE IF NOT EXISTS pet_cards (
 account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE, card TEXT NOT NULL, updated INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS pet_hellos (
 from_account TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 to_account TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 day TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(from_account, to_account, day)
);
"""


def db_for(request):
    db = request.app.state.storage._conn
    db.executescript(SCHEMA)
    return db


def normalized(code: str) -> str:
    value = re.sub(r'[^A-Za-z0-9]', '', code or '').upper()
    return value[5:] if value.startswith('PENNY') and len(value) > 6 else value


def code_for(db, account_id) -> str:
    row = db.execute('SELECT code FROM friend_codes WHERE account_id=?', (account_id,)).fetchone()
    if row:
        return row['code']
    while True:
        code = ''.join(secrets.choice(ALPHABET) for _ in range(6))
        try:
            with db:
                db.execute('INSERT INTO friend_codes VALUES(?,?)', (account_id, code))
            return code
        except Exception:  # a rare clash with another code: pick again
            if db.execute('SELECT code FROM friend_codes WHERE account_id=?', (account_id,)).fetchone():
                return code_for(db, account_id)


def account_for_code(db, code):
    row = db.execute('SELECT account_id FROM friend_codes WHERE code=?', (normalized(code),)).fetchone()
    return row['account_id'] if row else None


def are_friends(db, a, b) -> bool:
    return bool(db.execute('SELECT 1 FROM friendships WHERE account_id=? AND friend_id=?', (a, b)).fetchone())


def friend_notification_id(kind, sender, recipient):
    # Leave room for a fresh delivery suffix within APNs' 64-byte collapse ID.
    return hashlib.sha256(f'{kind}|{sender}|{recipient}'.encode()).hexdigest()[:16]


def notify_friend(db, kind, sender, recipient, now):
    who = card_of(db, sender).get('ownerName') or 'A friend'
    title = f'👋 {who} wants to be friends' if kind == 'friend_request' else f'🎉 {who} accepted your request'
    body = 'Open HowMuch to review the request.' if kind == 'friend_request' else "Visit each other's Penny and say hi."
    db.execute("INSERT INTO notification_jobs(job_id,account_id,kind,shift_id,fire_at,expires,title,body) VALUES(?,?,?,?,?,?,?,?)",
               (friend_notification_id(kind, sender, recipient) + secrets.token_hex(16), recipient, kind, '', now, now + 86400, title, body))


def today_for(db, account_id) -> str:
    row = db.execute('SELECT body FROM documents WHERE account_id=?', (account_id,)).fetchone()
    zone = 'Asia/Singapore'
    if row:
        try:
            zone = json.loads(row['body']).get('timezone') or zone
        except ValueError:
            pass
    try:
        return datetime.now(ZoneInfo(zone)).date().isoformat()
    except Exception:
        return datetime.now(ZoneInfo('Asia/Singapore')).date().isoformat()


def bonus_coins(db, account_id) -> int:
    """Coins kept on the server: gift codes, plus hellos sent and received at HELLO_COINS each.
    Sent to the app as helloCoins, so builds from before coin codes count them too."""
    db.executescript(SCHEMA)
    sent = db.execute('SELECT COUNT(*) FROM pet_hellos WHERE from_account=?', (account_id,)).fetchone()[0]
    got = db.execute('SELECT COUNT(*) FROM pet_hellos WHERE to_account=?', (account_id,)).fetchone()[0]
    return HELLO_COINS * (sent + got) + gift_coins(db, account_id)


def card_of(db, account_id) -> dict:
    row = db.execute('SELECT card FROM pet_cards WHERE account_id=?', (account_id,)).fetchone()
    if row:
        return json.loads(row['card'])
    return {'petName': 'Penny', 'ownerName': '', 'stage': 0, 'level': 1, 'mood': 'okay', 'streakWeeks': 0, 'outfit': {}, 'badges': []}


class PetCard(BaseModel):
    petName: str = Field(default='Penny', max_length=40)
    ownerName: str = Field(default='', max_length=60)
    stage: int = Field(default=0, ge=0, le=4)
    level: int = Field(default=1, ge=1, le=10000)
    mood: str = 'okay'
    streakWeeks: int = Field(default=0, ge=0, le=5200)
    outfit: dict[str, str] = Field(default_factory=dict, max_length=5)
    badges: list[str] = Field(default_factory=list, max_length=40)

    @field_validator('mood')
    @classmethod
    def known_mood(cls, value):
        if value not in MOODS:
            raise ValueError('Unknown mood')
        return value

    @field_validator('outfit')
    @classmethod
    def item_ids(cls, value):
        if any(not ITEM.match(k) or not ITEM.match(v) for k, v in value.items()):
            raise ValueError('Invalid outfit')
        return value

    @field_validator('badges')
    @classmethod
    def badge_ids(cls, value):
        if any(not ITEM.match(b) for b in value):
            raise ValueError('Invalid badge')
        return value


def person(db, me, other):
    """What one person sees of another: their code, Penny's card and today's hellos. Nothing about work."""
    today = today_for(db, me)
    return {'code': 'PENNY-' + code_for(db, other), 'card': card_of(db, other),
            'saidHiToday': bool(db.execute('SELECT 1 FROM pet_hellos WHERE from_account=? AND to_account=? AND day=?', (me, other, today)).fetchone()),
            'theySaidHiToday': bool(db.execute('SELECT 1 FROM pet_hellos WHERE from_account=? AND to_account=? AND day=?', (other, me, today_for(db, other))).fetchone())}


def overview(request, db, me):
    code = code_for(db, me)
    friends = [person(db, me, r['friend_id']) for r in db.execute('SELECT friend_id FROM friendships WHERE account_id=? ORDER BY created', (me,))]
    incoming = [person(db, me, r['from_account']) for r in db.execute('SELECT from_account FROM friend_requests WHERE to_account=? ORDER BY created', (me,))]
    outgoing = [person(db, me, r['to_account']) for r in db.execute('SELECT to_account FROM friend_requests WHERE from_account=? ORDER BY created', (me,))]
    base = str(request.base_url).rstrip('/')
    return {'code': f'PENNY-{code}', 'link': f'{base}/friend/{code}', 'friends': friends, 'incoming': incoming,
            'outgoing': outgoing, 'helloCoins': bonus_coins(db, me)}


@router.get('/friends')
async def get_friends(request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    db = db_for(request)
    return overview(request, db, account['account_id'])


class AddFriend(BaseModel):
    code: str = Field(min_length=4, max_length=40)


@router.post('/friends')
async def add_friend(payload: AddFriend, request: Request, authorization: str | None = Header(default=None)):
    """Ask to be friends, or accept if they already asked."""
    account = authenticated_account(request, authorization)
    limit(request, 'friend-add', maximum=20, key=account['account_id'])  # stops guessing codes
    db = db_for(request)
    me, other = account['account_id'], account_for_code(db, payload.code)
    if not other:
        raise HTTPException(404, "That friend code isn't right. Check it and try again.")
    if other == me:
        raise HTTPException(400, "That's your own code. Send it to a friend instead.")
    now = int(time.time())
    with db:
        if are_friends(db, me, other):
            pass
        elif db.execute('SELECT 1 FROM friend_requests WHERE from_account=? AND to_account=?', (other, me)).fetchone():
            db.execute('DELETE FROM friend_requests WHERE (from_account=? AND to_account=?) OR (from_account=? AND to_account=?)', (other, me, me, other))
            db.execute('INSERT OR IGNORE INTO friendships VALUES(?,?,?)', (me, other, now))
            db.execute('INSERT OR IGNORE INTO friendships VALUES(?,?,?)', (other, me, now))
            db.execute("UPDATE notification_jobs SET status='cancelled' WHERE job_id LIKE ? AND status='pending'",
                       (friend_notification_id('friend_request', other, me) + '%',))
            notify_friend(db, 'friend_accepted', me, other, now)
        else:
            added = db.execute('INSERT OR IGNORE INTO friend_requests VALUES(?,?,?)', (me, other, now)).rowcount
            if added:
                notify_friend(db, 'friend_request', me, other, now)
    return overview(request, db, me)


@router.delete('/friends/{code}')
async def remove_friend(code: str, request: Request, authorization: str | None = Header(default=None)):
    """Remove a friend, decline their request or cancel yours."""
    account = authenticated_account(request, authorization)
    db = db_for(request)
    me, other = account['account_id'], account_for_code(db, code)
    if other:
        with db:
            db.execute('DELETE FROM friendships WHERE (account_id=? AND friend_id=?) OR (account_id=? AND friend_id=?)', (me, other, other, me))
            db.execute('DELETE FROM friend_requests WHERE (from_account=? AND to_account=?) OR (from_account=? AND to_account=?)', (me, other, other, me))
            for sender, recipient in ((me, other), (other, me)):
                for kind in ('friend_request', 'friend_accepted'):
                    db.execute("UPDATE notification_jobs SET status='cancelled' WHERE job_id LIKE ? AND status='pending'",
                               (friend_notification_id(kind, sender, recipient) + '%',))
    return overview(request, db, me)


class CardWrite(BaseModel):
    card: PetCard


@router.put('/friends/card')
async def publish_card(payload: CardWrite, request: Request, authorization: str | None = Header(default=None)):
    """Penny as friends see her. The app sends it when Penny changes."""
    account = authenticated_account(request, authorization)
    limit(request, 'pet-card', maximum=120, key=account['account_id'])
    db = db_for(request)
    with db:
        db.execute('INSERT INTO pet_cards VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET card=excluded.card, updated=excluded.updated',
                   (account['account_id'], json.dumps(payload.card.model_dump()), int(time.time())))
    return {'saved': True}


@router.post('/friends/{code}/hello')
async def say_hello(code: str, request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    db = db_for(request)
    me, other = account['account_id'], account_for_code(db, code)
    if not other or not are_friends(db, me, other):
        raise HTTPException(404, "You can only say hi to friends.")
    today, now = today_for(db, me), int(time.time())
    with db:
        added = db.execute('INSERT OR IGNORE INTO pet_hellos VALUES(?,?,?,?)', (me, other, today, now)).rowcount
    if not added:
        raise HTTPException(409, "You've already said hi today. Come back tomorrow!")
    mine, theirs = card_of(db, me), card_of(db, other)
    who = mine.get('ownerName') or 'A friend'
    job = hashlib.sha256(f'hello|{me}|{other}|{today}'.encode()).hexdigest()
    with db:
        db.execute('INSERT OR IGNORE INTO notification_jobs(job_id,account_id,kind,shift_id,fire_at,expires,title,body) VALUES(?,?,?,?,?,?,?,?)',
                   (job, other, 'hello', '', now, now + 6 * 3600, f'👋 {who} said hi!',
                    f"{mine.get('petName') or 'Penny'} visited {theirs.get('petName') or 'Penny'}. You both earned {HELLO_COINS} coins."))
    return {'friend': person(db, me, other), 'helloCoins': bonus_coins(db, me)}


@page.get('/friend/{code}', response_class=HTMLResponse)
async def invite_page(code: str, request: Request):
    """The invite link: opens HowMuch on the Friends screen with the code filled in."""
    db = db_for(request)
    clean = normalized(code)
    if not account_for_code(db, clean):
        return HTMLResponse('<h1>This invite has expired</h1><p>Ask your friend for their HowMuch friend code.</p>', status_code=404)
    name = escape(card_of(db, account_for_code(db, clean)).get('ownerName') or 'A friend')
    open_url = f'howmuch://friend/{clean}'
    return HTMLResponse(f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Visit {name}'s Penny on HowMuch</title><style>body{{font-family:-apple-system,system-ui,sans-serif;background:#e3f2eb;color:#183b37;
text-align:center;padding:48px 24px}}a.button{{display:inline-block;background:#126b5e;color:#fff;padding:14px 28px;border-radius:14px;
text-decoration:none;font-weight:600;margin:16px 0}}code{{font-size:22px;letter-spacing:2px}}</style></head><body>
<h1>{name} wants to be friends on HowMuch</h1><p>Visit each other's Penny and say hi every day.</p>
<a class="button" href="{open_url}">Open in HowMuch</a><p>Or add this friend code in HowMuch → Penny → Friends:</p>
<p><code>PENNY-{clean}</code></p></body></html>""")
