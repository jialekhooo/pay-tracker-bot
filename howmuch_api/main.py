"""Standalone service: no Telegram imports, bot token, polling or bot database."""
from __future__ import annotations
import asyncio
import logging
import os
import time
from collections import deque
from contextlib import asynccontextmanager,suppress
from fastapi import FastAPI
from fastapi import HTTPException,Request
from fastapi.responses import HTMLResponse,JSONResponse,PlainTextResponse,RedirectResponse,Response
from starlette.exceptions import HTTPException as StarletteHTTPException
from .database import AppStorage,client_ip
from . import privacy as privacy_policy
from . import site
from . import diagnostics,friends,telegram_link,schedule_link,pet_codes,auth,documents,push,accounts,calendar_feed,gmail_payments,travel,receipts,email_providers,live_activity,pay_in,store

logging.getLogger('httpx').setLevel(logging.WARNING)
logging.getLogger('httpcore').setLevel(logging.WARNING)
# One line per request on Fly's log stream: method, route, status and time. Routes are templates such as
# /calendar/{token}.ics, so tokens and IDs in URLs never reach the logs, and no IP addresses are written.
logging.basicConfig(level=logging.INFO,format='%(levelname)s %(name)s %(message)s')
log=logging.getLogger('howmuch')
SLOW_SECONDS=1.0

@asynccontextmanager
async def lifespan(app):
    storage=AppStorage(os.environ.get('HOWMUCH_DB','/data/howmuch-ios.sqlite3'))
    diagnostics.ensure_schema(storage._conn)
    app.state.storage=storage
    workers=[asyncio.create_task(travel.worker(storage)),asyncio.create_task(push.worker(storage)),asyncio.create_task(gmail_payments.poll_mailboxes(storage)),asyncio.create_task(accounts.retry_revocations(storage))]
    try:yield
    finally:
        for task in workers:task.cancel()
        for task in workers:
            with suppress(asyncio.CancelledError):await task
        storage.close()
        del app.state.storage  # nothing may use a closed database

# No public API schema or docs: the only client is the HowMuch app.
app=FastAPI(title='HowMuch iOS',lifespan=lifespan,docs_url=None,redoc_url=None,openapi_url=None)
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
app.include_router(diagnostics.router,prefix='/v1')
app.include_router(friends.page)
app.include_router(calendar_feed.router)

# Every caller gets a generous allowance across the whole site (the app's sync makes a few calls at a time);
# the per-route limits on sign-in, codes and uploads are much tighter. Kept in memory: there is one machine.
GLOBAL_LIMIT,GLOBAL_WINDOW=600,600
_recent:dict[str,deque]={}

def _over_limit(ip:str,now:float)->bool:
    hits=_recent.setdefault(ip,deque())
    while hits and hits[0]<=now-GLOBAL_WINDOW:hits.popleft()
    hits.append(now)
    if len(_recent)>50_000:  # forget callers who have gone quiet
        for key in [k for k,v in _recent.items() if not v or v[-1]<=now-GLOBAL_WINDOW]:_recent.pop(key,None)
    return len(hits)>GLOBAL_LIMIT

def _route(request:Request,fallback:str='unmatched')->str:
    """The route template that served the request, e.g. /v1/receipts/{receipt_id}: never the raw URL."""
    template=getattr(request.scope.get('route'),'path',None)
    if template is None:return fallback
    # Routes from the /v1 routers report their path without the prefix.
    if request.url.path.startswith('/v1/') and not template.startswith('/v1/'):template='/v1'+template
    return template

def _is_api(path:str)->bool:
    return path.startswith('/v1/') or path=='/healthz' or path.endswith('.ics')

@app.middleware('http')
async def observe(request:Request,call_next):
    start=time.perf_counter()
    path=request.url.path
    if path!='/healthz' and _over_limit(client_ip(request),time.time()):
        response=JSONResponse({'detail':'Too many requests. Please try again later.'},status_code=429,headers={'Retry-After':'60'})
    else:
        try:
            response=await call_next(request)
        except Exception as error:  # an unhandled fault: record it, and answer with the right error page
            route=_route(request,path if not _is_api(path) else 'unmatched')
            log.exception('error %s %s',request.method,route)
            storage=getattr(request.app.state,'storage',None)
            if storage is not None:
                with suppress(Exception):diagnostics.record_server_error(storage._conn,f'{request.method} {route}',error)
            response=(JSONResponse({'detail':'Something went wrong on our side. Please try again.'},status_code=500) if _is_api(path)
                      else HTMLResponse(site.SERVER_ERROR,status_code=500))
    seconds=time.perf_counter()-start
    route=_route(request)
    if path!='/healthz' or response.status_code!=200:
        level=logging.WARNING if response.status_code>=500 or seconds>=SLOW_SECONDS else logging.INFO
        log.log(level,'%s %s %s %.0fms%s',request.method,route,response.status_code,seconds*1000,' slow' if seconds>=SLOW_SECONDS else '')
    return response

@app.exception_handler(StarletteHTTPException)
async def http_error(request:Request,error:StarletteHTTPException):
    # The website gets real pages; the app's API keeps its JSON errors.
    if error.status_code==404 and not _is_api(request.url.path):
        return HTMLResponse(site.NOT_FOUND,status_code=404)
    return JSONResponse({'detail':error.detail},status_code=error.status_code,headers=getattr(error,'headers',None))

@app.get('/healthz')
async def health():
    # Uptime checks read this: it fails if the database can't be read.
    storage=getattr(app.state,'storage',None)
    try:
        if storage is not None:storage._conn.execute('SELECT 1').fetchone()
    except Exception:
        return JSONResponse({'status':'error','service':'howmuch-ios','database':'unavailable'},status_code=503)
    return {'status':'ok','service':'howmuch-ios','appleBundleID':auth.bundle_id(),'pushReady':push.configured(),'travelReady':travel.configured()}

@app.get('/llms.txt')
async def llms_txt():return PlainTextResponse(site.LLMS_TXT,headers={'Cache-Control':'public, max-age=3600'})

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
