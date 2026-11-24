"""In-app purchases: only transactions signed through Apple's chain count; coins are credited once, ever."""
import base64
import datetime
import json
import time

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

from .test_accounts import setup, login, headers
from howmuch_api import pet_codes, store

BUNDLE = 'com.howmuch.tracker'  # what the test setup uses as HOWMUCH_APPLE_BUNDLE_ID


def certificate(name, key, issuer_name, issuer_key, marker=None, ca=False, days=30):
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)]))
               .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer_name)]))
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=days))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if marker:
        builder = builder.add_extension(x509.UnrecognizedExtension(x509.ObjectIdentifier(marker), b'\x05\x00'), critical=False)
    return builder.sign(issuer_key, hashes.SHA256())


class Chain:
    """A stand-in for Apple's three certificates, with the same marker extensions."""
    def __init__(self):
        self.root_key, self.mid_key, self.leaf_key = (ec.generate_private_key(ec.SECP256R1()) for _ in range(3))
        self.root = certificate('Test Root', self.root_key, 'Test Root', self.root_key, ca=True)
        self.mid = certificate('Test WWDR', self.mid_key, 'Test Root', self.root_key, marker='1.2.840.113635.100.6.2.1', ca=True)
        self.leaf = certificate('Test Store', self.leaf_key, 'Test WWDR', self.mid_key, marker='1.2.840.113635.100.6.11.1')

    def sign(self, payload, key=None, certs=None):
        der = lambda c: base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode()
        part = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b'=').decode()
        head = part(json.dumps({'alg': 'ES256', 'x5c': [der(c) for c in (certs or (self.leaf, self.mid, self.root))]}).encode())
        body = part(json.dumps(payload).encode())
        r, s = decode_dss_signature((key or self.leaf_key).sign(f'{head}.{body}'.encode(), ec.ECDSA(hashes.SHA256())))
        return f'{head}.{body}.{part(r.to_bytes(32, "big") + s.to_bytes(32, "big"))}'


def transaction(product, transaction_id, account=None, **extra):
    info = {'transactionId': transaction_id, 'originalTransactionId': transaction_id, 'bundleId': BUNDLE,
            'productId': 'com.jialekhoo.howmuch.' + product, 'purchaseDate': int(time.time() * 1000), 'environment': 'Sandbox'}
    if account:
        info['appAccountToken'] = store.account_token(account['account']['id'])
    info.update(extra)
    return info


@pytest.fixture
def chain(monkeypatch):
    made = Chain()
    monkeypatch.setattr(store, 'ROOT', made.root)
    return made


def prepare(setup, monkeypatch):
    setup.client.app.include_router(store.router, prefix='/v1')
    setup.client.app.include_router(pet_codes.router, prefix='/v1')
    monkeypatch.setenv('HOWMUCH_PIONEER_UNTIL', '2000-01-01')  # accounts made now are not early supporters
    return login(setup)[0], login(setup, 'apple-user-B')[0]


def send(setup, session, *jws):
    response = setup.client.post('/v1/store/transactions', headers=headers(session), json={'transactions': list(jws)})
    assert response.status_code == 200, response.text
    return response.json()


def test_the_real_apple_root_is_bundled():
    assert store.ROOT.subject.rfc4514_string().endswith('CN=Apple Root CA - G3')
    assert store.ROOT.fingerprint(hashes.SHA256()).hex().upper().startswith('63343ABFB89A6A03')


def test_coins_are_credited_once_and_never_to_a_second_account(setup, monkeypatch, chain):
    me, other = prepare(setup, monkeypatch)
    jws = chain.sign(transaction('coins.400', '2000000001', me))
    first = send(setup, me, jws)
    assert first['accepted'] == ['2000000001'] and first['helloCoins'] == 400
    assert send(setup, me, jws)['helloCoins'] == 400  # a retry adds nothing
    stolen = send(setup, other, jws)  # someone else's purchase
    assert stolen['accepted'] == [] and stolen['helloCoins'] == 0
    untagged = chain.sign(transaction('coins.150', '2000000002'))  # no account token on it
    assert send(setup, me, untagged)['helloCoins'] == 550
    assert send(setup, other, untagged)['helloCoins'] == 0
    assert setup.client.get('/v1/data', headers=headers(me)).json()['helloCoins'] == 550


def test_coins_stay_spent_after_the_account_is_deleted(setup, monkeypatch, chain):
    me, other = prepare(setup, monkeypatch)
    jws = chain.sign(transaction('coins.1000', '2000000003'))
    assert send(setup, me, jws)['helloCoins'] == 1000
    db = setup.storage._conn
    with db: db.execute('DELETE FROM accounts WHERE account_id=?', (me['account']['id'],))
    assert db.execute('SELECT COUNT(*) FROM store_transactions').fetchone()[0] == 0  # the record goes with the account
    assert send(setup, other, jws)['helloCoins'] == 0  # but the coins can't be claimed again


def test_packs_unlock_their_items_and_refunds_take_them_back(setup, monkeypatch, chain):
    me, _ = prepare(setup, monkeypatch)
    result = send(setup, me, chain.sign(transaction('penny.wonder', '2000000004', me)))
    assert result['petUnlocks'] == sorted(store.PACKS['wonder'])
    assert setup.client.get('/v1/data', headers=headers(me)).json()['petUnlocks'] == sorted(store.PACKS['wonder'])
    refunded = send(setup, me, chain.sign(transaction('penny.wonder', '2000000004', me, revocationDate=int(time.time() * 1000))))
    assert refunded['petUnlocks'] == []


def test_pro_comes_from_a_live_subscription_or_lifetime(setup, monkeypatch, chain):
    me, other = prepare(setup, monkeypatch)
    assert setup.client.get('/v1/data', headers=headers(me)).json()['pro'] is False
    soon = int((time.time() + 3600) * 1000)
    result = send(setup, me, chain.sign(transaction('pro.monthly', '2000000005', me, expiresDate=soon)))
    assert result['pro'] is True and result['proReason'] == 'purchase'
    expired = send(setup, me, chain.sign(transaction('pro.monthly', '2000000005', me, expiresDate=int((time.time() - 60) * 1000))))
    assert expired['pro'] is False
    lifetime = send(setup, other, chain.sign(transaction('pro.lifetime', '2000000006', other)))
    assert lifetime['pro'] is True and setup.client.get('/v1/data', headers=headers(other)).json()['pro'] is True


def test_early_supporters_and_developers_have_pro_without_buying(setup, monkeypatch, chain):
    me, other = prepare(setup, monkeypatch)
    monkeypatch.setenv('HOWMUCH_PIONEER_UNTIL', '2999-01-01')
    data = setup.client.get('/v1/data', headers=headers(me)).json()
    assert data['pro'] is True and data['proReason'] == 'pioneer'
    monkeypatch.setenv('HOWMUCH_PIONEER_UNTIL', '2000-01-01')
    monkeypatch.setenv('HOWMUCH_DEVELOPERS', other['account']['id'])
    assert setup.client.get('/v1/data', headers=headers(other)).json()['proReason'] == 'developer'


def test_forged_or_foreign_transactions_are_refused(setup, monkeypatch, chain):
    me, _ = prepare(setup, monkeypatch)
    impostor = Chain()  # a chain that doesn't lead to the trusted root
    other_app = transaction('coins.150', '2000000010', me, bundleId='com.example.other')
    unknown = transaction('coins.999999', '2000000011', me)
    wrong_key = chain.sign(transaction('coins.150', '2000000012', me), key=chain.mid_key)
    no_marker = chain.sign(transaction('coins.150', '2000000013', me),
                           certs=(certificate('No marker', chain.leaf_key, 'Test WWDR', chain.mid_key), chain.mid, chain.root))
    result = send(setup, me, impostor.sign(transaction('coins.150', '2000000009', me)), chain.sign(other_app), chain.sign(unknown),
                  wrong_key, no_marker, 'not.a.jws')
    assert result['accepted'] == [] and len(result['rejected']) == 6 and result['helloCoins'] == 0
    assert setup.client.post('/v1/store/transactions', json={'transactions': ['x']}).status_code == 401


def test_server_reminders_wait_for_pro(setup, monkeypatch, chain):
    from .test_accounts import document, write
    me, _ = prepare(setup, monkeypatch)
    db = setup.storage._conn
    pending = lambda: {row[0] for row in db.execute("SELECT kind FROM notification_jobs WHERE status='pending'")}
    assert write(setup, me, document()).status_code == 200
    assert pending() == set()  # a new account without Pro gets no server reminders
    send(setup, me, chain.sign(transaction('pro.lifetime', '2000000020', me)))
    assert pending() == {'start', 'end', 'upcoming', 'payment_due'}  # planned as soon as Pro is bought


def test_pay_in_alerts_are_ignored_without_pro(setup, monkeypatch, chain):
    from howmuch_api import pay_in
    setup.client.app.include_router(pay_in.router, prefix='/v1')  # already there in the fixture; harmless
    me, _ = prepare(setup, monkeypatch)
    alert = {'text': 'You have received SGD 120.00 from ACME PTE. LTD.'}
    result = setup.client.post('/v1/payment-detection/notification', headers=headers(me), json=alert).json()
    assert result == {'status': 'ignored', 'message': 'Pay-in tracking is part of HowMuch Pro.'}
    send(setup, me, chain.sign(transaction('pro.lifetime', '2000000030', me)))
    result = setup.client.post('/v1/payment-detection/notification', headers=headers(me), json=alert).json()
    assert result['message'] != 'Pay-in tracking is part of HowMuch Pro.'
