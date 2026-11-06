"""Penny gift codes: only developers make them; anyone can redeem each code once."""
import time

from .test_accounts import setup, login, headers
from howmuch_api import pet_codes


def prepare(setup, monkeypatch):
    setup.client.app.include_router(pet_codes.router, prefix='/v1')
    me, _ = login(setup)
    friend, _ = login(setup, 'apple-user-B')
    monkeypatch.setenv('HOWMUCH_DEVELOPERS', me['account']['id'])
    return me, friend


def test_only_developers_make_and_list_codes(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    assert setup.client.post('/v1/pet/codes', headers=headers(friend), json={'items': ['halo']}).status_code == 403
    assert setup.client.get('/v1/pet/codes', headers=headers(friend)).status_code == 403
    made = setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['halo', 'galaxy', 'halo'], 'max_uses': 2, 'label': 'Launch party'})
    assert made.status_code == 200, made.text
    code = made.json()
    assert code['code'].startswith('PENNY-') and len(code['code']) == 15 and code['items'] == ['halo', 'galaxy']
    assert code['maxUses'] == 2 and code['uses'] == 0 and code['expires'] == 0
    assert [c['code'] for c in setup.client.get('/v1/pet/codes', headers=headers(me)).json()['codes']] == [code['code']]
    assert setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['Not An Item!']}).status_code == 400


def test_redeeming_unlocks_items_once_per_account_until_used_up(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    code = setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['halo', 'fireworks'], 'max_uses': 1, 'code': 'launch 2026'}).json()['code']
    assert code == 'LAUNCH2026'
    assert setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['halo'], 'code': 'LAUNCH2026'}).status_code == 409
    assert setup.client.get('/v1/data', headers=headers(friend)).json()['petUnlocks'] == []
    redeemed = setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': ' launch2026 '})
    assert redeemed.status_code == 200, redeemed.text
    assert redeemed.json() == {'items': ['halo', 'fireworks'], 'unlocked': ['fireworks', 'halo']}
    assert setup.client.get('/v1/data', headers=headers(friend)).json()['petUnlocks'] == ['fireworks', 'halo']
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': 'LAUNCH2026'}).status_code == 409
    assert setup.client.post('/v1/pet/redeem', headers=headers(me), json={'code': 'LAUNCH2026'}).status_code == 410  # used up
    assert setup.client.post('/v1/pet/redeem', headers=headers(me), json={'code': 'NOPE-NOPE'}).status_code == 404
    listed = setup.client.get('/v1/pet/codes', headers=headers(me)).json()['codes'][0]
    assert listed['uses'] == 1


def test_disabled_and_expired_codes_are_refused(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    code = setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['halo'], 'max_uses': 5, 'days': 1}).json()['code']
    assert setup.client.delete('/v1/pet/codes/' + code.lower(), headers=headers(friend)).status_code == 403
    assert setup.client.delete('/v1/pet/codes/' + code.lower(), headers=headers(me)).json()['disabled'] is True
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': code}).status_code == 404
    other = setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['halo'], 'days': 1}).json()['code']
    db = setup.storage._conn
    with db: db.execute('UPDATE pet_codes SET expires=? WHERE code=?', (int(time.time()) - 1, other))
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': other}).status_code == 410


def test_guessing_codes_is_rate_limited(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    statuses = [setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': f'GUESS-{n:04d}'}).status_code for n in range(11)]
    assert statuses[:10] == [404] * 10 and statuses[10] == 429
