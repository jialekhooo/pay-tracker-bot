import asyncio
import copy
import json
import time
from datetime import datetime,timezone
from types import SimpleNamespace
import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization
from howmuch_api import travel,push
from howmuch_api.documents import TravelPreferences
from .test_accounts import setup,login,headers,document,write

@pytest.fixture
def configured(setup,monkeypatch):
    key=ec.generate_private_key(ec.SECP256R1())
    monkeypatch.setenv('HOWMUCH_MAPS_PRIVATE_KEY',key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode())
    monkeypatch.setenv('HOWMUCH_MAPS_KEY_ID','TESTMAPKEY')
    monkeypatch.setenv('HOWMUCH_APPLE_TEAM_ID','TESTTEAMID')
    monkeypatch.setattr(travel,'_token',None);monkeypatch.setattr(travel,'_token_until',0)
    setup.client.app.include_router(travel.router,prefix='/v1')
    return key

def prepared(setup):
    session,_=login(setup);data=document();now=int(time.time())
    start=now+7200
    local=datetime.fromtimestamp(start,__import__('zoneinfo').ZoneInfo('Asia/Singapore'))
    data['shifts'][0].update(day=local.date().isoformat(),startMinute=local.hour*60+local.minute,endMinute=(local.hour*60+local.minute+540)%1440)
    data['preferences']['travel']={'enabled':True,'origin':'Singapore Botanic Gardens, Singapore','mode':'automobile','arrivalBuffer':15,'prepareMinutes':10,'trafficUpdates':True}
    assert write(setup,session,data).status_code==200
    account=setup.storage._conn.execute('SELECT * FROM accounts').fetchone()
    envelope=travel.read_document(setup.storage,account)
    options,items=travel.candidates(envelope['data'],envelope['timezone'],now)
    return session,data,dict(account),options,items[0],now

def fake_client(duration=1800,handler=None):
    def respond(request):
        if handler:return handler(request)
        if request.url.path=='/v1/token':return httpx.Response(200,json={'accessToken':'synthetic','expiresInSeconds':1800})
        return httpx.Response(200,json={'routes':[{'durationSeconds':duration,'distanceMeters':10000}],
            'origin':{'name':'Botanic Gardens'},'destination':{'name':'Marina Bay'}})
    return httpx.AsyncClient(transport=httpx.MockTransport(respond))

def add_device(setup,account,session):
    row=setup.storage._conn.execute('SELECT * FROM auth_sessions WHERE account_id=?',(account['account_id'],)).fetchone()
    with setup.storage._conn as db:db.execute('INSERT INTO push_devices VALUES(?,?,?,?,?,?)',(row['session_id'],account['account_id'],row['session_id'],'a'*64,'production',int(time.time())))

@pytest.mark.parametrize('change',[{'origin':''},{'mode':'transit'},{'arrivalBuffer':-1},{'prepareMinutes':61}])
def test_validate_opt_in(change):
    with pytest.raises(ValueError):TravelPreferences.model_validate({'enabled':True,'origin':'A',**change})

def test_default_off_and_legacy_no_tracking(setup,configured):
    session,_=login(setup);assert write(setup,session,document()).status_code==200
    r=setup.client.get('/v1/travel/status',headers=headers(session));assert r.json()=={'ready':True,'estimates':[]}
    assert setup.client.post('/v1/travel/check',json={'shiftID':document()['shifts'][0]['id']},headers=headers(session)).status_code==400
    assert setup.client.get('/v1/travel/status').status_code==401

def test_maps_jwt_has_server_only_scope(setup,configured):
    token=travel.maps_token()
    result=jwt.decode(token,configured.public_key(),algorithms=['ES256'])
    assert result['scope']=='server_api' and result['iss']=='TESTTEAMID'
    assert 'origin' not in result and jwt.get_unverified_header(token)['kid']=='TESTMAPKEY'

def test_arrival_math_and_token_cache(setup,configured):
    _,_,_,options,item,now=prepared(setup);seen=[]
    def handler(req):
        seen.append(req)
        if req.url.path.endswith('token'):return httpx.Response(200,json={'accessToken':'test','expiresInSeconds':1800})
        assert req.url.params['transportType']=='Automobile'
        assert req.url.params['arrivalDate'].endswith('Z')
        return httpx.Response(200,json={'routes':[{'durationSeconds':1801.2,'distanceMeters':12345}]})
    async def run():
        async with fake_client(handler=handler) as client:
            first=await travel.route(options,item[1],item[0],client)
            await travel.route(options,item[1],item[0],client)
            return first
    result=asyncio.run(run())
    assert result['leaveAt']==item[0]-15*60-1802
    assert result['arriveAt']==item[0]-15*60
    assert len([r for r in seen if r.url.path.endswith('token')])==1

def test_scheduling_dedupe_privacy_and_regular_rebuild(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    async def run():
        async with fake_client() as client:
            await travel.refresh_one(setup.storage,account,options,*item,client,now)
            await travel.refresh_one(setup.storage,account,options,*item,client,now+300)
    asyncio.run(run())
    push.rebuild_jobs(setup.storage,account,data,'Asia/Singapore',now)
    rows=setup.storage._conn.execute("SELECT * FROM notification_jobs WHERE kind LIKE 'travel_%' AND status='pending'").fetchall()
    assert {r['kind'] for r in rows}=={'travel_prepare','travel_leave'}
    assert all('Roadshow' not in r['body'] and 'Gardens' not in r['body'] for r in rows)
    assert len(rows)==2

@pytest.mark.parametrize('change',['location','time','disable','delete','origin'])
def test_edit_cancels_old_notifications(setup,configured,change):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    async def run():
        async with fake_client() as client:await travel.refresh_one(setup.storage,account,options,*item,client,now)
    asyncio.run(run())
    if change=='location':data['shifts'][0]['location']='Another venue'
    if change=='time':
        data['shifts'][0]['startMinute']=(data['shifts'][0]['startMinute']+60)%1440
        data['shifts'][0]['endMinute']=(data['shifts'][0]['endMinute']+60)%1440
    if change=='disable':data['preferences']['travel']['enabled']=False
    if change=='delete':data['shifts']=[]
    if change=='origin':data['preferences']['travel']['origin']='Another origin'
    assert write(setup,session,data,1).status_code==200
    assert setup.storage._conn.execute("SELECT count(*) FROM notification_jobs WHERE kind LIKE 'travel_%' AND status='pending'").fetchone()[0]==0
    assert setup.storage._conn.execute('SELECT count(*) FROM travel_estimates').fetchone()[0]==0

def test_inflight_edit_does_not_restore_jobs(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    def handler(req):
        if req.url.path.endswith('token'):return httpx.Response(200,json={'accessToken':'t','expiresInSeconds':1800})
        data['preferences']['travel']['enabled']=False
        assert write(setup,session,data,1).status_code==200
        return httpx.Response(200,json={'routes':[{'durationSeconds':1800}]})
    async def run():
        async with fake_client(handler=handler) as client:return await travel.refresh_one(setup.storage,account,options,*item,client,now)
    assert asyncio.run(run()) is None
    assert setup.storage._conn.execute("SELECT count(*) FROM notification_jobs WHERE kind LIKE 'travel_%' AND status='pending'").fetchone()[0]==0

def test_failure_cancels_stale_forecast_and_backs_off(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    async def run():
        async with fake_client() as client:await travel.refresh_one(setup.storage,account,options,*item,client,now)
        async with fake_client(handler=lambda req:httpx.Response(429)) as client:
            assert await travel.refresh_one(setup.storage,account,options,*item,client,now+300) is None
    asyncio.run(run())
    assert setup.storage._conn.execute("SELECT count(*) FROM notification_jobs WHERE kind LIKE 'travel_%' AND status='pending'").fetchone()[0]==0
    row=setup.storage._conn.execute('SELECT * FROM travel_estimates').fetchone()
    assert row['retry_at']==now+600 and row['error']

def test_check_is_account_scoped_and_normalizes_uuid(setup,configured,monkeypatch):
    session,data,account,options,item,now=prepared(setup)
    async def fake(*args):return {'leaveAt':now}
    monkeypatch.setattr(travel,'refresh_one',fake)
    assert setup.client.post('/v1/travel/check',json={'shiftID':item[1]['id'].upper()},headers=headers(session)).status_code==200
    other,_=login(setup,'another-account')
    assert setup.client.post('/v1/travel/check',json={'shiftID':item[1]['id']},headers=headers(other)).status_code==400
    assert setup.client.get('/v1/travel/status',headers=headers(other)).json()['estimates']==[]

def test_no_devices_no_background_location_requests(setup,configured):
    prepared(setup)
    async def run():
        async with fake_client(handler=lambda req:pytest.fail('No device; must not call Maps')) as client:
            assert await travel.refresh_due(setup.storage,client)==0
    asyncio.run(run())

def test_traffic_worsens_updates_once_without_resending_sent_alert(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    async def run():
        async with fake_client() as client:await travel.refresh_one(setup.storage,account,options,*item,client,now)
        with setup.storage._conn as db:db.execute("UPDATE notification_jobs SET status='sent' WHERE kind='travel_prepare'")
        async with fake_client(duration=2400) as client:await travel.refresh_one(setup.storage,account,options,*item,client,now+300)
        async with fake_client(duration=3000) as client:await travel.refresh_one(setup.storage,account,options,*item,client,now+600)
    asyncio.run(run())
    db=setup.storage._conn
    assert db.execute("SELECT count(*) FROM notification_jobs WHERE kind='travel_update'").fetchone()[0]==1
    assert db.execute("SELECT status FROM notification_jobs WHERE kind='travel_prepare'").fetchone()[0]=='sent'
    assert db.execute("SELECT fire_at FROM notification_jobs WHERE kind='travel_leave'").fetchone()[0]==item[0]-900-3000

def test_privacy_toggle_cancels_detailed_jobs_immediately(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    data['preferences']['notifications']['showDetails']=True
    assert write(setup,session,data,1).status_code==200
    envelope=travel.read_document(setup.storage,account);options,items=travel.candidates(envelope['data'],'Asia/Singapore',now)
    async def run():
        async with fake_client() as client:await travel.refresh_one(setup.storage,account,options,*items[0],client,now)
    asyncio.run(run())
    assert setup.storage._conn.execute("SELECT body FROM notification_jobs WHERE kind='travel_leave'").fetchone()[0].startswith('Roadshow')
    data['preferences']['notifications']['showDetails']=False
    assert write(setup,session,data,2).status_code==200
    assert setup.storage._conn.execute("SELECT count(*) FROM notification_jobs WHERE kind LIKE 'travel_%' AND status='pending'").fetchone()[0]==0

def test_stale_route_not_delivered_and_daily_budget_bounds_calls(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    async def run():
        async with fake_client() as client:await travel.refresh_one(setup.storage,account,options,*item,client,now)
        travel.reconcile(setup.storage,account,data,'Asia/Singapore',now+901)
        assert setup.storage._conn.execute("SELECT count(*) FROM notification_jobs WHERE kind LIKE 'travel_%' AND status='pending'").fetchone()[0]==0
        with setup.storage._conn as db:db.execute('UPDATE travel_usage SET requests=5000')
        async with fake_client(handler=lambda req:pytest.fail('Daily limit must prevent Maps request')) as client:
            assert await travel.refresh_one(setup.storage,account,options,*item,client,now+902) is None
    asyncio.run(run())

def test_past_departure_sends_leave_now_once_not_old_preparation(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    start,shift,fp=item
    estimate={'leaveAt':now-1800,'durationSeconds':3600,'shiftStart':start}
    with setup.storage._conn:travel.schedule(setup.storage,{**account,'zone':'Asia/Singapore'},shift,fp,estimate,options,False,now)
    rows=setup.storage._conn.execute("SELECT * FROM notification_jobs WHERE kind LIKE 'travel_%'").fetchall()
    assert len(rows)==1 and rows[0]['kind']=='travel_leave'
    assert rows[0]['fire_at']==now and rows[0]['expires']==now+300
    assert rows[0]['title'].startswith('Leave now')

def test_departure_push_payload_and_delivery_are_account_scoped_and_once(setup,configured,monkeypatch):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    monkeypatch.setattr(push,'configured',lambda environment='production':True)
    monkeypatch.setattr(push,'provider_token',lambda environment:'synthetic-apns')
    delivered=[]
    def receive(request):
        payload=json.loads(request.content);delivered.append(payload)
        assert payload['kind']=='travel_leave'
        assert payload['account_id']==account['account_id']
        assert payload['shift_id']==item[1]['id']
        assert payload['aps']['category']=='HOWMUCH_TRAVEL_LEAVE'
        assert 'Roadshow' not in payload['aps']['alert']['body']
        return httpx.Response(200)
    async def run():
        async with fake_client(duration=item[0]-now-900) as client:
            await travel.refresh_one(setup.storage,account,options,*item,client,now)
        async with httpx.AsyncClient(transport=httpx.MockTransport(receive)) as client:
            assert await push.deliver_due(setup.storage,client,now)==1
            assert await push.deliver_due(setup.storage,client,now+1)==0
    asyncio.run(run());assert len(delivered)==1

def test_worker_checks_routes_for_accounts_with_travel_on(setup,configured):
    session,data,account,options,item,now=prepared(setup);add_device(setup,account,session)
    calls=[]
    def respond(request):
        calls.append(request.url.path)
        if request.url.path=='/v1/token':return httpx.Response(200,json={'accessToken':'synthetic','expiresInSeconds':1800})
        return httpx.Response(200,json={'routes':[{'durationSeconds':1800,'distanceMeters':10000}],'origin':{'name':'A'},'destination':{'name':'B'}})
    async def run():
        async with fake_client(handler=respond) as client:
            return await travel.refresh_due(setup.storage,client,now=max(now,item[0]-5*3600))
    assert asyncio.run(run())==1
    assert any(path!='/v1/token' for path in calls)
