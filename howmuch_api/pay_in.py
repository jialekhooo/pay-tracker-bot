"""Pay-in tracking without a connected mailbox (HowMuch 1.1).

Two sources feed the existing DBS receipt pipeline in payment_detection.PaymentStore:

* Bank app notifications. An iOS 27 Shortcuts automation runs on the iPhone when the bank app
  posts a notification; Apple Intelligence (or the text itself) gives the amount and payer, and
  the app sends them here. These come from the account holder's own device, so they may mark an
  event paid automatically when the person turned that on and exactly one saved payer's unpaid
  event total matches.
* Email forwarding. Each account gets a private address (pay+<token>@<domain>). The mail
  provider (e.g. a Cloudflare Email Worker) posts the raw message to /inbound-email/<secret>.
  Forwarded mail can't be authenticated, so it always waits for the person to confirm.
"""
from __future__ import annotations

import email
import hashlib
import hmac
import json
import os
import re
import secrets
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation
from email import policy

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field

from .database import limit
from .payment_detection import DBS_SENDER, DBS_SUBJECT, SGT, PaymentStore, normalized, parse_dbs_alert

router = APIRouter(prefix="/payment-detection")
inbound = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS pay_in_settings (
 user_id INTEGER PRIMARY KEY, notifications_auto INTEGER NOT NULL DEFAULT 0, forward_token TEXT UNIQUE
);
"""
AMOUNT = r"(?:SGD|S\$|\$)\s?((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)"


def ensure_schema(db) -> None:
    db.executescript(SCHEMA)
    columns = {r[1] for r in db.execute("PRAGMA table_info(pay_in_settings)")}
    if "forward_confirmation" not in columns:
        db.execute("ALTER TABLE pay_in_settings ADD COLUMN forward_confirmation TEXT")


def inbound_domain() -> str:
    return os.environ.get("HOWMUCH_INBOUND_DOMAIN", "").strip().lower()


def settings(store: PaymentStore, user_id: int) -> dict:
    ensure_schema(store.db)
    row = store.db.execute("SELECT * FROM pay_in_settings WHERE user_id=?", (user_id,)).fetchone()
    return dict(row) if row else {"user_id": user_id, "notifications_auto": 0, "forward_token": None}


def forwarding_address(store: PaymentStore, user_id: int) -> str | None:
    domain = inbound_domain()
    if not domain:
        return None
    token = settings(store, user_id)["forward_token"]
    if not token:
        token = secrets.token_hex(16)  # new addresses get 32 hex characters; older 16-character ones still work
        with store.db:
            store.db.execute("INSERT INTO pay_in_settings(user_id,forward_token) VALUES(?,?) "
                             "ON CONFLICT(user_id) DO UPDATE SET forward_token=excluded.forward_token", (user_id, token))
    return f"pay+{token}@{domain}"


def pay_in_status(store: PaymentStore, user_id: int) -> dict:
    current = settings(store, user_id)
    confirmation = None
    if current.get("forward_confirmation"):
        saved = json.loads(current["forward_confirmation"])
        # Gmail's codes stop working after a while; don't show stale ones.
        if time.time() - saved.get("received", 0) < 7 * 24 * 3600:
            confirmation = {k: saved.get(k) for k in ("code", "link", "account")}
    return {"notifications_auto": bool(current["notifications_auto"]),
            "forwarding": {"available": bool(inbound_domain()), "address": forwarding_address(store, user_id),
                           "confirmation": confirmation}}


GMAIL_CONFIRM_SENDER = "forwarding-noreply@google.com"


def gmail_forwarding_confirmation(raw: bytes) -> dict | None:
    """Gmail's "Forwarding Confirmation" email: the code and link that switch on auto-forwarding."""
    message = email.message_from_bytes(raw, policy=policy.default)
    if GMAIL_CONFIRM_SENDER not in str(message.get("From", "")).casefold():
        return None
    # Anyone can type Google's address in From. When the mail server reports authentication results,
    # require Google's DKIM signature to have passed.
    results = " ".join(str(v) for k in ("Authentication-Results", "ARC-Authentication-Results") for v in (message.get_all(k) or [])).casefold()
    if results and not re.search(r"dkim=pass[^;]*(header\.d=google\.com|header\.i=@google\.com)", results):
        return None
    subject = str(message.get("Subject", ""))
    if "forwarding confirmation" not in subject.casefold():
        return None
    text = _plain_text(message)
    code = re.search(r"Confirmation code:\s*(\d{6,12})", text, re.I)
    link = re.search(r"https://mail(?:-settings)?\.google\.com/mail/[^\s<>\")]+", text)
    account = re.search(r"from\s+([^\s()]+@[^\s()]+)", subject, re.I)
    if not code and not link:
        return None
    return {"code": code[1] if code else None, "link": link[0] if link else None,
            "account": account[1] if account else None}


def _key(value: str) -> str:
    """Payer names compared without case, punctuation or company suffix spacing ("REFIX PTE LTD" = "Refix Pte. Ltd.")."""
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def match_payer(store: PaymentStore, user_id: int, payer: str) -> tuple[str | None, bool]:
    """The saved payer this name refers to, and whether the match is exact. Only an exact match
    (same letters and digits) may mark a job paid automatically; a partial match waits for review."""
    wanted = _key(payer)
    if not wanted:
        return None, False
    rules = store.rules(user_id)
    for rule in rules:
        if _key(rule["payer"]) == wanted:
            return rule["payer"], True
    if len(wanted) < 5:
        return None, False
    partial = {rule["payer"] for rule in rules if len(_key(rule["payer"])) >= 5 and (_key(rule["payer"]) in wanted or wanted in _key(rule["payer"]))}
    # Several saved payers fit: don't guess.
    return (partial.pop(), False) if len(partial) == 1 else (None, False)


def saved_payer(store: PaymentStore, user_id: int, payer: str) -> str | None:
    return match_payer(store, user_id, payer)[0]


def parse_notification(text: str) -> tuple[Decimal | None, str]:
    """Best effort for bank push text such as "You have received SGD 1,200.00 from REFIX PTE. LTD." """
    flat = " ".join(text.split())
    if not re.search(r"\b(received|incoming|credited|paynow from|transfer from|deposit)\b", flat, re.I):
        return None, ""
    amount = re.search(AMOUNT, flat, re.I)
    payer = re.search(r"\bfrom\s+(.+?)(?=\s+(?:on\s+\d|to\s|via\s|into\s|ref)|[:;]|,\s|\s*$)", flat, re.I)
    try:
        value = Decimal(amount[1].replace(",", "")) if amount else None
    except InvalidOperation:
        value = None
    return value, (payer[1].strip(" .") if payer else "")


class Notification(BaseModel):
    text: str = Field(default="", max_length=2000)
    amount: str | None = Field(default=None, max_length=20)
    payer: str = Field(default="", max_length=200)
    currency: str = Field(default="SGD", min_length=3, max_length=3)


class PayInSettings(BaseModel):
    notifications_auto: bool


def _store(request: Request, authorization: str | None):
    from .gmail_payments import store_for
    store, user_id = store_for(request, authorization)
    ensure_schema(store.db)
    return store, user_id


@router.get("/pay-in")
async def get_pay_in(request: Request, authorization: str | None = Header(default=None)) -> dict:
    store, user_id = _store(request, authorization)
    return pay_in_status(store, user_id)


@router.patch("/pay-in")
async def update_pay_in(payload: PayInSettings, request: Request, authorization: str | None = Header(default=None)) -> dict:
    store, user_id = _store(request, authorization)
    with store.db:
        store.db.execute("INSERT INTO pay_in_settings(user_id,notifications_auto) VALUES(?,?) "
                         "ON CONFLICT(user_id) DO UPDATE SET notifications_auto=excluded.notifications_auto",
                         (user_id, int(payload.notifications_auto)))
    return pay_in_status(store, user_id)


@router.post("/pay-in/forwarding-confirmed")
async def forwarding_confirmed(request: Request, authorization: str | None = Header(default=None)) -> dict:
    """The person finished Gmail's confirmation, so the code and link are no longer needed."""
    store, user_id = _store(request, authorization)
    with store.db:
        store.db.execute("UPDATE pay_in_settings SET forward_confirmation=NULL WHERE user_id=?", (user_id,))
    return pay_in_status(store, user_id)


@router.post("/pay-in/forwarding/rotate")
async def rotate_forwarding(request: Request, authorization: str | None = Header(default=None)) -> dict:
    """A new private address: the old one stops working straight away (e.g. if it was shared by mistake)."""
    store, user_id = _store(request, authorization)
    with store.db:
        store.db.execute("INSERT INTO pay_in_settings(user_id,forward_token,forward_confirmation) VALUES(?,?,NULL) "
                         "ON CONFLICT(user_id) DO UPDATE SET forward_token=excluded.forward_token,forward_confirmation=NULL",
                         (user_id, secrets.token_hex(16)))
    return pay_in_status(store, user_id)


@router.post("/notification")
async def record_notification(payload: Notification, request: Request, authorization: str | None = Header(default=None)) -> dict:
    """Pay received, as read from a bank app notification on the person's iPhone."""
    store, user_id = _store(request, authorization)
    limit(request, "notification", maximum=120, key=str(user_id))
    parsed_amount, parsed_payer = parse_notification(payload.text)
    try:
        amount = Decimal(payload.amount.replace(",", "")) if payload.amount else parsed_amount
    except InvalidOperation:
        amount = parsed_amount
    payer_text = (payload.payer or parsed_payer).strip()
    if amount is None or amount <= 0:
        return {"status": "ignored", "message": "That notification doesn't look like money received."}
    amount = amount.quantize(Decimal("0.01"))
    payer, exact = match_payer(store, user_id, payer_text)
    if not payer:
        name = payer_text or "this payer"
        return {"status": "unknown_payer", "amount": str(amount), "payer": payer_text,
                "message": f"{payload.currency.upper()} {amount} from {name} isn't from a saved payer. Add them under Paid by on the event, then it'll be matched next time."}
    now = datetime.now(SGT).replace(second=0, microsecond=0)
    fingerprint = f"{now.isoformat()}|{amount}|{_key(payer)}"
    parsed = {"amount": str(amount), "currency": payload.currency.upper(), "payer": payer, "received_at": now.isoformat(),
              "account_last4": "", "reason": "", "receipt_key": hashlib.sha256(("notif:" + fingerprint).encode()).hexdigest()}
    auto = bool(settings(store, user_id)["notifications_auto"]) and exact
    if not exact:
        parsed["reason"] = f"Matched {payer} from \"{payer_text}\" by part of the name; check it's right."
    receipt_id = store.ingest(user_id, "notif:" + fingerprint, parsed, trusted=True, auto=auto)
    receipt = store.receipt(user_id, receipt_id)
    if receipt["status"] in {"auto_paid", "confirmed_paid"}:
        message = f"Marked {receipt['event']} paid: {parsed['currency']} {amount} from {payer}."
    else:
        message = f"{parsed['currency']} {amount} from {payer} is ready to check in Pay-in tracking."
    return {"status": receipt["status"], "event": receipt["event"], "amount": str(amount), "payer": payer, "message": message}


def _plain_text(message) -> str:
    part = message.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    text = part.get_content()
    if part.get_content_type() == "text/html":
        from .gmail_payments import TextHTML
        parser = TextHTML(); parser.feed(text); text = "".join(parser.parts)
    return text


def parse_forwarded(raw: bytes) -> tuple[str | None, dict | None]:
    """The forwarding token and the DBS alert inside a forwarded email (auto-forwarded or forwarded by hand)."""
    message = email.message_from_bytes(raw, policy=policy.default)
    recipients = " ".join(str(message.get(h, "")) for h in ("X-Original-To", "Delivered-To", "To"))
    token = re.search(r"pay\+([0-9a-f]{32}|[0-9a-f]{16})@", recipients, re.I)
    subject = re.sub(r"^\s*((fwd?|fw)\s*:\s*)+", "", str(message.get("Subject", "")), flags=re.I)
    text = _plain_text(message)
    sender = str(message.get("From", ""))
    if DBS_SENDER not in sender.casefold() and DBS_SENDER in text.casefold():
        sender = DBS_SENDER  # Forwarded by hand: the original sender is quoted in the body.
    if subject.casefold() != DBS_SUBJECT.casefold() and DBS_SUBJECT.casefold() in text.casefold():
        subject = DBS_SUBJECT
    # Read from the alert itself, skipping a hand-forward's quoted header ("From: digibank Alerts ...").
    start = text.casefold().find("you have received")
    if start > 0:
        text = text[start:]
    return (token[1].lower() if token else None), parse_dbs_alert(subject, sender, text)


@inbound.post("/inbound-email/{secret}")
async def inbound_email(secret: str, request: Request) -> dict:
    expected = os.environ.get("HOWMUCH_INBOUND_SECRET", "")
    if not expected or not hmac.compare_digest(secret, expected):
        raise HTTPException(404)
    raw = await request.body()
    if len(raw) > 2_000_000:
        raise HTTPException(413)
    token, parsed = parse_forwarded(raw)
    store = PaymentStore(request.app.state.storage)
    ensure_schema(store.db)
    row = store.db.execute("SELECT user_id FROM pay_in_settings WHERE forward_token=?", (token,)).fetchone() if token else None
    if not row:
        return {"status": "ignored"}
    confirmation = gmail_forwarding_confirmation(raw)
    if confirmation:
        # Keep it so Pay-in tracking can show the code and link needed to finish Gmail's setup.
        with store.db:
            store.db.execute("UPDATE pay_in_settings SET forward_confirmation=? WHERE user_id=?",
                             (json.dumps({**confirmation, "received": int(time.time())}), row["user_id"]))
        return {"status": "confirmation"}
    # Gmail stamps mail it auto-forwards; seeing that means forwarding is confirmed, so stop asking.
    headers = email.message_from_bytes(raw[:200_000])
    if headers.get("X-Forwarded-For") or headers.get("X-Forwarded-To"):
        with store.db:
            store.db.execute("UPDATE pay_in_settings SET forward_confirmation=NULL WHERE user_id=?", (row["user_id"],))
    if not parsed:
        return {"status": "ignored"}
    user_id = row["user_id"]
    if not store.accepts_payer(user_id, parsed["payer"]):
        payer = saved_payer(store, user_id, parsed["payer"])
        if not payer:
            return {"status": "ignored"}
        parsed["payer"] = payer
    message_id = "fwd:" + parsed["receipt_key"]
    receipt_id = store.ingest(user_id, message_id, parsed, trusted=False, auto=False,
                              review_reason="Forwarded email: check it against your bank before marking paid.")
    return {"status": store.receipt(user_id, receipt_id)["status"]}
