"""Synthetic provider checks: no personal credentials or mailbox network access."""
import asyncio
import base64
import time
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from .test_accounts import setup, login, headers, write
from .test_gmail_pipeline import configure, owner, completed_work, mail, PAYER
from howmuch_api import email_providers as providers, gmail_payments as gmail
from howmuch_api.payment_detection import PaymentStore, DBS_SENDER, DBS_SUBJECT


def prepare(setup, monkeypatch):
    configure(monkeypatch)
    setup.client.app.include_router(providers.router, prefix='/v1')
    session, _ = login(setup)
    return session


def microsoft(monkeypatch):
    monkeypatch.setenv('MICROSOFT_CLIENT_ID', 'test-ms-client')
    monkeypatch.setenv('MICROSOFT_CLIENT_SECRET', 'test-ms-secret')
    monkeypatch.setenv('HOWMUCH_MICROSOFT_REDIRECT_URI', 'https://howmuch-ios.test/v1/payment-detection/microsoft/callback')


def test_icloud_consent_validation_encryption_and_account_isolation(setup, monkeypatch):
    a = prepare(setup, monkeypatch); b, _ = login(setup, 'other')
    calls = []
    monkeypatch.setattr(providers, 'check_icloud', lambda *args: calls.append(args))
    path = '/v1/payment-detection/icloud/connect'
    payload = {'email': 'tester@me.com', 'app_password': 'aaaa-bbbb-cccc-dddd', 'consent': True}
    assert setup.client.post(path, json=payload).status_code == 401
    assert setup.client.post(path, headers=headers(a), json={**payload, 'consent': False}).status_code == 400
    assert setup.client.post(path, headers=headers(a), json={**payload, 'email': 'tester@evil.test'}).status_code == 400
    assert setup.client.post(path, headers=headers(a), json={**payload, 'app_password': 'main-account-password'}).status_code == 400
    assert not calls
    response = setup.client.post(path, headers=headers(a), json=payload)
    assert response.status_code == 200, response.text
    assert response.json()['provider'] == 'icloud'
    assert 'aaaa-bbbb' not in response.text
    conn = PaymentStore(setup.storage).connection(owner(setup, a))
    assert gmail.cipher().decrypt(conn['refresh_token'].encode()) == b'aaaa-bbbb-cccc-dddd'
    assert not setup.client.get('/v1/payment-detection', headers=headers(b)).json()['connected']
    assert setup.client.post(path, headers=headers(b), json=payload).status_code == 409
    assert setup.client.patch('/v1/payment-detection', headers=headers(a), json={'auto_enabled': True}).status_code == 400
    assert setup.client.post('/v1/payment-detection/connect', headers=headers(a)).status_code == 409
    assert setup.client.delete('/v1/payment-detection/connection', headers=headers(a)).status_code == 200
    assert PaymentStore(setup.storage).connection(owner(setup,a)) is None


def test_icloud_scan_never_autopays_requires_bank_ack_and_supports_undo(setup, monkeypatch):
    session = prepare(setup, monkeypatch); write(setup, session, completed_work())
    store = PaymentStore(setup.storage); uid = owner(setup, session)
    store.save_connection(uid, 'tester@me.com', gmail.cipher().encrypt(b'aaaa-bbbb-cccc-dddd').decode(), 'icloud')
    from howmuch_api.payment_detection import parse_dbs_alert
    payload = mail()['payload']
    parsed = parse_dbs_alert(DBS_SUBJECT, DBS_SENDER, base64.urlsafe_b64decode(payload['body']['data']).decode())
    monkeypatch.setattr(providers, 'icloud_messages', lambda *args: [('uid1', parsed), ('uid1', parsed)])
    response = setup.client.post('/v1/payment-detection/scan', headers=headers(session))
    assert response.status_code == 200, response.text
    receipt = response.json()['receipts'][0]
    assert len(response.json()['receipts']) == 1
    assert receipt['trusted'] is False and receipt['status'] == 'review'
    assert receipt['candidates'][0]['event'] == 'Roadshow'
    path = f"/v1/payment-detection/receipts/{receipt['id']}"
    assert setup.client.post(path+'/confirm', headers=headers(session), json={'event':'Roadshow'}).status_code == 409
    assert setup.client.post(path+'/confirm', headers=headers(session), json={'event':'Roadshow','acknowledge_unverified':True}).status_code == 200
    assert setup.client.get('/v1/data', headers=headers(session)).json()['data']['shifts'][0]['paid']
    assert setup.client.post(path+'/undo', headers=headers(session)).status_code == 200
    assert not setup.client.get('/v1/data', headers=headers(session)).json()['data']['shifts'][0]['paid']


def test_icloud_disconnect_during_scan_discards_inflight_results(setup, monkeypatch):
    session = prepare(setup, monkeypatch); write(setup,session,completed_work())
    store = PaymentStore(setup.storage); uid = owner(setup,session)
    store.save_connection(uid,'tester@me.com',gmail.cipher().encrypt(b'aaaa-bbbb-cccc-dddd').decode(),'icloud')
    def messages(*args):
        setup.client.delete('/v1/payment-detection/connection',headers=headers(session))
        return [('old',{'payer':PAYER})]
    monkeypatch.setattr(providers,'icloud_messages',messages)
    response = setup.client.post('/v1/payment-detection/scan',headers=headers(session))
    assert response.status_code == 200 and response.json()['receipts'] == [] and not response.json()['connected']


def test_icloud_uses_fixed_tls_readonly_and_peek(setup, monkeypatch):
    seen=[]
    class FakeIMAP:
        def __init__(self,host,port,**kwargs):
            assert host=='imap.mail.me.com' and port==993
            assert kwargs['ssl_context'].verify_mode == 2 and kwargs['timeout']==15
        def login(self,*args): seen.append(('login',args))
        def select(self,folder,readonly): assert folder=='INBOX' and readonly; return 'OK',[]
        def uid(self,command,*args):
            seen.append((command,args))
            if command=='search': return 'OK',[b'123']
            assert 'BODY.PEEK[]' in args[-1]
            return 'OK',[(b'123', b'From: nope@example.test\r\nSubject: harmless\r\n\r\nhello')]
        def logout(self): seen.append(('logout',))
    monkeypatch.setattr(providers.imaplib,'IMAP4_SSL',FakeIMAP)
    assert providers.icloud_messages({'email':'test@me.com'},'synthetic',int(time.time())-86400,int(time.time())) == []
    assert seen[-1] == ('logout',)


def test_microsoft_oauth_pkce_single_use_browser_binding_and_private_tokens(setup, monkeypatch):
    session=prepare(setup,monkeypatch); microsoft(monkeypatch)
    url=setup.client.post('/v1/payment-detection/microsoft/connect',headers=headers(session)).json()['url']
    assert 'Only continue if you started this' in setup.client.get(url,follow_redirects=False).text
    result=setup.client.post(urlparse(url).path,data={'ticket':parse_qs(urlparse(url).query)['ticket'][0]},follow_redirects=False)
    query=parse_qs(urlparse(result.headers['location']).query)
    assert query['code_challenge_method']==['S256'] and 'Mail.Read' in query['scope'][0]
    state=query['state'][0]
    with TestClient(setup.client.app,base_url='https://howmuch-ios.test') as other:
        assert 'could not be verified' in other.get('/v1/payment-detection/microsoft/callback',params={'state':state,'code':'stolen'}).text
    original=httpx.AsyncClient
    def respond(request):
        if request.url.path.endswith('/token'):
            assert 'code_verifier=' in request.content.decode()
            return httpx.Response(200,json={'access_token':'access','refresh_token':'refresh','scope':'Mail.Read User.Read'})
        return httpx.Response(200,json={'mail':'tester@outlook.com'})
    monkeypatch.setattr(providers.httpx,'AsyncClient',lambda **kwargs:original(transport=httpx.MockTransport(respond),**kwargs))
    response=setup.client.get('/v1/payment-detection/microsoft/callback',params={'state':state,'code':'code'})
    assert 'Outlook connected' in response.text
    conn=PaymentStore(setup.storage).connection(owner(setup,session))
    assert conn['provider']=='microsoft' and gmail.cipher().decrypt(conn['refresh_token'].encode())==b'refresh'
    assert 'could not be verified' in setup.client.get('/v1/payment-detection/microsoft/callback',params={'state':state,'code':'replay'}).text
    public=setup.client.get('/v1/payment-detection',headers=headers(session)).json()
    # Gmail stays hidden until Google has verified the app.
    assert public['providers']=={'gmail':False,'icloud':True,'microsoft':True}
    monkeypatch.setenv('HOWMUCH_GMAIL_PUBLIC','1')
    public=setup.client.get('/v1/payment-detection',headers=headers(session)).json()
    assert public['providers']=={'gmail':True,'icloud':True,'microsoft':True}


def test_microsoft_scan_rotates_token_and_does_not_autopay(setup,monkeypatch):
    session=prepare(setup,monkeypatch); microsoft(monkeypatch); write(setup,session,completed_work())
    store=PaymentStore(setup.storage); uid=owner(setup,session)
    store.save_connection(uid,'tester@outlook.com',gmail.cipher().encrypt(b'refresh').decode(),'microsoft')
    original=httpx.AsyncClient
    text=base64.urlsafe_b64decode(mail()['payload']['body']['data']).decode()
    def respond(request):
        if request.url.path.endswith('/token'): return httpx.Response(200,json={'access_token':'access','refresh_token':'rotated'})
        assert request.url.host=='graph.microsoft.com' and '/inbox/messages' in request.url.path
        return httpx.Response(200,json={'value':[{'id':'msg1','subject':DBS_SUBJECT,'from':{'emailAddress':{'address':DBS_SENDER}},'body':{'contentType':'text','content':text}}]})
    monkeypatch.setattr(providers.httpx,'AsyncClient',lambda **kwargs:original(transport=httpx.MockTransport(respond),**kwargs))
    result=setup.client.post('/v1/payment-detection/scan',headers=headers(session))
    assert result.status_code==200,result.text
    assert result.json()['receipts'][0]['trusted'] is False
    assert gmail.cipher().decrypt(store.connection(uid)['refresh_token'].encode())==b'rotated'
    assert not setup.client.get('/v1/data',headers=headers(session)).json()['data']['shifts'][0]['paid']


def test_microsoft_paging_cannot_exfiltrate_access_token(setup,monkeypatch):
    prepare(setup,monkeypatch); calls=[]
    def respond(request):
        calls.append(request)
        return httpx.Response(200,json={'value':[],'@odata.nextLink':'https://evil.test/steal'})
    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            with pytest.raises(ValueError,match='paging'):
                _ = [entry async for entry in providers.microsoft_messages(client,'secret',0,int(time.time()))]
    asyncio.run(check()); assert len(calls)==1


def test_disconnect_while_icloud_login_is_pending_cancels_save(setup,monkeypatch):
    session=prepare(setup,monkeypatch)
    def check(*args):
        setup.client.delete('/v1/payment-detection/connection',headers=headers(session))
    monkeypatch.setattr(providers,'check_icloud',check)
    result=setup.client.post('/v1/payment-detection/icloud/connect',headers=headers(session),json={'email':'tester@me.com','app_password':'aaaa-bbbb-cccc-dddd','consent':True})
    assert result.status_code==409
    assert PaymentStore(setup.storage).connection(owner(setup,session)) is None


def test_legacy_gmail_rows_migrate_without_losing_connection(setup,monkeypatch):
    configure(monkeypatch); session,_=login(setup)
    # Recreate only this synthetic connection table in its old format.
    db=setup.storage._conn
    db.execute('DROP TABLE payment_connections')
    db.execute("CREATE TABLE payment_connections(user_id INTEGER PRIMARY KEY,email TEXT UNIQUE,refresh_token TEXT,connected_at INTEGER NOT NULL DEFAULT 0,last_scan INTEGER NOT NULL DEFAULT 0,auto_since INTEGER NOT NULL DEFAULT 0,error TEXT NOT NULL DEFAULT '')")
    db.execute('INSERT INTO payment_connections(user_id,email,refresh_token) VALUES(?,?,?)',(owner(setup,session),'legacy@example.test','encrypted-legacy'))
    db.commit()
    conn=PaymentStore(setup.storage).connection(owner(setup,session))
    assert conn['provider']=='gmail' and conn['refresh_token']=='encrypted-legacy'
