// Cloudflare Email Worker for HowMuch Pay-in tracking: forwarded bank alerts sent to
// pay+<token>@howmuch.jialekhoo.com are posted, raw, to the HowMuch API, which reads them.
// HOWMUCH_INBOUND_SECRET is a Worker secret matching the API's Fly secret.
export default {
  async email(message, env) {
    const raw = await new Response(message.raw).arrayBuffer();
    const response = await fetch(`https://howmuch-ios.fly.dev/v1/inbound-email/${env.HOWMUCH_INBOUND_SECRET}`, {
      method: "POST",
      headers: { "content-type": "message/rfc822" },
      body: raw,
    });
    if (!response.ok) message.setReject(`HowMuch could not accept this email (${response.status}).`);
  },
  async fetch() {
    return new Response("Not found", { status: 404 });
  },
};
