"""The personal schedule bot's key: read, add, move, mark paid and remove shifts of one account."""
from datetime import date, datetime, timedelta, timezone
from .test_accounts import setup, login, headers, document, write
from .test_telegram_link import BOT, SECRET, link
from howmuch_api import schedule_link, telegram_link


def prepare(setup, monkeypatch, telegram_user_id=4242):
    setup.client.app.include_router(telegram_link.router, prefix='/v1')
    setup.client.app.include_router(schedule_link.router, prefix='/v1')
    monkeypatch.setenv('HOWMUCH_BOT_SECRET', SECRET)
    me = login(setup)[0]
    data = document()
    data['rules'] = {'rate': 20, 'currency': 'SGD', 'overtimeMultiplier': 1.5}
    data['preferences'] = {**(data.get('preferences') or {}), 'eventRates': {'wedding gig': 25}}
    assert write(setup, me, data).status_code == 200
    assert link(setup, me, telegram_user_id).json()['linked'] is True
    return me


def key_for(setup, telegram_user_id=4242):
    r = setup.client.post('/v1/bot/schedule-link', headers=BOT, json={'telegramUserId': telegram_user_id})
    assert r.status_code == 200, r.text
    return {'Authorization': 'Bearer ' + r.json()['key']}


def test_add_from_text_list_move_pay_and_remove(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    key = key_for(setup)
    day = (datetime.now(timezone.utc) + timedelta(days=5)).date()
    text = f"Wedding gig {day.strftime('%d/%m')} 6pm-11pm @ MBS\nRoadshow {day.strftime('%d/%m')} 9am-1pm 15/h"
    r = setup.client.post('/v1/schedule/shifts', headers=key, json={'text': text})
    assert r.status_code == 200, r.text
    added = r.json()['added']
    wedding = next(a for a in added if a['event'] == 'Wedding gig')
    road = next(a for a in added if a['event'] == 'Roadshow')
    assert (wedding['pay'], wedding['location'], wedding['startMinute']) == (125, 'MBS', 18 * 60)  # event rate 25/h
    assert road['pay'] == 60 and wedding['start'].startswith(day.isoformat())

    ours = {wedding['id'], road['id']}
    listed = [s for s in setup.client.get('/v1/schedule/shifts', headers=key).json()['shifts'] if s['id'] in ours]
    assert [s['event'] for s in listed] == ['Roadshow', 'Wedding gig']  # soonest first

    moved = setup.client.patch(f"/v1/schedule/shifts/{wedding['id']}", headers=key,
                               json={'startMinute': 19 * 60, 'endMinute': 23 * 60 + 30})
    assert moved.status_code == 200, moved.text
    assert moved.json()['shift']['pay'] == 112.5 and moved.json()['shift']['id'] == wedding['id']
    saved = setup.client.get('/v1/data', headers=headers(me)).json()['data']['shifts']
    kept = next(s for s in saved if s['id'] == wedding['id'])
    assert kept['startMinute'] == 19 * 60 and kept['rate'] == 25 and kept['location'] == 'MBS'

    assert setup.client.post('/v1/schedule/shifts/paid', headers=key, json={'ids': [road['id']]}).json()['changed'] == 1
    assert next(s for s in setup.client.get('/v1/schedule/shifts', headers=key).json()['shifts']
                if s['id'] == road['id'])['paid'] is True
    assert setup.client.post('/v1/schedule/shifts/undo', headers=key, json={'ids': [road['id']]}).json()['changed'] == 1
    left = {s['id'] for s in setup.client.get('/v1/schedule/shifts', headers=key).json()['shifts']}
    assert wedding['id'] in left and road['id'] not in left


def test_bad_text_and_keys_are_refused(setup, monkeypatch):
    prepare(setup, monkeypatch)
    key = key_for(setup)
    r = setup.client.post('/v1/schedule/shifts', headers=key, json={'text': 'hello there'})
    assert r.status_code == 422 and r.json()['detail']['problems']
    for bad in ({}, {'Authorization': 'Bearer nope'}, {'Authorization': 'Bearer hms_' + 'x' * 40}):
        assert setup.client.get('/v1/schedule/shifts', headers=bad).status_code == 401
    # The key is not an app session, and an app session is not a key.
    assert setup.client.get('/v1/data', headers=key).status_code == 401


def test_new_key_replaces_old_and_revoke_and_unlinked_bot(setup, monkeypatch):
    prepare(setup, monkeypatch)
    old = key_for(setup)
    new = key_for(setup)
    assert setup.client.get('/v1/schedule/shifts', headers=old).status_code == 401
    assert setup.client.get('/v1/schedule/shifts', headers=new).status_code == 200
    r = setup.client.post('/v1/bot/schedule-link', headers=BOT, json={'telegramUserId': 4242, 'revoke': True})
    assert r.json()['revoked'] is True and setup.client.get('/v1/schedule/shifts', headers=new).status_code == 401
    # Needs the bot's secret, and a Telegram account linked to the app.
    assert setup.client.post('/v1/bot/schedule-link', json={'telegramUserId': 4242}).status_code == 403
    assert setup.client.post('/v1/bot/schedule-link', headers=BOT, json={'telegramUserId': 999}).status_code == 404


def test_cannot_touch_another_accounts_shifts(setup, monkeypatch):
    prepare(setup, monkeypatch)
    key = key_for(setup)
    r = setup.client.patch('/v1/schedule/shifts/00000000-0000-4000-8000-000000000000', headers=key, json={'startMinute': 60})
    assert r.status_code == 404
    assert setup.client.post('/v1/schedule/shifts/undo', headers=key,
                             json={'ids': ['00000000-0000-4000-8000-000000000000']}).status_code == 404


def test_add_structured_shift_overnight_and_flat(setup, monkeypatch):
    prepare(setup, monkeypatch)
    key = key_for(setup)
    day = (datetime.now(timezone.utc) + timedelta(days=3)).date().isoformat()
    r = setup.client.post('/v1/schedule/shifts', headers=key, json={'shifts': [
        {'event': 'Wedding gig', 'location': 'MBS', 'day': day, 'startMinute': 22 * 60, 'endMinute': 2 * 60},
        {'event': 'Promo', 'day': day, 'startMinute': 10 * 60, 'endMinute': 14 * 60, 'fixedPay': 80}]})
    assert r.status_code == 200, r.text
    wedding, promo = r.json()['added']
    assert wedding['pay'] == 100 and wedding['end'] > wedding['start']  # 4h overnight at the event's 25/h
    assert promo['pay'] == 80
    assert setup.client.post('/v1/schedule/shifts', headers=key, json={}).status_code == 422
