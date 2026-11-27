# Email forwarding for Pay-in tracking (HowMuch 1.1)

Live setup (5 Nov 2026): domain `howmuch.jialekhoo.com`, Worker `howmuch-inbound-email` on the jialexkhoo@gmail.com Cloudflare account, rule `pay@howmuch.jialekhoo.com`. The jialekhoo.com zone also routes `smartspend.jialekhoo.com` (catch-all → `smartspend-inbound`) for a separate app.

Support mail (27 Nov 2026): `support@jialekhoo.com` is a real mailbox on iCloud+ Custom Email Domain (alongside `jiale@jialekhoo.com`). The apex `jialekhoo.com` has iCloud's MX (`mx01`/`mx02.mail.icloud.com`), its `apple-domain=` TXT, `sig1._domainkey` DKIM CNAME, and an SPF that includes both `icloud.com` and Cloudflare. Cloudflare Email Routing still owns the `howmuch.` and `smartspend.` subdomains, which have their own MX records. Its Settings page will show the apex MX as "Missing" and iCloud's as "Conflicting": leave that alone. Don't click "Add missing records", don't delete iCloud's MX, and never press Disable, because disabling the apex domain disables the subdomains too, which would stop Pay-in. The website (`howmuch_api/site.py` CONTACT) lists this address.

DMARC (27 Nov 2026): `_dmarc.jialekhoo.com` is `p=quarantine; sp=reject` (only iCloud sends as @jialekhoo.com, DKIM-signed by `sig1`), and `_dmarc.howmuch.` / `_dmarc.smartspend.` are `p=reject` because those subdomains only receive. If HowMuch ever sends mail from `howmuch.jialekhoo.com`, give that sender SPF/DKIM first or its mail will be rejected.

Each HowMuch account gets a private address, `pay+<16 hex>@<inbound domain>`, shown in
Settings → Pay-in tracking once forwarding is switched on. People forward DBS
"You've received a transfer" alerts there by hand or with a Gmail filter. The server reads the
alert with the same parser as mailbox detection and adds it to Payment review. Forwarded mail
can't be authenticated, so it always waits for the person to confirm against their bank.

## Switch it on

1. Buy or pick a domain you control, e.g. `howmuch.app`, and add it to Cloudflare.
2. Cloudflare → Email → Email Routing: enable it for the domain (it adds the MX records).
3. Create an Email Worker that posts each message to HowMuch:

   ```js
   export default {
     async email(message, env) {
       const raw = await new Response(message.raw).arrayBuffer();
       await fetch(`https://howmuch-ios.fly.dev/v1/inbound-email/${env.HOWMUCH_INBOUND_SECRET}`, {
         method: "POST", headers: { "content-type": "message/rfc822" }, body: raw,
       });
     },
   };
   ```

   Add `HOWMUCH_INBOUND_SECRET` to the Worker as a secret (a long random string).
4. Email Routing → Settings: add the subdomain (e.g. `howmuch`) and enable subaddressing. Routing rules → Create: `pay@howmuch.<domain>` → Send to a Worker → the Worker above. With subaddressing, every `pay+<token>@` address matches this rule, ahead of any catch-all.
5. Set the same values on the API and deploy:
   - `HOWMUCH_INBOUND_DOMAIN`: the domain, e.g. `howmuch.app`
   - `HOWMUCH_INBOUND_SECRET`: the same secret as the Worker

Until both are set, the app shows "Coming soon" and the inbound route answers 404.

Gmail's automatic forwarding sends a confirmation code to the new address first; it arrives
as an ignored message, so confirm the forwarding address with a manual forward of the code email
or check the Worker's logs.
