"""Standalone service: no Telegram imports, bot token, polling or bot database."""
from __future__ import annotations
import asyncio
import logging
import os
from contextlib import asynccontextmanager,suppress
from fastapi import FastAPI
from fastapi import HTTPException,Request
from fastapi.responses import HTMLResponse,RedirectResponse,Response
from .database import AppStorage
from . import privacy as privacy_policy
from . import site
from . import friends,telegram_link,schedule_link,pet_codes,auth,documents,push,accounts,calendar_feed,gmail_payments,travel,receipts,email_providers,live_activity,pay_in,store

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
app.include_router(store.router,prefix='/v1')
app.include_router(telegram_link.router,prefix='/v1')
app.include_router(schedule_link.router,prefix='/v1')
app.include_router(friends.router,prefix='/v1')
app.include_router(friends.page)
app.include_router(calendar_feed.router)

@app.get('/healthz')
async def health():return {'status':'ok','service':'howmuch-ios','appleBundleID':auth.bundle_id(),'pushReady':push.configured(),'travelReady':travel.configured()}

def _page(request:Request,html:str):
    # The website lives at site.SITE. The old fly.dev address still serves the app's API, so only its pages move.
    if request.url.hostname==site.LEGACY_HOST:
        query=f'?{request.url.query}' if request.url.query else ''
        return RedirectResponse(f'{site.SITE}{request.url.path}{query}',status_code=301)
    return HTMLResponse(html)

@app.get('/',response_class=HTMLResponse)
async def home(request:Request):
    return _page(request,site.HOME)

@app.get('/privacy',response_class=HTMLResponse)
async def privacy(request:Request):
    return _page(request,privacy_policy.PAGE)

@app.get('/support',response_class=HTMLResponse)
async def support(request:Request):
    return _page(request,site.SUPPORT)

@app.get('/robots.txt')
async def robots():
    return Response(site.ROBOTS,media_type='text/plain')

@app.get('/sitemap.xml')
async def sitemap():
    return Response(site.SITEMAP,media_type='application/xml')

_OG_IMAGE=site.OG_IMAGE.read_bytes()

@app.get('/og-image.png')
async def og_image():
    return Response(_OG_IMAGE,media_type='image/png',headers={'Cache-Control':'public, max-age=86400'})

_SCREENS={name:(site.SCREENS_DIR/f'{name}.jpg').read_bytes() for name,_,_ in site.SCREENS}

@app.get('/screens/{name}.jpg')
async def screen(name:str):
    # Only the home page's own screenshots, read once at start-up.
    if name not in _SCREENS:raise HTTPException(404)
    return Response(_SCREENS[name],media_type='image/jpeg',headers={'Cache-Control':'public, max-age=86400'})

_FAVICON_SVG=site.favicon_svg()
_FAVICON_PNG=(site.ICONS_DIR/'favicon-96.png').read_bytes()
_TOUCH_ICON=(site.ICONS_DIR/'apple-touch-icon.png').read_bytes()
_ICON_CACHE={'Cache-Control':'public, max-age=604800'}

@app.get('/favicon.svg')
async def favicon_svg():
    return Response(_FAVICON_SVG,media_type='image/svg+xml',headers=_ICON_CACHE)

@app.get('/favicon.ico')
async def favicon_ico():
    # A PNG under the name browsers ask for by default; every current browser reads it.
    return Response(_FAVICON_PNG,media_type='image/png',headers=_ICON_CACHE)

@app.get('/apple-touch-icon.png')
async def touch_icon():
    return Response(_TOUCH_ICON,media_type='image/png',headers=_ICON_CACHE)

@app.get('/terms')
async def terms():
    # HowMuch uses Apple's standard licence agreement for apps (the EULA linked from the plans screen).
    return RedirectResponse(site.TERMS,status_code=307)
