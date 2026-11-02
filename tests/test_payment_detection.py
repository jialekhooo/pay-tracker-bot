import asyncio
import base64
import hashlib
import hmac
import json
import time as clock
from datetime import date, datetime, time, timezone
from decimal import Decimal
from urllib.parse import urlencode, urlparse, parse_qs

import httpx
import pytest
from cryptography.fernet import Fernet
from fastapi import FastAPI
from fastapi.testclient import TestClient

from paybot import gmail_payments as gmail
from paybot.payment_detection import DBS_SUBJECT, DBS_SENDER, PaymentStore, gmail_authenticated, parse_dbs_alert
from paybot.storage import Storage
from paybot.webapp import router

BODY = """Transaction Ref: TEST-REF-1

Dear Customer,

You have received SGD 123.45 via FAST transfer on 30 Oct 2026 12:15 SGT

From: REFIX PTE. LTD.
To: Your DBS/POSB account ending 1234
"""
AUTH = [{"name": "Authentication-Results", "value": "mx.google.com; dkim=pass header.i=@dbs.com; dmarc=pass header.from=dbs.com;"}]


@pytest.fixture
def store(tmp_path):
    storage = Storage(tmp_path / 'payments.sqlite3')
    result = PaymentStore(storage)
    yield result
    storage.close()


def shift(store, event='Event', pay='123.45', day=date(2026, 10, 29), user=42, currency='SGD'):
    return store.storage.add_shift(user, day, time(9), time(17), event, Decimal('0'), False, Decimal('8'), Decimal(pay), currency)


def parsed(body=BODY):
    return parse_dbs_alert(DBS_SUBJECT, DBS_SENDER, body)


def enable(store, since=1):
    store.save_connection(42, 'person@gmail.com', 'encrypted')
    with store.db:
        store.db.execute('UPDATE payment_connections SET auto_since=? WHERE user_id=42', (since,))
    store.save_rule(42, 'REFIX PTE. LTD.', 'Event')


def test_parser_exact_user_format_and_commas():
    result = parsed(BODY.replace('123.45', '1,234.56'))
    assert result['amount'] == '1234.56'
    assert result['payer'] == 'REFIX PTE. LTD.'
    assert result['received_at'] == '2026-10-30T12:15:00+08:00'
    assert result['account_last4'] == '1234'
    assert not result['reason']
    assert 'TEST-REF' not in result['receipt_key']


@pytest.mark.parametrize('sender,subject', [('fraud@dbs.com.evil.test', DBS_SUBJECT), ('evil@example.com', DBS_SUBJECT), (DBS_SENDER, 'You sent a transfer'), (DBS_SENDER, 'Re: ' + DBS_SUBJECT)])
def test_only_expected_sender_and_subject(sender, subject):
    assert parse_dbs_alert(subject, sender, BODY) is None


@pytest.mark.parametrize('body', [BODY.replace('SGD 123.45', 'SGD'), BODY.replace('123.45', '0.00'), BODY.replace('30 Oct', '40 Oct'), BODY.replace('From: REFIX PTE. LTD.', ''), BODY.replace('ending 1234', 'ending')])
def test_incomplete_alert_never_autopays(store, body):
    sid = shift(store)
    enable(store)
    receipt = parsed(body)
    assert receipt['reason']
    store.ingest(42, 'mail-1', receipt, True)
    assert not store.storage.get_shift(42, sid).paid


def test_authentication_headers_fail_closed():
    assert gmail_authenticated(AUTH, ['INBOX'])
    for value in ['', 'mx.evil.test; dkim=pass header.i=@dbs.com; dmarc=pass header.from=dbs.com;', 'mx.google.com; dkim=fail header.i=@dbs.com; dmarc=pass header.from=dbs.com;', 'mx.google.com; dkim=pass header.i=@dbs.com.evil.test; dmarc=pass header.from=dbs.com;', 'mx.google.com; dkim=pass header.i=@dbs.com; dmarc=fail header.from=dbs.com;']:
        assert not gmail_authenticated([{'name':'Authentication-Results','value':value}], ['INBOX'])
    assert not gmail_authenticated(AUTH, ['SPAM'])
    assert not gmail_authenticated(AUTH, ['TRASH'])
    assert not gmail_authenticated(AUTH, ['SENT'])


def test_rule_and_exact_total_auto_apply_atomically_with_undo(store):
    first = shift(store, pay='100.00')
    second = shift(store, pay='23.45')
    enable(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    assert store.receipt(42, rid)['status'] == 'auto_paid'
    assert store.storage.get_shift(42, first).paid and store.storage.get_shift(42, second).paid
    assert store.db.execute('SELECT count(*) FROM payment_allocations').fetchone()[0] == 2
    store.undo(42, rid)
    assert not store.storage.get_shift(42, first).paid
    assert not store.storage.get_shift(42, second).paid
    assert store.receipt(42, rid)['status'] == 'undone'
    with pytest.raises(ValueError):
        store.undo(42, rid)
    assert store.db.execute('SELECT action FROM payment_audit ORDER BY id').fetchall()[0][0] == 'auto_paid'


def test_amount_only_match_needs_manual_confirmation(store):
    sid = shift(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    assert store.receipt(42, rid)['status'] == 'review'
    assert not store.storage.get_shift(42, sid).paid
    store.confirm(42, rid, 'Event')
    assert store.storage.get_shift(42, sid).paid
    assert store.receipt(42, rid)['status'] == 'confirmed_paid'
    with pytest.raises(ValueError):
        store.confirm(42, rid, 'Event')


def test_manual_confirmation_rechecks_changed_total(store):
    sid = shift(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    store.storage.update_shift(42, sid, pay='125.00')
    with pytest.raises(ValueError):
        store.confirm(42, rid, 'Event')
    assert not store.storage.get_shift(42, sid).paid


def test_unauthenticated_email_cannot_mark_paid_even_manually(store):
    sid = shift(store)
    enable(store)
    rid = store.ingest(42, 'mail-1', parsed(), False)
    with pytest.raises(ValueError):
        store.confirm(42, rid, 'Event')
    assert store.status(42)['receipts'][0]['candidates'] == []
    assert not store.storage.get_shift(42, sid).paid


def test_multiple_payer_rules_with_same_amount_need_review(store):
    a = shift(store)
    b = shift(store, event='Other event')
    enable(store)
    store.save_rule(42, 'REFIX PTE. LTD.', 'Other event')
    rid = store.ingest(42, 'mail-1', parsed(), True)
    assert store.receipt(42, rid)['status'] == 'review'
    assert not store.storage.get_shift(42, a).paid and not store.storage.get_shift(42, b).paid


def test_cab_reimbursements_can_be_included(store):
    shift(store, pay='100.00')
    store.storage.add_cab_claim(42, date(2026, 10, 29), Decimal('23.45'), '', 'SGD', 'Event')
    enable(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    assert store.receipt(42, rid)['status'] == 'auto_paid'


@pytest.mark.parametrize('kind', ['future', 'partial_paid', 'different_currency', 'partial_amount', 'combined_amount', 'before_enabled'])
def test_uncertain_cases_do_not_auto_apply(store, kind):
    sid = shift(store, day=date(2026, 10, 31) if kind == 'future' else date(2026, 10, 29), currency='USD' if kind == 'different_currency' else 'SGD', pay='200' if kind == 'partial_amount' else '123.45')
    if kind == 'partial_paid':
        other = shift(store, pay='10')
        store.storage.update_shift(42, other, paid=1)
    if kind == 'combined_amount':
        store.storage.update_shift(42, sid, pay='100')
        shift(store, event='Other event', pay='23.45')
    enable(store, since=2_000_000_000 if kind == 'before_enabled' else 1)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    assert store.receipt(42, rid)['status'] == 'review'
    assert not store.storage.get_shift(42, sid).paid


def test_duplicate_message_and_transaction_never_reapply_after_undo(store):
    sid = shift(store)
    enable(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    store.undo(42, rid)
    assert store.ingest(42, 'mail-1', parsed(), True) == rid
    assert store.ingest(42, 'another-gmail-id', parsed(), True) == rid
    assert not store.storage.get_shift(42, sid).paid
    assert len(store.status(42)['receipts']) == 1


def test_undo_changed_shift_is_atomic(store):
    first, second = shift(store, pay='100'), shift(store, pay='23.45')
    enable(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    store.storage.update_shift(42, second, pay='30')
    with pytest.raises(ValueError):
        store.undo(42, rid)
    assert store.storage.get_shift(42, first).paid
    assert store.receipt(42, rid)['status'] == 'auto_paid'


def test_tenant_isolation(store):
    sid = shift(store, user=99)
    shift(store)
    enable(store)
    rid = store.ingest(42, 'mail-1', parsed(), True)
    assert not store.storage.get_shift(99, sid).paid
    assert not store.status(99)['receipts']
    with pytest.raises(ValueError):
        store.undo(99, rid)


def client_for(store):
    app = FastAPI()
    app.state.storage = store.storage
    app.state.bot_token = 'TEST'
    app.include_router(router)
    user = json.dumps({'id':42})
    values = {'auth_date':str(int(clock.time())), 'user':user}
    secret = hmac.new(b'WebAppData', b'TEST', hashlib.sha256).digest()
    values['hash'] = hmac.new(secret, '\n'.join(f'{k}={v}' for k,v in sorted(values.items())).encode(), hashlib.sha256).hexdigest()
    return TestClient(app, base_url='https://app.test'), {'Authorization':'tma '+urlencode(values)}


def configured(monkeypatch):
    monkeypatch.setenv('GOOGLE_CLIENT_ID', 'client')
    monkeypatch.setenv('GOOGLE_CLIENT_SECRET', 'secret')
    monkeypatch.setenv('PAYBOT_GMAIL_TOKEN_KEY', Fernet.generate_key().decode())
    monkeypatch.setenv('PAYBOT_GMAIL_REDIRECT_URI', 'https://app.test/webapp/api/payment-detection/gmail/callback')


def test_api_requires_telegram_auth_and_reports_setup(store, monkeypatch):
    monkeypatch.delenv('GOOGLE_CLIENT_ID', raising=False)
    client, headers = client_for(store)
    assert client.get('/webapp/api/payment-detection').status_code == 401
    result = client.get('/webapp/api/payment-detection', headers=headers).json()
    assert not result['available'] and not result['connected']
    assert client.post('/webapp/api/payment-detection/connect', headers=headers).status_code == 503
    assert client.patch('/webapp/api/payment-detection', json={'auto_enabled':True}, headers=headers).status_code == 400
    assert 'refresh_token' not in json.dumps(result)


def test_oauth_single_use_state_browser_binding_and_rejection(store, monkeypatch):
    configured(monkeypatch)
    client, headers = client_for(store)
    link = client.post('/webapp/api/payment-detection/connect', headers=headers).json()['url']
    response = client.get(link, follow_redirects=False)
    assert response.status_code == 303
    state = parse_qs(urlparse(response.headers['location']).query)['state'][0]
    assert client.get(link).status_code == 200  # expired ticket result page
    other = TestClient(client.app, base_url='https://app.test')
    result = other.get('/webapp/api/payment-detection/gmail/callback', params={'state':state,'code':'stolen'})
    assert 'could not be verified' in result.text
    result = client.get('/webapp/api/payment-detection/gmail/callback', params={'state':state,'error':'access_denied'})
    assert 'was not connected' in result.text
    result = client.get('/webapp/api/payment-detection/gmail/callback', params={'state':state,'code':'replayed'})
    assert 'could not be verified' in result.text


def test_mime_plain_preferred_and_html_stripped():
    def part(mime, content):
        return {'mimeType':mime, 'body':{'data':base64.urlsafe_b64encode(content.encode()).decode().rstrip('=')}}
    assert gmail.message_text({'parts':[part('text/plain', BODY), part('text/html','<p>alternative</p>')]}) == BODY
    text = gmail.message_text(part('text/html','<style>bad</style><p>You have received SGD 123.45 via FAST transfer on 30 Oct 2026 12:15 SGT</p><p>From: REFIX PTE. LTD.</p><p>To: Your DBS/POSB account ending 1234</p>'))
    assert 'bad' not in text
    assert parsed(text)['amount'] == '123.45'


def test_mailbox_scan_paginates_deduplicates_and_encrypts(store, monkeypatch):
    configured(monkeypatch)
    sid = shift(store)
    enable(store)
    token = gmail.cipher().encrypt(b'REFRESH-SECRET').decode()
    with store.db:
        store.db.execute('UPDATE payment_connections SET refresh_token=?,connected_at=1 WHERE user_id=42', (token,))
    assert 'REFRESH-SECRET' not in token
    calls=[]
    def respond(request):
        calls.append(request)
        if request.url.path == '/token':
            return httpx.Response(200, json={'access_token':'access'})
        if request.url.path.endswith('/messages'):
            if request.url.params.get('pageToken'):
                return httpx.Response(200, json={'messages':[{'id':'mail-1'}]})
            return httpx.Response(200, json={'messages':[{'id':'mail-1'}],'nextPageToken':'page-2'})
        return httpx.Response(200, json={'id':'mail-1','labelIds':['INBOX'], 'payload':{'mimeType':'text/plain','headers':[{'name':'Subject','value':DBS_SUBJECT},{'name':'From','value':DBS_SENDER}]+AUTH,'body':{'data':base64.urlsafe_b64encode(BODY.encode()).decode()}}})
    original = httpx.AsyncClient
    monkeypatch.setattr(gmail.httpx, 'AsyncClient', lambda **kwargs: original(transport=httpx.MockTransport(respond), **kwargs))
    asyncio.run(gmail.scan_mailbox(store.storage,42))
    assert store.storage.get_shift(42,sid).paid
    assert len(store.status(42)['receipts']) == 1
    assert store.connection(42)['last_scan'] > 0
    assert sum(r.url.path.endswith('/messages') for r in calls) == 2


def test_mailbox_failure_does_not_advance_checkpoint(store, monkeypatch):
    configured(monkeypatch)
    store.save_connection(42,'person@gmail.com',gmail.cipher().encrypt(b'token').decode())
    original=httpx.AsyncClient
    monkeypatch.setattr(gmail.httpx,'AsyncClient',lambda **kwargs: original(transport=httpx.MockTransport(lambda r:httpx.Response(401,json={'error':'invalid_grant'})), **kwargs))
    with pytest.raises(ValueError):
        asyncio.run(gmail.scan_mailbox(store.storage,42))
    assert store.connection(42)['last_scan'] == 0
    assert store.connection(42)['error']


def test_similar_event_names_do_not_merge(store):
    first = shift(store, event='Event  name', pay='100')
    second = shift(store, event='Event name', pay='23.45')
    store.save_connection(42,'person@gmail.com','encrypted')
    with store.db:
        store.db.execute('UPDATE payment_connections SET auto_since=1 WHERE user_id=42')
    store.save_rule(42,'REFIX PTE. LTD.','Event  name')
    rid=store.ingest(42,'mail-1',parsed(),True)
    assert store.receipt(42,rid)['status']=='review'
    assert not store.storage.get_shift(42,first).paid
    assert not store.storage.get_shift(42,second).paid


def test_no_reference_still_deduplicates_by_receipt_fields(store):
    shift(store)
    body=BODY.replace('TEST-REF-1','')
    result=parsed(body)
    assert not result['reason']
    a=store.ingest(42,'mail-1',result,True)
    b=store.ingest(42,'mail-2',result,True)
    assert a==b


def test_oauth_success_stores_encrypted_token_and_defaults_off(store,monkeypatch):
    configured(monkeypatch)
    client,headers=client_for(store)
    link=client.post('/webapp/api/payment-detection/connect',headers=headers).json()['url']
    response=client.get(link,follow_redirects=False)
    state=parse_qs(urlparse(response.headers['location']).query)['state'][0]
    original=httpx.AsyncClient
    def respond(request):
        if request.url.path=='/token':
            return httpx.Response(200,json={'access_token':'access','refresh_token':'refresh-secret','scope':gmail.SCOPE})
        return httpx.Response(200,json={'emailAddress':'person@gmail.com'})
    monkeypatch.setattr(gmail.httpx,'AsyncClient',lambda **kwargs: original(transport=httpx.MockTransport(respond),**kwargs))
    result=client.get('/webapp/api/payment-detection/gmail/callback',params={'state':state,'code':'CODE'})
    assert 'Gmail connected' in result.text
    conn=store.connection(42)
    assert conn['email']=='person@gmail.com'
    assert not conn['auto_since']
    assert 'refresh-secret' not in conn['refresh_token']
    assert gmail.cipher().decrypt(conn['refresh_token'].encode())==b'refresh-secret'
    status=client.get('/webapp/api/payment-detection',headers=headers).json()
    assert 'refresh_token' not in status and 'auto_since' not in status
    assert client.patch('/webapp/api/payment-detection',headers=headers,json={'auto_enabled':True}).json()['auto_enabled']
    assert client.delete('/webapp/api/payment-detection/connection',headers=headers).status_code==200
    assert store.connection(42) is None


def test_access_log_redacts_oauth_query():
    import logging
    record=logging.LogRecord('uvicorn.access',20,'',1,'%s %s %s %s %s',('client','GET','/webapp/api/payment-detection/gmail/callback?code=SECRET&state=NONCE','1.1',200),None)
    gmail.OAuthAccessFilter().filter(record)
    assert 'SECRET' not in record.getMessage() and 'NONCE' not in record.getMessage()


def test_api_review_confirmation_undo_and_cross_user_access(store):
    shift(store)
    rid=store.ingest(42,'mail-1',parsed(),True)
    client,headers=client_for(store)
    assert client.post(f'/webapp/api/payment-detection/receipts/{rid}/confirm',headers=headers,json={'event':'Event'}).status_code==200
    result=client.post(f'/webapp/api/payment-detection/receipts/{rid}/undo',headers=headers)
    assert result.status_code==200
    assert result.json()['receipts'][0]['status']=='undone'
    assert client.post(f'/webapp/api/payment-detection/receipts/{rid}/undo',headers=headers).status_code==409


def test_manually_unpaid_allocation_cannot_be_reassigned_by_another_alert(store):
    sid=shift(store)
    enable(store)
    rid=store.ingest(42,'mail-1',parsed(),True)
    store.storage.update_shift(42,sid,paid=0)
    second=store.ingest(42,'mail-2',parsed(BODY.replace('TEST-REF-1','TEST-REF-2')),True)
    assert store.receipt(42,second)['status']=='review'
    assert not store.storage.get_shift(42,sid).paid
    assert not store.candidates(42,store.receipt(42,second))


def test_apply_failure_rolls_back_all_shift_flags_and_receipt(store):
    first=shift(store,pay='100')
    second=shift(store,pay='23.45')
    enable(store)
    store.db.execute(f"CREATE TRIGGER reject_second BEFORE UPDATE OF paid ON shifts WHEN NEW.ref={second} BEGIN SELECT RAISE(ABORT, 'test failure'); END")
    import sqlite3
    with pytest.raises(sqlite3.IntegrityError):
        store.ingest(42,'mail-1',parsed(),True)
    assert not store.storage.get_shift(42,first).paid
    assert not store.storage.get_shift(42,second).paid
    assert store.db.execute('SELECT count(*) FROM payment_receipts').fetchone()[0]==0
    assert store.db.execute('SELECT count(*) FROM payment_allocations').fetchone()[0]==0
