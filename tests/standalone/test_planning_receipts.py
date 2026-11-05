import copy
import uuid
from cryptography.fernet import Fernet
import pytest
from howmuch_api import receipts,travel
from .test_accounts import setup,login,headers,document,write

@pytest.fixture
def receipt_app(setup,monkeypatch):
    monkeypatch.setenv('HOWMUCH_ENCRYPTION_KEY',Fernet.generate_key().decode())
    setup.client.app.include_router(receipts.router,prefix='/v1')
    return setup

def jpeg(width=20,height=20):
    return b'\xff\xd8\xff\xc0\x00\x11\x08'+height.to_bytes(2,'big')+width.to_bytes(2,'big')+b'\x03'+b'\x01\x11\x00'*3+b'\xff\xd9'

def test_receipts_are_encrypted_private_immutable_and_cascade_on_account_delete(receipt_app):
    s=receipt_app;owner,_=login(s);other,_=login(s,'other');key=str(uuid.uuid4());body=jpeg()
    assert s.client.put('/v1/receipts/'+key,content=body,headers=headers(owner)).status_code==200
    stored=s.storage._conn.execute('SELECT * FROM receipt_photos').fetchone()
    assert bytes(stored['encrypted'])!=body and stored['byte_count']==len(body)
    response=s.client.get('/v1/receipts/'+key,headers=headers(owner))
    assert response.content==body and response.headers['cache-control']=='no-store'
    assert 'attachment;' in response.headers['content-disposition']
    assert s.client.get('/v1/receipts/'+key,headers=headers(other)).status_code==404
    assert s.client.get('/v1/receipts/'+key).status_code==401
    assert s.client.put('/v1/receipts/'+key,content=body,headers=headers(owner)).status_code==409
    with s.storage._conn as db:db.execute('DELETE FROM accounts WHERE account_id=?',(owner['account']['id'],))
    assert s.storage._conn.execute('SELECT count(*) FROM receipt_photos').fetchone()[0]==0

@pytest.mark.parametrize('body',[b'<html>not a receipt</html>',b'\xff\xd8\xff\xd9',jpeg(2000,20),b'\xff\xd8\xff\xc0\x00\x01\xff\xd9'])
def test_receipts_reject_invalid_images(receipt_app,body):
    session,_=login(receipt_app)
    assert receipt_app.client.put('/v1/receipts/'+str(uuid.uuid4()),content=body,headers=headers(session)).status_code==422

def test_receipt_size_and_storage_cap_are_bounded(receipt_app):
    s=receipt_app;session,_=login(s)
    assert s.client.put('/v1/receipts/'+str(uuid.uuid4()),content=b'x'*750001,headers=headers(session)).status_code==413
    with s.storage._conn as db:db.execute('INSERT INTO receipt_photos VALUES(?,?,?,?,?)',(session['account']['id'],str(uuid.uuid4()),b'placeholder',100000000,1))
    assert s.client.put('/v1/receipts/'+str(uuid.uuid4()),content=jpeg(),headers=headers(session)).status_code==413

def test_templates_expenses_and_receipt_refs_roundtrip_and_survive_old_client_save(setup):
    session,_=login(setup);data=document();shift=data['shifts'][0]
    claim={'id':str(uuid.uuid4()),'shiftID':shift['id'],'day':shift['day'],'amount':12.5,'note':'Meal','category':'food','receiptID':str(uuid.uuid4())}
    data['claims']=[claim];data['expenses']=[{**claim,'id':str(uuid.uuid4()),'amount':4,'note':'Not reimbursed'}]
    data['preferences']['jobTemplates']=[{'id':str(uuid.uuid4()),'name':'Usual','shift':shift}]
    first=write(setup,session,data);assert first.status_code==200,first.text
    old=copy.deepcopy(first.json()['data']);old.pop('expenses');old['preferences'].pop('jobTemplates');old['claims'][0].pop('receiptID')
    result=write(setup,session,old,1);assert result.status_code==200,result.text
    assert not result.json()['data'].get('expenses')
    assert result.json()['data']['claims'][1]['amount']==4
    assert result.json()['data']['claims'][0]['receiptID']==claim['receiptID']
    assert result.json()['data']['preferences']['jobTemplates'][0]['name']=='Usual'
    explicit=result.json()['data'];explicit['claims'][0]['receiptID']=None;explicit['expenses']=[];explicit['preferences']['jobTemplates']=[]
    result=write(setup,session,explicit,2)
    assert result.status_code==200
    assert not result.json()['data']['claims'][0].get('receiptID') and result.json()['data']['expenses']==[]

def test_old_client_deleting_shift_does_not_leave_unowned_expenses(setup):
    session,_=login(setup);data=document();s=data['shifts'][0]
    data['expenses']=[{'id':str(uuid.uuid4()),'shiftID':s['id'],'day':s['day'],'amount':1,'note':''}]
    assert write(setup,session,data).status_code==200
    data.pop('expenses');data['shifts']=[]
    assert write(setup,session,data,1).status_code==200
    assert not setup.client.get('/v1/data',headers=headers(session)).json()['data'].get('expenses')

def test_public_transport_never_creates_automobile_server_forecasts(setup):
    data=document();data['preferences']['travel']={'enabled':True,'origin':'A','mode':'automobile','transit':True}
    options,items=travel.candidates(data,'Asia/Singapore',0)
    assert options.transit is True and items==[]

def test_expenses_require_owned_shift_and_unique_identifiers(setup):
    session,_=login(setup);data=document();s=data['shifts'][0]
    cost={'id':str(uuid.uuid4()),'shiftID':str(uuid.uuid4()),'day':s['day'],'amount':1,'note':''}
    data['expenses']=[cost];assert write(setup,session,data).status_code==422
    cost['shiftID']=s['id'];data['expenses']=[cost,cost];assert write(setup,session,data).status_code==422


def test_legacy_reimbursement_get_migrates_once_with_receipt_and_collision(setup):
    import simplejson
    from howmuch_api.documents import normalize
    session,_=login(setup);data=document();shift=data['shifts'][0]
    claim={'id':str(uuid.uuid4()),'shiftID':shift['id'],'day':shift['day'],'amount':10,'note':'Cab','category':'cab','receiptID':str(uuid.uuid4())}
    data['claims']=[claim]
    first=write(setup,session,data);assert first.status_code==200
    body=first.json();body.pop('revision');body.pop('pushReady',None)
    body['data']['expenses']=[{**claim,'amount':12,'note':'Food','category':'food'}]
    with setup.storage._conn:
        setup.storage._conn.execute('UPDATE documents SET body=?',(simplejson.dumps(body),))
    response=setup.client.get('/v1/data',headers=headers(session));assert response.status_code==200,response.text
    saved=response.json();assert saved['revision']==2
    assert len(saved['data']['claims'])==2 and saved['data']['expenses']==[]
    converted=saved['data']['claims'][1]
    assert converted['receiptID']==claim['receiptID'] and converted['amount']==12 and converted['id']!=claim['id']
    assert setup.client.get('/v1/data',headers=headers(session)).json()==saved
    assert setup.storage._conn.execute('SELECT count(*) FROM cab_claims').fetchone()[0]==2


def test_unused_receipt_photos_are_deleted_after_a_grace_period(setup):
    from howmuch_api.receipts import collect_unused
    db=setup.storage._conn
    with db:
        db.execute("INSERT INTO accounts(account_id,apple_sub,email,display_name,created) VALUES('acct-gc','sub-gc',NULL,'',0)")
        db.execute("INSERT INTO receipt_photos VALUES('acct-gc','kept',x'00',1,0)")
        db.execute("INSERT INTO receipt_photos VALUES('acct-gc','old',x'00',1,0)")
        db.execute("INSERT INTO receipt_photos VALUES('acct-gc','fresh',x'00',1,strftime('%s','now'))")
    assert collect_unused(db,'acct-gc',{'claims':[{'receiptID':'kept'}]})==1
    left={r[0] for r in db.execute("SELECT receipt_id FROM receipt_photos WHERE account_id='acct-gc'")}
    assert left=={'kept','fresh'}
