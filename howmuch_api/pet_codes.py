"""Penny gift codes: developers make codes that unlock wardrobe items; anyone signed in can redeem one.

What an account has unlocked lives on the server (not in the editable account document), so it can't be
typed in by hand. Codes are short, readable and rate limited; each account can use a code once."""
from __future__ import annotations

import json
import re
import secrets
import time

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field

from .auth import authenticated_account, developer
from .database import limit

router = APIRouter(prefix='/pet')
ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'  # no 0/O or 1/I
ITEM = re.compile(r'[a-z0-9-]{1,40}')
CODE = re.compile(r'[A-Z0-9-]{4,24}')

SCHEMA = """
CREATE TABLE IF NOT EXISTS pet_codes (
 code TEXT PRIMARY KEY, items TEXT NOT NULL, label TEXT NOT NULL DEFAULT '', max_uses INTEGER NOT NULL,
 uses INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL DEFAULT 0, created_by TEXT NOT NULL,
 created INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS pet_redemptions (
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE, code TEXT NOT NULL,
 items TEXT NOT NULL, redeemed INTEGER NOT NULL, PRIMARY KEY(account_id, code)
);
"""


def db_for(request):
    db = request.app.state.storage._conn
    db.executescript(SCHEMA)
    return db


def normalized(code: str) -> str:
    return re.sub(r'\s+', '', code or '').upper()


def unlocks(db, account_id) -> list[str]:
    """Every item an account has unlocked with codes."""
    db.executescript(SCHEMA)
    items = set()
    for row in db.execute('SELECT items FROM pet_redemptions WHERE account_id=?', (account_id,)):
        items.update(json.loads(row['items']))
    return sorted(items)


def require_developer(request, authorization):
    account = authenticated_account(request, authorization)
    if not developer(account):
        raise HTTPException(403, 'Only HowMuch developers can make Penny codes.')
    return account


def public(row):
    return {'code': row['code'], 'items': json.loads(row['items']), 'label': row['label'], 'maxUses': row['max_uses'],
            'uses': row['uses'], 'expires': row['expires'], 'created': row['created'], 'disabled': bool(row['disabled'])}


class NewCode(BaseModel):
    items: list[str] = Field(min_length=1, max_length=12)
    max_uses: int = Field(default=1, ge=1, le=10000)
    days: int = Field(default=0, ge=0, le=365)  # 0: never expires
    label: str = Field(default='', max_length=60)
    code: str | None = Field(default=None, max_length=40)  # a custom code such as LAUNCH2026


@router.post('/codes')
async def create_code(payload: NewCode, request: Request, authorization: str | None = Header(default=None)):
    account = require_developer(request, authorization)
    items = list(dict.fromkeys(item.strip().lower() for item in payload.items))
    if not all(ITEM.fullmatch(item) for item in items):
        raise HTTPException(400, 'Choose items from the wardrobe.')
    db = db_for(request)
    custom = normalized(payload.code) if payload.code else ''
    if custom and not CODE.fullmatch(custom):
        raise HTTPException(400, 'A custom code uses 4 to 24 letters, numbers or dashes.')
    now = int(time.time())
    for _ in range(5):
        code = custom or 'PENNY-' + ''.join(secrets.choice(ALPHABET) for _ in range(4)) + '-' + ''.join(secrets.choice(ALPHABET) for _ in range(4))
        try:
            with db:
                db.execute('INSERT INTO pet_codes(code,items,label,max_uses,expires,created_by,created) VALUES(?,?,?,?,?,?,?)',
                           (code, json.dumps(items), payload.label.strip(), payload.max_uses,
                            now + payload.days * 86400 if payload.days else 0, account['account_id'], now))
            return public(db.execute('SELECT * FROM pet_codes WHERE code=?', (code,)).fetchone())
        except Exception as error:  # sqlite3.IntegrityError: the code already exists
            if 'UNIQUE' not in str(error): raise
            if custom: raise HTTPException(409, 'That code already exists. Choose another.')
    raise HTTPException(503, 'Could not make a code. Try again.')


@router.get('/codes')
async def list_codes(request: Request, authorization: str | None = Header(default=None)):
    require_developer(request, authorization)
    db = db_for(request)
    return {'codes': [public(row) for row in db.execute('SELECT * FROM pet_codes ORDER BY created DESC LIMIT 200')]}


@router.delete('/codes/{code}')
async def disable_code(code: str, request: Request, authorization: str | None = Header(default=None)):
    require_developer(request, authorization)
    db = db_for(request)
    with db:
        if db.execute('UPDATE pet_codes SET disabled=1 WHERE code=?', (normalized(code),)).rowcount != 1:
            raise HTTPException(404, 'Code not found.')
    return public(db.execute('SELECT * FROM pet_codes WHERE code=?', (normalized(code),)).fetchone())


class Redeem(BaseModel):
    code: str = Field(min_length=1, max_length=40)


@router.post('/redeem')
async def redeem(payload: Redeem, request: Request, authorization: str | None = Header(default=None)):
    account = authenticated_account(request, authorization)
    limit(request, 'pet-redeem', maximum=10, key=account['account_id'])  # stops guessing codes
    db = db_for(request)
    code, now = normalized(payload.code), int(time.time())
    with db:
        row = db.execute('SELECT * FROM pet_codes WHERE code=?', (code,)).fetchone()
        if not row or row['disabled']:
            raise HTTPException(404, "That code isn't valid. Check it and try again.")
        if db.execute('SELECT 1 FROM pet_redemptions WHERE account_id=? AND code=?', (account['account_id'], code)).fetchone():
            raise HTTPException(409, "You've already used this code.")
        if row['expires'] and row['expires'] <= now:
            raise HTTPException(410, 'This code has expired.')
        if not db.execute('UPDATE pet_codes SET uses=uses+1 WHERE code=? AND uses<max_uses', (code,)).rowcount:
            raise HTTPException(410, 'This code has already been used up.')
        db.execute('INSERT INTO pet_redemptions VALUES(?,?,?,?)', (account['account_id'], code, row['items'], now))
    return {'items': json.loads(row['items']), 'unlocked': unlocks(db, account['account_id'])}
