"""Validated, revisioned account documents and a stable work-record projection."""
from __future__ import annotations
import base64
import time
import uuid
from datetime import date, time as clock
from decimal import Decimal
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import simplejson as json
from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from .database import limit
from .auth import authenticated_account
from .database import json_response
from .pay import RateConfig

router=APIRouter()
class Rules(BaseModel):
    rate: Decimal=Field(ge=0,le=1000000)
    currency: str=Field(pattern=r'^[A-Z]{3}$')
    overtimeAfter: Decimal | None=Field(default=None,gt=0)
    overtimeMultiplier: Decimal=Field(default=Decimal('1.5'),ge=1,le=100)

class WorkShift(BaseModel):
    id: uuid.UUID
    sourceID: str | None=Field(default=None,max_length=100)
    event: str=Field(min_length=1,max_length=120)
    location: str=Field(default='',max_length=1000)
    day: date
    startMinute: int=Field(ge=0,lt=1440)
    endMinute: int=Field(ge=0,lt=1440)
    breakMinutes: int=Field(ge=0,lt=1440)
    paidBreak: bool
    rate: Decimal=Field(ge=0,le=1000000)
    fixedPay: Decimal | None=Field(default=None,ge=0,le=1000000000)
    pay: Decimal=Field(ge=0,le=1000000000,decimal_places=2)
    currency: str=Field(pattern=r'^[A-Z]{3}$')
    paid: bool
    paymentDue: date | None=None
    overtimeAfter: Decimal | None=Field(default=None,gt=0)
    overtimeMultiplier: Decimal=Field(ge=1,le=100)
    # A bonus, allowance or tip on top of pay (1.1); not part of the pay-rule check.
    extra: Decimal | None=Field(default=None,gt=0,le=1000000,decimal_places=2)
    extraNote: str | None=Field(default=None,max_length=60)
    @property
    def total(self): return self.pay+(self.extra or 0)
    @model_validator(mode='after')
    def valid_work(self):
        duration=(self.endMinute-self.startMinute) % 1440 or 1440
        if self.day.year>=9999 or (self.paymentDue and self.paymentDue.year>=9999):raise ValueError('Date is outside the supported calendar range')
        if self.breakMinutes>=duration or not self.event.strip(): raise ValueError('Invalid event or break')
        hours=Decimal(duration-(0 if self.paidBreak else self.breakMinutes))/60
        threshold=self.overtimeAfter
        computed=(hours*self.rate if threshold is None or hours<=threshold else
                  threshold*self.rate+(hours-threshold)*self.rate*self.overtimeMultiplier)
        expected=(self.fixedPay if self.fixedPay is not None else computed).quantize(Decimal('.01'),rounding='ROUND_HALF_UP')
        if self.pay!=expected: raise ValueError('Payout does not match the saved pay rules')
        return self

class Claim(BaseModel):
    id: uuid.UUID
    shiftID: uuid.UUID
    day: date
    amount: Decimal=Field(gt=0,le=1000000,decimal_places=2)
    note: str=Field(default='',max_length=250)
    category: Literal['cab','food','miscellaneous'] | None=None
    receiptID: uuid.UUID | None=None
    @model_validator(mode='after')
    def category_if_provided(self):
        if 'category' in self.model_fields_set and self.category is None:raise ValueError('Choose a valid claim category')
        return self

class NotificationPreferences(BaseModel):
    enabled: bool=True
    upcoming: bool=True
    starts: bool=True
    ends: bool=True
    paymentDue: bool=True
    leadMinutes: int=Field(default=30,ge=0,le=1440)
    startLeadMinutes: list[int] | None=Field(default=None,max_length=12)

    @model_validator(mode='after')
    def validate_start_reminders(self):
        if self.startLeadMinutes is not None:
            if any(value<0 or value>1440 for value in self.startLeadMinutes):
                raise ValueError('Choose reminder times between 0 and 1440 minutes.')
            self.startLeadMinutes=sorted(set(self.startLeadMinutes),reverse=True)
            if self.starts and not self.startLeadMinutes:
                raise ValueError('Choose at least one start reminder or turn start reminders off.')
        return self

    dayBeforeMinute: int=Field(default=1200,ge=0,lt=1440)
    dueMinute: int=Field(default=540,ge=0,lt=1440)
    showDetails: bool=False

class TravelPreferences(BaseModel):
    enabled: bool=False
    origin: str=Field(default='',max_length=1000)
    mode: Literal['automobile','walking','cycling']='automobile'
    transit: bool | None=None
    arrivalBuffer: int=Field(default=15,ge=0,le=120)
    prepareMinutes: int=Field(default=10,ge=0,le=60)
    trafficUpdates: bool=True
    @model_validator(mode='after')
    def valid_origin(self):
        self.origin=self.origin.strip()
        if self.enabled and not self.origin:raise ValueError('Choose a departure address first.')
        return self

class SavedPayer(BaseModel):
    id: uuid.UUID
    name: str=Field(min_length=1,max_length=120)
    bankNames: list[str]=Field(min_length=1,max_length=20)
    @model_validator(mode='after')
    def validate_payer(self):
        self.name=self.name.strip()
        self.bankNames=[name.strip() for name in self.bankNames]
        if not self.name or any(not name or len(name)>200 for name in self.bankNames): raise ValueError('Enter exact bank payer names of up to 200 characters.')
        return self

class JobTemplate(BaseModel):
    id: uuid.UUID
    name: str=Field(min_length=1,max_length=120)
    shift: WorkShift
    payerID: uuid.UUID | None=None

class PetCloset(BaseModel):
    bought: list[str]=Field(default_factory=list,max_length=200)
    spent: int=Field(default=0,ge=0,le=10_000_000)
    outfit: dict[str,str]=Field(default_factory=dict,max_length=8)

class PetPreferences(BaseModel):
    name: str | None=Field(default=None,max_length=40)
    closet: PetCloset | None=None

class LiveShiftPreferences(BaseModel):
    lockScreen: bool | None=None
    askFinish: bool | None=None
    confirmedFinishes: list[uuid.UUID] | None=Field(default=None,max_length=300)

class WidgetPreviewPreferences(BaseModel):
    showPay: bool | None=None
    showLocation: bool | None=None

# Account-wide settings added in 1.1. Older app versions don't send them, so a save without them keeps them.
ACCOUNT_SETTINGS={'pet':PetPreferences,'liveShift':LiveShiftPreferences,'widgetPreview':WidgetPreviewPreferences}

class Preferences(BaseModel):
    model_config=ConfigDict(extra='allow')
    travel: TravelPreferences | None=None
    jobTemplates: list[JobTemplate] | None=Field(default=None,max_length=100)
    groupUpcomingByEvent: bool | None=None
    displayName: str=Field(default='',max_length=60)
    avatar: str | None=Field(default=None,max_length=2700000)
    defaultBreakMinutes: int=Field(default=0,ge=0,lt=1440)
    defaultBreakPaid: bool=False
    reminderMinute: int=Field(default=1200,ge=0,lt=1440)
    eventRates: dict[str,Decimal]=Field(default_factory=dict,max_length=2000)
    payers: dict[str,str]=Field(default_factory=dict,max_length=2000)
    savedPayers: list[SavedPayer] | None=Field(default=None,max_length=2000)
    eventPayerIDs: dict[str,uuid.UUID] | None=Field(default=None,max_length=2000)
    notifications: NotificationPreferences | None=None
    pet: PetPreferences | None=None
    liveShift: LiveShiftPreferences | None=None
    widgetPreview: WidgetPreviewPreferences | None=None
    blockedDays: list[str] | None=Field(default=None,max_length=400)
    @model_validator(mode='after')
    def validate_preferences(self):
        if self.blockedDays:
            for day in self.blockedDays:
                try: date.fromisoformat(day)
                except ValueError as exc: raise ValueError('Invalid blocked day') from exc
        if self.jobTemplates:
            if len({t.id for t in self.jobTemplates})!=len(self.jobTemplates) or any(not t.name.strip() for t in self.jobTemplates):
                raise ValueError('Invalid job templates')
        if any(not r.is_finite() or r<0 or r>1000000 for r in self.eventRates.values()): raise ValueError('Invalid rate')
        if self.avatar:
            try: decoded=base64.b64decode(self.avatar,validate=True)
            except ValueError as exc: raise ValueError('Invalid profile photo') from exc
            if len(decoded)>2000000: raise ValueError('Profile photo is too large')
        return self

class Document(BaseModel):
    version: int=Field(default=1,ge=1,le=1)
    shifts: list[WorkShift]=Field(default_factory=list,max_length=20000)
    claims: list[Claim]=Field(default_factory=list,max_length=20000)
    expenses: list[Claim] | None=Field(default=None,max_length=20000)
    rules: Rules
    preferences: Preferences | None=None
    @model_validator(mode='after')
    def unique_records(self):
        ids={s.id for s in self.shifts}
        if len(ids)!=len(self.shifts) or len({c.id for c in self.claims})!=len(self.claims): raise ValueError('Duplicate record identifiers')
        if len({c.id for c in self.expenses or []})!=len(self.expenses or []):raise ValueError("Duplicate expense identifiers")
        if any(c.shiftID not in ids for c in self.claims+(self.expenses or [])): raise ValueError('Claim is missing its shift')
        # Legacy personal costs are now reimbursements; keep amounts, notes and receipt links.
        for cost in self.expenses or []:
            prior=next((c for c in self.claims if c.id==cost.id),None)
            if prior:
                if prior==cost:continue
                import hashlib
                cost=cost.model_copy(update={'id':uuid.UUID(hex=hashlib.sha256(('howmuch.payer:reimbursement:'+str(cost.id)).encode()).hexdigest()[:32])})
                if cost in self.claims:continue
            self.claims.append(cost)
        if self.expenses is not None:self.expenses=[]
        if len(self.claims)>20000 or len({c.id for c in self.claims})!=len(self.claims):raise ValueError('Invalid reimbursement identifiers or too many records')
        return self

class DocumentWrite(BaseModel):
    baseRevision: int=Field(ge=0)
    timezone: str=Field(max_length=100)
    data: Document


def empty_document():
    return {'version':1,'shifts':[],'claims':[],'rules':{'rate':Decimal(15),'currency':'SGD','overtimeMultiplier':Decimal('1.5')}}


def read_document(storage, account):
    db=storage._conn
    row=db.execute('SELECT * FROM documents WHERE account_id=?',(account['account_id'],)).fetchone()
    if not row: return {'revision':0,'data':empty_document(),'timezone':'Asia/Singapore'}
    envelope=json.loads(row['body'],use_decimal=True)
    # Payment detection modifies the stable SQL projection. Surface those changes via a new revision.
    paid={r['ios_uuid']:bool(r['paid']) for r in db.execute('SELECT ios_uuid,paid FROM shifts WHERE user_id=?',(account['id'],))}
    from .payers import migrate_document
    changed=migrate_document(envelope['data'],db,account['id'])
    if envelope['data'].get('expenses'):
        before=envelope['data']
        model=Document.model_validate(before)
        envelope['data']=normalize(model.model_dump(mode='python',exclude_none=True))
        with db:mirror_document(storage,account,model,envelope['timezone'],before)
        changed=True
    for shift in envelope['data']['shifts']:
        value=paid.get(shift['id'],shift['paid'])
        if value!=shift['paid']: shift['paid']=value; changed=True
    revision=row['revision']
    if changed:
        revision+=1
        with db:
            db.execute('UPDATE documents SET revision=?,body=?,updated=? WHERE account_id=?',
                       (revision,json.dumps(envelope,use_decimal=True),int(time.time()),account['account_id']))
        from .push import rebuild_jobs
        rebuild_jobs(storage,account,envelope['data'],envelope['timezone'])
    return {'revision':revision,**envelope}


def migrate_renamed_event_rules(db, user, model, previous_data):
    """Move exact payer rules only when stable IDs prove a complete event rename.

    Payment receipts, allocations and their audit snapshots remain immutable.
    Partial renames, merges and deleted shifts never infer a shared rename.
    """
    before={}
    for shift in previous_data.get('shifts',[]):
        before.setdefault(shift['event'].casefold(),[]).append(shift)
    after={str(shift.id):shift for shift in model.shifts}
    aliases={}
    for old,shifts in before.items():
        replacements=[after.get(str(shift['id'])) for shift in shifts]
        if any(shift is None for shift in replacements):continue
        names={shift.event for shift in replacements}
        if len(names)!=1:continue
        name=next(iter(names));new=name.casefold()
        if old==new or new in before or any(shift.event.casefold()==old for shift in model.shifts):continue
        for rule in db.execute('SELECT id,payer,event FROM payment_rules WHERE user_id=?',(user,)).fetchall():
            if rule['event'].casefold()!=old:continue
            duplicate=db.execute('SELECT id FROM payment_rules WHERE user_id=? AND payer=? AND event=?',(user,rule['payer'],name)).fetchone()
            if duplicate:db.execute('DELETE FROM payment_rules WHERE user_id=? AND id=?',(user,rule['id']))
            else:db.execute('UPDATE payment_rules SET event=? WHERE user_id=? AND id=?',(name,user,rule['id']))
        aliases[old]=name.lower()
    return aliases


def mirror_document(storage, account, model: Document, timezone_name, previous_data):
    """Keep immutable row IDs for payment audit/undo; never copy bot rows or IDs."""
    db=storage._conn
    user=account['id']
    renamed=migrate_renamed_event_rules(db,user,model,previous_data)
    existing={r['ios_uuid']:r for r in db.execute('SELECT id,ref,ios_uuid FROM shifts WHERE user_id=?',(user,))}
    next_ref=max((r['ref'] for r in existing.values()),default=0)+1
    wanted=set()
    for shift in model.shifts:
        key=str(shift.id); wanted.add(key)
        duration=(shift.endMinute-shift.startMinute)%1440 or 1440
        hours=Decimal(duration-(0 if shift.paidBreak else shift.breakMinutes))/60
        values=(shift.day.isoformat(),f'{shift.startMinute//60:02}:{shift.startMinute%60:02}',
                f'{shift.endMinute//60:02}:{shift.endMinute%60:02}',shift.event,shift.location,
                str(Decimal(shift.breakMinutes)/60),int(shift.paidBreak),str(hours),str(shift.total),
                int(shift.fixedPay is not None),shift.currency,shift.paymentDue.isoformat() if shift.paymentDue else None,int(shift.paid))
        if key in existing:
            db.execute('UPDATE shifts SET day=?,start_time=?,end_time=?,event=?,location=?,break_hours=?,break_paid=?,hours=?,pay=?,pay_is_fixed=?,currency=?,payment_due=?,paid=? WHERE id=? AND user_id=?',(*values,existing[key]['id'],user))
        else:
            db.execute('INSERT INTO shifts(day,start_time,end_time,event,location,break_hours,break_paid,hours,pay,pay_is_fixed,currency,payment_due,paid,user_id,ref,ios_uuid) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(*values,user,next_ref,key));next_ref+=1
    for key,row in existing.items():
        if key not in wanted: db.execute('DELETE FROM shifts WHERE id=? AND user_id=?',(row['id'],user))
    db.execute('DELETE FROM cab_claims WHERE user_id=?',(user,))
    shift_map={s.id:s for s in model.shifts}
    for claim in model.claims:
        shift=shift_map[claim.shiftID]
        db.execute('INSERT INTO cab_claims(user_id,day,amount,note,currency,event,ios_uuid) VALUES(?,?,?,?,?,?,?)',
                   (user,claim.day.isoformat(),str(claim.amount),claim.note,shift.currency,shift.event,str(claim.id)))
    # Matching uses the account's timezone without a Telegram chat or reminder delivery process.
    offset=int(__import__('datetime').datetime.now(ZoneInfo(timezone_name)).utcoffset().total_seconds()/60)
    db.execute("INSERT INTO reminders(user_id,chat_id,utc_offset_minutes,enabled) VALUES(?,0,?,0) ON CONFLICT(user_id) DO UPDATE SET utc_offset_minutes=excluded.utc_offset_minutes",(user,offset))
    preferences=model.preferences
    if preferences:
        db.execute('UPDATE accounts SET display_name=? WHERE id=?',(preferences.displayName,user))
        from .payment_detection import normalized
        previous_payers=(previous_data.get('preferences') or {}).get('payers') or {}
        comparison=dict(previous_payers)
        for old,new in renamed.items():
            if old in comparison and new not in comparison:comparison[new]=comparison[old]
        for event in previous_payers.keys()-preferences.payers.keys():
            db.execute('DELETE FROM payment_rules WHERE user_id=? AND lower(event)=lower(?)',(user,event))
        for event,payer in preferences.payers.items():
            if comparison.get(event)==payer:continue
            records=[s for s in model.shifts if s.event.casefold()==event.casefold()]
            if records:
                db.execute('DELETE FROM payment_rules WHERE user_id=? AND lower(event)=lower(?)',(user,records[0].event))
                if payer.strip():db.execute('INSERT OR IGNORE INTO payment_rules(user_id,payer,event) VALUES(?,?,?)',(user,normalized(payer),records[0].event))
        # Reconcile only changed assignments/aliases; keep stable rule IDs and
        # untouched legacy rules during unrelated saves and whole-event renames.
        library={p.id:p for p in preferences.savedPayers or []}
        prior_preferences=previous_data.get('preferences') or {}
        prior_library={p['id']:p for p in prior_preferences.get('savedPayers') or []}
        prior_assignments=dict(prior_preferences.get('eventPayerIDs') or {})
        for old,new in renamed.items():
            if old in prior_assignments and new not in prior_assignments: prior_assignments[new]=prior_assignments[old]
        for event,payer_id in (preferences.eventPayerIDs or {}).items():
            records=[shift for shift in model.shifts if shift.event.casefold()==event.casefold()]
            if not records: continue
            desired={normalized(alias) for alias in library[payer_id].bankNames}
            prior_id=prior_assignments.get(event)
            prior_aliases={normalized(alias) for alias in prior_library.get(prior_id,{}).get('bankNames',[])}
            if str(payer_id)==prior_id and desired==prior_aliases: continue
            event_name=records[0].event
            rows=db.execute('SELECT id,payer FROM payment_rules WHERE user_id=? AND lower(event)=lower(?)',(user,event_name)).fetchall()
            for row in rows:
                if normalized(row['payer']) not in desired: db.execute('DELETE FROM payment_rules WHERE user_id=? AND id=?',(user,row['id']))
            existing={normalized(row['payer']) for row in rows}
            for alias in desired-existing:
                db.execute('INSERT OR IGNORE INTO payment_rules(user_id,payer,event) VALUES(?,?,?)',(user,alias,event_name))


@router.get('/data')
async def get_data(request: Request, authorization: str | None=Header(default=None)):
    account=authenticated_account(request,authorization)
    result=read_document(request.app.state.storage,account)
    from .push import configured
    from .auth import developer, pioneer
    from .pet_codes import unlocks
    return json_response({**result,'pushReady':configured(),'pioneer':pioneer(account),'developer':developer(account),'petUnlocks':unlocks(request.app.state.storage._conn,account['account_id'])})


@router.put('/data')
async def put_data(request: Request, authorization: str | None=Header(default=None)):
    account=authenticated_account(request,authorization)
    limit(request,'save',maximum=240,key=account['account_id'])  # full saves validate and mirror the whole document
    chunks=[];size=0
    async for chunk in request.stream():
        size+=len(chunk)
        if size>10000000:raise HTTPException(413,'Choose a smaller archive or import fewer records.')
        chunks.append(chunk)
    raw=b''.join(chunks)
    try:
        payload=DocumentWrite.model_validate(json.loads(raw,use_decimal=True))
        ZoneInfo(payload.timezone)
    except (ValidationError,ValueError,ZoneInfoNotFoundError) as exc:
        raise HTTPException(422,'Check the work records, dates, pay values and timezone.') from exc
    storage=request.app.state.storage
    current=read_document(storage,account)
    if current['revision']!=payload.baseRevision:
        return json_response({'detail':'Your account changed on another device. Review the versions before syncing.','current':current},409)
    # Older clients omit new fields; preserve category/preference metadata on unrelated saves.
    prior_claims={str(claim['id']):claim for claim in current['data'].get('claims',[])}
    for claim in payload.data.claims:
        prior=prior_claims.get(str(claim.id))
        if ('category' not in claim.model_fields_set and prior and str(claim.shiftID)==str(prior['shiftID'])
                and prior.get('category') is not None):claim.category=prior['category']
    # Preserve photo references and personal costs when older clients omit new fields.
    for claim in payload.data.claims:
        prior=prior_claims.get(str(claim.id))
        if 'receiptID' not in claim.model_fields_set and prior and str(claim.shiftID)==str(prior['shiftID']):
            claim.receiptID=uuid.UUID(prior['receiptID']) if prior.get('receiptID') else None
    # Shift extras (1.1) survive a save from an older app that doesn't know them.
    prior_shifts={str(s['id']):s for s in current['data'].get('shifts',[])}
    for shift in payload.data.shifts:
        prior=prior_shifts.get(str(shift.id))
        if prior and 'extra' not in shift.model_fields_set and prior.get('extra') is not None:
            shift.extra=Decimal(str(prior['extra'])); shift.extraNote=prior.get('extraNote')
    if 'expenses' not in payload.data.model_fields_set:
        remaining={str(s.id) for s in payload.data.shifts}
        payload.data.expenses=[Claim.model_validate(c) for c in current['data'].get('expenses',[]) if str(c['shiftID']) in remaining] or None
    preferences=payload.data.preferences
    prior_preferences=current['data'].get('preferences') or {}
    if preferences and 'groupUpcomingByEvent' not in preferences.model_fields_set and prior_preferences.get('groupUpcomingByEvent') is not None:
        preferences.groupUpcomingByEvent=prior_preferences['groupUpcomingByEvent']
    if preferences and 'jobTemplates' not in preferences.model_fields_set and prior_preferences.get('jobTemplates') is not None:
        preferences.jobTemplates=[JobTemplate.model_validate(t) for t in prior_preferences['jobTemplates']]
    for key,model in ACCOUNT_SETTINGS.items():
        if preferences and key not in preferences.model_fields_set and prior_preferences.get(key) is not None:
            setattr(preferences,key,model.model_validate(prior_preferences[key]))
    # Blocked days (1.1) survive a save from an older app that doesn't know them.
    if preferences and 'blockedDays' not in preferences.model_fields_set and prior_preferences.get('blockedDays') is not None:
        preferences.blockedDays=list(prior_preferences['blockedDays'])
    if preferences:
        from .payers import prepare
        try: prepare(preferences,prior_preferences)
        except ValueError as exc: raise HTTPException(400,str(exc)) from None
    # Older app versions omit the new list when saving unrelated preferences.
    # Preserve it unless their legacy single-time value was explicitly changed.
    previous=(current['data'].get('preferences') or {}).get('notifications') or {}
    options=payload.data.preferences.notifications if payload.data.preferences else None
    if (options and 'startLeadMinutes' not in options.model_fields_set
            and previous.get('startLeadMinutes') and options.leadMinutes==previous.get('leadMinutes',30)):
        options.startLeadMinutes=previous['startLeadMinutes']
    revision,envelope=commit_document(storage,account,payload.data,payload.timezone,current)
    from .push import configured
    from .auth import developer, pioneer
    from .pet_codes import unlocks
    return json_response({'revision':revision,**envelope,'pushReady':configured(),'pioneer':pioneer(account),'developer':developer(account),'petUnlocks':unlocks(storage._conn,account['account_id'])})


def commit_document(storage, account, model: Document, timezone_name, current):
    """Save a validated document as the next revision: mirror it for payment matching, then refresh
    reminders and unused receipts. Used by app saves and by shifts added from Telegram."""
    # Pydantic validates, while simplejson preserves Decimal values as exact JSON numbers for Swift.
    data=normalize(model.model_dump(mode='python',exclude_none=True))
    envelope={'data':data,'timezone':timezone_name}
    db=storage._conn
    revision=current['revision']+1
    with db:
        # PaymentStore schema initialization occurs before this transaction, not during record writes.
        mirror_document(storage,account,model,timezone_name,current['data'])
        db.execute('INSERT INTO documents VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,body=excluded.body,updated=excluded.updated',
                   (account['account_id'],revision,json.dumps(envelope,use_decimal=True),int(time.time())))
    from .push import rebuild_jobs
    rebuild_jobs(storage,account,data,timezone_name)
    from .receipts import collect_unused
    collect_unused(db,account['account_id'],data)
    return revision,envelope


def normalize(value):
    if isinstance(value,(uuid.UUID,date)): return str(value)
    if isinstance(value,dict): return {k:normalize(v) for k,v in value.items()}
    if isinstance(value,list): return [normalize(v) for v in value]
    return value
