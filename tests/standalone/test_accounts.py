import asyncio
import copy
import hashlib
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime,timedelta,timezone
from decimal import Decimal
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from fastapi.testclient import TestClient

from howmuch_api import auth,documents,push,accounts,calendar_feed,gmail_payments,live_activity,pay_in
from howmuch_api.database import AppStorage

@pytest.fixture
def setup(tmp_path,monkeypatch):
    private=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    monkeypatch.setattr(auth,'APPLE_KEYS',SimpleNamespace(get_signing_key_from_jwt=lambda token:SimpleNamespace(key=private.public_key())))
    for name in ('HOWMUCH_APPLE_PRIVATE_KEY','HOWMUCH_APPLE_TEAM_ID','HOWMUCH_APPLE_KEY_ID',
                 'HOWMUCH_APNS_PRIVATE_KEY','HOWMUCH_APNS_TEAM_ID','HOWMUCH_APNS_KEY_ID',
                 'HOWMUCH_APNS_SANDBOX_KEY_ID','HOWMUCH_APNS_SANDBOX_PRIVATE_KEY','HOWMUCH_APNS_ENVIRONMENT'):
        monkeypatch.delenv(name,raising=False)
    monkeypatch.setenv('HOWMUCH_APPLE_BUNDLE_ID','com.howmuch.tracker')
    storage=AppStorage(tmp_path/'accounts.sqlite3')
    app=FastAPI();app.state.storage=storage
    for router in (auth.router,documents.router,push.router,accounts.router,gmail_payments.router,live_activity.router,pay_in.router,pay_in.inbound):app.include_router(router,prefix="/v1")
    app.include_router(calendar_feed.router)
    with TestClient(app,base_url='https://howmuch-ios.test') as client:
        yield SimpleNamespace(client=client,storage=storage,private=private)
    storage.close()


def signed(setup,challenge,subject='apple-user-A',**overrides):
    now=int(time.time())
    claims={'iss':auth.ISSUER,'aud':auth.bundle_id(),'sub':subject,'iat':now,'exp':now+300,
            'nonce':hashlib.sha256(challenge['nonce'].encode()).hexdigest(),'email':'relay@example.test','email_verified':True}
    claims.update(overrides)
    return jwt.encode(claims,setup.private,algorithm='RS256',headers={'kid':'test-key'})


def login(setup,subject='apple-user-A',**claims):
    ch=setup.client.post('/v1/auth/challenge').json()
    body={'challenge':ch['challenge'],'identityToken':signed(setup,ch,subject,**claims),
          'authorizationCode':'test-code','deviceID':str(uuid.uuid4()),'displayName':'Private user'}
    response=setup.client.post('/v1/auth/apple',json=body)
    assert response.status_code==200,response.text
    return response.json(),body


def headers(session):return {'Authorization':'Bearer '+session['accessToken']}


def document():
    day=(datetime.now(timezone.utc)+timedelta(days=3)).date()
    shift={'id':str(uuid.uuid4()),'event':'Roadshow','location':'Marina Bay','day':day.isoformat(),
           'startMinute':540,'endMinute':1080,'breakMinutes':60,'paidBreak':False,'rate':15,'pay':120,
           'currency':'SGD','paid':False,'paymentDue':(day+timedelta(days=14)).isoformat(),'overtimeMultiplier':1.5}
    return {'version':1,'shifts':[shift],'claims':[],'rules':{'rate':15,'currency':'SGD','overtimeMultiplier':1.5},
            'preferences':{'displayName':'Private user','defaultBreakMinutes':0,'defaultBreakPaid':False,
                           'eventRates':{},'payers':{},'reminderMinute':1200,
                           'notifications':{'enabled':True,'upcoming':True,'starts':True,'ends':True,'paymentDue':True,
                                            'leadMinutes':30,'dayBeforeMinute':1200,'dueMinute':540,'showDetails':False}}}


def write(setup,session,data,revision=0):
    return setup.client.put('/v1/data',json={'baseRevision':revision,'timezone':'Asia/Singapore','data':data},headers=headers(session))


def test_same_apple_identity_same_account_different_subjects_never_merge_by_email(setup):
    first,_=login(setup);again,_=login(setup)
    other,_=login(setup,'apple-user-B')
    assert first['account']['id']==again['account']['id']
    assert other['account']['id']!=first['account']['id']
    assert setup.storage._conn.execute('SELECT count(*) FROM accounts').fetchone()[0]==2
    assert first['account']['appleUserID']=='apple-user-A'


@pytest.mark.parametrize('changes',[
    {'aud':'wrong.app'},{'iss':'https://evil.test'},{'exp':int(time.time())-300},
    {'iat':int(time.time())+600},{'nonce':'different-nonce'},{'sub':''},
])
def test_rejects_invalid_signed_identity_claims(setup,changes):
    ch=setup.client.post('/v1/auth/challenge').json()
    response=setup.client.post('/v1/auth/apple',json={'challenge':ch['challenge'],
        'identityToken':signed(setup,ch,**changes),'authorizationCode':'x','deviceID':str(uuid.uuid4())})
    assert response.status_code==401
    assert setup.storage._conn.execute('SELECT count(*) FROM accounts').fetchone()[0]==0


def test_rejects_wrong_signature_and_replayed_or_expired_challenge(setup):
    ch=setup.client.post('/v1/auth/challenge').json()
    token=signed(setup,ch)
    parts=token.split('.');parts[2]=('A' if parts[2][0]!='A' else 'B')+parts[2][1:]
    payload={'challenge':ch['challenge'],'identityToken':'.'.join(parts),'authorizationCode':'x','deviceID':str(uuid.uuid4())}
    assert setup.client.post('/v1/auth/apple',json=payload).status_code==401
    payload['identityToken']=token
    assert setup.client.post('/v1/auth/apple',json=payload).status_code==200
    assert setup.client.post('/v1/auth/apple',json=payload).status_code==401
    with setup.storage._conn as db:db.execute('UPDATE auth_challenges SET expires=0')
    ch=setup.client.post('/v1/auth/challenge').json()
    with setup.storage._conn as db:db.execute('UPDATE auth_challenges SET expires=0')
    payload.update(challenge=ch['challenge'],identityToken=signed(setup,ch))
    assert setup.client.post('/v1/auth/apple',json=payload).status_code==401


def test_sessions_rotate_expire_revoke_and_store_only_hashes(setup):
    session,_=login(setup)
    row=setup.storage._conn.execute('SELECT * FROM auth_sessions').fetchone()
    assert session['accessToken'] not in tuple(row)
    assert session['refreshToken'] not in tuple(row)
    assert session['revocationToken'] not in tuple(row)
    response=setup.client.post('/v1/auth/refresh',json={'refreshToken':session['refreshToken']})
    assert response.status_code==200
    updated=response.json()
    assert setup.client.get('/v1/data',headers=headers(session)).status_code==401
    # The reply was lost on a bad connection: the same token again within the grace gets a fresh pair.
    retry=setup.client.post('/v1/auth/refresh',json={'refreshToken':session['refreshToken']})
    assert retry.status_code==200
    assert setup.client.get('/v1/data',headers=headers(updated)).status_code==401
    updated=retry.json()
    assert setup.client.get('/v1/data',headers=headers(updated)).status_code==200
    # Much later the old token turns up again: treat it as stolen and end that session.
    setup.storage._conn.execute('UPDATE auth_sessions SET rotated=rotated-600'); setup.storage._conn.commit()
    assert setup.client.post('/v1/auth/refresh',json={'refreshToken':session['refreshToken']}).status_code==401
    assert setup.client.get('/v1/data',headers=headers(updated)).status_code==401
    session,_=login(setup)
    updated=setup.client.post('/v1/auth/refresh',json={'refreshToken':session['refreshToken']}).json()
    assert setup.client.get('/v1/data',headers=headers(updated)).status_code==200
    assert setup.client.get('/v1/data',headers={'Authorization':'Bearer '+session['revocationToken']}).status_code==401
    assert setup.client.post('/v1/auth/revoke',json={'revocationToken':session['revocationToken']}).status_code==204
    assert setup.client.get('/v1/data',headers=headers(updated)).status_code==401


def test_documents_are_tenant_isolated_and_revision_conflicts_preserve_data(setup):
    a,_=login(setup);b,_=login(setup,'apple-user-B')
    data=document();r=write(setup,a,data)
    assert r.status_code==200,r.text
    assert r.json()['revision']==1
    assert setup.client.get('/v1/data',headers=headers(b)).json()['data']['shifts']==[]
    altered=copy.deepcopy(data);altered['shifts'][0]['event']='Different'
    conflict=write(setup,a,altered,0)
    assert conflict.status_code==409
    assert conflict.json()['current']['data']['shifts'][0]['event']=='Roadshow'
    assert setup.client.get('/v1/data',headers={'Authorization':'tma fake'}).status_code==401
    assert setup.client.get('/v1/data').status_code==401
    assert setup.client.get('/v1/data',headers=headers(a)).json()['data']['shifts'][0]['event']=='Roadshow'


def test_shared_event_rename_moves_owner_payer_rules_without_losing_other_rules(setup):
    from howmuch_api.payment_detection import PaymentStore
    PaymentStore(setup.storage)
    a,_=login(setup);b,_=login(setup,'apple-user-B')
    data=document();second=copy.deepcopy(data['shifts'][0]);second['id']=str(uuid.uuid4())
    second['day']=(datetime.fromisoformat(second['day'])+timedelta(days=1)).date().isoformat()
    data['shifts'].append(second);data['preferences']['payers']={'roadshow':'EXACT COMPANY'}
    assert write(setup,a,data).status_code==200
    assert write(setup,b,copy.deepcopy(data)).status_code==200
    uid=setup.storage._conn.execute('SELECT id FROM accounts WHERE account_id=?',(a['account']['id'],)).fetchone()[0]
    setup.storage._conn.execute('INSERT INTO payment_rules(user_id,payer,event) VALUES(?,?,?)',(uid,'ANOTHER COMPANY','Roadshow'))
    before=setup.storage._conn.execute('SELECT id,payer FROM payment_rules WHERE user_id=? ORDER BY id',(uid,)).fetchall()
    changed=copy.deepcopy(data)
    for shift in changed['shifts']:shift.update(event='Renamed event',location='Shared venue')
    changed['preferences']['payers']={'renamed event':'EXACT COMPANY'}
    assert write(setup,a,changed,1).status_code==200
    rules=setup.storage._conn.execute('SELECT id,payer,event FROM payment_rules WHERE user_id=? ORDER BY id',(uid,)).fetchall()
    assert [(row['id'],row['payer']) for row in rules]==[(row['id'],row['payer']) for row in before]
    assert all(row['event']=='Renamed event' for row in rules)
    current_a=setup.client.get('/v1/data',headers=headers(a)).json()['data']
    current_b=setup.client.get('/v1/data',headers=headers(b)).json()['data']
    assert 'renamed event' in current_a['preferences']['eventPayerIDs']
    assert 'roadshow' not in current_a['preferences']['eventPayerIDs']
    for result,expected in ((current_a,changed),(current_b,data)):
        result['preferences'].pop('savedPayers',None); result['preferences'].pop('eventPayerIDs',None)
        assert result==expected
    assert write(setup,a,data,2).status_code==200  # Undo the shared change.
    assert {row['event'] for row in setup.storage._conn.execute('SELECT event FROM payment_rules WHERE user_id=?',(uid,))}=={'Roadshow'}


def test_partial_event_rename_does_not_move_payer_rule(setup):
    from howmuch_api.payment_detection import PaymentStore
    PaymentStore(setup.storage)
    session,_=login(setup);data=document()
    second=copy.deepcopy(data['shifts'][0]);second['id']=str(uuid.uuid4());data['shifts'].append(second)
    data['preferences']['payers']={'roadshow':'EXACT COMPANY'}
    assert write(setup,session,data).status_code==200
    data['shifts'][0]['event']='Different event'
    assert write(setup,session,data,1).status_code==200
    assert {row['event'] for row in setup.storage._conn.execute('SELECT event FROM payment_rules')}=={'Roadshow'}


@pytest.mark.parametrize('category',['cab','food','miscellaneous'])
def test_claim_categories_round_trip_and_survive_older_client_writes(setup,category):
    a,_=login(setup);b,_=login(setup,'apple-user-B');data=document()
    claim={'id':str(uuid.uuid4()),'shiftID':data['shifts'][0]['id'],'day':data['shifts'][0]['day'],'amount':12.34,'note':'Expense','category':category}
    data['claims']=[claim]
    assert write(setup,a,data).status_code==200
    older=copy.deepcopy(data);older['claims'][0].pop('category');older['claims'][0]['note']='Edited on older app'
    assert write(setup,a,older,1).status_code==200
    saved=setup.client.get('/v1/data',headers=headers(a)).json()['data']
    assert saved['claims'][0]['category']==category and saved['claims'][0]['id']==claim['id']
    assert saved['shifts']==data['shifts']
    assert write(setup,b,older).status_code==200
    assert 'category' not in setup.client.get('/v1/data',headers=headers(b)).json()['data']['claims'][0]
    saved['claims'][0]['category']='cab'
    assert write(setup,a,saved,2).status_code==200
    assert setup.client.get('/v1/data',headers=headers(a)).json()['data']['claims'][0]['category']=='cab'


@pytest.mark.parametrize('category',['unknown',None])
def test_invalid_claim_category_never_commits(setup,category):
    session,_=login(setup);data=document()
    data['claims']=[{'id':str(uuid.uuid4()),'shiftID':data['shifts'][0]['id'],'day':data['shifts'][0]['day'],'amount':5,'note':'Expense','category':category}]
    assert write(setup,session,data).status_code==422
    assert setup.client.get('/v1/data',headers=headers(session)).json()['revision']==0


def test_upcoming_grouping_preference_survives_older_client_save(setup):
    session,_=login(setup);data=document();data['preferences']['groupUpcomingByEvent']=True
    assert write(setup,session,data).status_code==200
    data['preferences'].pop('groupUpcomingByEvent');data['preferences']['displayName']='Updated name'
    assert write(setup,session,data,1).status_code==200
    assert setup.client.get('/v1/data',headers=headers(session)).json()['data']['preferences']['groupUpcomingByEvent'] is True
    data['preferences']['groupUpcomingByEvent']=False
    assert write(setup,session,data,2).status_code==200
    assert setup.client.get('/v1/data',headers=headers(session)).json()['data']['preferences']['groupUpcomingByEvent'] is False


def test_payment_matching_counts_all_claim_categories_but_preserves_work_pay(setup):
    from howmuch_api.payment_detection import PaymentStore
    store=PaymentStore(setup.storage)
    session,_=login(setup);data=document();data['shifts'][0]['day']=(datetime.now(timezone.utc)-timedelta(days=2)).date().isoformat()
    data['preferences']['payers']={'roadshow':'EXACT COMPANY'}
    data['claims']=[{'id':str(uuid.uuid4()),'shiftID':data['shifts'][0]['id'],'day':data['shifts'][0]['day'],'amount':10,'note':kind,'category':kind} for kind in ['cab','food','miscellaneous']]
    assert write(setup,session,data).status_code==200
    uid=setup.storage._conn.execute('SELECT id FROM accounts WHERE account_id=?',(session['account']['id'],)).fetchone()[0]
    receipt={'amount':'150','received_at':datetime.now(timezone.utc).isoformat(),'currency':'SGD','payer':'EXACT COMPANY'}
    candidates=store.candidates(uid,receipt)
    assert len(candidates)==1 and candidates[0]['includes_cab'] and candidates[0]['payer_match']
    receipt['amount']='130';assert store.candidates(uid,receipt)==[]
    saved=setup.client.get('/v1/data',headers=headers(session)).json()['data']
    assert saved['shifts'][0]['pay']==120 and saved['shifts'][0]['paid'] is False


def test_cab_claim_edit_delete_and_restore_keep_identity_and_work_pay(setup):
    a,_=login(setup);b,_=login(setup,'apple-user-B')
    data=document();shift=copy.deepcopy(data['shifts'][0])
    claim={'id':str(uuid.uuid4()),'shiftID':shift['id'],'day':shift['day'],'amount':12.34,'note':'Cab ride'}
    data['claims']=[claim]
    assert write(setup,a,data).status_code==200
    claim.update(amount=18.75,note='Updated cab ride')
    assert write(setup,a,data,1).status_code==200
    saved=setup.client.get('/v1/data',headers=headers(a)).json()['data']
    assert saved['claims']==[claim]
    assert saved['shifts']==[shift]
    owner=setup.storage._conn.execute('SELECT id FROM accounts WHERE account_id=?',(a['account']['id'],)).fetchone()[0]
    rows=setup.storage._conn.execute('SELECT ios_uuid,amount FROM cab_claims WHERE user_id=?',(owner,)).fetchall()
    assert len(rows)==1 and rows[0]['ios_uuid']==claim['id']
    assert Decimal(rows[0]['amount'])==Decimal('18.75')
    assert setup.client.get('/v1/data',headers=headers(b)).json()['data']['claims']==[]
    data['claims']=[]
    assert write(setup,a,data,2).status_code==200
    assert setup.storage._conn.execute('SELECT count(*) FROM cab_claims WHERE user_id=?',(owner,)).fetchone()[0]==0
    data['claims']=[claim]
    assert write(setup,a,data,3).status_code==200
    restored=setup.client.get('/v1/data',headers=headers(a)).json()['data']
    assert restored['claims']==[claim] and restored['shifts']==[shift]


def test_invalid_pay_duplicate_ids_or_orphan_claims_never_commit(setup):
    session,_=login(setup)
    valid=document();assert write(setup,session,valid).status_code==200
    for mutation in ('pay','duplicate','orphan','timezone'):
        data=copy.deepcopy(valid)
        if mutation=='pay':data['shifts'][0]['pay']=999
        if mutation=='duplicate':data['shifts']*=2
        if mutation=='orphan':data['claims']=[{'id':str(uuid.uuid4()),'shiftID':str(uuid.uuid4()),'day':data['shifts'][0]['day'],'amount':12,'note':'Taxi'}]
        if mutation=='timezone':
            response=setup.client.put('/v1/data',headers=headers(session),json={'baseRevision':1,'data':data,'timezone':'Not/AZone'})
        else:response=write(setup,session,data,1)
        assert response.status_code==422
        assert setup.client.get('/v1/data',headers=headers(session)).json()['revision']==1


def test_payment_projection_keeps_immutable_ids_and_syncs_paid_flags(setup):
    session,_=login(setup);data=document();assert write(setup,session,data).status_code==200
    db=setup.storage._conn
    before=db.execute('SELECT id FROM shifts').fetchone()[0]
    data['shifts'][0]['location']='Suntec';assert write(setup,session,data,1).status_code==200
    assert db.execute('SELECT id FROM shifts').fetchone()[0]==before
    with db:db.execute('UPDATE shifts SET paid=1')
    fetched=setup.client.get('/v1/data',headers=headers(session)).json()
    assert fetched['revision']==3 and fetched['data']['shifts'][0]['paid'] is True
    assert write(setup,session,data,2).status_code==409


def test_push_registration_is_account_scoped_and_log_out_removes_device(setup,monkeypatch):
    monkeypatch.setattr(push,'configured',lambda *args:True)
    a,_=login(setup);b,_=login(setup,'apple-user-B')
    token='a'*64
    assert setup.client.put('/v1/devices/push',json={'token':token,'environment':'production'},headers=headers(a)).status_code==200
    assert setup.client.put('/v1/devices/push',json={'token':token,'environment':'production'},headers=headers(b)).status_code==200
    rows=setup.storage._conn.execute('SELECT account_id FROM push_devices').fetchall()
    assert len(rows)==1 and rows[0][0]==b['account']['id']
    assert setup.client.post('/v1/auth/logout',headers=headers(a)).status_code==204
    assert setup.storage._conn.execute('SELECT count(*) FROM push_devices').fetchone()[0]==1
    assert setup.client.post('/v1/auth/logout',headers=headers(b)).status_code==204
    assert setup.storage._conn.execute('SELECT count(*) FROM push_devices').fetchone()[0]==0


def test_unconfigured_apns_does_not_claim_remote_registration(setup):
    session,_=login(setup)
    result=setup.client.put('/v1/devices/push',json={'token':'a'*64,'environment':'sandbox'},headers=headers(session))
    assert result.json()=={'registered':False,'pushReady':False}
    assert setup.storage._conn.execute('SELECT count(*) FROM push_devices').fetchone()[0]==0


def test_notification_jobs_dedupe_cancel_and_suppress_paid_due_dates(setup):
    session,_=login(setup);data=document()
    assert write(setup,session,data).status_code==200
    db=setup.storage._conn
    kinds={r[0] for r in db.execute("SELECT kind FROM notification_jobs WHERE status='pending'")}
    assert kinds=={'start','end','upcoming','payment_due'}
    count=db.execute('SELECT count(*) FROM notification_jobs').fetchone()[0]
    assert write(setup,session,data,1).status_code==200
    assert db.execute('SELECT count(*) FROM notification_jobs').fetchone()[0]==count
    data['shifts'][0]['paid']=True
    assert write(setup,session,data,2).status_code==200
    assert db.execute("SELECT count(*) FROM notification_jobs WHERE kind='payment_due' AND status='pending'").fetchone()[0]==0
    data['preferences']['notifications']['enabled']=False
    assert write(setup,session,data,3).status_code==200
    assert db.execute("SELECT count(*) FROM notification_jobs WHERE status='pending'").fetchone()[0]==0


def test_apns_delivery_retries_and_deduplicates_without_cross_account_sends(setup,monkeypatch):
    monkeypatch.setattr(push,'configured',lambda *args:True);monkeypatch.setattr(push,'provider_token',lambda *args:'provider-test-token')
    a,_=login(setup);b,_=login(setup,'apple-user-B');data=document()
    assert write(setup,a,data).status_code==200
    setup.client.put('/v1/devices/push',json={'token':'a'*64,'environment':'sandbox'},headers=headers(a))
    setup.client.put('/v1/devices/push',json={'token':'b'*64,'environment':'production'},headers=headers(b))
    db=setup.storage._conn
    job=db.execute("SELECT * FROM notification_jobs WHERE kind='start'").fetchone()
    sent=[]
    def transport(request):
        sent.append((str(request.url),json.loads(request.content)))
        return httpx.Response(503 if len(sent)==1 else 200,json={})
    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
            await push.deliver_due(setup.storage,client=client,now=job['fire_at']+1)
            await push.deliver_due(setup.storage,client=client,now=job['fire_at']+200)
            count=len(sent)
            await push.deliver_due(setup.storage,client=client,now=job['fire_at']+201)
            assert len(sent)==count
    asyncio.run(run())
    assert sent and all('/device/'+'a'*64 in url for url,_ in sent)
    assert all(payload['account_id']==a['account']['id'] for _,payload in sent)
    assert all('Roadshow' not in payload['aps']['alert']['body'] for _,payload in sent)
    assert all(payload['aps']['category']=='HOWMUCH_START' for _,payload in sent)
    assert all(payload['aps']['thread-id']==f"howmuch.{a['account']['id']}.{data['shifts'][0]['id']}" for _,payload in sent)
    assert all(payload['aps']['interruption-level']=='active' for _,payload in sent)
    assert db.execute('SELECT status FROM notification_jobs WHERE job_id=?',(job['job_id'],)).fetchone()[0]=='sent'


def test_calendar_links_are_owned_rotatable_and_no_bot_auth_is_accepted(setup,monkeypatch):
    from cryptography.fernet import Fernet
    monkeypatch.setenv('HOWMUCH_ENCRYPTION_KEY',Fernet.generate_key().decode())
    a,_=login(setup);b,_=login(setup,'apple-user-B')
    data=document();assert write(setup,a,data).status_code==200
    assert setup.client.get('/v1/calendar/link',headers=headers(a)).json()['url'] is None
    first=setup.client.post('/v1/calendar/link',headers=headers(a)).json()['url']
    # Every iPhone on the account sees the same link.
    assert setup.client.get('/v1/calendar/link',headers=headers(a)).json()['url']==first
    response=setup.client.get(first.replace('https://howmuch-ios.fly.dev','https://howmuch-ios.test'))
    assert response.status_code==200 and 'Roadshow' in response.text
    assert 'X-WR-CALNAME:HowMuch shifts' in response.text and 'REFRESH-INTERVAL;VALUE=DURATION:PT1H' in response.text
    assert 'Awaiting payment' in response.text and 'DESCRIPTION:' in response.text
    other=setup.client.post('/v1/calendar/link',headers=headers(b)).json()['url']
    assert 'Roadshow' not in setup.client.get(other.replace('https://howmuch-ios.fly.dev','https://howmuch-ios.test')).text
    replaced=setup.client.post('/v1/calendar/link',headers=headers(a)).json()['url']
    assert setup.client.get('/v1/calendar/link',headers=headers(a)).json()['url']==replaced!=first
    assert setup.client.get(first.replace('https://howmuch-ios.fly.dev','https://howmuch-ios.test')).status_code==404


def test_account_deletion_requires_same_apple_identity_and_purges_only_owner(setup):
    a,_=login(setup);b,_=login(setup,'apple-user-B')
    assert write(setup,a,document()).status_code==200
    assert write(setup,b,document()).status_code==200
    challenge=setup.client.post('/v1/auth/challenge').json()
    payload={'challenge':challenge['challenge'],'identityToken':signed(setup,challenge,'apple-user-B'),
             'authorizationCode':'test-code','deviceID':str(uuid.uuid4())}
    assert setup.client.post('/v1/account/delete',json=payload,headers=headers(a)).status_code==403
    payload['identityToken']=signed(setup,challenge)
    result=setup.client.post('/v1/account/delete',json=payload,headers=headers(a))
    assert result.status_code==200,result.text
    assert result.json()['deleted'] is True
    assert setup.client.get('/v1/data',headers=headers(a)).status_code==401
    assert len(setup.client.get('/v1/data',headers=headers(b)).json()['data']['shifts'])==1
    assert setup.storage._conn.execute('SELECT count(*) FROM accounts').fetchone()[0]==1


def test_no_telegram_runtime_dependency():
    result=subprocess.run([sys.executable,'-c',"from howmuch_api.main import app; import sys; assert not any(k.startswith('paybot') for k in sys.modules)"],capture_output=True,text=True)
    assert result.returncode==0,result.stderr

@pytest.mark.parametrize('revoke_fails',[False,True])
def test_deletion_keeps_stored_apple_token_when_fresh_exchange_fails(setup,monkeypatch,revoke_fails):
    from cryptography.fernet import Fernet
    session,_=login(setup)
    cipher=Fernet(Fernet.generate_key())
    monkeypatch.setattr(accounts,'apple_service_configured',lambda:True)
    monkeypatch.setattr(accounts,'encryption',lambda:cipher)
    seen=[]
    async def failed_exchange(code):raise httpx.ConnectError('temporary outage')
    async def revoke(token):
        seen.append(token)
        if revoke_fails:raise httpx.ConnectError('temporary outage')
    monkeypatch.setattr(accounts,'exchange_apple_code',failed_exchange)
    monkeypatch.setattr(accounts,'revoke_token',revoke)
    with setup.storage._conn:
        setup.storage._conn.execute('UPDATE accounts SET apple_refresh=? WHERE account_id=?',
            (cipher.encrypt(b'stored-refresh-token').decode(),session['account']['id']))
    ch=setup.client.post('/v1/auth/challenge').json()
    result=setup.client.post('/v1/account/delete',headers=headers(session),json={
        'challenge':ch['challenge'],'identityToken':signed(setup,ch),'authorizationCode':'fresh-code','deviceID':str(uuid.uuid4())})
    assert result.status_code==200,result.text
    assert seen==['stored-refresh-token']
    assert result.json()['appleRevocationPending']==revoke_fails
    queued=setup.storage._conn.execute('SELECT * FROM apple_revocations').fetchall()
    assert len(queued)==int(revoke_fails)
    if queued:assert cipher.decrypt(queued[0]['encrypted_token'].encode())==b'stored-refresh-token'


def test_apns_uses_distinct_environment_keys_and_rejects_missing_sandbox(setup,monkeypatch):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.serialization import Encoding,PrivateFormat,NoEncryption
    prod=ec.generate_private_key(ec.SECP256R1());sandbox=ec.generate_private_key(ec.SECP256R1())
    pem=lambda k:k.private_bytes(Encoding.PEM,PrivateFormat.PKCS8,NoEncryption()).decode()
    monkeypatch.setenv('HOWMUCH_APNS_TEAM_ID','test-team')
    monkeypatch.setenv('HOWMUCH_APNS_ENVIRONMENT','production')
    monkeypatch.setenv('HOWMUCH_APNS_KEY_ID','production-key')
    monkeypatch.setenv('HOWMUCH_APNS_PRIVATE_KEY',pem(prod))
    assert push.configured('production') and not push.configured('sandbox')
    session,_=login(setup)
    response=setup.client.put('/v1/devices/push',headers=headers(session),json={'token':'a'*64,'environment':'sandbox'})
    assert response.json()=={'registered':False,'pushReady':False}
    monkeypatch.setenv('HOWMUCH_APNS_SANDBOX_KEY_ID','sandbox-key')
    monkeypatch.setenv('HOWMUCH_APNS_SANDBOX_PRIVATE_KEY',pem(sandbox))
    for environment,key,keyid in [('production',prod,'production-key'),('sandbox',sandbox,'sandbox-key')]:
        assert push.configured(environment)
        token=push.provider_token(environment)
        assert jwt.get_unverified_header(token)['kid']==keyid
        assert jwt.decode(token,key.public_key(),algorithms=['ES256'])['iss']=='test-team'


def test_notification_copy_privacy_and_earliest_digest(setup):
    session,_=login(setup);data=document()
    early=data['shifts'][0]
    late={**early,'id':str(uuid.uuid4()),'event':'Late private event','startMinute':1080,'endMinute':1200,'pay':15}
    data['shifts']=[late,early]
    assert write(setup,session,data).status_code==200
    db=setup.storage._conn
    digest=db.execute("SELECT * FROM notification_jobs WHERE kind='upcoming' AND status='pending'").fetchone()
    assert digest['title']=='Tomorrow: 2 shifts'
    assert digest['shift_id']==early['id']
    assert digest['body']=='First shift at 09:00. Open HowMuch to plan your day.'
    assert all('Roadshow' not in r['title']+r['body'] and 'Marina Bay' not in r['body'] for r in db.execute("SELECT * FROM notification_jobs"))
    data['preferences']['notifications']['showDetails']=True
    assert write(setup,session,data,1).status_code==200
    start=db.execute("SELECT * FROM notification_jobs WHERE kind='start' AND shift_id=?",(early['id'],)).fetchone()
    assert start['title']=='Shift starts at 09:00'
    assert start['body']=='Roadshow · 09:00–18:00 · Marina Bay'


def test_multiple_start_reminders_persist_dedupe_and_cancel_removed_times(setup):
    session,_=login(setup);data=document()
    data['preferences']['notifications']['startLeadMinutes']=[120,60,30,0,30]
    assert write(setup,session,data).status_code==200
    db=setup.storage._conn
    jobs=db.execute("SELECT * FROM notification_jobs WHERE kind='start' AND status='pending' ORDER BY fire_at").fetchall()
    assert len(jobs)==4 and len({j['job_id'] for j in jobs})==4
    start=jobs[-1]['fire_at']
    assert [(start-j['fire_at'])//60 for j in jobs]==[120,60,30,0]
    assert all(j['expires']-j['fire_at']<=900 for j in jobs)
    saved=setup.client.get('/v1/data',headers=headers(session)).json()['data']
    assert saved['preferences']['notifications']['startLeadMinutes']==[120,60,30,0]
    data['preferences']['notifications']['startLeadMinutes']=[30,0]
    assert write(setup,session,data,1).status_code==200
    pending=db.execute("SELECT * FROM notification_jobs WHERE kind='start' AND status='pending'").fetchall()
    assert len(pending)==2
    assert {j['job_id'] for j in pending}<={j['job_id'] for j in jobs}
    assert db.execute("SELECT count(*) FROM notification_jobs WHERE kind='start' AND status='cancelled'").fetchone()[0]==2


def test_start_reminder_choices_validate_and_skip_past_times(setup):
    session,_=login(setup);data=document()
    for choices in ([],[-1],[1441],list(range(13))):
        data['preferences']['notifications']['startLeadMinutes']=choices
        assert write(setup,session,data).status_code==422
    data['preferences']['notifications']['startLeadMinutes']=[120,60,30,0]
    assert write(setup,session,data).status_code==200
    db=setup.storage._conn
    start=db.execute("SELECT max(fire_at) FROM notification_jobs WHERE kind='start'").fetchone()[0]
    account=db.execute('SELECT * FROM accounts').fetchone()
    push.rebuild_jobs(setup.storage,account,data,'Asia/Singapore',now=start-45*60)
    pending=db.execute("SELECT fire_at FROM notification_jobs WHERE kind='start' AND status='pending' ORDER BY fire_at").fetchall()
    assert [r['fire_at'] for r in pending]==[start-30*60,start]


def test_old_client_keeps_multiple_times_when_saving_unrelated_preferences(setup):
    session,_=login(setup);data=document()
    data['preferences']['notifications']['startLeadMinutes']=[120,60,30,0]
    assert write(setup,session,data).status_code==200
    del data['preferences']['notifications']['startLeadMinutes']
    data['preferences']['displayName']='Updated on older app'
    response=write(setup,session,data,1)
    assert response.status_code==200
    assert response.json()['data']['preferences']['notifications']['startLeadMinutes']==[120,60,30,0]
    data['preferences']['notifications']['leadMinutes']=15
    response=write(setup,session,data,2)
    assert response.status_code==200
    assert response.json()['data']['preferences']['notifications'].get('startLeadMinutes') is None
    assert setup.storage._conn.execute("SELECT count(*) FROM notification_jobs WHERE kind='start' AND status='pending'").fetchone()[0]==1


def test_pet_live_shift_and_widget_settings_sync_and_survive_older_apps(setup):
    session,_=login(setup)
    data=document()
    data['preferences']['pet']={'name':'Coco','closet':{'bought':['party-hat'],'spent':40,'outfit':{'hat':'party-hat','background':'mint'}}}
    data['preferences']['liveShift']={'lockScreen':False,'askFinish':True,'confirmedFinishes':[data['shifts'][0]['id']]}
    data['preferences']['widgetPreview']={'showPay':True}
    first=write(setup,session,data)
    assert first.status_code==200
    # Another device signed in to the same account sees them.
    other,_=login(setup)
    synced=setup.client.get('/v1/data',headers=headers(other)).json()
    assert synced['data']['preferences']['pet']['closet']['outfit']['hat']=='party-hat'
    assert synced['data']['preferences']['liveShift']['lockScreen'] is False
    # An older app version saves without the new settings: they are kept.
    old=document(); old['shifts']=data['shifts']
    assert write(setup,other,old,revision=synced['revision']).status_code==200
    kept=setup.client.get('/v1/data',headers=headers(session)).json()['data']['preferences']
    assert kept['pet']['name']=='Coco' and kept['widgetPreview']['showPay'] is True
    # Nonsense values are rejected.
    bad=document(); bad['preferences']['pet']={'name':'x'*41}
    assert write(setup,session,bad,revision=kept and setup.client.get('/v1/data',headers=headers(session)).json()['revision']).status_code==422


def test_accounts_made_before_launch_are_pioneers(setup,monkeypatch):
    monkeypatch.delenv('HOWMUCH_PIONEER_UNTIL',raising=False)
    early,_=login(setup)
    assert early['account']['pioneer'] is True
    assert setup.client.get('/v1/data',headers=headers(early)).json()['pioneer'] is True
    # After launch, only accounts made before the cut-off keep the badge.
    setup.storage._conn.execute("UPDATE accounts SET created=? WHERE apple_sub='apple-user-A'",(int(time.time())-86400,))
    setup.storage._conn.commit()
    monkeypatch.setenv('HOWMUCH_PIONEER_UNTIL',str(int(time.time())-60))
    late,_=login(setup,'apple-user-B')
    assert late['account']['pioneer'] is False
    again,_=login(setup)
    assert again['account']['pioneer'] is True
    monkeypatch.setenv('HOWMUCH_PIONEER_UNTIL','2020-01-01')
    assert setup.client.get('/v1/data',headers=headers(again)).json()['pioneer'] is False


def test_only_listed_accounts_are_developers(setup,monkeypatch):
    monkeypatch.delenv('HOWMUCH_DEVELOPERS',raising=False)
    me,_=login(setup); other,_=login(setup,'apple-user-B')
    assert me['account']['developer'] is False
    monkeypatch.setenv('HOWMUCH_DEVELOPERS',' '+me['account']['id'].upper()+' , not-an-account')
    assert setup.client.get('/v1/data',headers=headers(me)).json()['developer'] is True
    assert setup.client.get('/v1/data',headers=headers(other)).json()['developer'] is False
    again,_=login(setup)
    assert again['account']['developer'] is True


def test_sign_out_everywhere_and_rate_limits_are_per_client(setup):
    first,_=login(setup); second,_=login(setup)
    assert setup.client.post('/v1/auth/logout-all',headers=headers(first)).status_code==204
    assert setup.client.get('/v1/data',headers=headers(first)).status_code==401
    assert setup.client.get('/v1/data',headers=headers(second)).status_code==401
    # One caller using up the limit doesn't block another (Fly passes each caller's address).
    for _ in range(41): setup.client.post('/v1/auth/challenge',headers={'Fly-Client-IP':'203.0.113.1'})
    assert setup.client.post('/v1/auth/challenge',headers={'Fly-Client-IP':'203.0.113.1'}).status_code==429
    assert setup.client.post('/v1/auth/challenge',headers={'Fly-Client-IP':'198.51.100.7'}).status_code==200


def test_a_due_reminder_still_goes_out_when_jobs_are_rebuilt(setup):
    session,_=login(setup);data=document()
    data['preferences']['notifications']['startLeadMinutes']=[30,0]
    assert write(setup,session,data).status_code==200
    db=setup.storage._conn
    start=db.execute("SELECT max(fire_at) FROM notification_jobs WHERE kind='start'").fetchone()[0]
    account=db.execute('SELECT * FROM accounts').fetchone()
    # 25 minutes before the start: the 30-minute reminder is due but the worker hasn't sent it yet.
    push.rebuild_jobs(setup.storage,account,data,'Asia/Singapore',now=start-25*60)
    pending=[r['fire_at'] for r in db.execute("SELECT fire_at FROM notification_jobs WHERE kind='start' AND status='pending' ORDER BY fire_at")]
    assert pending==[start-30*60,start]
