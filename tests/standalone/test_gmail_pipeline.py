"""Exercise the standalone Apple-account API with synthetic, authenticated DBS mail."""
import base64
import json
import time
from datetime import datetime,timedelta,timezone
from urllib.parse import parse_qs,urlparse
import httpx
import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from .test_accounts import setup,login,headers,document,write
from howmuch_api import gmail_payments as gmail
from howmuch_api.payment_detection import PaymentStore,DBS_SENDER,DBS_SUBJECT

SGT=timezone(timedelta(hours=8))
PAYER='REFIX PTE. LTD.'
AUTH={'name':'Authentication-Results','value':'mx.google.com; dkim=pass header.i=@dbs.com; dmarc=pass header.from=dbs.com;'}


def configure(monkeypatch):
    monkeypatch.setenv('GOOGLE_CLIENT_ID','synthetic-client')
    monkeypatch.setenv('GOOGLE_CLIENT_SECRET','synthetic-secret')
    monkeypatch.setenv('HOWMUCH_GMAIL_TOKEN_KEY',Fernet.generate_key().decode())
    monkeypatch.setenv('HOWMUCH_GMAIL_REDIRECT_URI','https://howmuch-ios.test/v1/payment-detection/gmail/callback')


def owner(setup,session):
    return setup.storage._conn.execute('SELECT id FROM accounts WHERE account_id=?',(session['account']['id'],)).fetchone()[0]


def completed_work():
    data=document();data['shifts'][0]['day']=(datetime.now(SGT)-timedelta(days=2)).date().isoformat()
    data['shifts'][0]['paymentDue']=(datetime.now(SGT)+timedelta(days=5)).date().isoformat()
    data['preferences']['payers']={'roadshow':PAYER}
    return data


def connect_fixture(setup,session,auto=False):
    store=PaymentStore(setup.storage);uid=owner(setup,session)
    store.save_connection(uid,'synthetic@example.test',gmail.cipher().encrypt(b'synthetic-refresh').decode())
    if auto:
        with store.db:store.db.execute('UPDATE payment_connections SET auto_since=? WHERE user_id=?',(int(time.time())-3600,uid))
    return store,uid


def mail(amount='120.00',trusted=True,payer=PAYER,ref='AUDIT-1'):
    when=datetime.now(SGT).strftime('%d %b %Y %H:%M')
    body=f'Transaction Ref: {ref}\nDear Customer,\nYou have received SGD {amount} via FAST transfer on {when} SGT\nFrom: {payer}\nTo: Your DBS/POSB account ending 1234\n'
    return {'id':'synthetic-1','labelIds':['INBOX'],'payload':{'mimeType':'text/plain',
        'headers':[{'name':'Subject','value':DBS_SUBJECT},{'name':'From','value':DBS_SENDER}]+([AUTH] if trusted else []),
        'body':{'data':base64.urlsafe_b64encode(body.encode()).decode()}}}


def install_mail(monkeypatch,payload,call_log=None):
    original=httpx.AsyncClient
    def respond(request):
        if call_log is not None:call_log.append(request)
        if request.url.path=='/token':return httpx.Response(200,json={'access_token':'synthetic-access'})
        if request.url.path.endswith('/messages'):
            assert 'from:'+DBS_SENDER in request.url.params['q']
            assert '"'+PAYER.lower()+'"' in request.url.params['q']
            return httpx.Response(200,json={'messages':[{'id':'synthetic-1'},{'id':'synthetic-1'}]})
        return httpx.Response(200,json=payload)
    monkeypatch.setattr(gmail.httpx,'AsyncClient',lambda **kwargs:original(transport=httpx.MockTransport(respond),**kwargs))


def test_missing_live_configuration_is_explicit_and_never_reads_mail(setup,monkeypatch):
    monkeypatch.delenv('GOOGLE_CLIENT_ID',raising=False);monkeypatch.delenv('GOOGLE_CLIENT_SECRET',raising=False)
    session,_=login(setup)
    response=setup.client.get('/v1/payment-detection',headers=headers(session))
    assert response.status_code==200 and response.json()['available'] is False
    assert setup.client.get('/v1/payment-detection').status_code==401
    assert setup.client.post('/v1/payment-detection/connect',headers=headers(session)).status_code==503


def test_standalone_oauth_is_single_use_browser_bound_and_encrypted(setup,monkeypatch):
    configure(monkeypatch);session,_=login(setup)
    start=setup.client.post('/v1/payment-detection/connect',headers=headers(session)).json()['url']
    redirect=setup.client.get(start,follow_redirects=False)
    query=parse_qs(urlparse(redirect.headers['location']).query)
    assert query['scope']==[gmail.SCOPE] and query['client_id']==['synthetic-client']
    state=query['state'][0]
    with TestClient(setup.client.app,base_url='https://howmuch-ios.test') as stranger:
        assert 'could not be verified' in stranger.get('/v1/payment-detection/gmail/callback',params={'state':state,'code':'stolen'}).text
    original=httpx.AsyncClient
    def respond(request):
        if request.url.path=='/token':return httpx.Response(200,json={'access_token':'synthetic-access','refresh_token':'synthetic-refresh','scope':gmail.SCOPE})
        return httpx.Response(200,json={'emailAddress':'synthetic@example.test'})
    monkeypatch.setattr(gmail.httpx,'AsyncClient',lambda **kwargs:original(transport=httpx.MockTransport(respond),**kwargs))
    result=setup.client.get('/v1/payment-detection/gmail/callback',params={'state':state,'code':'synthetic-code'})
    assert 'Gmail connected' in result.text
    store=PaymentStore(setup.storage);conn=store.connection(owner(setup,session))
    assert conn['refresh_token']!='synthetic-refresh'
    assert gmail.cipher().decrypt(conn['refresh_token'].encode())==b'synthetic-refresh'
    assert not conn['auto_since']
    public=setup.client.get('/v1/payment-detection',headers=headers(session)).text
    assert 'synthetic-refresh' not in public and 'access_token' not in public
    assert 'could not be verified' in setup.client.get('/v1/payment-detection/gmail/callback',params={'state':state,'code':'replayed'}).text


def test_real_scan_path_auto_marks_only_owner_and_reconciles_native_document(setup,monkeypatch):
    configure(monkeypatch);a,_=login(setup);b,_=login(setup,'apple-user-B')
    assert write(setup,a,completed_work()).status_code==200
    assert write(setup,b,completed_work()).status_code==200
    store,uid=connect_fixture(setup,a,auto=True)
    calls=[];install_mail(monkeypatch,mail(),calls)
    response=setup.client.post('/v1/payment-detection/scan',headers=headers(a))
    assert response.status_code==200,response.text
    receipt=response.json()['receipts'][0]
    assert receipt['status']=='auto_paid' and receipt['amount']=='120.00'
    assert len(response.json()['receipts'])==1
    assert setup.client.get('/v1/data',headers=headers(a)).json()['data']['shifts'][0]['paid']
    assert not setup.client.get('/v1/data',headers=headers(b)).json()['data']['shifts'][0]['paid']
    assert setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/undo",headers=headers(b)).status_code==409
    assert setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/undo",headers=headers(a)).status_code==200
    assert not setup.client.get('/v1/data',headers=headers(a)).json()['data']['shifts'][0]['paid']
    again=setup.client.post('/v1/payment-detection/scan',headers=headers(a)).json()
    assert len(again['receipts'])==1 and again['receipts'][0]['status']=='undone'
    assert store.connection(uid)['last_scan']>0


@pytest.mark.parametrize('amount,trusted,payer,receipt_count',[('50.00',True,PAYER,1),('120.00',False,PAYER,1),('120.00',True,'UNRELATED PERSON',0)])
def test_partial_unverified_or_unrelated_alerts_never_auto_mark(setup,monkeypatch,amount,trusted,payer,receipt_count):
    configure(monkeypatch);session,_=login(setup);assert write(setup,session,completed_work()).status_code==200
    connect_fixture(setup,session,auto=True);install_mail(monkeypatch,mail(amount,trusted,payer))
    result=setup.client.post('/v1/payment-detection/scan',headers=headers(session))
    assert result.status_code==200,result.text
    assert len(result.json()['receipts'])==receipt_count
    assert not setup.client.get('/v1/data',headers=headers(session)).json()['data']['shifts'][0]['paid']
    if receipt_count:assert result.json()['receipts'][0]['status']=='review'


def test_manual_receipt_confirmation_undo_and_dismiss_use_account_api(setup,monkeypatch):
    configure(monkeypatch);session,_=login(setup);assert write(setup,session,completed_work()).status_code==200
    connect_fixture(setup,session);install_mail(monkeypatch,mail())
    receipt=setup.client.post('/v1/payment-detection/scan',headers=headers(session)).json()['receipts'][0]
    assert receipt['status']=='review' and receipt['candidates'][0]['event']=='Roadshow'
    path=f"/v1/payment-detection/receipts/{receipt['id']}"
    assert setup.client.post(path+'/confirm',headers=headers(session),json={'event':'Roadshow'}).status_code==200
    assert setup.client.get('/v1/data',headers=headers(session)).json()['data']['shifts'][0]['paid']
    assert setup.client.post(path+'/undo',headers=headers(session)).status_code==200
    assert not setup.client.get('/v1/data',headers=headers(session)).json()['data']['shifts'][0]['paid']
    assert setup.client.post(path+'/dismiss',headers=headers(session)).status_code==409 # applied audit cannot be hidden
