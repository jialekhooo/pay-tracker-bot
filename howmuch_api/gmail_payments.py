"""Read-only Gmail OAuth and periodic DBS alert import. Credentials stay server-side."""
from __future__ import annotations

import asyncio
import base64
import hashlib
import html
import logging
import os
import secrets
import sqlite3
import time
from html.parser import HTMLParser
from urllib.parse import urlencode

import httpx
from cryptography.fernet import Fernet, InvalidToken
from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field

from .database import limit
from .payment_detection import DBS_SENDER, PaymentStore, gmail_authenticated, parse_dbs_alert

router = APIRouter(prefix="/payment-detection")
SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
API = "https://gmail.googleapis.com/gmail/v1/users/me"
_locks: dict[int, asyncio.Lock] = {}


class OAuthAccessFilter(logging.Filter):
    """Keep one-time OAuth credentials out of Uvicorn's access logs."""
    def filter(self, record):
        if isinstance(record.args, tuple):
            record.args = tuple(
                value.split("?", 1)[0] if isinstance(value, str) and (value.startswith("/v1/payment-detection/gmail/") or value.startswith("/v1/payment-detection/microsoft/")) else value
                for value in record.args
            )
        return True


logging.getLogger("uvicorn.access").addFilter(OAuthAccessFilter())


def configured() -> bool:
    try:
        Fernet(os.environ.get("HOWMUCH_GMAIL_TOKEN_KEY", "").encode())
    except (ValueError, TypeError):
        return False
    return bool(os.environ.get("GOOGLE_CLIENT_ID") and os.environ.get("GOOGLE_CLIENT_SECRET") and os.environ.get("HOWMUCH_GMAIL_REDIRECT_URI", "").startswith("https://"))


def cipher() -> Fernet:
    return Fernet(os.environ["HOWMUCH_GMAIL_TOKEN_KEY"].encode())


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def store_for(request: Request, authorization: str | None):
    from .auth import authenticated_account
    account = authenticated_account(request, authorization)
    storage, user_id = request.app.state.storage, account["id"]
    return PaymentStore(storage), user_id


def result_page(message: str, success: bool = False, provider: str = "Gmail") -> HTMLResponse:
    return HTMLResponse(
        '<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="referrer" content="no-referrer"><title>HowMuch · Gmail</title>'
        '<body style="font:17px/1.6 system-ui;margin:48px 24px;color:#183b37">'
        '<h1 style="font-size:26px">' + html.escape(provider + (" connected" if success else " connection")) + '</h1><p>'
        + html.escape(message) + '</p><p>Return to the HowMuch iPhone app and open Payment detection.</p></body></html>',
        headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"},
    )


def detection_status(store, user_id):
    from .email_providers import provider_ready
    conn = store.connection(user_id)
    provider = conn["provider"] if conn else "gmail"
    providers = {name: provider_ready(name) for name in ("gmail", "microsoft", "icloud")}
    return {**store.status(user_id), "available": providers.get(provider, False) if conn else any(providers.values()), "providers": providers}


@router.get("")
async def status(request: Request, authorization: str | None = Header(default=None)) -> dict:
    store, user_id = store_for(request, authorization)
    return detection_status(store, user_id)


@router.post("/connect")
async def connect(request: Request, authorization: str | None = Header(default=None)) -> dict:
    store, user_id = store_for(request, authorization)
    if not configured():
        raise HTTPException(503, "Gmail sign-in has not been configured on this deployment yet.")
    if store.connection(user_id) and store.connection(user_id)["provider"] != "gmail":
        raise HTTPException(409, "Disconnect your current email before connecting Gmail.")
    ticket = secrets.token_urlsafe(32)
    with store.db:
        store.db.execute("DELETE FROM payment_oauth WHERE expires<? OR user_id=?", (int(time.time()), user_id))
        store.db.execute("INSERT INTO payment_oauth(token_hash,user_id,stage,expires) VALUES(?,?,'ticket',?)", (digest(ticket), user_id, int(time.time()) + 600))
    redirect = os.environ["HOWMUCH_GMAIL_REDIRECT_URI"]
    return {"url": redirect.rsplit("/", 1)[0] + "/start?" + urlencode({"ticket": ticket})}


def ticket_label(store: PaymentStore, ticket: str, stage: str) -> str | None:
    """Who the connection link belongs to, as shown on the confirmation page (None if expired)."""
    row = store.db.execute("SELECT user_id FROM payment_oauth WHERE token_hash=? AND stage=? AND expires>=?",
                           (digest(ticket), stage, int(time.time()))).fetchone()
    if not row:
        return None
    account = store.db.execute("SELECT display_name,email FROM accounts WHERE id=?", (row["user_id"],)).fetchone()
    if account and account["display_name"]:
        return account["display_name"]
    email = (account["email"] if account else "") or ""
    if "@" in email:
        name, domain = email.split("@", 1)
        return name[:2] + "•••@" + domain
    return "a HowMuch account"


def confirm_page(provider: str, label: str, ticket: str, action: str) -> HTMLResponse:
    """A link someone sends you must not link your mailbox to their account: show whose account
    this is and require a deliberate Continue before going to the sign-in page."""
    return HTMLResponse(
        '<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="referrer" content="no-referrer"><title>HowMuch · Connect ' + html.escape(provider) + '</title>'
        '<body style="font:17px/1.6 system-ui;margin:48px 24px;color:#183b37">'
        '<h1 style="font-size:26px">Connect ' + html.escape(provider) + ' to HowMuch</h1>'
        '<p>This will let the HowMuch account of <b>' + html.escape(label) + '</b> read bank payment alerts in the mailbox you sign in to next.</p>'
        '<p>Only continue if you started this from <b>your own</b> HowMuch app just now. If someone sent you this link, close this page.</p>'
        '<form method="post" action="' + html.escape(action) + '"><input type="hidden" name="ticket" value="' + html.escape(ticket) + '">'
        '<button style="font:inherit;padding:12px 22px;border-radius:14px;border:0;background:#126b5e;color:#fff">Continue to ' + html.escape(provider) + '</button></form></body></html>',
        headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                 "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"},
    )


async def posted_ticket(request: Request) -> str:
    from urllib.parse import parse_qs
    return (parse_qs((await request.body())[:2000].decode(errors="ignore")).get("ticket") or [""])[0]


@router.get("/gmail/start")
async def oauth_confirm(ticket: str, request: Request):
    label = ticket_label(PaymentStore(request.app.state.storage), ticket, "ticket")
    if not label or not configured():
        return result_page("This connection link has expired. Start again from HowMuch.")
    return confirm_page("Gmail", label, ticket, "/v1/payment-detection/gmail/start")


@router.post("/gmail/start")
async def oauth_start(request: Request):
    ticket = await posted_ticket(request)
    store = PaymentStore(request.app.state.storage)
    with store.db:
        row = store.db.execute("DELETE FROM payment_oauth WHERE token_hash=? AND stage='ticket' AND expires>=? RETURNING user_id", (digest(ticket), int(time.time()))).fetchone()
        if not row or not configured():
            return result_page("This connection link has expired. Start again from HowMuch.")
        state, browser = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        store.db.execute("INSERT INTO payment_oauth VALUES(?,?,'callback',?,?)", (digest(state), row["user_id"], digest(browser), int(time.time()) + 600))
    response = RedirectResponse("https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
        "client_id": os.environ["GOOGLE_CLIENT_ID"], "redirect_uri": os.environ["HOWMUCH_GMAIL_REDIRECT_URI"],
        "scope": SCOPE, "response_type": "code", "access_type": "offline", "prompt": "consent", "state": state,
    }), status_code=303, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})
    response.set_cookie("howmuch_gmail_oauth", browser, max_age=600, secure=True, httponly=True, samesite="lax", path="/v1/payment-detection/gmail")
    return response


@router.get("/gmail/callback")
async def oauth_callback(request: Request, state: str = "", code: str = "", error: str = ""):
    store = PaymentStore(request.app.state.storage)
    cookie = request.cookies.get("howmuch_gmail_oauth", "")
    with store.db:
        row = store.db.execute(
            "DELETE FROM payment_oauth WHERE token_hash=? AND stage='callback' AND browser_hash=? AND expires>=? RETURNING user_id",
            (digest(state), digest(cookie), int(time.time())),
        ).fetchone() if state and cookie else None
    if not row or not configured():
        return result_page("The sign-in could not be verified. Start again from HowMuch.")
    existing = store.connection(row["user_id"])
    if existing and existing["provider"] != "gmail":
        return result_page("Disconnect your current email before connecting Gmail.")
    if error or not code:
        return result_page("Gmail was not connected. You can try again from Settings.")
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post("https://oauth2.googleapis.com/token", data={
                "client_id": os.environ["GOOGLE_CLIENT_ID"], "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
                "redirect_uri": os.environ["HOWMUCH_GMAIL_REDIRECT_URI"], "grant_type": "authorization_code", "code": code,
            })
            response.raise_for_status()
            token = response.json()
            if SCOPE not in token.get("scope", "").split() or not token.get("refresh_token"):
                return result_page("Read-only Gmail access was not granted. Start again and allow email reading.")
            profile = await client.get(API + "/profile", headers={"Authorization": "Bearer " + token["access_token"]})
            profile.raise_for_status()
            email = profile.json()["emailAddress"]
        if not store.db.execute("SELECT 1 FROM accounts WHERE id=?", (row["user_id"],)).fetchone():
            try:
                async with httpx.AsyncClient(timeout=10) as cleanup:
                    await cleanup.post("https://oauth2.googleapis.com/revoke", data={"token": token["refresh_token"]})
            except httpx.HTTPError:
                pass
            return result_page("This HowMuch account was removed. The Gmail connection was not saved.")
        if store.connection(row["user_id"]) and store.connection(row["user_id"])["provider"] != "gmail":
            return result_page("The mailbox connection changed. Start again from HowMuch.")
        store.save_connection(row["user_id"], email, cipher().encrypt(token["refresh_token"].encode()).decode())
    except sqlite3.IntegrityError:
        return result_page("This mailbox is already connected to another HowMuch account. Disconnect it there first.")
    except (httpx.HTTPError, KeyError, ValueError):
        return result_page("Gmail could not be connected. Please try again.")
    response = result_page("Recent DBS transfer alerts will be checked every two minutes. Automatic marking stays off until you enable it and add payer rules.", True)
    response.delete_cookie("howmuch_gmail_oauth", path="/v1/payment-detection/gmail")
    return response


class DetectionSettings(BaseModel):
    auto_enabled: bool


class PayerRule(BaseModel):
    payer: str = Field(min_length=1, max_length=200)
    event: str = Field(min_length=1, max_length=120)


class EventPayer(BaseModel):
    event: str = Field(min_length=1, max_length=120)
    payer: str = Field(max_length=200)


@router.put("/event-payer")
async def set_event_payer(payload: EventPayer, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    try:
        store.set_event_payer(user_id, payload.event, payload.payer)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {"event": payload.event, "payers": [r["payer"] for r in store.rules(user_id) if r["event"].casefold() == payload.event.strip().casefold()]}


class ApplyReceipt(BaseModel):
    event: str = Field(min_length=1, max_length=120)
    acknowledge_unverified: bool = False


@router.patch("")
async def update_settings(payload: DetectionSettings, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    connection = store.connection(user_id)
    if not connection or not connection["refresh_token"]:
        raise HTTPException(400, "Connect Gmail first.")
    if payload.auto_enabled and connection["provider"] != "gmail":
        raise HTTPException(400, "This provider requires bank confirmation before marking paid.")
    if payload.auto_enabled and not configured():
        raise HTTPException(400, "Gmail setup must be completed before enabling automatic marking.")
    with store.db:
        since = (connection["auto_since"] or int(time.time())) if payload.auto_enabled else 0
        store.db.execute("UPDATE payment_connections SET auto_since=? WHERE user_id=?", (since, user_id))
    return detection_status(store, user_id)


@router.post("/rules")
async def add_rule(payload: PayerRule, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    try:
        store.save_rule(user_id, payload.payer, payload.event)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return detection_status(store, user_id)


@router.delete("/rules/{rule_id}")
async def delete_rule(rule_id: int, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    with store.db:
        store.db.execute("DELETE FROM payment_rules WHERE id=? AND user_id=?", (rule_id, user_id))
    return detection_status(store, user_id)


@router.post("/receipts/{receipt_id}/{action}")
async def receipt_action(receipt_id: int, action: str, request: Request, payload: ApplyReceipt | None = None, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    try:
        if action == "confirm" and payload:
            store.confirm(user_id, receipt_id, payload.event, payload.acknowledge_unverified)
        elif action == "dismiss":
            store.dismiss(user_id, receipt_id)
        elif action == "undo":
            store.undo(user_id, receipt_id)
        else:
            raise ValueError("Unknown payment action.")
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    return detection_status(store, user_id)


async def revoke_google(connection) -> None:
    """Withdraws HowMuch's Gmail access at Google (best effort)."""
    if connection and connection["provider"] == "gmail" and connection["refresh_token"] and configured():
        try:
            token = cipher().decrypt(connection["refresh_token"].encode()).decode()
            async with httpx.AsyncClient(timeout=10) as client:
                await client.post("https://oauth2.googleapis.com/revoke", data={"token": token})
        except (httpx.HTTPError, InvalidToken, ValueError):
            pass


@router.delete("/connection")
async def disconnect(request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    # Clear local credentials even if Google's revocation endpoint is unavailable.
    connection = store.connection(user_id)
    with store.db:
        store.db.execute("DELETE FROM payment_connections WHERE user_id=?", (user_id,))
        store.db.execute("DELETE FROM payment_oauth WHERE user_id=?", (user_id,))
    await revoke_google(connection)
    return detection_status(store, user_id)


class TextHTML(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts: list[str] = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"style", "script"}:
            self.skip += 1
        if tag in {"br", "p", "div", "tr", "td"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"style", "script"}:
            self.skip = max(0, self.skip - 1)
        if tag in {"p", "div", "tr", "td"}:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def message_text(payload: dict) -> str:
    plain, rich = [], []

    def visit(part):
        data = part.get("body", {}).get("data", "")
        mime = part.get("mimeType", "")
        if data and not part.get("filename") and mime in {"text/plain", "text/html"}:
            decoded = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", errors="replace")
            if mime == "text/plain":
                plain.append(decoded)
            else:
                parser = TextHTML()
                parser.feed(decoded)
                rich.append("".join(parser.parts))
        for child in part.get("parts", []):
            visit(child)
    visit(payload)
    return "\n".join(plain or rich).replace("\xa0", " ")


async def scan_mailbox(storage, user_id: int) -> None:
    connection = PaymentStore(storage).connection(user_id)
    if connection and connection["provider"] != "gmail":
        from .email_providers import scan_other_mailbox
        return await scan_other_mailbox(storage, user_id)
    if not configured():
        raise ValueError("Gmail is not configured on this deployment.")
    async with _locks.setdefault(user_id, asyncio.Lock()):
        store = PaymentStore(storage)
        connection = store.connection(user_id)
        if not connection or not connection["refresh_token"]:
            raise ValueError("Connect Gmail first.")
        payers = sorted(store.allowed_payers(user_id))
        if not payers:
            return  # No job companies configured: do not access Gmail at all.
        started = int(time.time())
        try:
            refresh = cipher().decrypt(connection["refresh_token"].encode()).decode()
            async with httpx.AsyncClient(timeout=20) as client:
                response = await client.post("https://oauth2.googleapis.com/token", data={
                    "client_id": os.environ["GOOGLE_CLIENT_ID"], "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
                    "grant_type": "refresh_token", "refresh_token": refresh,
                })
                response.raise_for_status()
                token = response.json()
                headers = {"Authorization": "Bearer " + token["access_token"]}
                since = max(connection["connected_at"] - 30 * 86400, connection["last_scan"] - 300)
                # Keep company names inside quoted search terms, never query operators.
                phrases = ['"' + payer.replace('\\', ' ').replace('"', ' ') + '"' for payer in payers]
                base_query = f'from:{DBS_SENDER} subject:"digibank Alerts" subject:received subject:transfer after:{since} before:{started + 1}'
                queries = [base_query + ' {' + ' '.join(phrases[i:i + 20]) + '}' for i in range(0, len(phrases), 20)]
                for query in queries:
                    if not await _scan_query(client, headers, query, store, user_id, connection, set(payers)):
                        return
            with store.db:
                store.db.execute("UPDATE payment_connections SET last_scan=?,error='' WHERE user_id=? AND refresh_token=?", (started, user_id, connection["refresh_token"]))
        except (httpx.HTTPError, InvalidToken, KeyError, ValueError) as exc:
            message = "Gmail could not be checked. Reconnect Gmail if access has expired."
            with store.db:
                store.db.execute("UPDATE payment_connections SET error=? WHERE user_id=? AND refresh_token=?", (message, user_id, connection["refresh_token"]))
            raise ValueError(message) from exc


async def _scan_query(client, headers, query, store, user_id, connection, payers):
    def still_current():
        current = store.connection(user_id)
        return bool(current and current["refresh_token"] == connection["refresh_token"] and store.allowed_payers(user_id) == payers)

    page_token = None
    for _ in range(100):
        if not still_current():
            return False
        params = {"q": query, "maxResults": 100}
        if page_token:
            params["pageToken"] = page_token
        response = await client.get(API + "/messages", headers=headers, params=params)
        response.raise_for_status()
        page = response.json()
        for item in page.get("messages", []):
            if not still_current():
                return False
            response = await client.get(API + "/messages/" + item["id"], headers=headers, params={"format": "full"})
            response.raise_for_status()
            message = response.json()
            payload = message.get("payload", {})
            mail_headers = payload.get("headers", [])
            values = {h["name"].lower(): h["value"] for h in mail_headers if h["name"].lower() in {"subject", "from"}}
            parsed = parse_dbs_alert(values.get("subject", ""), values.get("from", ""), message_text(payload))
            if not still_current():
                return False  # Disconnected or replaced while requests were in flight.
            # Gmail can match a name elsewhere in the message. Verify the
            # actual From: payer line again against the latest saved rules.
            if parsed and store.accepts_payer(user_id, parsed["payer"]):
                store.ingest(user_id, item["id"], parsed, gmail_authenticated(mail_headers, message.get("labelIds", [])))
        page_token = page.get("nextPageToken")
        if not page_token:
            break
    else:
        raise ValueError("There are too many alerts to scan at once. Please try again later.")
    return True


@router.post("/scan")
async def scan(request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    limit(request, "scan", maximum=10, key=str(user_id))  # mailbox scans are slow and costly
    try:
        await scan_mailbox(store.storage, user_id)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return detection_status(store, user_id)


async def poll_mailboxes(storage):
    while True:
        store = PaymentStore(storage)
        users = [r[0] for r in store.db.execute("SELECT user_id FROM payment_connections WHERE refresh_token IS NOT NULL")]
        for user_id in users:
            try:
                await scan_mailbox(storage, user_id)
            except ValueError:
                pass  # A reconnect/check error is already visible in Settings.
            except Exception:
                # One bad mailbox must not terminate the background worker.
                logging.getLogger(__name__).error("Payment detection check failed for user %s", user_id)
                with store.db:
                    store.db.execute("UPDATE payment_connections SET error=? WHERE user_id=?", ("Payment detection could not complete. Try checking again.", user_id))
        await asyncio.sleep(120)
