# DBS payment detection with Gmail

Settings → Payment detection connects a Gmail mailbox using Google's read-only
OAuth permission. A background task checks new DBS alerts every two minutes;
**Check now** runs the same importer. No email is sent, moved, marked read, or deleted.

## One-time deployment setup

1. Create/select a Google Cloud project and enable the **Gmail API**.
2. Configure the Google Auth consent screen for HowMuch. Request only
   `https://www.googleapis.com/auth/gmail.readonly`. During testing, add the actual
   Gmail account as a test user. This is a restricted scope: Google's verification
   requirements apply before broader distribution. External testing refresh tokens
   can expire after seven days, so testing mode is not a permanent connection.
3. Create an OAuth client of type **Web application**. Register this exact redirect URI:
   `https://pay-tracker-bot.fly.dev/webapp/api/payment-detection/gmail/callback`
4. Set these Fly secrets using the Fly dashboard or a local secret manager (never
   commit credentials or paste them into a public issue/chat):
   - `GOOGLE_CLIENT_ID`: OAuth web client ID.
   - `GOOGLE_CLIENT_SECRET`: matching client secret.
   - `PAYBOT_GMAIL_REDIRECT_URI`: the URI above.
   - `PAYBOT_GMAIL_TOKEN_KEY`: a Fernet key generated locally with
     `python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'`.
     Preserve this key across deployments. Changing it makes saved connections
     unreadable and requires users to reconnect.
5. Open Settings → Payment detection → **Connect Gmail**. Complete Google consent
   in the external browser, return to Telegram, then **Refresh connection status**.
6. In Earnings, open **Paid by** on a job card and select or enter the paying
   company (for example `REFIX PTE. LTD.`). Suggestions come from verified bank
   alerts and saved companies. The same field is available in event details.
   Save once for that job; it creates the matching rule automatically. The payer
   rule list in Settings is also available for advanced edits. Enable automatic
   marking after checking the company. It starts disabled.

Until all four deployment settings are present and valid, the UI reports that
Gmail setup is needed and the background importer makes no Gmail requests.
OAuth tickets and states expire after ten minutes, are single use, and are stored
as hashes. The browser callback also requires the secure, HTTP-only flow cookie.
Connection links and OAuth query strings are redacted from the app's access log.

Google documentation:
- https://developers.google.com/identity/protocols/oauth2/web-server
- https://developers.google.com/workspace/gmail/api/auth/scopes
- https://developers.google.com/workspace/gmail/api/guides/filtering

## Alert format and matching

Only the exact From address `ibanking.alert@dbs.com` and subject
`digibank Alerts - You've received a transfer` are accepted (straight/curly
apostrophes are supported). The parser expects:

```text
Transaction Ref: EXAMPLE-REFERENCE
Dear Customer,
You have received SGD 123.45 via FAST transfer on 30 Oct 2026 12:15 SGT
From: REFIX PTE. LTD.
To: Your DBS/POSB account ending 1234
```

Plain text is preferred; HTML-only messages are converted to text. Attachments and
scripts are not processed. Missing amounts, payer names, account suffixes, or dates
never authorize automatic marking. The reference can be missing; in that case a
conservative receipt fingerprint prevents duplicate crediting.

Gmail must report successful DKIM and DMARC for `dbs.com` in its receiving-server
Authentication-Results. Spam, Trash, drafts, and sent messages cannot authorize
marking paid. Unverifiable alerts appear for review but cannot mark shifts paid
through this feature; users can check the original mail and use existing manual
payment controls if appropriate.

An automatic match requires:

- Automation is enabled, and the transfer happened after it was enabled.
- An exact normalized payer-name rule identifies exactly one matching event.
- All shifts for that event are unpaid, use SGD, and finished before the transfer.
- The alert amount equals the event earnings, or earnings plus that event's cab claims.

No fuzzy payer matching or amount-only automation is used. Partially paid events,
reused event names with future shifts, partial payments, and combined payouts are
left for manual reconciliation. Two payer-matched events with the same total
require review. Existing alerts are not automatically re-applied when rules or
settings change. A review confirmation rechecks the event's current total.

The first import checks the last 30 days of DBS alerts. Transfers before
automatic marking was enabled require review. Subsequent scans overlap their last successful checkpoint by five minutes,
follow every result page, and deduplicate by Gmail message ID and transaction
reference/fingerprint. Failed scans never advance the checkpoint. A failed scan
may have committed some individually processed alerts; retries do not apply them
twice. No bank login, password, or OTP is needed.

## Data and recovery

Refresh tokens are encrypted with Fernet; access tokens exist only during a scan.
The database retains only the parsed amount/currency, payer, transfer time, last
four account digits, opaque Gmail ID, hashed transaction identity, decision, and
audit records. Full email bodies and account numbers are not stored.

Every application atomically records the exact underlying SQLite shift IDs,
original shift details, and payment decision. **Undo marking paid** reverses only
those shifts; it refuses if they have since been deleted, changed in pay/event/currency/date/time, or marked unpaid.
The alert stays processed after undo, so a later scan cannot silently reapply it.

**Disconnect Gmail** removes local tokens immediately, cancels pending connection
links, and attempts Google token revocation. If offline, remove HowMuch's access
from your Google account as well. Audit history and payer rules remain available.

## Validation

`python -m pytest -q` covers parsing, sender/authentication checks, malformed alerts,
exact/ambiguous matching, cab reimbursements, partial/future/paid events, tenant
isolation, transactional undo, OAuth browser binding/replay prevention, encrypted
credentials, Gmail pagination, duplicate alerts, and failed scan checkpoints.
Browser checks cover setup, payer rules, and responsive layouts in Chrome and WebKit.
Real Gmail consent and a real bank alert must still be checked after configuring
OAuth; mocks do not replace that end-to-end connection test.

### Company on the job card

**Paid by → Save company** replaces that job's existing payer rules with the
selected company. Clearing the field removes the job's payer rule. Other jobs and
users are unaffected. A company can pay multiple jobs; the automatic matcher still
requires an exact event total and a single eligible match. Saving a company does
not reprocess older alerts or enable automatic marking by itself.
