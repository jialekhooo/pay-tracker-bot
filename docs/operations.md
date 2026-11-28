# Running HowMuch in production

How the API, website and app are deployed, watched, backed up and rolled back. Written 28 Nov 2026
against the launch checklist (CI/CD, tests, monitoring, backups, secrets, rate limits and the rest).

## Where things run

| What | Where | Notes |
|---|---|---|
| API + website | Fly app `howmuch-ios` (sin), one `shared-cpu-1x` 256 MB machine, volume `vol_rnzl6mezdwqxxmkr` (`paybot_data`, mounted at `/data`) | Website is `https://howmuch.jialekhoo.com` through Cloudflare (Full strict, HSTS); the app calls `https://howmuch-ios.fly.dev` |
| Staging | Fly app `howmuch-ios-staging`, volume `staging_data`, `howmuch_api/fly.staging.toml` | Same code, empty database, **no production secrets** (no APNs, Gmail, Outlook or Apple Maps keys). Sleeps when idle |
| Telegram bot | Fly app `pay-tracker-bot` | Separate service and volume; not covered here |
| App | App Store / TestFlight, record `6830079731` | See `ios/AppStore.md` |

## Deploying the API

Automatic: every push to `main` that touches the API runs `.github/workflows/deploy-api.yml`. It uses
two Fly deploy tokens, each able to deploy only one app: `FLY_STAGING_API_TOKEN` (repository secret,
`howmuch-ios-staging`) and `FLY_API_TOKEN` (secret of the GitHub `production` environment, `howmuch-ios`;
the environment needs your approval and only accepts `main`). **Both expire 28 Nov 2027.** To renew one:

```bash
flyctl tokens create deploy --app howmuch-ios --name "github-actions production" --expiry 8760h | gh secret set FLY_API_TOKEN --env production
flyctl tokens create deploy --app howmuch-ios-staging --name "github-actions staging" --expiry 8760h | gh secret set FLY_STAGING_API_TOKEN
```

then revoke the old one (`flyctl tokens list --app …`, `flyctl tokens revoke <id>`). The workflow:

1. tests and `pip-audit`;
2. deploy to **staging**, then `scripts/smoke.py` against it;
3. waits for your approval, snapshots the production volume, notes the running image;
4. deploys **production** and smoke-tests it; **if the smoke test fails it redeploys the previous image**.

By hand, from the repository root:

```bash
flyctl deploy . --config howmuch_api/fly.staging.toml --remote-only
python3 scripts/smoke.py https://howmuch-ios-staging.fly.dev
flyctl volumes snapshots create vol_rnzl6mezdwqxxmkr --app howmuch-ios
flyctl deploy . --config howmuch_api/fly.toml --app howmuch-ios --remote-only
python3 scripts/smoke.py https://howmuch.jialekhoo.com https://howmuch-ios.fly.dev
```

`scripts/smoke.py` checks: `/healthz` answers ok within 3 s (it fails if the database can't be read),
signed-in routes refuse a caller with no session, the API schema is not public, every site page, the
FAQ data, `robots.txt`, `sitemap.xml`, `llms.txt` and the real 404 page.

## Rolling back a bad deploy

1. List recent images: `flyctl releases --app howmuch-ios --image`.
2. Redeploy the last good one (no build):
   `flyctl deploy . --config howmuch_api/fly.toml --app howmuch-ios --image registry.fly.io/howmuch-ios:deployment-XXXX`
3. Smoke test. If the bad release changed the database in a way old code can't read, restore the
   snapshot taken before the deploy (below) — it loses changes made since, so prefer a forward fix.

The app can't be rolled back on the App Store. For a bad app release: pause the phased release (App
Store Connect → version → Phased Release → Pause), fix forward with a new build, and request an
expedited review if users are blocked. Server changes must stay compatible with the version in the
store and the one before it.

## Backups and restore

Fly snapshots the production volume daily (encrypted, kept 5 days), and the deploy workflow takes one
before each production deploy. Users can also export full archives from the app.

**Restore tested 28 Nov 2026**: snapshot `vs_Nbx7L18JpBbU6aoOz7g` (27 Nov 19:36 UTC) restored to a
new volume and checked on a temporary machine: `PRAGMA integrity_check` = ok, all tables present with
data (9 accounts, 9 document sets, 2 receipt photos, 2 calendar links). Steps:

```bash
flyctl volumes snapshots list vol_rnzl6mezdwqxxmkr --app howmuch-ios
flyctl volumes create restore_test --snapshot-id <vs_…> --app howmuch-ios --region sin --size 1 --yes
# A machine with no services, mounting the copy (the image's server starts but gets no traffic):
flyctl machine run <current image> --app howmuch-ios --region sin --name restore-test --volume <vol_…>:/restore --restart no --detach
flyctl ssh console --app howmuch-ios --machine <id> -C "python3 -c \"import sqlite3;print(sqlite3.connect('file:/restore/howmuch-ios.sqlite3?mode=ro',uri=True).execute('PRAGMA integrity_check').fetchone())\""
flyctl machine destroy <id> --app howmuch-ios --force && flyctl volumes destroy <vol_…> --app howmuch-ios --yes
```

To actually replace production data: stop the machine, create a volume from the snapshot named
`paybot_data`, remove the old volume from the machine's config (`flyctl machine update --mount`), start,
smoke test. Repeat the restore test every few months.

## Watching it

- **Uptime and alerting**: `.github/workflows/uptime.yml` runs the smoke test every 15 minutes (once on
  `main`); a failed run emails you (GitHub → Settings → Notifications → Actions → failed workflows).
  Fly's own health check restarts the machine if `/healthz` fails.
- **Logs**: `flyctl logs --app howmuch-ios`. One line per request: method, route template (never the raw
  URL, so tokens stay out), status and time. 5xx and requests over 1 s are logged as warnings and marked
  `slow` — that is the performance monitoring.
- **Errors and crashes (in-house)**: unhandled server errors and the app's MetricKit crash, hang, CPU,
  disk and slow-launch reports go to the `diagnostics` table (30 days, not linked to any account).
  Read them: `flyctl ssh console --app howmuch-ios -C "python -m howmuch_api.diagnostics"`.
- **Analytics**: App Store Connect → Analytics (downloads, sessions, retention, crashes from users who
  share analytics); Cloudflare → jialekhoo.com → Analytics & Logs (website traffic, no cookies or
  scripts); Search Console (search). The app itself has no analytics SDK, matching "No ads, no tracking".

## Rate limits

Every caller (by IP) gets 600 requests per 10 minutes across the whole site; `/healthz` is exempt.
Tighter limits per route: sign-in, refresh and revoke; codes, friends, uploads, scans, travel checks
(20 per account per 10 minutes) and crash reports (30). Apple Maps route checks are also capped at 5,000
a day server-wide.

## Secrets

Production secrets live only in Fly (`flyctl secrets list --app howmuch-ios` shows names): APNs and
APNs sandbox keys, Sign in with Apple key, Apple Maps key, Google and Microsoft OAuth clients, the Gmail
token encryption key, the inbound email secret, the bot secret. Never in the repository: a scan of every
file and all git history on 28 Nov 2026 found no keys or tokens, so nothing needed rotating.

To rotate one: create the new key at its source (Apple Developer → Keys; Google Cloud / Microsoft Entra
for OAuth clients), `flyctl secrets set NAME=… --app howmuch-ios` (this redeploys), smoke test, then
revoke the old key. `HOWMUCH_GMAIL_TOKEN_KEY` encrypts stored mailbox tokens: rotating it disconnects
mailboxes, so users would reconnect. The App Store Connect API key (`~/.appstoreconnect/private_keys`)
stays on your Mac and is not in the repository.

## Spend

Fly has no hard spending cap, so costs are limited by configuration: fixed machine sizes, one
production machine, staging stops when idle, and the daily Apple Maps cap above. Check Fly →
Billing monthly; Cloudflare is on the free plan. Apple Maps Server API and Sign in with Apple are free
within Apple's quotas.

## Testing the app on slow networks and other devices

On an iPhone: Settings → Developer → Network Link Conditioner → "3G" or "Very Bad Network", then add,
edit and sync shifts. The app saves locally first and syncs when it can; requests time out after
20–25 s with an error, not a hang. UI tests run on iPhone Pro, Pro Max, SE and 13" iPad simulators.
