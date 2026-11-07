"""Apple-verified identities and revocable, rotated account sessions."""
from __future__ import annotations
import asyncio
import hashlib
import hmac
import os
import secrets
import time
import uuid
import httpx
import jwt
from cryptography.fernet import Fernet
from fastapi import APIRouter, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field
from .database import digest, json_response, limit

router=APIRouter(prefix='/auth')
ISSUER='https://appleid.apple.com'
APPLE_KEYS=jwt.PyJWKClient(ISSUER+'/auth/keys',cache_keys=True,lifespan=3600,timeout=10)
ACCESS_SECONDS=3600
REFRESH_GRACE_SECONDS=120
REFRESH_SECONDS=30*86400


def bundle_id(): return os.environ.get('HOWMUCH_APPLE_BUNDLE_ID','com.jialekhoo.howmuch')


def verify_identity(token: str, nonce_hash: str) -> dict:
    try:
        # No algorithm negotiation, arbitrary JWKS URL, email-based identity or unverified decode.
        key=APPLE_KEYS.get_signing_key_from_jwt(token).key
        claims=jwt.decode(token,key,algorithms=['RS256'],audience=bundle_id(),issuer=ISSUER,
                          options={'require':['iss','aud','sub','exp','iat','nonce']},leeway=15)
        if not isinstance(claims['sub'],str) or not claims['sub'] or len(claims['sub'])>255:
            raise ValueError('Invalid subject')
        if not isinstance(claims['nonce'],str) or not hmac.compare_digest(claims['nonce'],nonce_hash):
            raise ValueError('Nonce mismatch')
        return claims
    except (jwt.PyJWTError,ValueError,TypeError,KeyError) as exc:
        raise HTTPException(401,'Apple sign-in could not be verified. Please sign in again.') from exc


def apple_service_configured():
    return all(os.environ.get(k) for k in ('HOWMUCH_APPLE_TEAM_ID','HOWMUCH_APPLE_KEY_ID','HOWMUCH_APPLE_PRIVATE_KEY','HOWMUCH_ENCRYPTION_KEY'))


def apple_client_secret():
    now=int(time.time())
    return jwt.encode({'iss':os.environ['HOWMUCH_APPLE_TEAM_ID'],'iat':now,'exp':now+600,
                       'aud':ISSUER,'sub':bundle_id()},os.environ['HOWMUCH_APPLE_PRIVATE_KEY'].replace('\\n','\n'),
                      algorithm='ES256',headers={'kid':os.environ['HOWMUCH_APPLE_KEY_ID']})


def encryption(): return Fernet(os.environ['HOWMUCH_ENCRYPTION_KEY'].encode())


async def exchange_apple_code(code: str):
    if not apple_service_configured(): return None
    async with httpx.AsyncClient(timeout=15) as client:
        response=await client.post(ISSUER+'/auth/token',data={'client_id':bundle_id(),'client_secret':apple_client_secret(),
                                  'code':code,'grant_type':'authorization_code'})
        response.raise_for_status()
        return response.json().get('refresh_token')


def authenticated_account(request: Request, authorization: str | None):
    scheme,_,token=(authorization or '').partition(' ')
    if scheme.lower()!='bearer' or not token or len(token)>256:
        raise HTTPException(401,'Sign in with Apple to use your account.')
    row=request.app.state.storage._conn.execute(
        'SELECT a.*,s.session_id,s.device_id FROM accounts a JOIN auth_sessions s ON s.account_id=a.account_id '
        'WHERE s.access_hash=? AND s.access_expires>? AND s.refresh_expires>?',
        (digest(token),int(time.time()),int(time.time()))).fetchone()
    if not row: raise HTTPException(401,'Your session expired. Please sign in again.')
    return row


def pioneer(account) -> bool:
    """Accounts made before the official launch. Until HOWMUCH_PIONEER_UNTIL is set (a date
    like 2026-12-01, or Unix seconds), every account is a pioneer."""
    cutoff=os.environ.get('HOWMUCH_PIONEER_UNTIL','').strip()
    if not cutoff: return True
    try: until=int(cutoff) if cutoff.isdigit() else int(time.mktime(time.strptime(cutoff,'%Y-%m-%d')))
    except ValueError: return False
    return int(account['created'])<until


def developer(account) -> bool:
    """The people building HowMuch: account IDs listed in HOWMUCH_DEVELOPERS (comma separated).
    They get a Developer badge and every Penny skin."""
    listed={item.strip().lower() for item in os.environ.get('HOWMUCH_DEVELOPERS','').split(',') if item.strip()}
    return str(account['account_id']).lower() in listed


def account_json(account):
    return {'id':account['account_id'],'email':account['email'],'displayName':account['display_name'],
            'appleUserID':account['apple_sub'],'pioneer':pioneer(account),'developer':developer(account)}


def session_response(db, account, device_id):
    access,refresh,revoke=secrets.token_urlsafe(32),secrets.token_urlsafe(48),secrets.token_urlsafe(32)
    now=int(time.time())
    session=str(uuid.uuid4())
    with db:
        db.execute('DELETE FROM auth_sessions WHERE refresh_expires<=?',(now,))
        db.execute('INSERT INTO auth_sessions(session_id,account_id,access_hash,refresh_hash,revoke_hash,access_expires,refresh_expires,device_id,created) VALUES(?,?,?,?,?,?,?,?,?)',
                   (session,account['account_id'],digest(access),digest(refresh),digest(revoke),now+ACCESS_SECONDS,now+REFRESH_SECONDS,device_id,now))
    return {'accessToken':access,'refreshToken':refresh,'revocationToken':revoke,'expiresAt':now+ACCESS_SECONDS,
            'account':account_json(account)}


class AppleSignIn(BaseModel):
    challenge: str=Field(min_length=32,max_length=256)
    identityToken: str=Field(min_length=32,max_length=16384)
    authorizationCode: str=Field(min_length=1,max_length=4096)
    deviceID: uuid.UUID
    displayName: str=Field(default='',max_length=60)

class RefreshSession(BaseModel):
    refreshToken: str=Field(min_length=32,max_length=256)


@router.post('/challenge')
async def challenge(request: Request):
    limit(request,'challenge')
    challenge,nonce=secrets.token_urlsafe(32),secrets.token_urlsafe(32)
    db=request.app.state.storage._conn
    with db:
        db.execute('DELETE FROM auth_challenges WHERE expires<=?',(int(time.time()),))
        db.execute('INSERT INTO auth_challenges VALUES(?,?,?)',(digest(challenge),digest(nonce),int(time.time())+300))
    return json_response({'challenge':challenge,'nonce':nonce})


def challenge_row(db, challenge):
    row=db.execute('SELECT * FROM auth_challenges WHERE challenge_hash=? AND expires>?',(digest(challenge),int(time.time()))).fetchone()
    if not row: raise HTTPException(401,'Sign-in expired. Start again with Apple.')
    return row


@router.post('/apple')
async def sign_in(payload: AppleSignIn, request: Request):
    limit(request,'sign-in')
    db=request.app.state.storage._conn
    row=challenge_row(db,payload.challenge)
    claims=await asyncio.to_thread(verify_identity,payload.identityToken,row['nonce_hash'])
    refresh=None
    if apple_service_configured():
        try: refresh=await exchange_apple_code(payload.authorizationCode)
        except (httpx.HTTPError,ValueError,KeyError) as exc:
            raise HTTPException(503,'Apple sign-in is temporarily unavailable. Please try again.') from exc
    email=claims.get('email') if claims.get('email_verified') in (True,'true') else None
    now=int(time.time())
    with db:
        consumed=db.execute('DELETE FROM auth_challenges WHERE challenge_hash=? AND expires>?',(digest(payload.challenge),now))
        if consumed.rowcount!=1: raise HTTPException(401,'This sign-in has already been used.')
        db.execute('INSERT INTO accounts(account_id,apple_sub,email,display_name,created) VALUES(?,?,?,?,?) '
                   'ON CONFLICT(apple_sub) DO NOTHING',(str(uuid.uuid4()),claims['sub'],email,payload.displayName.strip(),now))
        account=db.execute('SELECT * FROM accounts WHERE apple_sub=?',(claims['sub'],)).fetchone()
        if refresh:
            db.execute('UPDATE accounts SET apple_refresh=? WHERE id=?',(encryption().encrypt(refresh.encode()).decode(),account['id']))
    return json_response(session_response(db,account,str(payload.deviceID)))


@router.post('/refresh')
async def refresh(payload: RefreshSession, request: Request):
    presented=digest(payload.refreshToken)
    limit(request,'refresh',maximum=100,key=presented)
    db=request.app.state.storage._conn
    now=int(time.time())
    row=db.execute('SELECT * FROM auth_sessions WHERE refresh_hash=? AND refresh_expires>?',(presented,now)).fetchone()
    if not row:
        old=db.execute('SELECT * FROM auth_sessions WHERE prev_refresh_hash=? AND refresh_expires>?',(presented,now)).fetchone()
        if old and now-old['rotated']<=REFRESH_GRACE_SECONDS:
            # The reply to the last refresh was lost on a bad connection: issue a fresh pair once more.
            row=old
        else:
            if old:
                # An already-rotated token used again later: it may have been stolen, so end that session
                # (committed before the error is raised).
                with db: db.execute('DELETE FROM auth_sessions WHERE session_id=?',(old['session_id'],))
            raise HTTPException(401,'Please sign in with Apple again.')
    with db:
        # Rotation keeps the session ID, so a registered device stays attached to its session.
        access,new_refresh=secrets.token_urlsafe(32),secrets.token_urlsafe(48)
        previous=row['prev_refresh_hash'] if row['refresh_hash']!=presented else presented
        cursor=db.execute('UPDATE auth_sessions SET access_hash=?,refresh_hash=?,access_expires=?,refresh_expires=?,prev_refresh_hash=?,rotated=? '
                          'WHERE session_id=? AND refresh_hash=?',(digest(access),digest(new_refresh),now+ACCESS_SECONDS,
                          now+REFRESH_SECONDS,previous,now,row['session_id'],row['refresh_hash']))
        if cursor.rowcount!=1: raise HTTPException(401,'This refresh token has already been used.')
        account=db.execute('SELECT * FROM accounts WHERE account_id=?',(row['account_id'],)).fetchone()
    return json_response({'accessToken':access,'refreshToken':new_refresh,'expiresAt':now+ACCESS_SECONDS,
            'account':account_json(account)})


@router.post('/logout',status_code=204)
async def logout(request: Request, authorization: str | None=Header(default=None)):
    account=authenticated_account(request,authorization)
    db=request.app.state.storage._conn
    with db: db.execute('DELETE FROM auth_sessions WHERE session_id=?',(account['session_id'],))
    return Response(status_code=204)


@router.post('/logout-all',status_code=204)
async def logout_all(request: Request, authorization: str | None=Header(default=None)):
    """Signs the account out everywhere, e.g. after a lost or stolen phone."""
    account=authenticated_account(request,authorization)
    with request.app.state.storage._conn as db:
        db.execute('DELETE FROM auth_sessions WHERE account_id=?',(account['account_id'],))
    return Response(status_code=204)


@router.get('/me')
async def me(request: Request, authorization: str | None=Header(default=None)):
    account=authenticated_account(request,authorization)
    from .push import configured as push_configured
    return json_response({'id':account['account_id'],'email':account['email'],'displayName':account['display_name'],'appleUserID':account['apple_sub'],
                          'pushReady':push_configured()})


class RevokeSession(BaseModel):
    revocationToken: str=Field(min_length=32,max_length=256)

@router.post('/revoke',status_code=204)
async def revoke_session(payload:RevokeSession,request:Request):
    limit(request,'revoke',maximum=100)
    with request.app.state.storage._conn as db:
        db.execute('DELETE FROM auth_sessions WHERE revoke_hash=?',(digest(payload.revocationToken),))
    return Response(status_code=204)
