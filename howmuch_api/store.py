"""In-app purchases: HowMuch Pro (monthly, yearly or lifetime), Penny's item packs and coin bundles.

The app sends each StoreKit 2 transaction exactly as Apple signed it (a JWS). Before trusting one, the server checks
the certificate chain up to Apple Root CA - G3 (AppleRootCA-G3.cer, from apple.com/certificateauthority), Apple's
marker extensions on the two lower certificates, the ES256 signature and that it is for this app. Then it records it:

- Coin bundles are credited once per transaction ID, ever. A hash of the ID is kept even after the account is
  deleted, so the same transaction can't be sent again to another account for more coins.
- Penny packs unlock their items the same way gift codes do (they come back as petUnlocks).
- Pro (a live subscription or lifetime) is kept with the account, so it follows the person to another iPhone even
  when that iPhone uses a different Apple Account. Pioneers (accounts made before HOWMUCH_PIONEER_UNTIL) and
  developers have Pro without buying it.
"""
from __future__ import annotations

import base64
import hashlib
import json
import time
import uuid
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field

from .auth import authenticated_account, bundle_id, developer, launched, pioneer
from .database import limit

router = APIRouter(prefix='/store')

PREFIX = 'com.jialekhoo.howmuch.'
PACKS = {
    'celebration': ['halo', 'heart-glasses', 'lei', 'fireworks', 'galaxy'],
    'wonder': ['bunny-ears', '3d-glasses', 'bell-collar', 'aurora', 'frost'],
}
PRODUCTS = {
    PREFIX + 'pro.monthly': {'kind': 'subscription'},
    PREFIX + 'pro.yearly': {'kind': 'subscription'},
    PREFIX + 'pro.lifetime': {'kind': 'lifetime'},
    PREFIX + 'penny.celebration': {'kind': 'pack', 'pack': 'celebration'},
    PREFIX + 'penny.wonder': {'kind': 'pack', 'pack': 'wonder'},
    PREFIX + 'coins.150': {'kind': 'coins', 'coins': 150},
    PREFIX + 'coins.400': {'kind': 'coins', 'coins': 400},
    PREFIX + 'coins.1000': {'kind': 'coins', 'coins': 1000},
}
ROOT = x509.load_der_x509_certificate((Path(__file__).with_name('AppleRootCA-G3.cer')).read_bytes())
LEAF_MARKER = x509.ObjectIdentifier('1.2.840.113635.100.6.11.1')
INTERMEDIATE_MARKER = x509.ObjectIdentifier('1.2.840.113635.100.6.2.1')

SCHEMA = """
CREATE TABLE IF NOT EXISTS store_transactions (
 transaction_id TEXT PRIMARY KEY, original_id TEXT NOT NULL,
 account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
 product_id TEXT NOT NULL, kind TEXT NOT NULL, coins INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL DEFAULT 0,
 revoked INTEGER NOT NULL DEFAULT 0, environment TEXT NOT NULL, purchased INTEGER NOT NULL, recorded INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS store_transactions_account ON store_transactions(account_id);
CREATE TABLE IF NOT EXISTS store_credited (transaction_hash TEXT PRIMARY KEY, credited INTEGER NOT NULL);
"""


def ensure_schema(db):
    db.executescript(SCHEMA)


class Unverified(ValueError):
    pass


def _part(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))


def verify(jws: str, now: float | None = None) -> dict:
    """The transaction's payload, once its signature is shown to come from Apple for this app."""
    try:
        head, body, signature = jws.split('.')
        header = json.loads(_part(head))
        chain = [x509.load_der_x509_certificate(base64.b64decode(item)) for item in header['x5c']]
    except Exception as error:
        raise Unverified('Not a signed App Store transaction.') from error
    if header.get('alg') != 'ES256' or len(chain) != 3:
        raise Unverified('Not a signed App Store transaction.')
    leaf, intermediate, root = chain
    if root.fingerprint(hashes.SHA256()) != ROOT.fingerprint(hashes.SHA256()):
        raise Unverified('Not signed by Apple.')
    moment = now if now is not None else time.time()
    try:
        intermediate.verify_directly_issued_by(ROOT)
        leaf.verify_directly_issued_by(intermediate)
        for cert in (leaf, intermediate):
            if not cert.not_valid_before_utc.timestamp() <= moment <= cert.not_valid_after_utc.timestamp():
                raise Unverified('The signing certificate has expired.')
        intermediate.extensions.get_extension_for_oid(INTERMEDIATE_MARKER)
        leaf.extensions.get_extension_for_oid(LEAF_MARKER)
        raw = _part(signature)
        if len(raw) != 64:
            raise Unverified('Bad signature.')
        der = encode_dss_signature(int.from_bytes(raw[:32], 'big'), int.from_bytes(raw[32:], 'big'))
        leaf.public_key().verify(der, f'{head}.{body}'.encode(), ec.ECDSA(hashes.SHA256()))
        payload = json.loads(_part(body))
    except (InvalidSignature, ValueError, TypeError, x509.ExtensionNotFound) as error:
        if isinstance(error, Unverified):
            raise
        raise Unverified('Not signed by Apple.') from error
    if payload.get('bundleId') != bundle_id():
        raise Unverified('This purchase is for a different app.')
    return payload


def account_token(account_id: str) -> str:
    """The appAccountToken the app puts on purchases: the account ID when it is a UUID (it always is)."""
    try:
        return str(uuid.UUID(account_id))
    except ValueError:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, 'howmuch:' + account_id))


def pack_items(db, account_id) -> list[str]:
    ensure_schema(db)
    items = set()
    for (product,) in db.execute("SELECT product_id FROM store_transactions WHERE account_id=? AND kind='pack' AND revoked=0", (account_id,)):
        items.update(PACKS.get(PRODUCTS.get(product, {}).get('pack', ''), []))
    return sorted(items)


def bought_coins(db, account_id) -> int:
    ensure_schema(db)
    return db.execute("SELECT COALESCE(SUM(coins),0) FROM store_transactions WHERE account_id=? AND kind='coins'", (account_id,)).fetchone()[0]


def purchased_pro(db, account_id, now: float | None = None) -> bool:
    ensure_schema(db)
    moment = int(now if now is not None else time.time())
    return db.execute("SELECT 1 FROM store_transactions WHERE account_id=? AND revoked=0 AND "
                      "(kind='lifetime' OR (kind='subscription' AND expires>?)) LIMIT 1", (account_id, moment)).fetchone() is not None


def has_pro(db, account_id) -> bool:
    """For the server's own work (reminders, travel alerts, Lock Screen cards), looked up by account ID."""
    account = db.execute('SELECT * FROM accounts WHERE account_id=?', (account_id,)).fetchone()
    return account is not None and pro_status(db, account)['pro']


def has_pro_user(db, user_id) -> bool:
    """The same, for code that knows the account by its numeric row ID (pay-in tracking)."""
    account = db.execute('SELECT * FROM accounts WHERE id=?', (user_id,)).fetchone()
    return account is not None and pro_status(db, account)['pro']


def pro_status(db, account) -> dict:
    """Why an account has Pro, if it does: 'developer', 'pioneer' (early supporter) or 'purchase'."""
    if developer(account):
        reason = 'developer'
    elif pioneer(account):
        reason = 'pioneer'
    elif purchased_pro(db, account['account_id']):
        reason = 'purchase'
    else:
        reason = None
    return {'pro': reason is not None, 'proReason': reason}


FREE_EVENTS = 5
FREE_EVENTS_MESSAGE = (f'Free accounts can keep up to {FREE_EVENTS} events. Add this to one of your events, delete an old event, '
                       'or get HowMuch Pro for unlimited events.')


def event_names(data) -> set[str]:
    """Events are told apart by name, ignoring case and surrounding spaces (as in the app's FreePlan)."""
    return {str(shift.get('event', '')).strip().lower() for shift in (data or {}).get('shifts', [])}


def check_event_limit(db, account, before, after):
    """Refuse a change that takes an account without Pro past FREE_EVENTS events. Accounts already above it (for
    example, after Pro ends) keep their events but can't add more. More shifts in an existing event are always fine."""
    count = len(event_names(after))
    if count > FREE_EVENTS and count > len(event_names(before)) and not pro_status(db, account)['pro']:
        raise HTTPException(402, FREE_EVENTS_MESSAGE)


class Transactions(BaseModel):
    transactions: list[str] = Field(min_length=1, max_length=50)


@router.post('/transactions')
async def record(payload: Transactions, request: Request, authorization: str | None = Header(default=None)):
    """Record purchases the app has. Returns which were accepted, and the account's Pro, unlocks and coins."""
    account = authenticated_account(request, authorization)
    limit(request, 'store', maximum=60, key=account['account_id'])
    db = request.app.state.storage._conn
    ensure_schema(db)
    accepted, rejected, now = [], [], int(time.time())
    for jws in payload.transactions:
        try:
            info = verify(jws)
        except Unverified as error:
            rejected.append({'reason': str(error)})
            continue
        transaction_id = str(info.get('transactionId', ''))
        product = PRODUCTS.get(info.get('productId', ''))
        token = info.get('appAccountToken')
        if not transaction_id or product is None:
            rejected.append({'transactionId': transaction_id, 'reason': 'Unknown product.'})
            continue
        if token and str(token).lower() != account_token(account['account_id']):
            rejected.append({'transactionId': transaction_id, 'reason': 'This purchase belongs to another HowMuch account.'})
            continue
        kind = product['kind']
        revoked = 1 if info.get('revocationDate') else 0
        expires = int(info.get('expiresDate', 0) or 0) // 1000
        with db:
            row = db.execute('SELECT account_id FROM store_transactions WHERE transaction_id=?', (transaction_id,)).fetchone()
            if kind == 'coins':
                if row is None:
                    marker = hashlib.sha256(('howmuch-store|' + transaction_id).encode()).hexdigest()
                    if db.execute('SELECT 1 FROM store_credited WHERE transaction_hash=?', (marker,)).fetchone():
                        rejected.append({'transactionId': transaction_id, 'reason': 'These coins were already added to another account.'})
                        continue
                    db.execute('INSERT INTO store_credited VALUES(?,?)', (marker, now))
                    db.execute('INSERT INTO store_transactions VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                               (transaction_id, str(info.get('originalTransactionId', transaction_id)), account['account_id'], info['productId'], kind,
                                product['coins'], 0, revoked, str(info.get('environment', '')), int(info.get('purchaseDate', 0) or 0) // 1000, now))
                elif row['account_id'] != account['account_id']:
                    rejected.append({'transactionId': transaction_id, 'reason': 'These coins were already added to another account.'})
                    continue
            elif row is None:
                db.execute('INSERT INTO store_transactions VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                           (transaction_id, str(info.get('originalTransactionId', transaction_id)), account['account_id'], info['productId'], kind,
                            0, expires, revoked, str(info.get('environment', '')), int(info.get('purchaseDate', 0) or 0) // 1000, now))
            else:
                # Renewals arrive as new transactions; a known one may now be refunded or revoked.
                db.execute('UPDATE store_transactions SET revoked=?, expires=? WHERE transaction_id=?', (revoked, expires, transaction_id))
        accepted.append(transaction_id)
    if any(PRODUCTS[p]['kind'] in ('subscription', 'lifetime') for (p,) in db.execute(
            'SELECT product_id FROM store_transactions WHERE transaction_id IN (%s)' % ','.join('?' * len(accepted)), accepted)) if accepted else False:
        # Pro may have just started: plan this account's reminders, travel alerts and Lock Screen cards now.
        from .documents import read_document
        from .push import rebuild_jobs
        envelope = read_document(request.app.state.storage, account)
        rebuild_jobs(request.app.state.storage, account, envelope['data'], envelope['timezone'])
    from .friends import bonus_coins
    from .pet_codes import unlocks
    return {'accepted': accepted, 'rejected': rejected, **pro_status(db, account),
            'petUnlocks': unlocks(db, account['account_id']), 'helloCoins': bonus_coins(db, account['account_id'])}


class AppTransaction(BaseModel):
    jws: str = Field(min_length=20, max_length=20000)


@router.post('/app-transaction')
async def app_transaction(payload: AppTransaction, request: Request, authorization: str | None = Header(default=None)):
    """TestFlight builds send Apple's signed app transaction. Before launch, an account seen in one (Apple's Sandbox
    environment) is marked as a TestFlight tester: an early supporter, with Pro free. After launch nobody new is
    marked, so App Review (also Sandbox) sees HowMuch as a new person would."""
    account = authenticated_account(request, authorization)
    limit(request, 'store', maximum=60, key=account['account_id'])
    try:
        info = verify(payload.jws)
    except Unverified as error:
        raise HTTPException(422, str(error)) from None
    db = request.app.state.storage._conn
    if info.get('environment') == 'Sandbox' and not launched() and not account['tester']:
        with db:
            db.execute('UPDATE accounts SET tester=1 WHERE account_id=?', (account['account_id'],))
        account = db.execute('SELECT * FROM accounts WHERE account_id=?', (account['account_id'],)).fetchone()
    return {'pioneer': pioneer(account), **pro_status(db, account)}
