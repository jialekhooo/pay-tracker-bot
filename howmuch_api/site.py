"""HowMuch's public website: the home page, support and the privacy policy share one look.

Every page is self-contained: no scripts, fonts or images from anywhere else, and it works in light and dark mode.
"""
from __future__ import annotations

from html import escape

CONTACT = 'jialexkhoo@gmail.com'
TELEGRAM = 'jiale'
APP_STORE = 'https://apps.apple.com/app/id6830079731'
TERMS = 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'

STYLE = """
:root{color-scheme:light dark;--bg:#e8f3ee;--panel:#fff;--soft:#eff7f3;--ink:#183b37;--muted:#50706a;--line:#d5e5dd;--teal:#126b5e;--on-teal:#fff;--gold:#d9a521;--gold-dark:#a87912}
@media (prefers-color-scheme:dark){:root{--bg:#0e2622;--panel:#17352f;--soft:#1e413a;--ink:#ecf6f1;--muted:#a4c9bd;--line:#2c524a;--teal:#7fd6c3;--on-teal:#0e2622;--gold:#e8bd4a;--gold-dark:#b98b1c}}
*{box-sizing:border-box}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
a{color:var(--teal);text-underline-offset:2px}
.wrap{max-width:760px;margin:0 auto;padding:20px 16px 64px}
.top{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:10px;font:700 19px/1 ui-rounded,-apple-system,system-ui,sans-serif;color:var(--ink);text-decoration:none}
.links{display:flex;gap:4px;margin:0;padding:0;list-style:none;font-size:16px}
.links a{display:block;padding:10px 12px;border-radius:999px;text-decoration:none;font-weight:600;color:var(--muted)}
.links a:hover{color:var(--ink);background:var(--soft)}
.links a[aria-current=page]{color:var(--ink);background:var(--panel)}
h1,h2,h3{font-family:ui-rounded,-apple-system,BlinkMacSystemFont,system-ui,sans-serif;line-height:1.2;text-wrap:balance}
h1{font-size:clamp(36px,8vw,52px);margin:36px 0 8px;letter-spacing:-.02em}
h2{font-size:26px;margin:0 0 12px;scroll-margin-top:16px}
h3{font-size:18px;margin:26px 0 4px;scroll-margin-top:16px}
p{margin:0 0 12px}
ul{margin:0 0 12px;padding-left:20px}
li{margin-bottom:6px}
.lede{font-size:20px;line-height:1.45;color:var(--muted);margin:0}
.date{font-size:15px;color:var(--muted);margin:12px 0 28px}
section{background:var(--panel);border-radius:22px;padding:26px 24px;margin-top:16px}
section>:last-child,section>:last-child>:last-child{margin-bottom:0}
.actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:24px}
.button{display:inline-block;background:var(--teal);color:var(--on-teal);font-weight:700;text-decoration:none;padding:14px 22px;border-radius:999px}
.button.quiet{background:var(--panel);color:var(--teal)}
.short{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin:0;padding:0;list-style:none}
.short li{background:var(--soft);border-radius:16px;padding:16px;margin:0;font-size:16px;line-height:1.4}
.short strong{display:block;font-family:ui-rounded,-apple-system,system-ui,sans-serif;font-size:17px;margin-bottom:3px}
nav.toc ol{columns:2;column-gap:28px;margin:0;padding-left:22px;font-size:16px}
nav.toc li{break-inside:avoid}
table{width:100%;border-collapse:collapse;font-size:16px;line-height:1.45}
th{text-align:left;font-size:14px;font-weight:600;color:var(--muted);padding:0 12px 8px 0}
td{vertical-align:top;padding:12px 12px 12px 0;border-top:1px solid var(--line)}
td:first-child{font-weight:600;width:27%}
th:last-child,td:last-child{padding-right:0}
.note{background:var(--soft);border-radius:14px;padding:14px 16px;font-size:16px;line-height:1.5;margin:14px 0 0}
details{border-top:1px solid var(--line);padding:4px 0}
details:first-of-type{border-top:0}
summary{cursor:pointer;font-weight:600;padding:10px 0;list-style-position:outside}
details p,details ul{color:var(--muted)}
footer{color:var(--muted);font-size:15px;text-align:center;margin-top:28px}
footer a{color:var(--muted);white-space:nowrap}
@media (max-width:620px){
 body{font-size:16px}.lede{font-size:18px}section{padding:22px 18px;border-radius:20px}
 h1{margin-top:24px}h2{font-size:23px}.short{grid-template-columns:1fr}nav.toc ol{columns:1}
 .links a{padding:10px}
 thead{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}
 table,tbody,tr,td{display:block;width:100%}
 tr{border-top:1px solid var(--line);padding:12px 0}tr:first-child{border-top:0;padding-top:0}tr:last-child{padding-bottom:0}
 td,td:first-child{border:0;padding:0;width:100%}td:first-child{margin-bottom:2px}td+td{color:var(--muted)}td+td+td{margin-top:4px}
}
@media print{:root{--bg:#fff;--panel:#fff;--soft:#fff}section{padding:0;margin-top:24px;border-radius:0}nav,.actions{display:none}a{color:inherit}}
"""

COIN = ('<svg width="30" height="30" viewBox="0 0 30 30" aria-hidden="true"><circle cx="15" cy="15" r="14" fill="var(--gold)"/>'
        '<circle cx="15" cy="15" r="10" fill="none" stroke="var(--gold-dark)" stroke-width="2"/></svg>')

PAGES = (('/', 'Home'), ('/support', 'Support'), ('/privacy', 'Privacy'))


def page(path: str, title: str, description: str, body: str) -> str:
    """A full HTML page with the shared header, links and footer."""
    links = ''.join(f'<li><a href="{href}"{" aria-current=page" if href == path else ""}>{name}</a></li>' for href, name in PAGES)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#e8f3ee" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0e2622" media="(prefers-color-scheme: dark)">
<meta name="apple-itunes-app" content="app-id=6830079731">
<title>{escape(title)}</title>
<meta name="description" content="{escape(description)}">
<style>{STYLE}</style>
</head>
<body><main class="wrap">
<header class="top">
 <a class="brand" href="/">{COIN} HowMuch</a>
 <nav aria-label="Site"><ul class="links">{links}</ul></nav>
</header>
{body}
<footer>HowMuch by Jia Le Khoo &middot; <a href="/support">Support</a> &middot; <a href="/privacy">Privacy</a> &middot; <a href="/terms">Terms of Use</a></footer>
</main></body>
</html>
"""


HOME = page('/', 'HowMuch: Work & Pay', 'Track the shifts you work and the pay you are owed. Built for event crew, promoters and anyone paid by the shift.', f"""
<header>
 <h1>Know how much you&rsquo;re owed</h1>
 <p class="lede">HowMuch keeps track of the shifts you work and the money you&rsquo;re owed. It&rsquo;s built for event crew, promoters, part-timers and anyone paid by the shift.</p>
 <div class="actions"><a class="button" href="{APP_STORE}">Download on the App Store</a><a class="button quiet" href="/support">Get help</a></div>
</header>

<section aria-labelledby="what">
 <h2 id="what">What it does</h2>
 <ul class="short">
  <li><strong>Add jobs in seconds</strong>Paste a job message from WhatsApp or Telegram, and the dates, times, venue and pay are filled in for you to check.</li>
  <li><strong>See what you&rsquo;ve earned</strong>Earnings by day, week, month and event, plus what&rsquo;s still booked and what&rsquo;s waiting to be paid.</li>
  <li><strong>Get paid on time</strong>Mark shifts paid, set due dates and get a nudge when pay is late. Pay-in tracking can match bank alerts to your jobs.</li>
  <li><strong>While you work</strong>Your shift on the Lock Screen, reminders before you start, and a time-to-leave alert with directions.</li>
  <li><strong>Claims and receipts</strong>Keep cab and meal claims with receipt photos alongside each job.</li>
  <li><strong>Meet Penny</strong>A pixel pet that grows as you work and get paid. Dress it up, and say hi to friends&rsquo; pets.</li>
 </ul>
</section>

<section aria-labelledby="plans">
 <h2 id="plans">Free, with HowMuch Pro for more</h2>
 <p>Tracking shifts in up to 5 events, your earnings, the work calendar and Penny are free.</p>
 <p>HowMuch Pro adds unlimited events, Pay-in tracking, reminders and the live shift on the Lock Screen, calendar sync and exports, and insights and widgets. Choose monthly or yearly, each with a free first week for new subscribers, or a one-time lifetime purchase. Prices for your region are shown in the app.</p>
</section>

<section aria-labelledby="private">
 <h2 id="private">Private by design</h2>
 <p>You sign in with Apple, and your records sync across your devices. There are no ads and no tracking, and your data is never sold. Friends only ever see your pet, never your shifts or pay. Read the <a href="/privacy">privacy policy</a>.</p>
</section>
""")


SUPPORT = page('/support', 'Support | HowMuch', 'Help with HowMuch: contact us on Telegram or by email, and answers about getting started, syncing, HowMuch Pro, Pay-in tracking and deleting your account.', f"""
<header>
 <h1>Support</h1>
 <p class="lede">Message us on Telegram or by email, or find answers to common questions below.</p>
</header>

<section aria-labelledby="contact">
 <h2 id="contact">Contact us</h2>
 <p>For any issue, message <a href="https://t.me/{TELEGRAM}">@{TELEGRAM}</a> on Telegram or email <a href="mailto:{CONTACT}?subject=HowMuch%20support">{CONTACT}</a>. We reply within 7 days, usually sooner.</p>
 <p>It helps to include the app version (at the bottom of Settings), your iPhone model and iOS version, and the steps that led to the problem. A screenshot helps too.</p>
 <p class="note">Please never send passwords, app passwords or full bank statements. We will never ask for them.</p>
</section>

<section aria-labelledby="start">
 <h2 id="start">Getting started</h2>
 <details><summary>How do I add a shift?</summary>
  <p>Tap + and fill in the date, times and pay. You can also copy a job message and tap Paste in Add shift, share a message to HowMuch from Messages or Notes, or ask Siri to add a job.</p></details>
 <details><summary>Do I need an account?</summary>
  <p>Yes. You sign in with Apple, so there&rsquo;s no new password. Your records belong to that account and sync to every device where you sign in with it.</p></details>
 <details><summary>My shifts aren&rsquo;t showing on my other device</summary>
  <p>Check that both devices are signed in to the same Apple Account in HowMuch (Settings &rarr; Account &amp; sync) and are online. Changes sync when the app is open.</p></details>
</section>

<section aria-labelledby="pro">
 <h2 id="pro">HowMuch Pro and purchases</h2>
 <details><summary>What&rsquo;s free, and what needs Pro?</summary>
  <p>Tracking shifts in up to 5 events, your earnings, the work calendar and Penny are free. Pro adds unlimited events, Pay-in tracking, reminders and the live shift on the Lock Screen, calendar sync and exports, and insights and widgets.</p></details>
 <details><summary>I bought Pro but it isn&rsquo;t showing</summary>
  <p>Open Settings &rarr; HowMuch Pro and tap Restore purchases, while signed in to the same Apple Account you bought it with. Penny&rsquo;s store has the same button for item packs.</p></details>
 <details><summary>How do I cancel my subscription?</summary>
  <p>In HowMuch, open Settings &rarr; HowMuch Pro &rarr; Manage subscription. Or, on your iPhone, open Settings &rarr; your name &rarr; Subscriptions. Cancel at least 24 hours before the renewal date to avoid being charged for the next period.</p></details>
 <details><summary>How do I ask for a refund?</summary>
  <p>Purchases are handled by Apple, so refunds are too. Request one at <a href="https://reportaproblem.apple.com">reportaproblem.apple.com</a>.</p></details>
</section>

<section aria-labelledby="features">
 <h2 id="features">Features</h2>
 <details><summary>How does Pay-in tracking work?</summary>
  <p>It matches money you receive to your jobs, in Settings &rarr; Pay-in tracking. You can pass bank app notifications to HowMuch with a Shortcuts automation, forward bank alert emails to your private HowMuch address, or connect a mailbox. Matches wait for your confirmation before a job is marked paid. It&rsquo;s off until you set it up.</p></details>
 <details><summary>Can I see my shifts in Apple or Google Calendar?</summary>
  <p>Yes, with Settings &rarr; Calendar sync. It gives you a private calendar link. Anyone with the link can see those shifts, so keep it private, and rotate it in the app if you shared it by mistake.</p></details>
 <details><summary>How does Penny earn coins?</summary>
  <p>Penny earns coins when you work shifts and get paid, finish missions, earn badges and say hi to friends. Spend them in the shop on your pet&rsquo;s page. Tap any item to try it on first.</p></details>
</section>

<section aria-labelledby="data">
 <h2 id="data">Your data</h2>
 <details><summary>How do I back up or export my records?</summary>
  <p>Settings &rarr; Data &amp; backups. A full archive includes your records and receipt photos. Keep it somewhere private.</p></details>
 <details><summary>How do I delete my account?</summary>
  <p>Settings &rarr; Account &amp; sync &rarr; Delete account. This deletes your account and its records from HowMuch, disconnects any mailbox and removes your friendships. It can&rsquo;t be undone, so export a backup first if you want to keep a copy.</p></details>
 <details><summary>What do you do with my data?</summary>
  <p>Only what&rsquo;s needed to run the app. No ads, no tracking, and your data is never sold. The <a href="/privacy">privacy policy</a> has the details.</p></details>
</section>
""")
