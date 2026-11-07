# Independent HowMuch account service

This service does not import or run `paybot`. Its own Fly app is `howmuch-ios`; its database is `/data/howmuch-ios.sqlite3`. The older `/data/paybot.sqlite3` on that app’s volume is preserved and never opened by this service. The separate `pay-tracker-bot` app retains the Telegram service.

## Configuration

- `HOWMUCH_APPLE_BUNDLE_ID=com.jialekhoo.howmuch`
- `HOWMUCH_APPLE_TEAM_ID=8FSHKXDVJ2`
- `HOWMUCH_APPLE_KEY_ID`, `HOWMUCH_APPLE_PRIVATE_KEY`: Sign in with Apple ES256 key, associated with the primary native App ID.
- `HOWMUCH_ENCRYPTION_KEY`: Fernet key for stored Apple refresh tokens and retry cleanup.
- `HOWMUCH_APNS_TEAM_ID`, `HOWMUCH_APNS_KEY_ID`, `HOWMUCH_APNS_PRIVATE_KEY`: production APNs topic-specific key. Set `HOWMUCH_APNS_ENVIRONMENT=production` so this key cannot be used for sandbox delivery.
- `HOWMUCH_APNS_SANDBOX_KEY_ID`, `HOWMUCH_APNS_SANDBOX_PRIVATE_KEY`: separate sandbox APNs topic-specific key. Sandbox/production is taken from the signed client’s environment and constrained to fixed Apple hosts. Missing environment credentials cause registration to return unavailable and leave local fallback active.
- `HOWMUCH_GMAIL_TOKEN_KEY`: independent Fernet key for optional Google credentials.
- Optional Gmail: separate `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `HOWMUCH_GMAIL_REDIRECT_URI=https://howmuch-ios.fly.dev/v1/payment-detection/gmail/callback`. Configure the Google consent screen and allowed callback separately; do not copy the bot’s connection or user tokens.
- `HOWMUCH_PUBLIC_URL=https://howmuch-ios.fly.dev`

Keep private keys in Fly encrypted secrets, never in source, logs or command arguments. Newline escapes in PEM keys are accepted. `/healthz` exposes readiness and the public bundle ID, never credentials. APNs returns unavailable until configured. Apple JWT verification has no production development bypass.

From the repository root, deploy with `flyctl deploy . --config howmuch_api/fly.toml --app howmuch-ios --remote-only`. The Dockerfile copies only this service. A restricted staging context containing only `howmuch_api/` is preferable. Keep the mounted volume and request a snapshot before updates. Never use the Telegram Fly app for this deployment.

## Ownership and deletion

Every data, Gmail, device and calendar-management route resolves the account from its verified API session; clients cannot choose another account ID. Apple sub is unique; email is not an account key. Access/refresh/revocation tokens are stored as hashes. Calendar URLs are independent revocable bearer links. API responses disable caching. Monetary JSON values preserve Decimal precision.

Snapshots use optimistic revision checks; SQL projections retain shift IDs for receipt audit and reconcile auto-paid updates back into snapshots. Push queues persist in SQLite, suppress canceled/paid work, deduplicate delivery per device and retry transient failures. Logout revokes the session and its devices; token transfer removes the prior account’s registration. Deletion uses fresh Apple authorization for the same subject and removes only that owner’s records, with encrypted Apple revocation retry if required.

Run `python -m pytest tests/standalone -q` on Python 3.12 after installing this requirements file plus pytest. Tests use signed mock Apple tokens and mock APNs transport; they never authenticate real users or deliver real notifications.


Google beta setup (3 November 2026): dedicated project `howmuch-ios-2026` (HowMuch), separate web OAuth client, Gmail API enabled and only `gmail.readonly` declared. Callback matches the standalone service above. Credentials deployed as encrypted secrets to `howmuch-ios`, and server `configured()` verified true. OAuth remains External/Testing with only the account holder’s two explicitly approved Google addresses allowlisted. Users must complete Connect Gmail themselves; no mailbox tokens from Telegram are migrated. Live email consent and scanning have not yet been verified. No Google production verification is implied.

Email provider expansion (build 21): `email_providers.py` adds fixed-endpoint iCloud IMAP and Microsoft Graph. One active mailbox per account; disconnect before switching. Existing rows migrate to provider=gmail. iCloud supports icloud.com/me.com/mac.com, requires a dedicated Apple app-specific password and explicit consent. Uses TLS IMAP 993 on imap.mail.me.com, EXAMINE/read-only INBOX, BODY.PEEK, bounded 30-day/100-alert/60-second scans. No SMTP, writes, arbitrary hosts, attachment retention or Apple Account passwords. Credentials use the existing encrypted mailbox key. Disconnect removes stored credentials; revoke the app password at Apple for provider-side revocation.

Microsoft requires a separately registered confidential web app supporting personal Microsoft accounts and organizational accounts; delegated `Mail.Read`, `User.Read`, `offline_access`. Configure `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, `HOWMUCH_MICROSOFT_REDIRECT_URI=https://howmuch-ios.fly.dev/v1/payment-detection/microsoft/callback` as Fly encrypted secrets. Do not use application-wide mailbox permissions. OAuth uses single-use browser-bound state, PKCE and encrypted rotating refresh tokens. The UI is disabled until these credentials are configured. Production app registration was completed on 4 November 2026 (see QA); no real user Microsoft mailbox sign-in is claimed.

New providers deliberately import alerts as unverified, so no automatic paid marking. An exact payer/event/amount candidate can be applied only with explicit `acknowledge_unverified` bank confirmation. Existing verified Gmail automatic matching is retained. Provider identity and availability are returned by `/v1/payment-detection`. Test-only connectors use synthetic credentials and messages; no live mailbox content is used.

Microsoft production registration: HowMuch Payment Detection, client ID 41e2f7f2-860b-4852-88c3-7b29616c9856, tenant 1272d0ce-8cf8-4b53-874d-eaca4bb8be2e. Personal Microsoft + multitenant accounts, Web callback above, only delegated Mail.Read/User.Read/offline_access. Secret stored outside source in ~/.config/howmuch/microsoft-oauth.json (0600) and encrypted Fly secrets, expires 3 May 2027; rotate before expiry. Home/support and privacy URLs set. No tenant-wide admin consent granted or security policy weakened. Publisher unverified; work/school consent may require tenant admin approval. Personal user sign-in/consent remains a beta check.

Build 22 payer library: optional preferences.savedPayers (UUID, display name, bankNames) and eventPayerIDs map event names to owned library entries. The legacy payers map remains a first-alias compatibility projection. PUT preserves new fields omitted by older clients; deliberate legacy assignment changes are migrated. On first GET, legacy metadata/SQL payer rules migrate once into shared companies; shared aliases join a company. Saved assignments project exact aliases transactionally into account-owned matching rules, retaining stable rule IDs when unchanged and preserving payment history. No fuzzy payer/amount matching is introduced.


Build 23 migrates legacy expenses to reimbursement claims, retaining identity, notes, dates and receipt references. GET migration persists once and updates the payment-matching SQL projection. Receipt JPEGs remain encrypted and owner-scoped with no-store responses; authenticated GET supplies an attachment filename. Native View receipt / Save to Files downloads the stored copy. No third-party OCR or model service receives receipt images.
