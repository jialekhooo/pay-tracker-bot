"""HowMuch's public website: the home page, support and the privacy policy share one playful, Penny-led look.

Every page is self-contained: no scripts, fonts or images from anywhere else. Penny and the icons are pixel art
drawn as inline SVG, and every page works in light and dark mode.
"""
from __future__ import annotations

from html import escape
from pathlib import Path

CONTACT = 'jialexkhoo@gmail.com'
TELEGRAM = 'jialekhoo'
APP_STORE = 'https://apps.apple.com/app/id6830079731'
TERMS = 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'

# App screenshots on the home page (demo data from build 81), served from static/screens at /screens/<name>.jpg.
SCREENS_DIR = Path(__file__).with_name('static') / 'screens'
SCREENS = (('overview', 'Overview', 'The Overview screen: Penny, all-time earnings, and what is paid, pending and booked'),
           ('paste-job', 'Paste a job', 'Adding a shift by pasting a job message: the dates, venue and pay are filled in'),
           ('calendar', 'Calendar', 'The work calendar for November with booked shifts'),
           ('earnings', 'Earnings', 'Earnings by event, with paid, pending and booked totals'),
           ('penny', 'Penny', 'Penny the pay pet, with a 3-week streak and this week\'s missions'))

# ---------------------------------------------------------------------------------------------------------------
# Pixel art. Each letter is one pixel of a colour from the palette; "." is empty.

INK = '#273f46'
ART = {'a': INK, 'b': '#338e46', 'c': '#56b960', 'd': '#6e460c', 'e': '#e6a62e', 'f': '#eadfc6', 'g': '#fdd459',
       'h': '#fdf1ac', 'i': '#fdf3e4', 'j': '#feaeac', 'o': INK, 'y': '#fdd459', 'D': '#e6a62e', 'w': '#ffffff',
       't': '#126b5e', 'm': '#9fd8c3', 'r': '#e5575c', 's': '#7bb8e8'}

# Penny as a hatchling, taken pixel for pixel from the app's artwork.
PENNY = ['.......c....',
         '......b.....',
         '...dddddd...',
         '..dggggggd..',
         '.dgghgggggd.',
         '.dghaggaggd.',
         '.dgagaagagd.',
         '.djggggggjd.',
         '.dgggagaggd.',
         '..deeeaeed..',
         'aiaiaiaiaiai',
         'aiiiiiiiiiia',
         'aiiiiiiiiiia',
         '.affffffffa.',
         '..aaaaaaaa..']

COIN = ['..oooo..',
        '.oyyyyo.',
        'oywyyyDo',
        'oyyyyyDo',
        'oyyyyyDo',
        'oyyyyDDo',
        '.oDDDDo.',
        '..oooo..']

ICONS = {
    'paste': ['..oooo..', 'oottttoo', 'owwwwwwo', 'owttttwo', 'owwwwwwo', 'owtttwwo', 'owwwwwwo', 'owttttwo', 'owwwwwwo', 'oooooooo'],
    'earned': ['......yy', '......yy', '...tt.yy', '...tt.yy', 'tt.tt.yy', 'tt.tt.yy', 'tt.tt.yy', 'oooooooo'],
    'paid': ['..oooo..', '.oyyyyo.', 'oyyyyyto', 'oyyyytyo', 'otyytyyo', 'oyttyyyo', '.oyyyyo.', '..oooo..'],
    'work': ['..oooo..', '.owwwwo.', 'owwwowwo', 'owwwowwo', 'owwwoowo', 'owwwwwwo', '.owwwwo.', '..oooo..'],
    'receipt': ['oooooooo', 'owwwwwwo', 'owttttwo', 'owwwwwwo', 'owtttwwo', 'owwwwwwo', 'owyyyywo', 'o.o.o.o.'],
    'penny': ['.oo..oo.', 'orroorro', 'orrrrrro', 'orrrrrro', '.orrrro.', '..orro..', '...oo...'],
    'shield': ['oooooooo', 'otttttto', 'ottwwtto', 'ottwwtto', '.otttto.', '.otttto.', '..otto..', '...oo...'],
    'chat': ['oooooooo', 'owwwwwwo', 'owtwtwto', 'owwwwwwo', 'oooowooo', '...owo..', '...oo...'],
    'mail': ['oooooooo', 'ootwwtoo', 'owotwtwo', 'owwottwo', 'owwwwwwo', 'oooooooo'],
}


def pixels(rows: list[str], cls: str = '', label: str | None = None) -> str:
    """Pixel art as a crisp inline SVG, one rect per run of same-coloured pixels."""
    rects = []
    for y, row in enumerate(rows):
        x = 0
        while x < len(row):
            ch = row[x]
            run = 1
            while x + run < len(row) and row[x + run] == ch:
                run += 1
            if ch != '.':
                rects.append(f'<rect x="{x}" y="{y}" width="{run}" height="1" fill="{ART[ch]}"/>')
            x += run
    a11y = f'role="img" aria-label="{escape(label)}"' if label else 'aria-hidden="true"'
    return (f'<svg class="px {cls}" viewBox="0 0 {len(rows[0])} {len(rows)}" shape-rendering="crispEdges" {a11y}>'
            + ''.join(rects) + '</svg>')


def penny(cls: str = '', label: str | None = None) -> str:
    return pixels(PENNY, cls, label)


def coin(cls: str = '') -> str:
    return pixels(COIN, cls)


def icon(name: str) -> str:
    return f'<span class="icon">{pixels(ICONS[name])}</span>'


# ---------------------------------------------------------------------------------------------------------------

STYLE = """
:root{color-scheme:light dark;
 --bg:#fff7e6;--dot:#f2e2bb;--panel:#fff;--ink:#1d3833;--muted:#56706a;--edge:#1d3833;--shadow:#1d3833;--line:#e7dcc2;
 --teal:#126b5e;--link:#126b5e;--gold:#fdd459;--mint:#def3ea;--sun:#fff0c4;--rose:#ffe4e1;--sky:#e2effc;
 --scene:#d4ece2;--floor:#b6dccb}
@media (prefers-color-scheme:dark){:root{
 --bg:#10231f;--dot:#1a3631;--panel:#173430;--ink:#f6efdc;--muted:#b3c9c1;--edge:#3f6c62;--shadow:#061210;--line:#2c5049;
 --teal:#86dcc6;--link:#9be6d2;--mint:#1c4038;--sun:#3a3320;--rose:#40292c;--sky:#1d3249}}
*{box-sizing:border-box}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
body{margin:0;background-color:var(--bg);background-image:radial-gradient(var(--dot) 1.4px,transparent 1.6px);background-size:24px 24px;
 color:var(--ink);font:17px/1.6 ui-rounded,"SF Pro Rounded",-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
a{color:var(--link);text-underline-offset:3px;text-decoration-thickness:2px}
.px{display:block;image-rendering:pixelated}
.wrap{max-width:1040px;margin:0 auto;padding:18px 20px 40px}
.narrow{max-width:780px;margin:0 auto}

/* Header */
.top{display:flex;align-items:center;gap:8px 20px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:22px;color:var(--ink);text-decoration:none;letter-spacing:-.01em;margin-right:auto}
.brand .px{width:auto;height:36px}
@media (prefers-color-scheme:dark){.brand .px,.pagehead .px,.btn:not(.primary) .px{filter:drop-shadow(0 0 1.5px #fff7e6)}}
.links{display:flex;gap:4px;margin:0;padding:0;list-style:none}
.links a{display:block;padding:8px 12px;border-radius:12px;color:var(--muted);font-weight:800;font-size:16px;text-decoration:none}
.links a:hover{color:var(--ink);background:var(--panel)}
.links a[aria-current=page]{color:var(--ink);text-decoration:underline;text-decoration-color:var(--gold);text-decoration-thickness:4px;text-underline-offset:8px}
.btn.cta{padding:9px 16px;font-size:15px;border-radius:14px;box-shadow:0 4px 0 var(--shadow)}
.btn.cta:hover{box-shadow:0 6px 0 var(--shadow)}

/* Type */
h1,h2,h3{line-height:1.1;text-wrap:balance;letter-spacing:-.02em;font-weight:800}
h1{font-size:clamp(42px,7vw,68px);margin:0 0 16px}
h2{font-size:clamp(26px,4vw,34px);margin:0 0 14px;scroll-margin-top:16px}
h3{font-size:19px;margin:24px 0 4px;scroll-margin-top:16px}
p{margin:0 0 12px}
ul{margin:0 0 12px;padding-left:20px}
li{margin-bottom:6px}
.mark{background:linear-gradient(transparent 58%,var(--gold) 58%,var(--gold) 92%,transparent 92%);padding:0 .06em}
@media (prefers-color-scheme:dark){.mark{background:none;color:var(--gold)}}
.lede{font-size:clamp(18px,2.4vw,21px);line-height:1.5;color:var(--muted);margin:0;max-width:34em}
.date{font-size:15px;color:var(--muted);margin:10px 0 0;font-weight:600}
.kicker{display:inline-block;font-size:13px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:var(--teal);margin-bottom:10px}

/* Buttons */
.actions{display:flex;flex-wrap:wrap;gap:12px;margin-top:26px}
.btn{display:inline-flex;align-items:center;gap:10px;padding:13px 22px;border:2.5px solid var(--edge);border-radius:16px;background:var(--panel);
 color:var(--ink);font-weight:800;font-size:17px;text-decoration:none;box-shadow:0 5px 0 var(--shadow);transition:transform .12s,box-shadow .12s}
.btn:hover{transform:translateY(-2px);box-shadow:0 7px 0 var(--shadow)}
.btn:active{transform:translateY(4px);box-shadow:0 1px 0 var(--shadow)}
.btn.primary{background:var(--gold);color:#1d3833}
.btn .px{width:22px;height:22px}

/* Cards */
.card,section{background:var(--panel);border:2.5px solid var(--edge);border-radius:24px;box-shadow:0 6px 0 var(--shadow);padding:26px 24px;margin-top:22px}
section.bare{background:none;border:0;box-shadow:none;padding:0}
section>:last-child,section>:last-child>:last-child{margin-bottom:0}
.icon{display:grid;place-items:center;width:52px;height:52px;border:2.5px solid var(--edge);border-radius:14px;background:#fffaf0;flex:none}
.icon .px{width:30px;height:auto}
.head{display:flex;align-items:center;gap:14px;margin-bottom:14px}
.head h2{margin:0}

/* Home hero */
.hero{display:grid;grid-template-columns:1.15fr .85fr;gap:40px;align-items:center;margin:44px 0 18px}
.stage{position:relative;aspect-ratio:1;border:3px solid var(--edge);border-radius:32px;overflow:hidden;box-shadow:0 8px 0 var(--shadow);
 background:linear-gradient(var(--scene) 74%,var(--floor) 74%)}
.stage .window{position:absolute;left:14%;top:14%;width:15%;aspect-ratio:1;border:4px solid var(--floor);border-radius:4px;
 background:linear-gradient(90deg,transparent 46%,var(--floor) 46%,var(--floor) 54%,transparent 54%),linear-gradient(transparent 46%,var(--floor) 46%,var(--floor) 54%,transparent 54%)}
.stage .penny{position:absolute;left:28%;bottom:16%;width:44%;height:auto;animation:hop 2.6s ease-in-out infinite}
.stage .coin{position:absolute;width:11%;height:auto;animation:float 3.2s ease-in-out infinite}
.stage .c1{left:9%;bottom:42%}.stage .c2{right:10%;bottom:52%;animation-delay:-1.1s}.stage .c3{right:20%;top:12%;width:8%;animation-delay:-2s}
.bubble{position:absolute;left:50%;top:15%;transform:translateX(-50%) rotate(-3deg);background:#fff;color:#1d3833;border:2.5px solid #1d3833;
 border-radius:999px;padding:6px 16px;font-weight:800;font-size:clamp(15px,2vw,19px);white-space:nowrap;box-shadow:0 3px 0 #1d3833}
@keyframes hop{0%,70%,100%{transform:translateY(0)}80%{transform:translateY(-9%)}}
@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-14%)}}
@media (prefers-reduced-motion:reduce){.stage .penny,.stage .coin{animation:none}.btn,.links a,.phone{transition:none}html{scroll-behavior:auto}}

/* Screenshots */
.screens{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:22px;margin:0;padding:6px 2px 10px;list-style:none}
.screens li{margin:0;text-align:center}
.phone{display:block;background:#1d3833;border:3px solid var(--edge);border-radius:30px;padding:6px;box-shadow:0 6px 0 var(--shadow);transition:transform .15s}
.phone img{display:block;width:100%;height:auto;border-radius:23px}
.screens li:nth-child(odd) .phone{transform:rotate(-2deg)}.screens li:nth-child(even) .phone{transform:rotate(2deg) translateY(10px)}
.screens li:hover .phone{transform:rotate(0) translateY(-4px)}
.screens .label{display:inline-block;margin-top:18px;padding:4px 14px;border:2px solid var(--edge);border-radius:999px;background:var(--panel);font-weight:800;font-size:15px}
.screens li:nth-child(even) .label{margin-top:28px}

/* Features */
.features{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px;margin:0;padding:0;list-style:none}
.features li{margin:0;border:2.5px solid var(--edge);border-radius:22px;box-shadow:0 5px 0 var(--shadow);padding:20px;transition:transform .15s}
.features li:nth-child(4n+1){background:var(--mint)}.features li:nth-child(4n+2){background:var(--sun)}
.features li:nth-child(4n+3){background:var(--rose)}.features li:nth-child(4n+4){background:var(--sky)}
.features li:nth-child(odd):hover{transform:rotate(-1.2deg) translateY(-3px)}.features li:nth-child(even):hover{transform:rotate(1.2deg) translateY(-3px)}
.features h3{margin:14px 0 6px;font-size:20px}
.features p{margin:0;font-size:16px;line-height:1.5}
.section-title{text-align:center;margin:64px 0 24px}
.section-title p{color:var(--muted);margin:0}

/* Plans */
.plans{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}
.plan{position:relative;border:2.5px solid var(--edge);border-radius:24px;box-shadow:0 6px 0 var(--shadow);padding:26px 24px}
.plan.free{background:var(--mint)}.plan.pro{background:var(--sun)}
.plan h3{margin:0 0 10px;font-size:24px}
.plan p{margin:0}
.sticker{position:absolute;top:-16px;right:18px;transform:rotate(5deg);background:var(--teal);color:var(--bg);border:2.5px solid var(--edge);
 border-radius:10px;padding:3px 12px;font-weight:800;font-size:14px;letter-spacing:.08em;box-shadow:0 3px 0 var(--shadow)}
.private{display:flex;gap:20px;align-items:center}

/* Pages */
.pagehead{display:flex;align-items:center;justify-content:space-between;gap:24px;margin:40px auto 8px}
.pagehead .px{width:110px;height:auto;flex:none;animation:hop 2.6s ease-in-out infinite}
@media (prefers-reduced-motion:reduce){.pagehead .px{animation:none}}
.contact{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin:6px 0 16px}
.contact .btn{justify-content:center;flex-direction:column;gap:4px;padding:16px;text-align:center}
.contact .btn small{font-weight:600;font-size:14px;color:inherit;opacity:.8;word-break:break-all}
.note{background:var(--sun);border:2px dashed var(--edge);border-radius:16px;padding:14px 16px;font-size:16px;line-height:1.5;margin:14px 0 0}
details{border-top:2px dashed var(--line);padding:2px 0}
details:first-of-type{border-top:0}
summary{cursor:pointer;font-weight:800;padding:12px 40px 12px 0;list-style:none;position:relative}
summary::-webkit-details-marker{display:none}
summary::after{content:"+";position:absolute;right:0;top:50%;transform:translateY(-50%);width:28px;height:28px;display:grid;place-items:center;
 border:2px solid var(--edge);border-radius:8px;background:var(--gold);color:#1d3833;font-size:18px;line-height:1}
details[open] summary::after{content:"\\2212"}
details p,details ul{color:var(--muted)}
.short{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin:0;padding:0;list-style:none}
.short li{border:2px solid var(--edge);border-radius:18px;padding:16px;margin:0;font-size:16px;line-height:1.45}
.short li:nth-child(4n+1){background:var(--mint)}.short li:nth-child(4n+2){background:var(--sun)}
.short li:nth-child(4n+3){background:var(--rose)}.short li:nth-child(4n+4){background:var(--sky)}
.short strong{display:block;font-size:18px;margin-bottom:3px}
nav.toc ol{columns:2;column-gap:28px;margin:0;padding-left:24px;font-size:16px;font-weight:600}
nav.toc li{break-inside:avoid}
table{width:100%;border-collapse:collapse;font-size:16px;line-height:1.45}
th{text-align:left;font-size:13px;font-weight:800;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);padding:0 12px 8px 0}
td{vertical-align:top;padding:12px 12px 12px 0;border-top:2px dashed var(--line)}
td:first-child{font-weight:800;width:27%}
th:last-child,td:last-child{padding-right:0}

/* Footer */
footer{margin-top:72px}
.ground{height:10px;margin:0 0 22px;border-radius:4px;background:repeating-linear-gradient(90deg,var(--edge) 0 10px,transparent 10px 20px)}
.legal{margin:18px 0 0;text-align:center;color:var(--muted);font-size:14px;font-weight:600}
.legal a{color:var(--muted);white-space:nowrap}

@media (max-width:820px){
 .screens{display:flex;overflow-x:auto;scroll-snap-type:x mandatory;gap:18px;padding:8px 4px 16px;margin:0 -16px;padding-left:16px;padding-right:16px}
 .screens li{flex:0 0 min(62vw,240px);scroll-snap-align:center}
 .hero{grid-template-columns:1fr;gap:28px;margin-top:28px}
 .stage{max-width:380px;width:100%;margin:0 auto}
 .features{grid-template-columns:repeat(2,minmax(0,1fr))}
}
@media (max-width:620px){
 body{font-size:16px}.wrap{padding:14px 16px 32px}
 .brand{font-size:20px}
 .top nav{order:3;width:100%}.links{justify-content:space-between;gap:0}.links a{padding:6px 8px;font-size:15px}
 .features,.plans,.short,.contact{grid-template-columns:1fr}
 .card,section{padding:22px 18px;border-radius:20px}
 .pagehead .px{width:72px}
 nav.toc ol{columns:1}
 .private{flex-direction:column;align-items:flex-start}
 thead{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}
 table,tbody,tr,td{display:block;width:100%}
 tr{border-top:2px dashed var(--line);padding:12px 0}tr:first-child{border-top:0;padding-top:0}tr:last-child{padding-bottom:0}
 td,td:first-child{border:0;padding:0;width:100%}td:first-child{margin-bottom:2px}td+td{color:var(--muted)}td+td+td{margin-top:4px}
}
@media print{body{background:#fff}.card,section,.features li,.plan{box-shadow:none;border-width:1px}nav,.actions,.stage,.pagehead .px,.ground{display:none}a{color:inherit}}
"""

# The logo is the way home. The tabs go from learning about the app, to getting help, to the legal page.
PAGES = (('/#what', 'Features'), ('/#plans', 'Pricing'), ('/support', 'Support'), ('/privacy', 'Privacy'))


def page(path: str, title: str, description: str, body: str) -> str:
    """A full HTML page with the shared header, links and footer."""
    links = ''.join(f'<li><a href="{href}"{" aria-current=page" if href == path else ""}>{name}</a></li>' for href, name in PAGES)

    def bar(label: str) -> str:
        # The same logo, tabs and button at the top and bottom of every page.
        return (f'<a class="brand" href="/"{" aria-current=page" if path == "/" else ""}>{penny()} HowMuch</a>'
                f'<nav aria-label="{label}"><ul class="links">{links}</ul></nav>'
                f'<a class="btn primary cta" href="{APP_STORE}">Get the app</a>')
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#fff7e6" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#10231f" media="(prefers-color-scheme: dark)">
<meta name="apple-itunes-app" content="app-id=6830079731">
<title>{escape(title)}</title>
<meta name="description" content="{escape(description)}">
<style>{STYLE}</style>
</head>
<body><main class="wrap">
<header class="top">{bar("Site")}</header>
{body}
<footer>
 <div class="ground"></div>
 <div class="top">{bar("Footer")}</div>
 <p class="legal">HowMuch by Jia Le Khoo &middot; <a href="/terms">Terms of Use</a></p>
</footer>
</main></body>
</html>
"""


def page_head(title: str, lede: str, extra: str = '') -> str:
    """The heading of an inner page, with Penny beside it."""
    return f"""<header class="pagehead narrow">
 <div><h1>{title}</h1><p class="lede">{lede}</p>{extra}</div>
 {penny()}
</header>"""


SCREEN_ITEMS = ''.join(
    f'<li><span class="phone"><img src="/screens/{name}.jpg" width="552" height="1200" loading="lazy" decoding="async" alt="{escape(alt)}"></span>'
    f'<span class="label">{title}</span></li>' for name, title, alt in SCREENS)

HOME = page('/', 'HowMuch: Work & Pay', 'Track the shifts you work and the pay you are owed. Built for event crew, promoters and anyone paid by the shift.', f"""
<div class="hero">
 <div>
  <span class="kicker">For anyone paid by the shift</span>
  <h1>Know how much you&rsquo;re <span class="mark">owed</span></h1>
  <p class="lede">HowMuch keeps track of the shifts you work and the money you&rsquo;re owed. It&rsquo;s built for event crew, promoters, part-timers and anyone paid by the shift.</p>
  <div class="actions"><a class="btn primary" href="{APP_STORE}">{coin()} Download on the App Store</a><a class="btn" href="/support">Get help</a></div>
 </div>
 <div class="stage" role="img" aria-label="Penny, the HowMuch pet, hopping among gold coins and saying Ka-ching!">
  <div class="window"></div>
  {coin('coin c1')}{coin('coin c2')}{coin('coin c3')}
  <div class="bubble">Ka-ching!</div>
  {penny('penny')}
 </div>
</div>

<section class="bare" aria-labelledby="inside">
 <div class="section-title"><h2 id="inside">Take a look inside</h2><p>Real screens from the app, with demo data.</p></div>
 <ul class="screens">{SCREEN_ITEMS}</ul>
</section>

<section class="bare" aria-labelledby="what">
 <div class="section-title"><h2 id="what">What it does</h2><p>Everything between &ldquo;you&rsquo;re hired&rdquo; and &ldquo;you&rsquo;ve been paid&rdquo;.</p></div>
 <ul class="features">
  <li>{icon('paste')}<h3>Add jobs in seconds</h3><p>Paste a job message from WhatsApp or Telegram, and the dates, times, venue and pay are filled in for you to check.</p></li>
  <li>{icon('earned')}<h3>See what you&rsquo;ve earned</h3><p>Earnings by day, week, month and event, plus what&rsquo;s still booked and what&rsquo;s waiting to be paid.</p></li>
  <li>{icon('paid')}<h3>Get paid on time</h3><p>Mark shifts paid, set due dates and get a nudge when pay is late. Pay-in tracking can match bank alerts to your jobs.</p></li>
  <li>{icon('work')}<h3>While you work</h3><p>Your shift on the Lock Screen, reminders before you start, and a time-to-leave alert with directions.</p></li>
  <li>{icon('receipt')}<h3>Claims and receipts</h3><p>Keep cab and meal claims with receipt photos alongside each job.</p></li>
  <li>{icon('penny')}<h3>Meet Penny</h3><p>A pixel pet that grows as you work and get paid. Dress it up, and say hi to friends&rsquo; pets.</p></li>
 </ul>
</section>

<section class="bare" aria-labelledby="plans">
 <div class="section-title"><h2 id="plans">Free, with HowMuch Pro for more</h2></div>
 <div class="plans">
  <div class="plan free"><h3>Free</h3><p>Tracking shifts in up to 5 events, your earnings, the work calendar and Penny are free.</p></div>
  <div class="plan pro"><span class="sticker">PRO</span><h3>HowMuch Pro</h3><p>HowMuch Pro adds unlimited events, Pay-in tracking, reminders and the live shift on the Lock Screen, calendar sync and exports, and insights and widgets. Choose monthly or yearly, each with a free first week for new subscribers, or a one-time lifetime purchase. Prices for your region are shown in the app.</p></div>
 </div>
</section>

<section aria-labelledby="private" class="private">
 {icon('shield')}
 <div><h2 id="private">Private by design</h2>
 <p>You sign in with Apple, and your records sync across your devices. There are no ads and no tracking, and your data is never sold. Friends only ever see your pet, never your shifts or pay. Read the <a href="/privacy">privacy policy</a>.</p></div>
</section>
""")


SUPPORT = page('/support', 'Support | HowMuch', 'Help with HowMuch: contact us on Telegram or by email, and answers about getting started, syncing, HowMuch Pro, Pay-in tracking and deleting your account.', page_head(
    'Support', 'Message us on Telegram or by email, or find answers to common questions below.') + f"""
<div class="narrow">
<section aria-labelledby="contact">
 <div class="head">{icon('chat')}<h2 id="contact">Contact us</h2></div>
 <p>For any issue, message <a href="https://t.me/{TELEGRAM}">@{TELEGRAM}</a> on Telegram or email <a href="mailto:{CONTACT}?subject=HowMuch%20support">{CONTACT}</a>. We reply within 7 days, usually sooner.</p>
 <div class="contact">
  <a class="btn primary" href="https://t.me/{TELEGRAM}">Telegram<small>@{TELEGRAM}</small></a>
  <a class="btn" href="mailto:{CONTACT}?subject=HowMuch%20support">Email<small>{CONTACT}</small></a>
 </div>
 <p>It helps to include the app version (at the bottom of Settings), your iPhone model and iOS version, and the steps that led to the problem. A screenshot helps too.</p>
 <p class="note">Please never send passwords, app passwords or full bank statements. We will never ask for them.</p>
</section>

<section aria-labelledby="start">
 <div class="head">{icon('paste')}<h2 id="start">Getting started</h2></div>
 <details><summary>How do I add a shift?</summary>
  <p>Tap + and fill in the date, times and pay. You can also copy a job message and tap Paste in Add shift, share a message to HowMuch from Messages or Notes, or ask Siri to add a job.</p></details>
 <details><summary>Do I need an account?</summary>
  <p>Yes. You sign in with Apple, so there&rsquo;s no new password. Your records belong to that account and sync to every device where you sign in with it.</p></details>
 <details><summary>My shifts aren&rsquo;t showing on my other device</summary>
  <p>Check that both devices are signed in to the same Apple Account in HowMuch (Settings &rarr; Account &amp; sync) and are online. Changes sync when the app is open.</p></details>
</section>

<section aria-labelledby="pro">
 <div class="head">{icon('paid')}<h2 id="pro">HowMuch Pro and purchases</h2></div>
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
 <div class="head">{icon('penny')}<h2 id="features">Features</h2></div>
 <details><summary>How does Pay-in tracking work?</summary>
  <p>It matches money you receive to your jobs, in Settings &rarr; Pay-in tracking. You can pass bank app notifications to HowMuch with a Shortcuts automation, forward bank alert emails to your private HowMuch address, or connect a mailbox. Matches wait for your confirmation before a job is marked paid. It&rsquo;s off until you set it up.</p></details>
 <details><summary>Can I see my shifts in Apple or Google Calendar?</summary>
  <p>Yes, with Settings &rarr; Calendar sync. It gives you a private calendar link. Anyone with the link can see those shifts, so keep it private, and rotate it in the app if you shared it by mistake.</p></details>
 <details><summary>How does Penny earn coins?</summary>
  <p>Penny earns coins when you work shifts and get paid, finish missions, earn badges and say hi to friends. Spend them in the shop on your pet&rsquo;s page. Tap any item to try it on first.</p></details>
</section>

<section aria-labelledby="data">
 <div class="head">{icon('shield')}<h2 id="data">Your data</h2></div>
 <details><summary>How do I back up or export my records?</summary>
  <p>Settings &rarr; Data &amp; backups. A full archive includes your records and receipt photos. Keep it somewhere private.</p></details>
 <details><summary>How do I delete my account?</summary>
  <p>Settings &rarr; Account &amp; sync &rarr; Delete account. This deletes your account and its records from HowMuch, disconnects any mailbox and removes your friendships. It can&rsquo;t be undone, so export a backup first if you want to keep a copy.</p></details>
 <details><summary>What do you do with my data?</summary>
  <p>Only what&rsquo;s needed to run the app. No ads, no tracking, and your data is never sold. The <a href="/privacy">privacy policy</a> has the details.</p></details>
</section>
</div>
""")
