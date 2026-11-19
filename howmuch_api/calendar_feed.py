"""Account-owned calendar subscriptions, with revocable opaque links."""
from __future__ import annotations
import secrets
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from fastapi import APIRouter, Header, HTTPException, Request, Response
from .auth import authenticated_account
from .database import digest
from .documents import read_document
router=APIRouter()


def describe(shift):
    """Pay and whether it's in, e.g. "SGD 176.00 · Awaiting payment"."""
    try: pay=f"{shift.get('currency','SGD')} {float(shift.get('pay',0)):,.2f}"
    except (TypeError,ValueError): pay=''
    status='Paid' if shift.get('paid') else 'Awaiting payment'
    return ' · '.join(part for part in (pay,status,'From HowMuch') if part)


def calendar_text(data,timezone_name):
    zone=ZoneInfo(timezone_name)
    def escape(text):return str(text).replace('\\','\\\\').replace('\r\n','\n').replace('\r','\n').replace('\n','\\n').replace(';','\\;').replace(',','\\,')
    # A named calendar that subscribers re-check hourly (Apple, Google, Outlook; TimeTree via the iPhone calendar).
    lines=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//HowMuch//iOS Accounts//EN','CALSCALE:GREGORIAN','METHOD:PUBLISH',
           'X-WR-CALNAME:HowMuch shifts','X-WR-CALDESC:Your shifts from HowMuch','X-WR-TIMEZONE:'+timezone_name,
           'REFRESH-INTERVAL;VALUE=DURATION:PT1H','X-PUBLISHED-TTL:PT1H']
    now=datetime.now(ZoneInfo('UTC')).strftime('%Y%m%dT%H%M%SZ')
    for shift in data['shifts']:
        day=datetime.fromisoformat(shift['day']).replace(tzinfo=zone)
        start=day+timedelta(minutes=shift['startMinute'])
        end=day+timedelta(minutes=shift['endMinute'],days=1 if shift['endMinute']<=shift['startMinute'] else 0)
        lines+=['BEGIN:VEVENT','UID:'+shift['id']+'@howmuch-ios','DTSTAMP:'+now,
                'DTSTART:'+start.astimezone(ZoneInfo('UTC')).strftime('%Y%m%dT%H%M%SZ'),
                'DTEND:'+end.astimezone(ZoneInfo('UTC')).strftime('%Y%m%dT%H%M%SZ'),
                'SUMMARY:'+escape(shift['event']),'LOCATION:'+escape(shift['location']),
                'DESCRIPTION:'+escape(describe(shift)),'END:VEVENT']
    lines.append('END:VCALENDAR')
    folded=[]
    for line in lines:
        part=''
        for char in line:
            if len((part+char).encode())>75: folded.append(part);part=' '
            part+=char
        folded.append(part)
    return '\r\n'.join(folded)+'\r\n'


def feed_url(token):
    import os
    base=os.environ.get('HOWMUCH_PUBLIC_URL','https://howmuch-ios.fly.dev').rstrip('/')
    return base+'/calendar/'+token+'.ics'


@router.get('/v1/calendar/link')
async def current_link(request:Request,authorization:str|None=Header(default=None)):
    """The account's live link, so every signed-in iPhone shows the same one (null before it's made)."""
    account=authenticated_account(request,authorization)
    row=request.app.state.storage._conn.execute('SELECT encrypted_token FROM calendar_links WHERE account_id=?',(account['account_id'],)).fetchone()
    if not row or not row['encrypted_token']: return {'url':None}
    from .auth import encryption
    try: token=encryption().decrypt(row['encrypted_token'].encode()).decode()
    except Exception: return {'url':None}
    return {'url':feed_url(token)}


@router.post('/v1/calendar/link')
async def issue_link(request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    token=secrets.token_urlsafe(32)
    from .auth import encryption
    sealed=encryption().encrypt(token.encode()).decode()
    with request.app.state.storage._conn as db:
        db.execute('INSERT INTO calendar_links(account_id,token_hash,encrypted_token) VALUES(?,?,?) '
                   'ON CONFLICT(account_id) DO UPDATE SET token_hash=excluded.token_hash,encrypted_token=excluded.encrypted_token',
                   (account['account_id'],digest(token),sealed))
    return {'url':feed_url(token)}


@router.get('/calendar/{token}.ics')
async def calendar_feed(token:str,request:Request):
    if len(token)>100:raise HTTPException(404,'Calendar not found.')
    db=request.app.state.storage._conn
    account=db.execute('SELECT a.* FROM accounts a JOIN calendar_links c ON c.account_id=a.account_id WHERE c.token_hash=?',(digest(token),)).fetchone()
    if not account:raise HTTPException(404,'Calendar not found.')
    document=read_document(request.app.state.storage,account)
    return Response(calendar_text(document['data'],document['timezone']),media_type='text/calendar',headers={'Cache-Control':'private, no-cache'})
