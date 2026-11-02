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
                value.split("?", 1)[0] if isinstance(value, str) and value.startswith("/webapp/api/payment-detection/gmail/") else value
                for value in record.args
            )
        return True


logging.getLogger("uvicorn.access").addFilter(OAuthAccessFilter())


def configured() -> bool:
    try:
        Fernet(os.environ.get("PAYBOT_GMAIL_TOKEN_KEY", "").encode())
    except (ValueError, TypeError):
        return False
    return bool(os.environ.get("GOOGLE_CLIENT_ID") and os.environ.get("GOOGLE_CLIENT_SECRET") and os.environ.get("PAYBOT_GMAIL_REDIRECT_URI", "").startswith("https://"))


def cipher() -> Fernet:
    return Fernet(os.environ["PAYBOT_GMAIL_TOKEN_KEY"].encode())


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def store_for(request: Request, authorization: str | None):
    from .webapp import _authed_user
    storage, user_id = _authed_user(request, authorization)
    return PaymentStore(storage), user_id


def result_page(message: str, success: bool = False) -> HTMLResponse:
    return HTMLResponse(
        '<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="referrer" content="no-referrer"><title>HowMuch · Gmail</title>'
        '<body style="font:17px/1.6 system-ui;margin:48px 24px;color:#183b37">'
        '<h1 style="font-size:26px">' + ("Gmail connected" if success else "Gmail connection") + '</h1><p>'
        + html.escape(message) + '</p><p>Return to HowMuch in Telegram and open Payment detection.</p></body></html>',
        headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"},
    )


@router.get("")
async def status(request: Request, authorization: str | None = Header(default=None)) -> dict:
    store, user_id = store_for(request, authorization)
    return {**store.status(user_id), "available": configured()}


@router.post("/connect")
async def connect(request: Request, authorization: str | None = Header(default=None)) -> dict:
    store, user_id = store_for(request, authorization)
    if not configured():
        raise HTTPException(503, "Gmail sign-in has not been configured on this deployment yet.")
    ticket = secrets.token_urlsafe(32)
    with store.db:
        store.db.execute("DELETE FROM payment_oauth WHERE expires<? OR user_id=?", (int(time.time()), user_id))
        store.db.execute("INSERT INTO payment_oauth(token_hash,user_id,stage,expires) VALUES(?,?,'ticket',?)", (digest(ticket), user_id, int(time.time()) + 600))
    redirect = os.environ["PAYBOT_GMAIL_REDIRECT_URI"]
    return {"url": redirect.rsplit("/", 1)[0] + "/start?" + urlencode({"ticket": ticket})}


@router.get("/gmail/start")
async def oauth_start(ticket: str, request: Request):
    store = PaymentStore(request.app.state.storage)
    with store.db:
        row = store.db.execute("DELETE FROM payment_oauth WHERE token_hash=? AND stage='ticket' AND expires>=? RETURNING user_id", (digest(ticket), int(time.time()))).fetchone()
        if not row or not configured():
            return result_page("This connection link has expired. Start again from HowMuch.")
        state, browser = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        store.db.execute("INSERT INTO payment_oauth VALUES(?,?,'callback',?,?)", (digest(state), row["user_id"], digest(browser), int(time.time()) + 600))
    response = RedirectResponse("https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
        "client_id": os.environ["GOOGLE_CLIENT_ID"], "redirect_uri": os.environ["PAYBOT_GMAIL_REDIRECT_URI"],
        "scope": SCOPE, "response_type": "code", "access_type": "offline", "prompt": "consent", "state": state,
    }), status_code=303, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})
    response.set_cookie("howmuch_gmail_oauth", browser, max_age=600, secure=True, httponly=True, samesite="lax", path="/webapp/api/payment-detection/gmail")
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
    if error or not code:
        return result_page("Gmail was not connected. You can try again from Settings.")
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post("https://oauth2.googleapis.com/token", data={
                "client_id": os.environ["GOOGLE_CLIENT_ID"], "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
                "redirect_uri": os.environ["PAYBOT_GMAIL_REDIRECT_URI"], "grant_type": "authorization_code", "code": code,
            })
            response.raise_for_status()
            token = response.json()
            if SCOPE not in token.get("scope", "").split() or not token.get("refresh_token"):
                return result_page("Read-only Gmail access was not granted. Start again and allow email reading.")
            profile = await client.get(API + "/profile", headers={"Authorization": "Bearer " + token["access_token"]})
            profile.raise_for_status()
            email = profile.json()["emailAddress"]
        store.save_connection(row["user_id"], email, cipher().encrypt(token["refresh_token"].encode()).decode())
    except sqlite3.IntegrityError:
        return result_page("This mailbox is already connected to another HowMuch account. Disconnect it there first.")
    except (httpx.HTTPError, KeyError, ValueError):
        return result_page("Gmail could not be connected. Please try again.")
    response = result_page("Recent DBS transfer alerts will be checked every two minutes. Automatic marking stays off until you enable it and add payer rules.", True)
    response.delete_cookie("howmuch_gmail_oauth", path="/webapp/api/payment-detection/gmail")
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


@router.patch("")
async def update_settings(payload: DetectionSettings, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    connection = store.connection(user_id)
    if not connection or not connection["refresh_token"]:
        raise HTTPException(400, "Connect Gmail first.")
    if payload.auto_enabled and not configured():
        raise HTTPException(400, "Gmail setup must be completed before enabling automatic marking.")
    with store.db:
        since = (connection["auto_since"] or int(time.time())) if payload.auto_enabled else 0
        store.db.execute("UPDATE payment_connections SET auto_since=? WHERE user_id=?", (since, user_id))
    return {**store.status(user_id), "available": configured()}


@router.post("/rules")
async def add_rule(payload: PayerRule, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    try:
        store.save_rule(user_id, payload.payer, payload.event)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {**store.status(user_id), "available": configured()}


@router.delete("/rules/{rule_id}")
async def delete_rule(rule_id: int, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    with store.db:
        store.db.execute("DELETE FROM payment_rules WHERE id=? AND user_id=?", (rule_id, user_id))
    return {**store.status(user_id), "available": configured()}


@router.post("/receipts/{receipt_id}/{action}")
async def receipt_action(receipt_id: int, action: str, request: Request, payload: ApplyReceipt | None = None, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    try:
        if action == "confirm" and payload:
            store.confirm(user_id, receipt_id, payload.event)
        elif action == "dismiss":
            store.dismiss(user_id, receipt_id)
        elif action == "undo":
            store.undo(user_id, receipt_id)
        else:
            raise ValueError("Unknown payment action.")
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {**store.status(user_id), "available": configured()}


@router.delete("/connection")
async def disconnect(request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    # Clear local credentials even if Google's revocation endpoint is unavailable.
    connection = store.connection(user_id)
    with store.db:
        store.db.execute("DELETE FROM payment_connections WHERE user_id=?", (user_id,))
        store.db.execute("DELETE FROM payment_oauth WHERE user_id=?", (user_id,))
    if connection and connection["refresh_token"] and configured():
        try:
            token = cipher().decrypt(connection["refresh_token"].encode()).decode()
            async with httpx.AsyncClient(timeout=10) as client:
                await client.post("https://oauth2.googleapis.com/revoke", data={"token": token})
        except (httpx.HTTPError, InvalidToken):
            pass
    return {**store.status(user_id), "available": configured()}


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
    if not configured():
        raise ValueError("Gmail is not configured on this deployment.")
    async with _locks.setdefault(user_id, asyncio.Lock()):
        store = PaymentStore(storage)
        connection = store.connection(user_id)
        if not connection or not connection["refresh_token"]:
            raise ValueError("Connect Gmail first.")
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
                query = f'from:{DBS_SENDER} subject:"digibank Alerts" after:{since} before:{started + 1}'
                page_token = None
                for _ in range(100):
                    params = {"q": query, "maxResults": 100}
                    if page_token:
                        params["pageToken"] = page_token
                    response = await client.get(API + "/messages", headers=headers, params=params)
                    response.raise_for_status()
                    page = response.json()
                    for item in page.get("messages", []):
                        response = await client.get(API + "/messages/" + item["id"], headers=headers, params={"format": "full"})
                        response.raise_for_status()
                        message = response.json()
                        payload = message.get("payload", {})
                        mail_headers = payload.get("headers", [])
                        values = {h["name"].lower(): h["value"] for h in mail_headers if h["name"].lower() in {"subject", "from"}}
                        parsed = parse_dbs_alert(values.get("subject", ""), values.get("from", ""), message_text(payload))
                        current = store.connection(user_id)
                        if not current or current["refresh_token"] != connection["refresh_token"]:
                            return  # Disconnected or replaced while requests were in flight.
                        if parsed:
                            store.ingest(user_id, item["id"], parsed, gmail_authenticated(mail_headers, message.get("labelIds", [])))
                    page_token = page.get("nextPageToken")
                    if not page_token:
                        break
                else:
                    raise ValueError("There are too many alerts to scan at once. Please try again later.")
            with store.db:
                store.db.execute("UPDATE payment_connections SET last_scan=?,error='' WHERE user_id=? AND refresh_token=?", (started, user_id, connection["refresh_token"]))
        except (httpx.HTTPError, InvalidToken, KeyError, ValueError) as exc:
            message = "Gmail could not be checked. Reconnect Gmail if access has expired."
            with store.db:
                store.db.execute("UPDATE payment_connections SET error=? WHERE user_id=? AND refresh_token=?", (message, user_id, connection["refresh_token"]))
            raise ValueError(message) from exc


@router.post("/scan")
async def scan(request: Request, authorization: str | None = Header(default=None)):
    store, user_id = store_for(request, authorization)
    try:
        await scan_mailbox(store.storage, user_id)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return {**store.status(user_id), "available": configured()}


async def poll_mailboxes(storage):
    while True:
        if configured():
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
