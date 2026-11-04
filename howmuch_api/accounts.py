"""In-app account deletion with fresh Apple authorization and token revocation."""
from __future__ import annotations
import asyncio
import time
import httpx
from cryptography.fernet import InvalidToken
from fastapi import APIRouter, Header, HTTPException, Request
from .auth import AppleSignIn,authenticated_account,challenge_row,verify_identity,exchange_apple_code,apple_service_configured,apple_client_secret,encryption,bundle_id,ISSUER
from .database import digest
router=APIRouter()

async def revoke_token(token):
    async with httpx.AsyncClient(timeout=15) as client:
        result=await client.post(ISSUER+'/auth/revoke',data={'client_id':bundle_id(),'client_secret':apple_client_secret(),
                                 'token':token,'token_type_hint':'refresh_token'})
        result.raise_for_status()


@router.post('/account/delete')
async def delete_account(payload:AppleSignIn,request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    db=request.app.state.storage._conn
    challenge=challenge_row(db,payload.challenge)
    claims=await asyncio.to_thread(verify_identity,payload.identityToken,challenge['nonce_hash'])
    if claims['sub']!=account['apple_sub']: raise HTTPException(403,'Use the Apple Account that owns this HowMuch account.')
    # Once verified, finish deletion even if Apple's revocation endpoint is temporarily unavailable.
    pending=False; refresh=None
    if apple_service_configured():
        if account['apple_refresh']:
            try:refresh=encryption().decrypt(account['apple_refresh'].encode()).decode()
            except (ValueError,InvalidToken):pass
        try:
            exchanged=await exchange_apple_code(payload.authorizationCode)
            if exchanged:refresh=exchanged
        except (httpx.HTTPError,ValueError):pass
        if refresh:
            try:await revoke_token(refresh)
            except (httpx.HTTPError,ValueError):pending=True
        else:pending=True
    else:pending=True
    with db:
        deleted=db.execute('DELETE FROM auth_challenges WHERE challenge_hash=? AND expires>?',(digest(payload.challenge),int(time.time())))
        if deleted.rowcount!=1:raise HTTPException(401,'This Apple authorization has expired or was already used.')
        if pending and refresh and apple_service_configured():
            db.execute('INSERT OR REPLACE INTO apple_revocations VALUES(?,?,?)',(digest(refresh),encryption().encrypt(refresh.encode()).decode(),int(time.time())))
        # The work/payment projection has numeric IDs owned by this account, not Telegram IDs.
        for table in ('payment_audit','payment_allocations','payment_receipts','payment_rules','payment_oauth','payment_connections','avatars','reminders','feeds','cab_claims','event_rates','shifts','settings'):
            db.execute(f'DELETE FROM {table} WHERE user_id=?',(account['id'],))
        db.execute('DELETE FROM accounts WHERE account_id=?',(account['account_id'],))
    return {'deleted':True,'appleRevocationPending':pending}


async def retry_revocations(storage):
    while True:
        if apple_service_configured():
            for row in storage._conn.execute('SELECT * FROM apple_revocations LIMIT 20').fetchall():
                try:
                    await revoke_token(encryption().decrypt(row['encrypted_token'].encode()).decode())
                    with storage._conn:storage._conn.execute('DELETE FROM apple_revocations WHERE token_hash=?',(row['token_hash'],))
                except (httpx.HTTPError,ValueError,InvalidToken):pass
        await asyncio.sleep(300)
