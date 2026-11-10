"""Standalone service: no Telegram imports, bot token, polling or bot database."""
from __future__ import annotations
import asyncio
import logging
import os
from contextlib import asynccontextmanager,suppress
from fastapi import FastAPI
from fastapi.responses import HTMLResponse,PlainTextResponse
from .database import AppStorage
from . import privacy as privacy_policy
from . import friends,telegram_link,schedule_link,pet_codes,auth,documents,push,accounts,calendar_feed,gmail_payments,travel,receipts,email_providers,live_activity,pay_in

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
app.include_router(pet_codes.router,prefix='/v1')
app.include_router(telegram_link.router,prefix='/v1')
app.include_router(schedule_link.router,prefix='/v1')
app.include_router(friends.router,prefix='/v1')
app.include_router(friends.page)
app.include_router(calendar_feed.router)

@app.get('/healthz')
async def health():return {'status':'ok','service':'howmuch-ios','appleBundleID':auth.bundle_id(),'pushReady':push.configured(),'travelReady':travel.configured()}

@app.get('/privacy',response_class=HTMLResponse)
async def privacy():
    return privacy_policy.PAGE

@app.get('/support',response_class=PlainTextResponse)
async def support():
    return '''HowMuch support

Email jialexkhoo@gmail.com with your question or problem. Include the app version (shown at the bottom of Settings) and the steps that led to the issue. Please do not send passwords or private receipt contents.

Account: sign in with Apple. To delete your account and its records, open Settings → Account & sync → Delete account.

Privacy policy: https://howmuch-ios.fly.dev/privacy'''
