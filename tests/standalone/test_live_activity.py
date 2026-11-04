import asyncio
import json
from types import SimpleNamespace

import httpx

from howmuch_api import live_activity, push
from tests.standalone.test_accounts import document, headers, login, setup, write  # noqa: F401 (fixture)


def configure(monkeypatch):
    monkeypatch.setattr(push, 'configured', lambda *args: True)
    monkeypatch.setattr(push, 'provider_token', lambda *args: 'provider-test-token')


def run(setup, now, responses=None):
    sent = []

    def transport(request):
        sent.append((str(request.url), dict(request.headers), json.loads(request.content)))
        return httpx.Response((responses or {}).get(len(sent), 200), json={})

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
            return await live_activity.deliver(setup.storage, client=client, now=now)
    count = asyncio.run(go())
    return count, sent


def plan(setup):
    return setup.storage._conn.execute('SELECT * FROM live_plans').fetchone()


def test_card_starts_at_shift_start_and_is_not_repeated(setup, monkeypatch):
    configure(monkeypatch)
    session, _ = login(setup)
    data = document()
    assert write(setup, session, data).status_code == 200
    assert setup.client.put('/v1/devices/live-start', json={'token': 'c' * 64, 'environment': 'production'},
                            headers=headers(session)).json() == {'registered': True}
    row = plan(setup)
    assert run(setup, row['start_at'] - live_activity.LEAD - 60)[0] == 0      # too early
    count, sent = run(setup, row['start_at'] - 60)
    assert count == 1
    url, request_headers, payload = sent[0]
    assert url.endswith('/3/device/' + 'c' * 64)
    assert request_headers['apns-push-type'] == 'liveactivity'
    assert request_headers['apns-topic'].endswith('.push-type.liveactivity')
    aps = payload['aps']
    assert aps['event'] == 'start' and aps['attributes-type'] == 'LiveShiftAttributes'
    assert aps['attributes'] == {'shiftID': data['shifts'][0]['id'].upper(), 'accountID': session['account']['id'].lower()}
    assert aps['content-state']['endTime'] == row['end_at'] and aps['stale-date'] == row['end_at']
    # Privacy default: no job name or venue on the Lock Screen.
    assert aps['content-state']['event'] == 'Shift in progress' and aps['content-state']['location'] == ''
    assert 'Roadshow' not in json.dumps(payload)
    assert run(setup, row['start_at'] + 600)[0] == 0                         # already running


def test_names_shown_when_notification_details_are_allowed(setup, monkeypatch):
    configure(monkeypatch)
    session, _ = login(setup)
    data = document()
    data['preferences']['notifications']['showDetails'] = True
    write(setup, session, data)
    state = json.loads(plan(setup)['state'])
    assert state['event'] == 'Roadshow' and state['location'] == 'Marina Bay'


def test_card_started_by_the_app_is_not_duplicated(setup, monkeypatch):
    configure(monkeypatch)
    session, _ = login(setup)
    data = document()
    write(setup, session, data)
    setup.client.put('/v1/devices/live-start', json={'token': 'c' * 64, 'environment': 'production'}, headers=headers(session))
    row = plan(setup)
    # The app starts its own card 20 minutes before the shift and reports it.
    monkeypatch.setattr(live_activity, 'time', SimpleNamespace(time=lambda: row['start_at'] - 20 * 60))
    assert setup.client.put('/v1/devices/live-activity', json={'token': 'd' * 64, 'environment': 'production',
                            'shiftID': data['shifts'][0]['id']}, headers=headers(session)).status_code == 200
    assert run(setup, row['start_at'])[0] == 0


def test_long_shift_is_renewed_before_eight_hours_and_old_card_ended(setup, monkeypatch):
    configure(monkeypatch)
    session, _ = login(setup)
    data = document()
    data['shifts'][0]['startMinute'], data['shifts'][0]['endMinute'] = 7 * 60, 21 * 60   # 14 hours
    data['shifts'][0]['pay'] = 195
    write(setup, session, data)
    setup.client.put('/v1/devices/live-start', json={'token': 'c' * 64, 'environment': 'production'}, headers=headers(session))
    row = plan(setup)
    assert run(setup, row['start_at'])[0] == 1
    # The phone reports the started card's update token.
    db = setup.storage._conn
    db.execute("UPDATE live_segments SET token=?, environment='production'", ('e' * 64,)); db.commit()
    assert run(setup, row['start_at'] + 6 * 3600)[0] == 0
    count, sent = run(setup, row['start_at'] + live_activity.RENEW + 1)
    assert count == 1
    events = [(url.rsplit('/', 1)[1][:1], payload['aps']['event']) for url, _, payload in sent]
    assert ('c', 'start') in events and ('e', 'end') in events


def test_deleted_shift_ends_its_card_and_logout_stops_starts(setup, monkeypatch):
    configure(monkeypatch)
    session, _ = login(setup)
    data = document()
    write(setup, session, data)
    setup.client.put('/v1/devices/live-start', json={'token': 'c' * 64, 'environment': 'production'}, headers=headers(session))
    setup.client.put('/v1/devices/live-activity', json={'token': 'd' * 64, 'environment': 'production',
                     'shiftID': data['shifts'][0]['id']}, headers=headers(session))
    data['shifts'] = []
    write(setup, session, data, 1)
    count, sent = run(setup, int(live_activity.time.time()) + 60)
    assert count == 0 and [payload['aps']['event'] for _, _, payload in sent] == ['end']
    assert setup.client.post('/v1/auth/logout', headers=headers(session)).status_code == 204
    assert setup.storage._conn.execute('SELECT count(*) FROM live_start_tokens').fetchone()[0] == 0


def test_invalid_start_token_is_dropped_and_other_accounts_are_untouched(setup, monkeypatch):
    configure(monkeypatch)
    a, _ = login(setup)
    b, _ = login(setup, 'apple-user-B')
    write(setup, a, document())
    setup.client.put('/v1/devices/live-start', json={'token': 'c' * 64, 'environment': 'production'}, headers=headers(a))
    setup.client.put('/v1/devices/live-start', json={'token': 'f' * 64, 'environment': 'production'}, headers=headers(b))
    row = plan(setup)
    count, sent = run(setup, row['start_at'], responses={1: 410})
    assert count == 0 and all('f' * 64 not in url for url, _, _ in sent)
    tokens = [r[0] for r in setup.storage._conn.execute('SELECT token FROM live_start_tokens')]
    assert tokens == ['f' * 64]
