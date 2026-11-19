"""Persistent account-scoped job reminders delivered through APNs HTTP/2."""
from __future__ import annotations
import asyncio
import hashlib
import json
import logging
import os
import re
import time
from datetime import datetime,timedelta
from zoneinfo import ZoneInfo
import httpx
import jwt
from fastapi import APIRouter, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field
from .auth import authenticated_account,bundle_id
from .documents import NotificationPreferences

router=APIRouter(prefix='/devices')
logger=logging.getLogger(__name__)


def key_prefix(environment):
    if environment=='sandbox' and os.environ.get('HOWMUCH_APNS_SANDBOX_KEY_ID'):
        return 'HOWMUCH_APNS_SANDBOX'
    if os.environ.get('HOWMUCH_APNS_ENVIRONMENT','both') not in ('both',environment):
        return None
    return 'HOWMUCH_APNS'


def configured(environment='production'):
    prefix=key_prefix(environment)
    if not prefix:return False
    keys=('HOWMUCH_APNS_TEAM_ID',prefix+'_KEY_ID',prefix+'_PRIVATE_KEY')
    if not all(os.environ.get(key) for key in keys): return False
    try: provider_token(environment)
    except (ValueError,TypeError,jwt.PyJWTError): return False
    return True


_provider_tokens={}

def provider_token(environment='production'):
    """Apple asks providers to reuse a signed token for 20-60 minutes, not sign one per push."""
    prefix=key_prefix(environment)
    if not prefix:raise ValueError('APNs environment is not configured')
    cached=_provider_tokens.get(environment)
    if cached and time.time()-cached[1]<40*60: return cached[0]
    issued=int(time.time())
    token=jwt.encode({'iss':os.environ['HOWMUCH_APNS_TEAM_ID'],'iat':issued},
                     os.environ[prefix+'_PRIVATE_KEY'].replace('\\n','\n'),algorithm='ES256',
                     headers={'kid':os.environ[prefix+'_KEY_ID']})
    _provider_tokens[environment]=(token,issued)
    return token


class DeviceRegistration(BaseModel):
    token: str=Field(min_length=32,max_length=512,pattern=r'^[0-9a-fA-F]+$')
    environment: str=Field(pattern=r'^(sandbox|production)$')


@router.put('/push')
async def register_device(payload: DeviceRegistration,request: Request,authorization: str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    db=request.app.state.storage._conn
    with db:
        # APNs may return the same installation token after switching accounts. Transfer it
        # to the newly authenticated session; never send the old account's jobs to it.
        db.execute('DELETE FROM push_devices WHERE (token=? AND environment=?) OR session_id=?',
                   (payload.token.lower(),payload.environment,account['session_id']))
        if not configured(payload.environment):return {'registered':False,'pushReady':False}
        db.execute('INSERT INTO push_devices VALUES(?,?,?,?,?,?)',
                   (account['session_id'],account['account_id'],account['session_id'],payload.token.lower(),payload.environment,int(time.time())))
    return {'registered':True,'pushReady':configured(payload.environment)}


@router.delete('/push',status_code=204)
async def unregister_device(request: Request,authorization: str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    with request.app.state.storage._conn as db:
        db.execute('DELETE FROM push_devices WHERE session_id=?',(account['session_id'],))
    return Response(status_code=204)


def rebuild_jobs(storage,account,data,timezone_name,now=None):
    now=int(time.time()) if now is None else now
    from .travel import reconcile
    reconcile(storage,account,data,timezone_name,now)
    zone=ZoneInfo(timezone_name)
    prefs=(data.get('preferences') or {}).get('notifications') or {}
    options=NotificationPreferences.model_validate(prefs)
    desired=[]
    def job(kind,identity,shift,fire,expires,title,details):
        when=int(fire.timestamp())
        if when<=now or int(expires.timestamp())<=now: return
        key=hashlib.sha256(f"{account['account_id']}|{kind}|{identity}|{when}".encode()).hexdigest()
        body=details
        desired.append((key,account['account_id'],kind,shift,when,int(expires.timestamp()),title,body))
    upcoming={};due={}
    if options.enabled:
        for shift in data['shifts']:
            day=datetime.fromisoformat(shift['day']).replace(tzinfo=zone)
            start=day+timedelta(minutes=shift['startMinute'])
            end=day+timedelta(minutes=shift['endMinute'],days=1 if shift['endMinute']<=shift['startMinute'] else 0)
            if options.starts and start.timestamp()>now:
                minutes=options.startLeadMinutes if options.startLeadMinutes is not None else [options.leadMinutes]
                for lead in sorted(set(minutes),reverse=True):
                    fire=start-timedelta(minutes=lead)
                    if options.startLeadMinutes is None and fire.timestamp()<=now: fire=start
                    expires=min(fire+timedelta(minutes=15),start+timedelta(minutes=10))
                    job('start',shift['id'],shift['id'],fire,expires,f'Shift starts at {start:%H:%M}',
                        (f"{shift['event']} · {start:%H:%M}–{end:%H:%M}" + (' (+1 day)' if end.date()>start.date() else '') + (f" · {shift['location']}" if shift.get('location') else '')) if options.showDetails else 'Open HowMuch for your location and job details.' )
            if options.ends and end.timestamp()>now:
                job('end',shift['id'],shift['id'],end,end+timedelta(hours=2),f'Shift ended at {end:%H:%M}',f"{shift['event']} · Review your hours and add any claims." if options.showDetails else 'Review your hours and add any claims in HowMuch.' )
            if start.timestamp()>now: upcoming.setdefault(shift['day'],[]).append(shift)
            if options.paymentDue and not shift['paid'] and shift.get('paymentDue'):
                due.setdefault((shift['event'].casefold(),shift['currency'],shift['paymentDue']),[]).append(shift)
        if options.upcoming:
            for day,shifts in upcoming.items():
                shifts=sorted(shifts,key=lambda s:(s['startMinute'],s['id']))
                first=shifts[0]; clock=f"{first['startMinute']//60:02d}:{first['startMinute']%60:02d}"
                fire=datetime.fromisoformat(day).replace(tzinfo=zone)-timedelta(days=1)+timedelta(minutes=options.dayBeforeMinute)
                details=(f"First: {first['event']} at {clock}" + (f" · {first['location']}" if first.get('location') else '')) if options.showDetails else f"First shift at {clock}. Open HowMuch to plan your day."
                job('upcoming',day,first['id'],fire,fire+timedelta(hours=4),f"Tomorrow: {len(shifts)} {'shift' if len(shifts)==1 else 'shifts'}",details)
        for (event,currency,day),shifts in due.items():
            fire=datetime.fromisoformat(day).replace(tzinfo=zone)+timedelta(minutes=options.dueMinute)
            job('payment_due',event+'|'+currency+'|'+day,shifts[0]['id'],fire,fire+timedelta(hours=12), 'Payment due today',f"{shifts[0]['event']} · {len(shifts)} unpaid {'shift' if len(shifts)==1 else 'shifts'}. Check payment, then mark paid." if options.showDetails else 'Check your unpaid work in HowMuch and mark payments received.' )
    from .live_activity import rebuild_plans
    rebuild_plans(storage,account,data,timezone_name,now)
    db=storage._conn
    wanted={row[0] for row in desired}
    with db:
        # Only cancel reminders that haven't come due yet; one that is due but not yet delivered still goes out
        # (its expiry ends it). A payment reminder is the exception: once the shift is paid it must not arrive.
        for row in db.execute("SELECT job_id,kind,fire_at,expires FROM notification_jobs WHERE account_id=? AND status='pending' AND kind NOT LIKE 'travel_%' AND kind NOT LIKE 'friend_%' AND kind!='hello'",(account['account_id'],)).fetchall():
            if row['job_id'] in wanted: continue
            if row['expires']<=now: db.execute("UPDATE notification_jobs SET status='expired' WHERE job_id=?",(row['job_id'],))
            elif row['fire_at']>now or row['kind']=='payment_due':
                db.execute("UPDATE notification_jobs SET status='cancelled' WHERE job_id=?",(row['job_id'],))
        for row in desired:
            db.execute("INSERT INTO notification_jobs(job_id,account_id,kind,shift_id,fire_at,expires,title,body) VALUES(?,?,?,?,?,?,?,?) "
                       "ON CONFLICT(job_id) DO UPDATE SET title=excluded.title,body=excluded.body,expires=excluded.expires,"
                       "status=CASE WHEN notification_jobs.status='cancelled' THEN 'pending' ELSE notification_jobs.status END",row)


async def deliver_due(storage,client=None,now=None):
    if not configured(): return 0
    now=int(time.time()) if now is None else now
    db=storage._conn
    # Bring any server-side payment decisions into the document and cancel paid reminders first.
    from .documents import read_document
    for account in db.execute("SELECT DISTINCT a.* FROM accounts a JOIN notification_jobs j ON j.account_id=a.account_id WHERE j.status='pending' AND j.fire_at<=?",(now,)).fetchall():
        read_document(storage,account)
    with db:
        db.execute("UPDATE notification_jobs SET status='expired' WHERE status='pending' AND expires<=?",(now,))
    jobs=db.execute("SELECT * FROM notification_jobs WHERE status='pending' AND fire_at<=? AND expires>? AND next_attempt<=? ORDER BY fire_at LIMIT 100",(now,now,now)).fetchall()
    count=0
    owned=client is None
    client=client or httpx.AsyncClient(http2=True,timeout=15)
    try:
        for job in jobs:
            devices=db.execute('SELECT d.* FROM push_devices d JOIN auth_sessions s ON s.session_id=d.session_id '
                               'WHERE d.account_id=? AND s.refresh_expires>?',(job['account_id'],now)).fetchall()
            if not devices:
                with db: db.execute('UPDATE notification_jobs SET next_attempt=? WHERE job_id=?',(now+60,job['job_id']))
                continue
            all_done=True
            for device in devices:
                # Recheck ownership after awaits; sign-out/account deletion may run while a previous send was in flight.
                current=db.execute('SELECT * FROM push_devices WHERE device_id=? AND account_id=? AND session_id=?',
                                   (device['device_id'],job['account_id'],device['session_id'])).fetchone()
                current_job=db.execute("SELECT status FROM notification_jobs WHERE job_id=?",(job['job_id'],)).fetchone()
                if not current or not current_job or current_job['status']!='pending': continue
                prior=db.execute('SELECT * FROM notification_deliveries WHERE job_id=? AND device_id=?',(job['job_id'],device['device_id'])).fetchone()
                if prior and prior['status'] in ('sent','invalid'): continue
                attempts=(prior['attempts'] if prior else 0)+1
                status,error='retry','Temporary delivery error'
                host='https://api.sandbox.push.apple.com' if device['environment']=='sandbox' else 'https://api.push.apple.com'
                payload={'aps':{'alert':{'title':job['title'],'body':job['body']},'sound':'default','thread-id':f"howmuch.{job['account_id']}.{job['shift_id']}",'category':'HOWMUCH_'+job['kind'].upper(),'interruption-level':'active'},
                         'account_id':job['account_id'],'shift_id':job['shift_id'],'kind':job['kind'],'notification_id':job['job_id']}
                try:
                    response=await client.post(host+'/3/device/'+device['token'],json=payload,headers={
                        'authorization':'bearer '+provider_token(device['environment']),'apns-topic':bundle_id(),'apns-push-type':'alert',
                        'apns-priority':'10','apns-expiration':str(job['expires']),'apns-collapse-id':job['job_id'],
                        'apns-id':str(__import__('uuid').UUID(job['job_id'][:32]))})
                    if response.status_code==200: status,error='sent',''; count+=1
                    else:
                        reason=response.json().get('reason','APNs rejected the notification')
                        error=str(reason)[:100]
                        if response.status_code==410 or reason in ('Unregistered','BadDeviceToken'):
                            status='invalid'
                            with db: db.execute('DELETE FROM push_devices WHERE device_id=? AND token=?',(device['device_id'],device['token']))
                except (httpx.HTTPError,ValueError): pass
                # Account/job may have been deleted during network I/O. Never resurrect its deliveries.
                if db.execute('SELECT 1 FROM notification_jobs WHERE job_id=?',(job['job_id'],)).fetchone():
                    with db:
                        db.execute('INSERT INTO notification_deliveries VALUES(?,?,?,?,?) ON CONFLICT(job_id,device_id) '
                                   'DO UPDATE SET status=excluded.status,attempts=excluded.attempts,last_error=excluded.last_error',
                                   (job['job_id'],device['device_id'],status,attempts,error))
                if status=='retry': all_done=False
            with db:
                if all_done: db.execute("UPDATE notification_jobs SET status='sent' WHERE job_id=? AND status='pending'",(job['job_id'],))
                else: db.execute('UPDATE notification_jobs SET next_attempt=? WHERE job_id=?',(now+min(600,30*2**min(attempts,4)),job['job_id']))
    finally:
        if owned: await client.aclose()
    return count


async def worker(storage):
    # One long-lived HTTP/2 connection to APNs instead of a new one every 15 seconds.
    client=httpx.AsyncClient(http2=True,timeout=15)
    while True:
        try: await deliver_due(storage,client=client)
        except asyncio.CancelledError: raise
        except Exception:
            logger.error('Notification delivery check could not complete; it will retry.')
        try:
            from .live_activity import deliver
            await deliver(storage,client=client)
        except asyncio.CancelledError: raise
        except Exception:
            # Never log APNs tokens, authorization headers, keys or job content.
            logger.error('Live shift card check could not complete; it will retry.')
        await asyncio.sleep(15)
