# Email forwarding for Pay-in tracking (HowMuch 1.1)

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
4. Email Routing → Routing rules → Catch-all (or `pay+*`) → Send to Worker → the Worker above.
5. Set the same values on the API and deploy:
   - `HOWMUCH_INBOUND_DOMAIN`: the domain, e.g. `howmuch.app`
   - `HOWMUCH_INBOUND_SECRET`: the same secret as the Worker

Until both are set, the app shows "Coming soon" and the inbound route answers 404.

Gmail's automatic forwarding sends a confirmation code to the new address first; it arrives
as an ignored message, so confirm the forwarding address with a manual forward of the code email
or check the Worker's logs.
