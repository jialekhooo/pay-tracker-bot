"""Optional read-only iCloud IMAP and delegated Microsoft Graph connectors.

Only Gmail's established receiver authentication can authorize automatic payment.
Other providers import candidates for explicit bank-confirmed review.
"""
from __future__ import annotations

import asyncio
import hashlib
import imaplib
import os
import re
import secrets
import sqlite3
import ssl
import time
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from urllib.parse import urlencode, urlparse

import httpx
from cryptography.fernet import Fernet, InvalidToken
from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field, SecretStr

from . import gmail_payments as gmail
from .payment_detection import DBS_SENDER, PaymentStore, parse_dbs_alert

router = APIRouter(prefix="/payment-detection")
MS = "https://login.microsoftonline.com/common/oauth2/v2.0"
GRAPH = "https://graph.microsoft.com/v1.0/me"
MS_SCOPE = "https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read offline_access"
MAX_MAIL_BYTES = 524288


def result_page(message, success=False):
    return gmail.result_page(message, success, provider="Outlook")


def provider_ready(provider: str) -> bool:
    if provider == "gmail":
        return gmail.configured()
    try:
        Fernet(os.environ.get("HOWMUCH_GMAIL_TOKEN_KEY", "").encode())
    except (ValueError, TypeError):
        return False
    if provider == "icloud":
        return True
    return provider == "microsoft" and bool(os.getenv("MICROSOFT_CLIENT_ID") and os.getenv("MICROSOFT_CLIENT_SECRET") and os.getenv("HOWMUCH_MICROSOFT_REDIRECT_URI", "").startswith("https://"))


def current(store, user_id, connection, payers):
    conn = store.connection(user_id)
    return bool(conn and conn["provider"] == connection["provider"] and conn["refresh_token"] == connection["refresh_token"] and store.allowed_payers(user_id) == payers)


def mail_text(message):
    plain, rich = [], []
    for part in message.walk():
        if part.get_content_disposition() == "attachment" or part.get_filename():
            continue
        if part.get_content_type() not in {"text/plain", "text/html"}:
            continue
        content = part.get_payload(decode=True) or b""
        value = content.decode(part.get_content_charset() or "utf-8", errors="replace")
        if part.get_content_type() == "text/plain":
            plain.append(value)
        else:
            parser = gmail.TextHTML(); parser.feed(value); rich.append("".join(parser.parts))
    return "\n".join(plain or rich).replace("\xa0", " ")


def icloud_client(email, password):
    # Fixed Apple endpoint: never accept arbitrary IMAP hosts or ports.
    client = imaplib.IMAP4_SSL("imap.mail.me.com", 993, ssl_context=ssl.create_default_context(), timeout=15)
    try:
        client.login(email, password)
        if client.select("INBOX", readonly=True)[0] != "OK":
            raise ValueError("The iCloud inbox could not be opened.")
        return client
    except Exception:
        try: client.logout()
        except Exception: pass
        raise


def check_icloud(email, password):
    client = icloud_client(email, password)
    client.logout()


class ICloudConnection(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    app_password: SecretStr
    consent: bool = False


@router.post("/icloud/connect")
async def connect_icloud(payload: ICloudConnection, request: Request, authorization: str | None = Header(default=None)):
    store, user_id = gmail.store_for(request, authorization)
    if not provider_ready("icloud"):
        raise HTTPException(503, "iCloud connection is not configured.")
    email = payload.email.strip().casefold()
    password = payload.app_password.get_secret_value().strip()
    if not re.fullmatch(r"[a-z0-9._+%-]+@(icloud\.com|me\.com|mac\.com)", email) or not re.fullmatch(r"[a-z]{4}(?:-[a-z]{4}){3}", password):
        raise HTTPException(400, "Enter your iCloud Mail address and an Apple app-specific password (xxxx-xxxx-xxxx-xxxx). Do not use your Apple Account password.")
    if not payload.consent:
        raise HTTPException(400, "Approve private email scanning before connecting.")
    async with gmail._locks.setdefault(user_id, asyncio.Lock()):
        if store.connection(user_id):
            raise HTTPException(409, "Disconnect your current email before connecting another mailbox.")
        ticket = gmail.digest(secrets.token_urlsafe(32))
        with store.db:
            store.db.execute("DELETE FROM payment_oauth WHERE user_id=?", (user_id,))
            store.db.execute("INSERT INTO payment_oauth(token_hash,user_id,stage,expires) VALUES(?,?,'icloud_connect',?)", (ticket, user_id, int(time.time()) + 120))
        try:
            await asyncio.to_thread(check_icloud, email, password)
            # Sign-out/deletion while the network operation was in flight must win.
            gmail.store_for(request, authorization)
            with store.db:
                active = store.db.execute("DELETE FROM payment_oauth WHERE token_hash=? AND stage='icloud_connect' AND expires>=? RETURNING user_id", (ticket, int(time.time()))).fetchone()
                if not active or store.connection(user_id):
                    raise HTTPException(409, "The connection was cancelled or changed. Start again from HowMuch.")
            store.save_connection(user_id, email, gmail.cipher().encrypt(password.encode()).decode(), "icloud")
        except sqlite3.IntegrityError:
            raise HTTPException(409, "This mailbox is already connected to another HowMuch account.")
        except (imaplib.IMAP4.error, OSError, ValueError):
            raise HTTPException(400, "iCloud could not connect. Check the Mail address and app-specific password, then retry.") from None
        finally:
            with store.db: store.db.execute("DELETE FROM payment_oauth WHERE token_hash=?", (ticket,))
    return gmail.detection_status(store, user_id)


@router.post("/microsoft/connect")
async def connect_microsoft(request: Request, authorization: str | None = Header(default=None)):
    store, user_id = gmail.store_for(request, authorization)
    if not provider_ready("microsoft"):
        raise HTTPException(503, "Outlook sign-in is awaiting Microsoft app configuration. iCloud and Gmail can be connected separately.")
    if store.connection(user_id):
        raise HTTPException(409, "Disconnect your current email before connecting another mailbox.")
    ticket = secrets.token_urlsafe(32)
    with store.db:
        store.db.execute("DELETE FROM payment_oauth WHERE expires<? OR user_id=?", (int(time.time()), user_id))
        store.db.execute("INSERT INTO payment_oauth(token_hash,user_id,stage,expires) VALUES(?,?,'microsoft_ticket',?)", (gmail.digest(ticket), user_id, int(time.time()) + 600))
    return {"url": os.environ["HOWMUCH_MICROSOFT_REDIRECT_URI"].rsplit("/", 1)[0] + "/start?" + urlencode({"ticket": ticket})}


def verifier_for(state, browser):
    # Derivable only by this browser callback plus the service secret; not stored in DB.
    import hmac
    return hmac.new(os.environ["HOWMUCH_GMAIL_TOKEN_KEY"].encode(), (state + ":" + browser).encode(), hashlib.sha256).hexdigest()


@router.get("/microsoft/start")
async def microsoft_start(ticket: str, request: Request):
    store = PaymentStore(request.app.state.storage)
    with store.db:
        row = store.db.execute("DELETE FROM payment_oauth WHERE token_hash=? AND stage='microsoft_ticket' AND expires>=? RETURNING user_id", (gmail.digest(ticket), int(time.time()))).fetchone()
        if not row or not provider_ready("microsoft"):
            return result_page("This connection link has expired. Start again from HowMuch.")
        state, browser = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        store.db.execute("INSERT INTO payment_oauth VALUES(?,?,'microsoft_callback',?,?)", (gmail.digest(state), row["user_id"], gmail.digest(browser), int(time.time()) + 600))
    import base64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier_for(state, browser).encode()).digest()).decode().rstrip("=")
    response = RedirectResponse(MS + "/authorize?" + urlencode({"client_id": os.environ["MICROSOFT_CLIENT_ID"], "redirect_uri": os.environ["HOWMUCH_MICROSOFT_REDIRECT_URI"], "scope": MS_SCOPE, "response_type": "code", "response_mode": "query", "state": state, "prompt": "select_account", "code_challenge": challenge, "code_challenge_method": "S256"}), status_code=303, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})
    response.set_cookie("howmuch_microsoft_oauth", browser, secure=True, httponly=True, samesite="lax", max_age=600, path="/v1/payment-detection/microsoft")
    return response


def ms_token_data(**values):
    return {"client_id": os.environ["MICROSOFT_CLIENT_ID"], "client_secret": os.environ["MICROSOFT_CLIENT_SECRET"], **values}


@router.get("/microsoft/callback")
async def microsoft_callback(request: Request, state: str = "", code: str = "", error: str = ""):
    store = PaymentStore(request.app.state.storage)
    browser = request.cookies.get("howmuch_microsoft_oauth", "")
    with store.db:
        row = store.db.execute("DELETE FROM payment_oauth WHERE token_hash=? AND browser_hash=? AND stage='microsoft_callback' AND expires>=? RETURNING user_id", (gmail.digest(state), gmail.digest(browser), int(time.time()))).fetchone() if state and browser else None
    if not row or not provider_ready("microsoft"):
        return result_page("The sign-in could not be verified. Start again from HowMuch.")
    if error or not code:
        return result_page("Outlook was not connected. Try again from HowMuch.")
    async with gmail._locks.setdefault(row["user_id"], asyncio.Lock()):
        if store.connection(row["user_id"]):
            return result_page("Disconnect your current mailbox before connecting Outlook.")
        ticket = gmail.digest(secrets.token_urlsafe(32))
        with store.db:
            store.db.execute("INSERT INTO payment_oauth(token_hash,user_id,stage,expires) VALUES(?,?,'microsoft_finishing',?)", (ticket, row["user_id"], int(time.time()) + 120))
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                response = await client.post(MS + "/token", data=ms_token_data(grant_type="authorization_code", code=code, redirect_uri=os.environ["HOWMUCH_MICROSOFT_REDIRECT_URI"], code_verifier=verifier_for(state, browser)))
                response.raise_for_status(); token = response.json()
                if not token.get("refresh_token") or not any(s.casefold().endswith("mail.read") for s in token.get("scope", "").split()):
                    return result_page("Read-only mail access was not granted. Try again and approve mail reading.")
                profile = await client.get(GRAPH + "?$select=mail,userPrincipalName", headers={"Authorization": "Bearer " + token["access_token"]})
                profile.raise_for_status(); data = profile.json()
                email = data.get("mail") or data.get("userPrincipalName")
                if not email or "@" not in email:
                    raise ValueError("No mailbox")
            if not store.db.execute("SELECT 1 FROM accounts WHERE id=?", (row["user_id"],)).fetchone():
                return result_page("This HowMuch account was removed. The connection was not saved.")
            with store.db:
                active = store.db.execute("DELETE FROM payment_oauth WHERE token_hash=? AND stage='microsoft_finishing' AND expires>=? RETURNING user_id", (ticket, int(time.time()))).fetchone()
                if not active or store.connection(row["user_id"]):
                    return result_page("The connection was cancelled or changed. Start again from HowMuch.")
            store.save_connection(row["user_id"], email, gmail.cipher().encrypt(token["refresh_token"].encode()).decode(), "microsoft")
        except sqlite3.IntegrityError:
            return result_page("This mailbox is already connected to another HowMuch account.")
        except (httpx.HTTPError, KeyError, ValueError):
            return result_page("Outlook could not connect. Check your mailbox access and retry.")
        finally:
            with store.db: store.db.execute("DELETE FROM payment_oauth WHERE token_hash=?", (ticket,))
    response = result_page("DBS alerts will be imported for bank-confirmed review. Return to HowMuch → Payment detection.", True)
    response.delete_cookie("howmuch_microsoft_oauth", path="/v1/payment-detection/microsoft")
    return response


def icloud_messages(connection, password, since, before):
    client = icloud_client(connection["email"], password)
    deadline = time.monotonic() + 60
    try:
        start = datetime.fromtimestamp(since, timezone.utc).strftime("%d-%b-%Y")
        # Read only INBOX, bounded to 100 matching recent alerts, no attachments retained.
        result, data = client.uid("search", None, "FROM", '"' + DBS_SENDER + '"', "SINCE", start)
        if result != "OK": raise ValueError("Search failed")
        ids = (data[0] or b"").split()
        if len(ids) > 100: raise ValueError("Too many alerts")
        messages = []
        for uid in ids:
            if time.monotonic() > deadline: raise ValueError("Scan timed out")
            result, parts = client.uid("fetch", uid, f"(BODY.PEEK[]<0.{MAX_MAIL_BYTES + 1}>)")
            if result != "OK": raise ValueError("Fetch failed")
            raw = next((p[1] for p in parts if isinstance(p, tuple) and isinstance(p[1], bytes)), b"")
            if len(raw) > MAX_MAIL_BYTES: raise ValueError("Alert too large")
            message = BytesParser(policy=policy.default).parsebytes(raw)
            parsed = parse_dbs_alert(str(message.get("Subject", "")), str(message.get("From", "")), mail_text(message))
            # Exact receipt timestamp recheck complements IMAP's whole-day SINCE.
            if parsed and parsed["received_at"] and since <= datetime.fromisoformat(parsed["received_at"]).timestamp() <= before:
                messages.append((hashlib.sha256(raw).hexdigest(), parsed))
        return messages
    finally:
        try: client.logout()
        except Exception: pass


async def microsoft_messages(client, token, since, before):
    headers = {"Authorization": "Bearer " + token, "Prefer": 'outlook.body-content-type="text"'}
    start = datetime.fromtimestamp(since, timezone.utc).isoformat().replace("+00:00", "Z")
    end = datetime.fromtimestamp(before, timezone.utc).isoformat().replace("+00:00", "Z")
    url = GRAPH + "/mailFolders/inbox/messages"
    params = {"$filter": f"receivedDateTime ge {start} and receivedDateTime le {end} and from/emailAddress/address eq '{DBS_SENDER}'", "$select": "id,subject,from,body", "$top": "50"}
    for _ in range(10):
        response = await client.get(url, headers=headers, params=params); response.raise_for_status()
        if len(response.content) > 4 * 1024 * 1024: raise ValueError("Response too large")
        page = response.json()
        for item in page.get("value", []):
            body = item.get("body", {})
            text = body.get("content", "")
            if len(text.encode()) > MAX_MAIL_BYTES: raise ValueError("Alert too large")
            if body.get("contentType", "").casefold() == "html":
                parser = gmail.TextHTML(); parser.feed(text); text = "".join(parser.parts)
            parsed = parse_dbs_alert(item.get("subject", ""), item.get("from", {}).get("emailAddress", {}).get("address", ""), text)
            if parsed: yield str(item["id"]), parsed
        url = page.get("@odata.nextLink")
        if not url: return
        target = urlparse(url)
        if target.scheme != "https" or target.netloc != "graph.microsoft.com" or target.path != "/v1.0/me/mailFolders/inbox/messages":
            raise ValueError("Invalid paging link")
        params = None
    raise ValueError("Too many alerts")


async def scan_other_mailbox(storage, user_id):
    async with gmail._locks.setdefault(user_id, asyncio.Lock()):
        store = PaymentStore(storage); conn = store.connection(user_id)
        if not conn or not conn["refresh_token"]: raise ValueError("Connect email first.")
        provider = conn["provider"]
        if provider not in {"icloud", "microsoft"}: return
        if not provider_ready(provider): raise ValueError("This email provider is not configured yet.")
        payers = store.allowed_payers(user_id)
        if not payers: return
        started = int(time.time()); since = max(conn["connected_at"] - 30 * 86400, conn["last_scan"] - 300)
        try:
            credential = gmail.cipher().decrypt(conn["refresh_token"].encode()).decode()
            if provider == "icloud":
                results = await asyncio.to_thread(icloud_messages, conn, credential, since, started)
                for message_id, parsed in results:
                    if not current(store, user_id, conn, payers): return
                    if store.accepts_payer(user_id, parsed["payer"]): store.ingest(user_id, "icloud:" + message_id, parsed, False)
            else:
                async with httpx.AsyncClient(timeout=20) as client:
                    response = await client.post(MS + "/token", data=ms_token_data(grant_type="refresh_token", refresh_token=credential, scope=MS_SCOPE))
                    response.raise_for_status(); token = response.json()
                    if not current(store, user_id, conn, payers): return
                    if token.get("refresh_token"):
                        encrypted = gmail.cipher().encrypt(token["refresh_token"].encode()).decode()
                        with store.db: store.db.execute("UPDATE payment_connections SET refresh_token=? WHERE user_id=? AND refresh_token=?", (encrypted, user_id, conn["refresh_token"]))
                        conn["refresh_token"] = encrypted
                    async for message_id, parsed in microsoft_messages(client, token["access_token"], since, started):
                        if not current(store, user_id, conn, payers): return
                        if store.accepts_payer(user_id, parsed["payer"]): store.ingest(user_id, "microsoft:" + message_id, parsed, False)
            if current(store, user_id, conn, payers):
                with store.db: store.db.execute("UPDATE payment_connections SET last_scan=?,error='' WHERE user_id=? AND refresh_token=?", (started, user_id, conn["refresh_token"]))
        except (httpx.HTTPError, InvalidToken, KeyError, ValueError, OSError, imaplib.IMAP4.error, LookupError):
            message = "Email could not be checked. Retry, or reconnect if access has expired."
            with store.db: store.db.execute("UPDATE payment_connections SET error=? WHERE user_id=? AND refresh_token=?", (message, user_id, conn["refresh_token"]))
            raise ValueError(message) from None
