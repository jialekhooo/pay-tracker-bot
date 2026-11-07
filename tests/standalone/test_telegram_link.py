"""Linking a HowMuch account with the Telegram bot, and the bot adding shifts and reading summaries."""
from datetime import date, datetime, timedelta, timezone
from .test_accounts import setup, login, headers, document, write
from howmuch_api import telegram_link

SECRET = 'bot-secret-for-tests'
BOT = {'X-HowMuch-Bot': SECRET}


def prepare(setup, monkeypatch):
    setup.client.app.include_router(telegram_link.router, prefix='/v1')
    monkeypatch.setenv('HOWMUCH_BOT_SECRET', SECRET)
    return login(setup)[0]


def link(setup, session, telegram_user_id=4242):
    made = setup.client.post('/v1/telegram/link', headers=headers(session)).json()
    assert made['url'].startswith('https://t.me/paytracker1_bot?start=link-')
    code = made['url'].split('link-', 1)[1]
    return setup.client.post('/v1/bot/link', headers=BOT, json={'code': code, 'telegramUserId': telegram_user_id, 'username': 'jia'})


def test_linking_needs_the_secret_and_a_fresh_code_used_once(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    assert setup.client.get('/v1/telegram', headers=headers(me)).json()['linked'] is False
    made = setup.client.post('/v1/telegram/link', headers=headers(me)).json()
    code = made['url'].split('link-', 1)[1]
    assert setup.client.post('/v1/bot/link', json={'code': code, 'telegramUserId': 1}).status_code == 403
    assert setup.client.post('/v1/bot/link', headers={'X-HowMuch-Bot': 'wrong'}, json={'code': code, 'telegramUserId': 1}).status_code == 403
    assert setup.client.post('/v1/bot/link', headers=BOT, json={'code': code, 'telegramUserId': 7, 'username': 'jia'}).json()['linked'] is True
    assert setup.client.post('/v1/bot/link', headers=BOT, json={'code': code, 'telegramUserId': 7}).status_code == 404, 'codes work once'
    status = setup.client.get('/v1/telegram', headers=headers(me)).json()
    assert status['linked'] is True and status['username'] == 'jia'
    assert setup.client.post('/v1/bot/status', headers=BOT, json={'telegramUserId': 7}).json()['linked'] is True
    # Unlinking from the app stops the bot from reaching the account.
    assert setup.client.delete('/v1/telegram', headers=headers(me)).json()['linked'] is False
    assert setup.client.post('/v1/bot/summary', headers=BOT, json={'telegramUserId': 7}).status_code == 404


def test_expired_codes_and_bot_routes_without_a_secret_are_refused(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    made = setup.client.post('/v1/telegram/link', headers=headers(me)).json()
    code = made['url'].split('link-', 1)[1]
    with setup.storage._conn as db:
        db.execute('UPDATE telegram_link_codes SET expires=0')
    assert setup.client.post('/v1/bot/link', headers=BOT, json={'code': code, 'telegramUserId': 7}).status_code == 404
    monkeypatch.setenv('HOWMUCH_BOT_SECRET', '')
    assert setup.client.post('/v1/bot/status', headers={'X-HowMuch-Bot': ''}, json={'telegramUserId': 7}).status_code == 403


def test_bot_shifts_use_the_accounts_rates_and_appear_in_the_app(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    data = document()
    data['rules'] = {'rate': 20, 'currency': 'SGD', 'overtimeAfter': 8, 'overtimeMultiplier': 1.5}
    data['preferences'] = {**(data.get('preferences') or {}), 'eventRates': {'wedding gig': 25}, 'defaultBreakMinutes': 30}
    assert write(setup, me, data).status_code == 200
    assert link(setup, me).json()['linked'] is True
    sent = setup.client.post('/v1/bot/shifts', headers=BOT, json={'telegramUserId': 4242, 'shifts': [
        {'event': 'Wedding gig', 'location': 'MBS', 'day': '2026-12-12', 'startMinute': 18 * 60, 'endMinute': 23 * 60},
        {'event': 'Roadshow', 'day': '2026-12-13', 'startMinute': 9 * 60, 'endMinute': 19 * 60, 'breakMinutes': 60},
        {'event': 'Promo', 'day': '2026-12-14', 'startMinute': 10 * 60, 'endMinute': 12 * 60, 'fixedPay': 80},
    ]})
    assert sent.status_code == 200, sent.text
    added = sent.json()['added']
    assert [a['pay'] for a in added] == [112.5, 190, 80]  # event rate less default break; 9 paid hours with overtime past 8h; flat
    saved = setup.client.get('/v1/data', headers=headers(me)).json()
    assert saved['revision'] == 2
    wedding = next(s for s in saved['data']['shifts'] if s['event'] == 'Wedding gig')
    assert wedding['rate'] == 25 and wedding['breakMinutes'] == 30 and wedding['location'] == 'MBS' and wedding['paid'] is False
    assert date.fromisoformat(wedding['paymentDue']).weekday() == 4, 'due on a Friday, like the app'
    promo = next(s for s in saved['data']['shifts'] if s['event'] == 'Promo')
    assert promo['fixedPay'] == 80 and 'overtimeAfter' not in promo
    # The app can keep saving on top of what the bot added.
    assert write(setup, me, saved['data'], 2).status_code == 200


def test_summary_shows_what_is_owed_and_coming_up(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    data = document()
    past = (datetime.now(timezone.utc) - timedelta(days=3)).date().isoformat()
    data['shifts'][0].update(day=past, paid=False, extra=10)
    assert write(setup, me, data).status_code == 200
    link(setup, me)
    soon = (datetime.now(timezone.utc) + timedelta(days=2)).date().isoformat()
    setup.client.post('/v1/bot/shifts', headers=BOT, json={'telegramUserId': 4242, 'shifts': [
        {'event': 'Next gig', 'day': soon, 'startMinute': 600, 'endMinute': 720}]})
    summary = setup.client.post('/v1/bot/summary', headers=BOT, json={'telegramUserId': 4242}).json()
    assert summary['owed'] == [{'currency': 'SGD', 'amount': 130, 'shifts': 1}]
    assert [u['event'] for u in summary['upcoming']] == ['Next gig']


def test_a_telegram_account_links_to_one_howmuch_account_at_a_time(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    friend, _ = login(setup, 'apple-user-B')
    link(setup, me, 99)
    link(setup, friend, 99)
    assert setup.client.get('/v1/telegram', headers=headers(me)).json()['linked'] is False
    assert setup.client.get('/v1/telegram', headers=headers(friend)).json()['linked'] is True


def test_buttons_under_a_logged_shift_undo_it_or_mark_it_paid(setup, monkeypatch):
    me = prepare(setup, monkeypatch)
    assert write(setup, me, document()).status_code == 200
    link(setup, me)
    added = setup.client.post('/v1/bot/shifts', headers=BOT, json={'telegramUserId': 4242, 'shifts': [
        {'event': 'Done gig', 'day': '2026-01-05', 'startMinute': 600, 'endMinute': 720},
        {'event': 'Oops gig', 'day': '2026-01-06', 'startMinute': 600, 'endMinute': 720}]}).json()['added']
    done, oops = added[0]['id'], added[1]['id']
    assert setup.client.post('/v1/bot/shifts/paid', headers=BOT, json={'telegramUserId': 4242, 'ids': [done]}).json() == {'changed': 1}
    assert setup.client.post('/v1/bot/shifts/undo', headers=BOT, json={'telegramUserId': 4242, 'ids': [oops]}).json() == {'changed': 1}
    shifts = {s['event']: s for s in setup.client.get('/v1/data', headers=headers(me)).json()['data']['shifts']}
    assert shifts['Done gig']['paid'] is True and 'Oops gig' not in shifts and 'Roadshow' in shifts
    assert setup.client.post('/v1/bot/shifts/undo', headers=BOT, json={'telegramUserId': 4242, 'ids': [oops]}).status_code == 404
    assert setup.client.post('/v1/bot/shifts/undo', json={'telegramUserId': 4242, 'ids': [done]}).status_code == 403
