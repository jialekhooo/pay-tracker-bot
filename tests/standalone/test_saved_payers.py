import copy
import uuid
from .test_accounts import setup,login,headers,document,write
from howmuch_api.payment_detection import PaymentStore


def payer(name='Friendly Company',banks=None):
    return {'id':str(uuid.uuid4()),'name':name,'bankNames':banks or ['BANK COMPANY LTD','BANK COMPANY SERVICES']}


def test_saved_company_aliases_update_every_assigned_event_and_isolate_accounts(setup):
    a,_=login(setup); b,_=login(setup,'other')
    data=document(); second=copy.deepcopy(data['shifts'][0]);second['id']=str(uuid.uuid4());second['event']='Second event';data['shifts'].append(second)
    company=payer(); data['preferences'].update(savedPayers=[company],eventPayerIDs={'roadshow':company['id'],'second event':company['id']})
    result=write(setup,a,data);assert result.status_code==200,result.text
    data=result.json()['data']; store=PaymentStore(setup.storage)
    uid=store.db.execute('SELECT id FROM accounts WHERE account_id=?',(a['account']['id'],)).fetchone()[0]
    assert {(r['event'],r['payer']) for r in store.rules(uid)} == {(e,n.lower()) for e in ['Roadshow','Second event'] for n in company['bankNames']}
    data['preferences']['savedPayers'][0]['bankNames']=['BANK COMPANY LTD','UPDATED NAME']
    result=write(setup,a,data,1); assert result.status_code==200,result.text
    assert {r['payer'] for r in store.rules(uid)}=={'bank company ltd','updated name'}
    assert not setup.client.get('/v1/payment-detection',headers=headers(b)).json()['rules']
    # An older client saves an unrelated profile change without new fields.
    old=result.json()['data']; old['preferences'].pop('savedPayers');old['preferences'].pop('eventPayerIDs');old['preferences']['displayName']='Updated profile'
    result=write(setup,a,old,2);assert result.status_code==200,result.text
    assert result.json()['data']['preferences']['savedPayers'][0]['bankNames']==['BANK COMPANY LTD','UPDATED NAME']
    assert {r['payer'] for r in store.rules(uid)}=={'bank company ltd','updated name'}


def test_unassign_and_delete_company_do_not_recreate_legacy_rules(setup):
    a,_=login(setup);data=document(); company=payer()
    data['preferences'].update(savedPayers=[company],eventPayerIDs={'roadshow':company['id']})
    result=write(setup,a,data);assert result.status_code==200
    data=result.json()['data'];data['preferences'].update(savedPayers=[],eventPayerIDs={},payers={'roadshow':''})
    result=write(setup,a,data,1);assert result.status_code==200,result.text
    assert result.json()['data']['preferences']['savedPayers']==[]
    assert setup.client.get('/v1/payment-detection',headers=headers(a)).json()['rules']==[]


def test_duplicate_alias_and_dangling_assignment_are_rejected(setup):
    a,_=login(setup);data=document();first=payer();second=payer('Another',[' bank  company ltd '])
    data['preferences'].update(savedPayers=[first,second],eventPayerIDs={})
    assert write(setup,a,data).status_code==400
    data['preferences'].update(savedPayers=[first],eventPayerIDs={'roadshow':str(uuid.uuid4())})
    assert write(setup,a,data).status_code==400


def test_legacy_sql_only_rules_migrate_on_first_account_read(setup):
    a,_=login(setup);data=document();write(setup,a,data)
    db=setup.storage._conn;uid=db.execute('SELECT id FROM accounts WHERE account_id=?',(a['account']['id'],)).fetchone()[0]
    db.execute('INSERT INTO payment_rules(user_id,payer,event) VALUES(?,?,?)',(uid,'EXACT COMPANY','Roadshow'))
    db.execute('INSERT INTO payment_rules(user_id,payer,event) VALUES(?,?,?)',(uid,'SECOND BANK NAME','Roadshow'));db.commit()
    result=setup.client.get('/v1/data',headers=headers(a)).json()
    assert result['revision']==2
    prefs=result['data']['preferences'];assert len(prefs['savedPayers'])==1
    assert set(prefs['savedPayers'][0]['bankNames'])=={'EXACT COMPANY','SECOND BANK NAME'}
    assert prefs['eventPayerIDs']['roadshow']==prefs['savedPayers'][0]['id']
    assert setup.client.get('/v1/data',headers=headers(a)).json()['revision']==2
