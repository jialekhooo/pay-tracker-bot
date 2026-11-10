from datetime import datetime, timedelta, timezone
from email.message import EmailMessage

from howmuch_api import pay_in
from tests.standalone.test_accounts import document, headers, login, setup, write  # noqa: F401 (fixture)


def finished_roadshow(setup):
    """An account with one finished, unpaid SGD 120 Roadshow shift paid by Refix."""
    session, _ = login(setup)
    data = document()
    data['shifts'][0]['day'] = (datetime.now(timezone.utc) - timedelta(days=3)).date().isoformat()
    assert write(setup, session, data).status_code == 200
    assert setup.client.put('/v1/payment-detection/event-payer', json={'event': 'Roadshow', 'payer': 'REFIX PTE. LTD.'},
                            headers=headers(session)).status_code == 200
    return session


def paid(setup, session):
    return setup.client.get('/v1/data', headers=headers(session)).json()['data']['shifts'][0]['paid']


def test_notification_text_is_read_for_amount_and_payer():
    assert pay_in.parse_notification('You have received SGD 1,200.50 from REFIX PTE. LTD. on 5 Nov.') == (pay_in.Decimal('1200.50'), 'REFIX PTE. LTD')
    assert pay_in.parse_notification('PayNow from Jane Tan: S$45 received')[0] == pay_in.Decimal('45')
    assert pay_in.parse_notification('Your OTP is 123456. Do not share.') == (None, '')
    assert pay_in.parse_notification('Card purchase of SGD 5.40 at STARBUCKS') == (None, '')


def test_notification_waits_for_review_until_automatic_marking_is_on(setup):
    session = finished_roadshow(setup)
    result = setup.client.post('/v1/payment-detection/notification', json={'amount': '120', 'payer': 'Refix Pte Ltd'},
                               headers=headers(session)).json()
    assert result['status'] == 'review' and not paid(setup, session)
    status = setup.client.get('/v1/payment-detection', headers=headers(session)).json()
    assert status['receipts'][0]['candidates'][0]['event'] == 'Roadshow'
    assert setup.client.patch('/v1/payment-detection/pay-in', json={'notifications_auto': True},
                              headers=headers(session)).json()['notifications_auto'] is True


def test_automatic_notification_marks_the_matching_event_paid_and_can_be_undone(setup):
    session = finished_roadshow(setup)
    setup.client.patch('/v1/payment-detection/pay-in', json={'notifications_auto': True}, headers=headers(session))
    result = setup.client.post('/v1/payment-detection/notification',
                               json={'text': 'You have received SGD 120.00 from REFIX PTE LTD'}, headers=headers(session)).json()
    assert result['status'] == 'auto_paid' and result['event'] == 'Roadshow'
    assert paid(setup, session)
    receipt = setup.client.get('/v1/payment-detection', headers=headers(session)).json()['receipts'][0]
    assert setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/undo", headers=headers(session)).status_code == 200
    assert not paid(setup, session)


def test_notifications_from_unsaved_payers_or_other_amounts_never_mark_paid(setup):
    session = finished_roadshow(setup)
    setup.client.patch('/v1/payment-detection/pay-in', json={'notifications_auto': True}, headers=headers(session))
    stranger = setup.client.post('/v1/payment-detection/notification', json={'amount': '120', 'payer': 'Someone Else'},
                                 headers=headers(session)).json()
    assert stranger['status'] == 'unknown_payer'
    partial = setup.client.post('/v1/payment-detection/notification', json={'amount': '60', 'payer': 'Refix'},
                                headers=headers(session)).json()
    assert partial['status'] == 'review'
    assert setup.client.post('/v1/payment-detection/notification', json={'text': 'Your OTP is 1234'},
                             headers=headers(session)).json()['status'] == 'ignored'
    assert not paid(setup, session)


def forwarded(address, body, sender='Jia Le <me@example.com>'):
    message = EmailMessage()
    message['From'], message['To'] = sender, address
    message['Subject'] = "Fwd: digibank Alerts - You've received a transfer"
    message.set_content(body)
    return bytes(message)


def test_forwarded_dbs_alert_becomes_a_receipt_to_confirm(setup, monkeypatch):
    monkeypatch.setenv('HOWMUCH_INBOUND_DOMAIN', 'in.howmuch.test')
    monkeypatch.setenv('HOWMUCH_INBOUND_SECRET', 'hook-secret')
    session = finished_roadshow(setup)
    status = setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()
    address = status['forwarding']['address']
    assert status['forwarding']['available'] and address.startswith('pay+') and address.endswith('@in.howmuch.test')
    when = (datetime.now(timezone(timedelta(hours=8))) - timedelta(hours=1)).strftime('%d %b %Y %H:%M')
    body = ("---------- Forwarded message ---------\nFrom: digibank Alerts <ibanking.alert@dbs.com>\n\n"
            f"You have received SGD 120.00 via FAST transfer on {when} SGT.\nFrom: REFIX PTE. LTD.\n"
            "To: Your DBS/POSB account ending 1234\nTransaction Ref: ABC123\n")
    assert setup.client.post('/v1/inbound-email/wrong', content=forwarded(address, body)).status_code == 404
    assert setup.client.post('/v1/inbound-email/hook-secret', content=forwarded(address, body)).json()['status'] == 'review'
    receipt = setup.client.get('/v1/payment-detection', headers=headers(session)).json()['receipts'][0]
    assert receipt['trusted'] is False and receipt['candidates'][0]['event'] == 'Roadshow'
    assert not paid(setup, session)
    confirm = setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/confirm",
                                json={'event': 'Roadshow', 'acknowledge_unverified': True}, headers=headers(session))
    assert confirm.status_code == 200 and paid(setup, session)


def test_forwarding_is_unavailable_without_an_inbound_domain(setup, monkeypatch):
    monkeypatch.delenv('HOWMUCH_INBOUND_DOMAIN', raising=False)
    session = finished_roadshow(setup)
    status = setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()
    assert status['forwarding'] == {'available': False, 'address': None, 'confirmation': None}


def test_gmail_forwarding_confirmation_shows_in_pay_in_tracking(setup, monkeypatch):
    monkeypatch.setenv('HOWMUCH_INBOUND_DOMAIN', 'in.howmuch.test')
    monkeypatch.setenv('HOWMUCH_INBOUND_SECRET', 'hook-secret')
    session = finished_roadshow(setup)
    address = setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()['forwarding']['address']
    message = EmailMessage()
    message['From'], message['To'] = 'Gmail Team <forwarding-noreply@google.com>', address
    message['Subject'] = '(#123456789) Gmail Forwarding Confirmation - Receive Mail from jane@gmail.com'
    message.set_content('jane@gmail.com has requested to automatically forward mail to your email address.\n'
                        'Confirmation code: 123456789\n\nTo allow jane@gmail.com to automatically forward mail to your address, '
                        'please click the link below to confirm the request:\n\n'
                        'https://mail-settings.google.com/mail/vf-%5BANGjdJ8abc%5D-xyz\n')
    assert setup.client.post('/v1/inbound-email/hook-secret', content=bytes(message)).json()['status'] == 'confirmation'
    forwarding = setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()['forwarding']
    assert forwarding['confirmation'] == {'code': '123456789', 'link': 'https://mail-settings.google.com/mail/vf-%5BANGjdJ8abc%5D-xyz',
                                          'account': 'jane@gmail.com'}
    # A look-alike from anyone else is ignored.
    fake = EmailMessage(); fake['From'], fake['To'] = 'someone@example.com', address
    fake['Subject'] = 'Gmail Forwarding Confirmation'; fake.set_content('Confirmation code: 999999999')
    assert setup.client.post('/v1/inbound-email/hook-secret', content=bytes(fake)).json()['status'] == 'ignored'
    assert setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()['forwarding']['confirmation']
    # Mail Gmail auto-forwards proves forwarding is confirmed, so the code goes away.
    forwarded = EmailMessage(); forwarded['From'], forwarded['To'] = 'jane@gmail.com', address
    forwarded['X-Forwarded-For'] = f'jane@gmail.com {address}'; forwarded['Subject'] = 'Hello'; forwarded.set_content('Hi')
    setup.client.post('/v1/inbound-email/hook-secret', content=bytes(forwarded))
    assert setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()['forwarding']['confirmation'] is None
    # It can also be dismissed by hand.
    assert setup.client.post('/v1/inbound-email/hook-secret', content=bytes(message)).json()['status'] == 'confirmation'
    cleared = setup.client.post('/v1/payment-detection/pay-in/forwarding-confirmed', headers=headers(session)).json()
    assert cleared['forwarding']['confirmation'] is None


def test_forwarding_address_can_be_replaced_and_fake_google_confirmations_are_ignored(setup, monkeypatch):
    monkeypatch.setenv('HOWMUCH_INBOUND_DOMAIN', 'in.howmuch.test')
    monkeypatch.setenv('HOWMUCH_INBOUND_SECRET', 'hook-secret')
    session = finished_roadshow(setup)
    old = setup.client.get('/v1/payment-detection/pay-in', headers=headers(session)).json()['forwarding']['address']
    new = setup.client.post('/v1/payment-detection/pay-in/forwarding/rotate', headers=headers(session)).json()['forwarding']['address']
    assert new != old and len(new.split('+')[1].split('@')[0]) == 32
    fake = EmailMessage(); fake['From'], fake['To'] = 'Gmail Team <forwarding-noreply@google.com>', new
    fake['Subject'] = 'Gmail Forwarding Confirmation'
    fake['Authentication-Results'] = 'mx.cloudflare.net; dkim=fail header.d=evil.example'
    fake.set_content('Confirmation code: 999999999')
    assert setup.client.post('/v1/inbound-email/hook-secret', content=bytes(fake)).json()['status'] != 'confirmation'
    assert setup.client.post('/v1/inbound-email/hook-secret', content=bytes(forwarded(old, 'You have received SGD 120.00 from REFIX PTE. LTD.'))).json()['status'] == 'ignored'


def account_with(setup, events):
    """Finished, unpaid shifts (one per entry, oldest first) all paid by REFIX."""
    import copy, uuid
    session, _ = login(setup)
    data = document()
    base = data['shifts'][0]
    data['shifts'] = []
    for index, event in enumerate(events):
        shift = copy.deepcopy(base)
        shift['id'] = str(uuid.uuid4()); shift['event'] = event
        shift['day'] = (datetime.now(timezone.utc) - timedelta(days=10 - index)).date().isoformat()
        data['shifts'].append(shift)
    data['claims'] = []
    assert write(setup, session, data).status_code == 200
    for event in set(events):
        setup.client.put('/v1/payment-detection/event-payer', json={'event': event, 'payer': 'REFIX PTE. LTD.'}, headers=headers(session))
    return session, base['pay']


def latest_receipt(setup, session):
    return setup.client.get('/v1/payment-detection', headers=headers(session)).json()['receipts'][0]


def shifts_paid(setup, session):
    return [s['paid'] for s in setup.client.get('/v1/data', headers=headers(session)).json()['data']['shifts']]


def test_one_transfer_for_two_events_is_offered_as_combined(setup):
    session, pay = account_with(setup, ['Roadshow', 'Gala'])
    setup.client.patch('/v1/payment-detection/pay-in', json={'notifications_auto': True}, headers=headers(session))
    total = str(pay_in.Decimal(str(pay)) * 2)
    assert setup.client.post('/v1/payment-detection/notification', json={'amount': total, 'payer': 'REFIX PTE. LTD.'}, headers=headers(session)).json()['status'] == 'review'
    receipt = latest_receipt(setup, session)
    combined = [c for c in receipt['candidates'] if c['kind'] == 'combined']
    assert combined and set(combined[0]['events']) == {'Roadshow', 'Gala'}
    assert not any(shifts_paid(setup, session))  # never applied automatically
    assert setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/confirm", json={'event': combined[0]['event']}, headers=headers(session)).status_code == 200
    assert all(shifts_paid(setup, session))


def test_a_transfer_for_the_first_shifts_of_an_event_pays_those_shifts(setup):
    session, pay = account_with(setup, ['Roadshow', 'Roadshow', 'Roadshow'])
    total = str(pay_in.Decimal(str(pay)) * 2)
    setup.client.post('/v1/payment-detection/notification', json={'amount': total, 'payer': 'REFIX PTE. LTD.'}, headers=headers(session))
    receipt = latest_receipt(setup, session)
    some = [c for c in receipt['candidates'] if c['kind'] == 'some']
    assert some and some[0]['event'] == 'Roadshow (first 2 unpaid shifts)'
    setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/confirm", json={'event': some[0]['event']}, headers=headers(session))
    assert sorted(shifts_paid(setup, session)) == [False, True, True]


def test_a_short_payment_shows_what_is_missing(setup):
    session, pay = account_with(setup, ['Roadshow'])
    short = str(pay_in.Decimal(str(pay)) - 20)
    setup.client.post('/v1/payment-detection/notification', json={'amount': short, 'payer': 'REFIX PTE. LTD.'}, headers=headers(session))
    receipt = latest_receipt(setup, session)
    assert receipt['candidates'][0]['kind'] == 'short' and receipt['candidates'][0]['shortfall'] == '20.00'
    assert 'Less than' in receipt['reason']
    setup.client.post(f"/v1/payment-detection/receipts/{receipt['id']}/confirm", json={'event': 'Roadshow'}, headers=headers(session))
    assert all(shifts_paid(setup, session))
    assert '20.00 less' in latest_receipt(setup, session)['reason']
