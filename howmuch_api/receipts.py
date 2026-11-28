"""Private account-owned JPEG attachments, encrypted separately from sync documents."""
import time
import uuid
from cryptography.fernet import InvalidToken
from fastapi import APIRouter,Header,HTTPException,Request,Response
from .auth import authenticated_account,encryption
from .database import limit
router=APIRouter(prefix='/receipts')
MAX_BYTES=750_000

def jpeg_dimensions(data):
    if not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):raise ValueError('JPEG required')
    offset=2
    while offset+4<len(data):
        if data[offset]!=255:raise ValueError('Invalid JPEG marker')
        while offset<len(data) and data[offset]==255:offset+=1
        marker=data[offset];offset+=1
        if marker in (0xD8,0xD9,0xDA):break
        size=int.from_bytes(data[offset:offset+2],'big')
        if size<2 or offset+size>len(data):raise ValueError('Invalid JPEG segment')
        if marker in (0xC0,0xC1,0xC2):
            height=int.from_bytes(data[offset+3:offset+5],'big');width=int.from_bytes(data[offset+5:offset+7],'big')
            if size<8 or not 1<=width<=1600 or not 1<=height<=1600:raise ValueError('Image too large')
            return width,height
        offset+=size
    raise ValueError('Unsupported JPEG')

@router.put('/{receipt_id}')
@router.put('/{receipt_id}/restore')
async def upload(receipt_id:uuid.UUID,request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    # A complete backup may contain more than 40 photos. Restore still uses the
    # same ownership, image-size, immutable-ID and 100 MB storage checks below.
    restoring=request.url.path.endswith('/restore')
    limit(request,('receipt-restore:' if restoring else 'receipt:')+account['account_id'],maximum=2000 if restoring else 40)
    chunks=[];size=0
    async for part in request.stream():
        size+=len(part)
        if size>MAX_BYTES:raise HTTPException(413,'Choose a receipt photo smaller than 750 KB.')
        chunks.append(part)
    data=b''.join(chunks)
    try:jpeg_dimensions(data)
    except (ValueError,IndexError):raise HTTPException(422,'Choose a JPEG receipt photo up to 1600 pixels wide and high.') from None
    account=authenticated_account(request,authorization) # Recheck sign-out/deletion after reading the upload.
    db=request.app.state.storage._conn
    if db.execute('SELECT 1 FROM receipt_photos WHERE account_id=? AND receipt_id=?',(account['account_id'],str(receipt_id))).fetchone():
        raise HTTPException(409,'This attachment already exists. Choose a new photo to replace it.')
    used=db.execute('SELECT COALESCE(sum(byte_count),0) FROM receipt_photos WHERE account_id=?',(account['account_id'],)).fetchone()[0]
    if used+size>100_000_000:raise HTTPException(413,'Receipt storage for this account is full. Remove some receipt photos or contact support.')
    encoded=encryption().encrypt(data)
    with db:db.execute('INSERT INTO receipt_photos VALUES(?,?,?,?,?)',(account['account_id'],str(receipt_id),encoded,size,int(time.time())))
    return {'receiptID':str(receipt_id)}

@router.get('/{receipt_id}')
async def download(receipt_id:uuid.UUID,request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    row=request.app.state.storage._conn.execute('SELECT encrypted FROM receipt_photos WHERE account_id=? AND receipt_id=?',(account['account_id'],str(receipt_id))).fetchone()
    if not row:raise HTTPException(404,'This receipt photo is unavailable. Attach it again from your Photos library.')
    try:data=encryption().decrypt(row['encrypted'])
    except InvalidToken:raise HTTPException(503,'This receipt photo is temporarily unavailable.') from None
    return Response(data,media_type='image/jpeg',headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Content-Disposition':f'attachment; filename="HowMuch-receipt-{receipt_id}.jpg"'})


@router.delete('/{receipt_id}',status_code=204)
async def delete(receipt_id:uuid.UUID,request:Request,authorization:str|None=Header(default=None)):
    account=authenticated_account(request,authorization)
    with request.app.state.storage._conn as db:
        db.execute('DELETE FROM receipt_photos WHERE account_id=? AND receipt_id=?',(account['account_id'],str(receipt_id)))
    return Response(status_code=204)


GRACE_SECONDS=86400

def collect_unused(db,account_id,data):
    """Deletes photos no claim refers to any more. A day's grace keeps a photo uploaded just before its claim is saved."""
    used={str(claim.get('receiptID')) for claim in (data.get('claims') or [])+(data.get('expenses') or []) if claim.get('receiptID')}
    stale=[row['receipt_id'] for row in db.execute('SELECT receipt_id FROM receipt_photos WHERE account_id=? AND created<?',
                                                  (account_id,int(time.time())-GRACE_SECONDS)) if row['receipt_id'] not in used]
    with db:
        for receipt_id in stale: db.execute('DELETE FROM receipt_photos WHERE account_id=? AND receipt_id=?',(account_id,receipt_id))
    return len(stale)
