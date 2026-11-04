"""Opt-in departure estimates; saved addresses only, never background GPS tracking."""
from __future__ import annotations
import asyncio
import hashlib
import json
import logging
import math
import os
import time
import uuid
from datetime import datetime,timedelta,timezone
from zoneinfo import ZoneInfo
import httpx
import jwt
from fastapi import APIRouter,Header,HTTPException,Request
from pydantic import BaseModel
from .auth import authenticated_account
from .database import json_response,limit
from .documents import TravelPreferences,read_document

router=APIRouter(prefix='/travel')
logger=logging.getLogger(__name__)
MAPS='https://maps-api.apple.com'
_token=None
_token_until=0
_token_lock=asyncio.Lock()

def configured():
    return all(os.environ.get(k) for k in ('HOWMUCH_MAPS_KEY_ID','HOWMUCH_MAPS_PRIVATE_KEY','HOWMUCH_APPLE_TEAM_ID'))

def maps_token(now=None):
    now=int(time.time()) if now is None else now
    return jwt.encode({'iss':os.environ['HOWMUCH_APPLE_TEAM_ID'],'iat':now,'exp':now+1800,'scope':'server_api'},
        os.environ['HOWMUCH_MAPS_PRIVATE_KEY'].replace('\\n','\n'),algorithm='ES256',
        headers={'kid':os.environ['HOWMUCH_MAPS_KEY_ID'],'typ':'JWT'})

class RouteUnavailable(Exception):pass

async def access_token(client,refresh=False):
    global _token,_token_until
    async with _token_lock:
        if not refresh and _token and time.time()<_token_until:return _token
        r=await client.get(MAPS+'/v1/token',headers={'Authorization':'Bearer '+maps_token()})
        r.raise_for_status();data=r.json()
        _token=data['accessToken'];_token_until=time.time()+max(0,min(int(data['expiresInSeconds']),1800)-60)
        return _token

async def route(options,shift,start,client):
    """Use an arrival-time route so traffic predictions match the planned journey."""
    arrival=start-options.arrivalBuffer*60
    params={'origin':options.origin,'destination':shift['location'],'transportType':options.mode.capitalize()}
    when=arrival if arrival>time.time() else int(time.time())
    params['arrivalDate' if arrival>time.time() else 'departureDate']=datetime.fromtimestamp(when,timezone.utc).isoformat().replace('+00:00','Z')
    try:
        for attempt in range(2):
            token=await access_token(client,refresh=bool(attempt))
            response=await client.get(MAPS+'/v1/directions',params=params,headers={'Authorization':'Bearer '+token})
            if response.status_code==401 and attempt==0:continue
            response.raise_for_status();data=response.json();break
        routes=data.get('routes') or []
        if not routes:raise RouteUnavailable('No route found. Check both addresses or choose another travel mode.')
        duration=float(routes[0]['durationSeconds'])
        if not math.isfinite(duration) or duration<=0 or duration>86400:raise ValueError('Invalid duration')
        def name(key):
            value=data.get(key) or {}
            return (value.get('name') or ', '.join(value.get('formattedAddressLines') or []))[:500]
        return {'durationSeconds':math.ceil(duration),'distanceMeters':max(0,int(routes[0].get('distanceMeters',0))),
                'leaveAt':int(arrival-math.ceil(duration)),'arriveAt':arrival,'shiftStart':start,
                'originName':name('origin'),'destinationName':name('destination'),'checkedAt':int(time.time())}
    except RouteUnavailable:raise
    except (httpx.HTTPError,ValueError,KeyError,TypeError,jwt.PyJWTError):
        raise RouteUnavailable('Route estimates are temporarily unavailable. Check Apple Maps before travelling.') from None

def candidates(data,zone,now):
    options=TravelPreferences.model_validate((data.get('preferences') or {}).get('travel') or {})
    if not options.enabled or options.transit:return options,[]
    result=[]
    for shift in data['shifts']:
        start=int((datetime.fromisoformat(shift['day']).replace(tzinfo=ZoneInfo(zone))+timedelta(minutes=shift['startMinute'])).timestamp())
        if now<start<=now+24*3600 and shift.get('location','').strip():
            fingerprint=hashlib.sha256(json.dumps([options.model_dump(exclude_none=True),shift['event'],shift['location'],start,((data.get('preferences') or {}).get('notifications') or {}).get('showDetails',False)],sort_keys=True).encode()).hexdigest()
            result.append((start,shift,fingerprint))
    return options,sorted(result,key=lambda x:(x[0],x[1]['id']))

def reconcile(storage,account,data,zone,now=None):
    """Cancel stale alerts synchronously on every document update, before any network wait."""
    now=int(time.time()) if now is None else now
    _,items=candidates(data,zone,now);wanted={s['id']:fp for _,s,fp in items}
    db=storage._conn;owner=account['account_id']
    with db:
        for row in db.execute('SELECT * FROM travel_estimates WHERE account_id=?',(owner,)).fetchall():
            if row['checked'] and row['checked']<now-900:
                db.execute("UPDATE notification_jobs SET status='cancelled' WHERE account_id=? AND shift_id=? AND kind LIKE 'travel_%' AND status='pending'",(owner,row['shift_id']))
            if wanted.get(row['shift_id'])!=row['fingerprint']:
                db.execute("UPDATE notification_jobs SET status='cancelled' WHERE account_id=? AND shift_id=? AND kind LIKE 'travel_%' AND status='pending'",(owner,row['shift_id']))
                db.execute('DELETE FROM travel_estimates WHERE account_id=? AND shift_id=?',(owner,row['shift_id']))


def schedule(storage,account,shift,fp,estimate,options,show_details,now):
    db=storage._conn;owner=account['account_id'];leave=estimate['leaveAt'];start=estimate['shiftStart']
    clock=datetime.fromtimestamp(leave,ZoneInfo(account['zone'])).strftime('%H:%M')
    minutes=math.ceil(estimate['durationSeconds']/60)
    body=f"About {minutes} min travelling · arrive {options.arrivalBuffer} min before your shift."
    if show_details:body=shift['event']+' · '+body
    else:body+=' Open HowMuch for directions.'
    # Stable identities retain per-device delivery receipts across traffic refreshes.
    for kind,fire,title in [('travel_prepare',leave-options.prepareMinutes*60,'Get ready to leave'),('travel_leave',leave,'Time to leave')]:
        if kind=='travel_prepare' and (options.prepareMinutes==0 or fire<=now):continue
        if kind=='travel_leave' and fire<now:
            fire=now;title='Leave now';body='Your planned departure time has passed. Check your route and arrival time in Apple Maps.'
        key=hashlib.sha256(f"{owner}|{shift['id']}|{fp}|{kind}".encode()).hexdigest()
        expires=min(start,fire+300)
        if expires<=now:continue
        db.execute('INSERT INTO notification_jobs(job_id,account_id,kind,shift_id,fire_at,expires,title,body) VALUES(?,?,?,?,?,?,?,?) '
                   "ON CONFLICT(job_id) DO UPDATE SET fire_at=excluded.fire_at,expires=excluded.expires,title=excluded.title,body=excluded.body,"
                   "status=CASE WHEN notification_jobs.status='cancelled' THEN 'pending' ELSE notification_jobs.status END",
                   (key,owner,kind,shift['id'],max(now,fire),expires,title+f' · {clock}',body))

async def refresh_one(storage,account,options,start,shift,fp,client,now):
    db=storage._conn;owner=account['account_id']
    with db:
        db.execute('INSERT OR IGNORE INTO travel_estimates(account_id,shift_id,fingerprint) VALUES(?,?,?)',(owner,shift['id'],fp))
        # Reserve the next check first so errors and concurrent preview requests are bounded.
        db.execute('UPDATE travel_estimates SET retry_at=? WHERE account_id=? AND shift_id=?',(now+300,owner,shift['id']))
    with db:
        day=now//86400
        db.execute('DELETE FROM travel_usage WHERE day<?',(day,))
        usage=db.execute('INSERT INTO travel_usage VALUES(?,1) ON CONFLICT(day) DO UPDATE SET requests=requests+1 RETURNING requests',(day,)).fetchone()
    if usage['requests']>5000:
        with db:db.execute('UPDATE travel_estimates SET error=?,retry_at=? WHERE account_id=? AND shift_id=?',('Daily route check limit reached. Check Apple Maps directly.',(day+1)*86400,owner,shift['id']))
        return None
    try:estimate=await route(options,shift,start,client)
    except RouteUnavailable as exc:
        with db:
            db.execute('UPDATE travel_estimates SET error=? WHERE account_id=? AND shift_id=? AND fingerprint=?',(str(exc),owner,shift['id'],fp))
            db.execute("UPDATE notification_jobs SET status='cancelled' WHERE account_id=? AND shift_id=? AND kind LIKE 'travel_%' AND status='pending'",(owner,shift['id']))
        return None
    # Preferences, shifts, sessions or the account may have changed during I/O.
    current=db.execute('SELECT * FROM accounts WHERE account_id=?',(owner,)).fetchone()
    if not current:return None
    envelope=read_document(storage,current);reconcile(storage,current,envelope['data'],envelope['timezone'],now)
    row=db.execute('SELECT * FROM travel_estimates WHERE account_id=? AND shift_id=? AND fingerprint=?',(owner,shift['id'],fp)).fetchone()
    if not row:return None
    with db:
        db.execute("UPDATE travel_estimates SET checked=?,estimate=?,error='' WHERE account_id=? AND shift_id=?",(now,json.dumps(estimate),owner,shift['id']))
        if db.execute('SELECT 1 FROM push_devices WHERE account_id=?',(owner,)).fetchone():
            previous=json.loads(row['estimate']) if row['estimate'] else None
            prepared=db.execute("SELECT 1 FROM notification_jobs WHERE account_id=? AND shift_id=? AND kind='travel_prepare' AND status='sent'",(owner,shift['id'])).fetchone()
            if options.trafficUpdates and previous and prepared and estimate['leaveAt']<=previous['leaveAt']-300 and estimate['leaveAt']>now:
                key=hashlib.sha256(f"{owner}|{shift['id']}|{fp}|travel_update".encode()).hexdigest()
                db.execute('INSERT OR IGNORE INTO notification_jobs(job_id,account_id,kind,shift_id,fire_at,expires,title,body) VALUES(?,?,?,?,?,?,?,?)',
                    (key,owner,'travel_update',shift['id'],now,min(start,now+300),'Your journey may take longer','Open HowMuch to check your updated departure time and directions.'))
            schedule(storage,{**dict(current),'zone':envelope['timezone']},shift,fp,estimate,options,
                     ((envelope['data'].get('preferences') or {}).get('notifications') or {}).get('showDetails',False),now)
    return estimate

@router.get('/status')
async def status(request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization);storage=request.app.state.storage
    envelope=read_document(storage,account);reconcile(storage,account,envelope['data'],envelope['timezone'])
    estimates=[]
    for row in storage._conn.execute('SELECT * FROM travel_estimates WHERE account_id=?',(account['account_id'],)):
        estimates.append({'shiftID':row['shift_id'],'estimate':json.loads(row['estimate']) if row['estimate'] else None,'error':row['error']})
    return json_response({'ready':configured(),'estimates':estimates})

class CheckRoute(BaseModel):
    shiftID:uuid.UUID

@router.post('/check')
async def check(payload:CheckRoute,request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization);limit(request,'travel:'+account['account_id'],maximum=20)
    if not configured():raise HTTPException(503,'Travel reminders are waiting for Apple Maps configuration.')
    storage=request.app.state.storage;now=int(time.time());envelope=read_document(storage,account)
    reconcile(storage,account,envelope['data'],envelope['timezone'],now)
    options,items=candidates(envelope['data'],envelope['timezone'],now)
    item=next((i for i in items if i[1]['id']==str(payload.shiftID)),None)
    if not item:raise HTTPException(400,'Enable travel reminders and choose a job with a location starting within 24 hours.')
    row=storage._conn.execute('SELECT * FROM travel_estimates WHERE account_id=? AND shift_id=?',(account['account_id'],str(payload.shiftID))).fetchone()
    if row and row['retry_at']>now:
        if row['estimate'] and not row['error']:return json_response(json.loads(row['estimate']))
        raise HTTPException(429,'Please wait a few minutes before checking this route again.')
    async with httpx.AsyncClient(timeout=15) as client:
        result=await refresh_one(storage,account,options,*item,client,now)
    if result is None:raise HTTPException(503,'Could not estimate this route. Check the addresses and try again shortly.')
    return json_response(result)

async def refresh_due(storage,client,now=None):
    now=int(time.time()) if now is None else now
    db=storage._conn;count=0
    for account in db.execute('SELECT DISTINCT a.* FROM accounts a JOIN push_devices d ON d.account_id=a.account_id JOIN auth_sessions s ON s.session_id=d.session_id WHERE s.refresh_expires>?',(now,)).fetchall():
        envelope=read_document(storage,account);reconcile(storage,account,envelope['data'],envelope['timezone'],now)
        options,items=candidates(envelope['data'],envelope['timezone'],now)
        for item in items[:2]:
            if item[0]>now+6*3600:continue
            row=db.execute('SELECT * FROM travel_estimates WHERE account_id=? AND shift_id=?',(account['account_id'],item[1]['id'])).fetchone()
            if row and row['retry_at']>now:continue
            # An account without traffic updates receives one forecast, then a check near departure.
            if row and row['estimate'] and not options.trafficUpdates:
                estimate=json.loads(row['estimate'])
                if now<estimate['leaveAt']-options.prepareMinutes*60-300:continue
            await refresh_one(storage,account,options,*item,client,now);count+=1
            if count>=10:return count
    return count

async def worker(storage):
    async with httpx.AsyncClient(timeout=15) as client:
        while True:
            try:
                if configured():await refresh_due(storage,client)
            except Exception:
                logger.warning('Travel checks temporarily unavailable') # Never log addresses, tokens or response bodies.
            await asyncio.sleep(60)
