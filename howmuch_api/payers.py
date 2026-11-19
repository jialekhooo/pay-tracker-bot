"""Saved payer migration and exact-name projection, independent of mailbox credentials."""
import hashlib
import uuid


def key(value):
    return ' '.join(value.lower().split())


def prepare(preferences, previous):
    from .documents import SavedPayer
    if 'payers' not in preferences.model_fields_set:
        preferences.payers=dict(previous.get('payers') or {})
    legacy_client = 'eventPayerIDs' not in preferences.model_fields_set
    if 'savedPayers' not in preferences.model_fields_set and previous.get('savedPayers') is not None:
        preferences.savedPayers = [SavedPayer.model_validate(p) for p in previous['savedPayers']]
    if legacy_client and previous.get('eventPayerIDs') is not None:
        preferences.eventPayerIDs = {event:uuid.UUID(value) for event,value in previous['eventPayerIDs'].items()}
    library = list(preferences.savedPayers or [])
    assignments = dict(preferences.eventPayerIDs or {})
    if legacy_client:
        assignments={event:id for event,id in assignments.items() if event in preferences.payers}
    for event, bank in sorted(preferences.payers.items()):
        if legacy_client and bank != (previous.get('payers') or {}).get(event):
            assignments.pop(event, None)
        if event in assignments or not key(bank):
            continue
        payer = next((p for p in library if any(key(alias)==key(bank) for alias in p.bankNames)), None)
        if payer is None:
            payer = SavedPayer(id=uuid.UUID(hex=hashlib.sha256(('howmuch.payer:'+key(bank)).encode()).hexdigest()[:32]),name=bank.strip()[:120],bankNames=[bank.strip()])
            library.append(payer)
        assignments[event] = payer.id
    if library or preferences.savedPayers is not None: preferences.savedPayers = library
    if assignments or preferences.eventPayerIDs is not None: preferences.eventPayerIDs = assignments
    ids = {p.id for p in library}
    if any(not event or len(event)>120 or id not in ids for event,id in assignments.items()):
        raise ValueError('Choose an existing saved payer for this event.')
    for template in preferences.jobTemplates or []:
        if template.payerID and template.payerID not in ids:
            if 'jobTemplates' not in preferences.model_fields_set: template.payerID = None
            else: raise ValueError('Choose an existing saved payer for this template.')
    names = [key(p.name) for p in library]
    aliases = [key(a) for p in library for a in p.bankNames]
    if len(library)>2000 or len(ids)!=len(library) or len(set(names))!=len(names) or len(set(aliases))!=len(aliases):
        raise ValueError('Use unique company names and bank payer names across your saved payers.')
    for event,id in assignments.items():
        preferences.payers[event] = next(p.bankNames[0] for p in library if p.id==id)


def migrate_document(data, db, user):
    """One-time import also includes rules created in older Payment detection screens."""
    from .documents import Preferences, normalize
    previous=data.get('preferences') or {}
    if previous.get('savedPayers') is not None: return False
    groups={}
    display={}
    for event,bank in (previous.get('payers') or {}).items():
        if key(bank): groups.setdefault(event.lower(),set()).add(key(bank)); display[key(bank)]=bank.strip()
    for row in db.execute('SELECT event,payer FROM payment_rules WHERE user_id=? ORDER BY id',(user,)):
        groups.setdefault(row['event'].lower(),set()).add(key(row['payer']))
        display.setdefault(key(row['payer']),row['payer'].strip())
    if not groups: return False
    # Shared aliases join the same company, retaining every previous event rule.
    components=[]
    for aliases in groups.values():
        merged=set(aliases)
        rest=[]
        for component in components:
            if merged & component: merged |= component
            else: rest.append(component)
        # Repeat to close a transitive join exposed by another overlapping component.
        while any(merged & component for component in rest):
            overlap=[component for component in rest if merged & component]
            rest=[component for component in rest if not merged & component]
            for component in overlap: merged |= component
        components=rest+[merged]
    library=[]; assignments={}
    for aliases in sorted(components,key=lambda a:sorted(a)):
        first=sorted(aliases)[0]
        id=str(uuid.UUID(hex=hashlib.sha256(('howmuch.payer:'+first).encode()).hexdigest()[:32]))
        library.append({'id':id,'name':display[first][:120],'bankNames':[display[a] for a in sorted(aliases)]})
        for event,names in groups.items():
            if names & aliases: assignments[event]=id
    candidate={**previous,'savedPayers':library,'eventPayerIDs':assignments}
    model=Preferences.model_validate(candidate)
    prepare(model,{})
    data['preferences']=normalize(model.model_dump(mode='python',exclude_none=True))
    return True
