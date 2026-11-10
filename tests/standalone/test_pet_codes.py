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
    assert redeemed.json() == {'items': ['halo', 'fireworks'], 'coins': 0, 'unlocked': ['fireworks', 'halo'], 'helloCoins': 0}
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


def test_only_revoked_codes_can_be_deleted_and_redeemers_keep_their_items(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    code = setup.client.post('/v1/pet/codes', headers=headers(me), json={'items': ['halo'], 'max_uses': 5}).json()['code']
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': code}).status_code == 200
    assert setup.client.delete(f'/v1/pet/codes/{code}/forever', headers=headers(me)).status_code == 409
    assert setup.client.delete('/v1/pet/codes/' + code, headers=headers(me)).json()['disabled'] is True
    assert setup.client.delete(f'/v1/pet/codes/{code}/forever', headers=headers(friend)).status_code == 403
    assert setup.client.delete(f'/v1/pet/codes/{code}/forever', headers=headers(me)).json() == {'deleted': code}
    assert setup.client.get('/v1/pet/codes', headers=headers(me)).json()['codes'] == []
    assert setup.client.delete(f'/v1/pet/codes/{code}/forever', headers=headers(me)).status_code == 404
    assert setup.client.get('/v1/data', headers=headers(friend)).json()['petUnlocks'] == ['halo']


def test_coin_codes_add_spendable_coins_once_and_stay_after_the_code_is_deleted(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    code = setup.client.post('/v1/pet/codes', headers=headers(me), json={'coins': 150, 'max_uses': 5}).json()
    assert code['coins'] == 150 and code['items'] == []
    redeemed = setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': code['code']})
    assert redeemed.status_code == 200, redeemed.text
    assert redeemed.json() == {'items': [], 'coins': 150, 'unlocked': [], 'helloCoins': 150}
    assert setup.client.get('/v1/data', headers=headers(friend)).json()['helloCoins'] == 150
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': code['code']}).status_code == 409
    assert setup.client.get('/v1/data', headers=headers(friend)).json()['helloCoins'] == 150
    assert setup.client.get('/v1/data', headers=headers(me)).json()['helloCoins'] == 0
    both = setup.client.post('/v1/pet/codes', headers=headers(me), json={'coins': 50, 'items': ['halo']}).json()['code']
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': both}).json()['helloCoins'] == 200
    setup.client.delete('/v1/pet/codes/' + both, headers=headers(me))
    assert setup.client.delete('/v1/pet/codes/' + both + '/forever', headers=headers(me)).status_code == 200
    assert setup.client.get('/v1/data', headers=headers(friend)).json()['helloCoins'] == 200


def test_coin_codes_need_a_developer_and_a_sensible_amount(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    assert setup.client.post('/v1/pet/codes', headers=headers(friend), json={'coins': 100}).status_code == 403
    assert setup.client.post('/v1/pet/codes', headers=headers(me), json={}).status_code == 400
    assert setup.client.post('/v1/pet/codes', headers=headers(me), json={'coins': 0, 'items': []}).status_code == 400
    assert setup.client.post('/v1/pet/codes', headers=headers(me), json={'coins': -5, 'items': ['halo']}).status_code == 422
    assert setup.client.post('/v1/pet/codes', headers=headers(me), json={'coins': pet_codes.MAX_COINS + 1}).status_code == 422


def test_codes_redeemed_before_coin_codes_survive_the_upgrade(setup, monkeypatch):
    me, friend = prepare(setup, monkeypatch)
    db = setup.storage._conn
    db.executescript("""
    DROP TABLE IF EXISTS pet_codes; DROP TABLE IF EXISTS pet_redemptions;
    CREATE TABLE pet_codes (code TEXT PRIMARY KEY, items TEXT NOT NULL, label TEXT NOT NULL DEFAULT '', max_uses INTEGER NOT NULL,
     uses INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL DEFAULT 0, created_by TEXT NOT NULL, created INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE pet_redemptions (account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE, code TEXT NOT NULL,
     items TEXT NOT NULL, redeemed INTEGER NOT NULL, PRIMARY KEY(account_id, code));
    """)
    with db:
        db.execute('INSERT INTO pet_redemptions VALUES(?,?,?,?)', (friend['account']['id'], 'OLDCODE', '["halo"]', 1))
    data = setup.client.get('/v1/data', headers=headers(friend)).json()
    assert data['petUnlocks'] == ['halo'] and data['helloCoins'] == 0
    made = setup.client.post('/v1/pet/codes', headers=headers(me), json={'coins': 75}).json()['code']
    assert setup.client.post('/v1/pet/redeem', headers=headers(friend), json={'code': made}).json()['helloCoins'] == 75
