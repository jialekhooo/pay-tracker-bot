"""Friends: codes, requests both sides accept, Penny cards only, and once-a-day hellos with coins."""
from .test_accounts import setup, login, headers, document, write
from howmuch_api import friends

CARD = {'petName': 'Coco', 'ownerName': 'Jia', 'stage': 2, 'level': 5, 'mood': 'happy', 'streakWeeks': 3,
        'outfit': {'hat': 'party-hat', 'background': 'mint'}, 'badges': ['first-shift']}


def prepare(setup):
    setup.client.app.include_router(friends.router, prefix='/v1')
    setup.client.app.include_router(friends.page)
    return login(setup)[0], login(setup, 'apple-user-B')[0]


def make_friends(setup, a, b):
    code_a = setup.client.get('/v1/friends', headers=headers(a)).json()['code']
    code_b = setup.client.get('/v1/friends', headers=headers(b)).json()['code']
    setup.client.post('/v1/friends', headers=headers(a), json={'code': code_b})
    setup.client.post('/v1/friends', headers=headers(b), json={'code': code_a.lower().replace('-', ' ')})
    return code_a, code_b


def test_both_sides_must_agree_before_they_are_friends(setup):
    a, b = prepare(setup)
    mine = setup.client.get('/v1/friends', headers=headers(a)).json()
    assert mine['code'].startswith('PENNY-') and len(mine['code']) == 12 and mine['link'].endswith('/friend/' + mine['code'][6:])
    assert setup.client.post('/v1/friends', headers=headers(a), json={'code': mine['code']}).status_code == 400
    assert setup.client.post('/v1/friends', headers=headers(a), json={'code': 'PENNY-ZZZZZZ'}).status_code == 404
    code_b = setup.client.get('/v1/friends', headers=headers(b)).json()['code']
    sent = setup.client.post('/v1/friends', headers=headers(a), json={'code': code_b}).json()
    assert sent['friends'] == [] and [o['code'] for o in sent['outgoing']] == [code_b]
    incoming = setup.client.get('/v1/friends', headers=headers(b)).json()['incoming']
    assert [i['code'] for i in incoming] == [mine['code']]
    accepted = setup.client.post('/v1/friends', headers=headers(b), json={'code': incoming[0]['code']}).json()
    assert len(accepted['friends']) == 1 and accepted['incoming'] == []
    assert len(setup.client.get('/v1/friends', headers=headers(a)).json()['friends']) == 1


def test_friends_see_only_penny_never_work(setup):
    a, b = prepare(setup)
    assert write(setup, a, document()).status_code == 200
    assert setup.client.put('/v1/friends/card', headers=headers(a), json={'card': CARD}).json() == {'saved': True}
    make_friends(setup, a, b)
    seen = setup.client.get('/v1/friends', headers=headers(b)).json()['friends'][0]
    assert seen['card'] == CARD
    text = str(seen)
    assert 'Roadshow' not in text and 'Marina' not in text and 'pay' not in text.lower()
    bad = {**CARD, 'mood': 'evil'}
    assert setup.client.put('/v1/friends/card', headers=headers(a), json={'card': bad}).status_code == 422
    assert setup.client.put('/v1/friends/card', headers=headers(a), json={'card': {**CARD, 'outfit': {'hat': '<script>'}}}).status_code == 422


def test_hello_once_a_day_with_coins_and_a_notification(setup):
    a, b = prepare(setup)
    setup.client.put('/v1/friends/card', headers=headers(a), json={'card': CARD})
    code_a, code_b = make_friends(setup, a, b)
    said = setup.client.post(f'/v1/friends/{code_b}/hello', headers=headers(a))
    assert said.status_code == 200 and said.json()['friend']['saidHiToday'] is True and said.json()['helloCoins'] == 2
    assert setup.client.post(f'/v1/friends/{code_b}/hello', headers=headers(a)).status_code == 409
    theirs = setup.client.get('/v1/friends', headers=headers(b)).json()
    assert theirs['helloCoins'] == 2 and theirs['friends'][0]['theySaidHiToday'] is True
    assert setup.client.get('/v1/data', headers=headers(b)).json()['helloCoins'] == 2
    job = setup.storage._conn.execute("SELECT title, body FROM notification_jobs WHERE kind='hello'").fetchone()
    assert job['title'] == '👋 Jia said hi!' and 'Coco visited' in job['body']
    # Saying hi back earns both of them more.
    setup.client.post(f'/v1/friends/{code_a}/hello', headers=headers(b))
    assert setup.client.get('/v1/friends', headers=headers(a)).json()['helloCoins'] == 4


def test_only_friends_can_say_hi_and_removing_ends_it(setup):
    a, b = prepare(setup)
    code_b = setup.client.get('/v1/friends', headers=headers(b)).json()['code']
    assert setup.client.post(f'/v1/friends/{code_b}/hello', headers=headers(a)).status_code == 404
    make_friends(setup, a, b)
    assert setup.client.delete(f'/v1/friends/{code_b}', headers=headers(a)).json()['friends'] == []
    assert setup.client.get('/v1/friends', headers=headers(b)).json()['friends'] == []
    assert setup.client.post(f'/v1/friends/{code_b}/hello', headers=headers(a)).status_code == 404


def test_invite_page_opens_the_app(setup):
    a, _ = prepare(setup)
    setup.client.put('/v1/friends/card', headers=headers(a), json={'card': {**CARD, 'ownerName': '<b>Jia</b>'}})
    code = setup.client.get('/v1/friends', headers=headers(a)).json()['code'][6:]
    page = setup.client.get(f'/friend/{code}')
    assert page.status_code == 200 and f'howmuch://friend/{code}' in page.text and '&lt;b&gt;Jia' in page.text
    assert setup.client.get('/friend/ZZZZZZ').status_code == 404
