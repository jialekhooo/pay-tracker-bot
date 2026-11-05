"""Standalone service: no Telegram imports, bot token, polling or bot database."""
from __future__ import annotations
import asyncio
import logging
import os
from contextlib import asynccontextmanager,suppress
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from .database import AppStorage
from . import auth,documents,push,accounts,calendar_feed,gmail_payments,travel,receipts,email_providers,live_activity,pay_in

logging.getLogger('httpx').setLevel(logging.WARNING)
logging.getLogger('httpcore').setLevel(logging.WARNING)

@asynccontextmanager
async def lifespan(app):
    storage=AppStorage(os.environ.get('HOWMUCH_DB','/data/howmuch-ios.sqlite3'))
    app.state.storage=storage
    workers=[asyncio.create_task(travel.worker(storage)),asyncio.create_task(push.worker(storage)),asyncio.create_task(gmail_payments.poll_mailboxes(storage)),asyncio.create_task(accounts.retry_revocations(storage))]
    try:yield
    finally:
        for task in workers:task.cancel()
        for task in workers:
            with suppress(asyncio.CancelledError):await task
        storage.close()

app=FastAPI(title='HowMuch iOS',lifespan=lifespan,docs_url=None,redoc_url=None)
app.include_router(auth.router,prefix='/v1')
app.include_router(documents.router,prefix='/v1')
app.include_router(push.router,prefix='/v1')
app.include_router(live_activity.router,prefix='/v1')
app.include_router(accounts.router,prefix='/v1')
app.include_router(gmail_payments.router,prefix='/v1')
app.include_router(pay_in.router,prefix='/v1')
app.include_router(pay_in.inbound,prefix='/v1')
app.include_router(email_providers.router,prefix='/v1')
app.include_router(travel.router,prefix='/v1')
app.include_router(receipts.router,prefix='/v1')
app.include_router(calendar_feed.router)

@app.get('/healthz')
async def health():return {'status':'ok','service':'howmuch-ios','appleBundleID':auth.bundle_id(),'pushReady':push.configured(),'travelReady':travel.configured()}

@app.get('/privacy',response_class=PlainTextResponse)
async def privacy():
    return '''HowMuch privacy policy — 5 November 2026

HowMuch is independent of Telegram. Sign in with Apple identifies your account. We store your Apple account identifier, any name/email you choose to share, and your shifts, pay settings, claims and preferences to provide account sync. Your device keeps a protected account-specific cache. Telegram CSV imports are optional and become records in your HowMuch account.

If you permit notifications, we store your device push token and reminder preferences to deliver job and payment alerts through Apple. Lock-screen job details are hidden by default. You can disable alerts in Settings.

Time to leave reminders are off by default. If enabled, your saved departure address, job destination, travel mode and arrival time are sent to the HowMuch service and Apple Maps to estimate a route. The service periodically checks upcoming work while you are signed in for push notifications. Public-transport estimates are requested from Apple Maps on your iPhone when the app is open and used for scheduled iPhone reminders; they are not continuously refreshed while closed. It does not track your live location. Estimates and traffic coverage vary, and notification delivery is not guaranteed. Turning this feature off cancels pending travel reminders; removing the saved address removes it from the active account document.

Receipt photos are optional. Selected images are resized on your iPhone and uploaded to encrypted, account-owned attachment storage on the HowMuch service. Receipt text recognition runs on the device and fills a detected total automatically; review it before saving. Saved receipt copies can be reopened and downloaded to Files. Images are not sent to an AI service. JSON/CSV work exports do not contain receipt image files. Removing an attachment from a claim unlinks it; account deletion removes all receipt photos from the active service.

Pay-in tracking is optional. If you set up the bank notification shortcut, the text of the bank notifications it passes to HowMuch (and any amount or payer read from them) is sent to the HowMuch service to match payments from your saved payers; notifications that aren't money received are discarded, and matched payments are kept with your payment history so you can undo them. If you forward bank alert emails to your private HowMuch address, those emails are read the same way and wait for your confirmation.

No advertising or analytics SDK is used, and we do not sell or share your data for tracking.

Settings → Account & sync → Delete account removes the account and its work, payment and notification records from the active service and this device. Infrastructure backups may retain earlier copies until their retention period ends. Exported files and copies on other devices remain under your control. Private calendar subscription URLs grant access to that calendar; rotate the link to revoke a shared URL.

Questions or requests about your data: email jialexkhoo@gmail.com. We will reply within 7 days.'''

@app.get('/support',response_class=PlainTextResponse)
async def support():
    return '''HowMuch support

Email jialexkhoo@gmail.com with your question or problem. Include the app version (shown at the bottom of Settings) and the steps that led to the issue. Please do not send passwords or private receipt contents.

Account: sign in with Apple. To delete your account and its records, open Settings → Account & sync → Delete account.

Privacy policy: https://howmuch-ios.fly.dev/privacy'''
