# Pay tracker Telegram bot

Log a shift in Telegram and the bot calculates the pay and stores it in SQLite.

To log, key in the event name, the date and time, and (optionally) the location
and pay rate — in any order:

```
Wedding gig 12/8 6pm-11.30pm 25/h @ Marina Bay Sands
12/8 6pm-11.30pm Wedding gig
2026-08-12 18:00 23:30 Wedding gig
Roadshow today 9am to 5pm
```

Without a rate in the line, the stored rate for that event (or your default) is used.
A location is anything after `@` or `at`; it shows up in listings and the CSV export.

Reply: `Logged #3: Wedding gig — 5.5h @ SGD 25.00/h — Pay: SGD 137.50`

Shifts ending after midnight (e.g. `10pm - 2am`) roll over to the next day.

## Batches and inline rates

Send one shift per line to log them all in one message; `15/h` (or `$15 per hour`)
in a line overrides the stored rate for that shift only:

```
13/8 8.30am - 8pm 15/h Hermes Private Sale
14/8 9am - 8pm 15/h Hermes Private Sale
15/8 9am - 9pm 15/h Hermes Private Sale
```

The reply lists each logged shift plus the batch total; unreadable lines are
reported without blocking the rest.

## Double bookings

Logging a shift that overlaps one you already stored still logs it, but the reply
warns which shift it clashes with (overnight shifts are compared properly).
`/upcoming` lists what you're booked for from today onwards and flags clashes.

## Calendar

`/calendar` sends a `.ics` file of your upcoming shifts (open it to add them to Apple
or Google Calendar) plus a tap-to-add Google Calendar link per shift. `/calendar aug`
exports one month, `/calendar all` everything, `/calendar #12 #13` specific shifts.
Overnight shifts end on the following day, and Google links use the timezone from
`/reminders`.

### Auto-syncing subscription (TimeTree, Google, Apple)

`/calendarlink` returns a private feed URL your calendar app subscribes to once and
re-reads on its own, so shifts you log or delete later update themselves. Subscribe
in Google Calendar (*Other calendars → + → From URL*) or on iPhone (*Settings →
Calendar → Accounts → Add Subscribed Calendar*); TimeTree then picks the shifts up
through its calendar sync, since it imports from the phone's calendars rather than
from an .ics URL. `/calendarlink new` rotates the link if it leaks.

The feed only runs when the bot is started with a reachable address:

```bash
export PAYBOT_FEED_PORT=8799            # local port the feed listens on
export PAYBOT_FEED_URL=https://your-host # public base URL of that port
```

Google Calendar refuses URLs carrying basic-auth credentials, so host the feed
somewhere with a plain `https://host/<token>.ics` address (see below).

## Reminders

`/reminders on` sends you a message the evening before (20:00, UTC+8 by default)
listing the shifts you have the next day. `/reminders 19:30 +8` changes the time or
timezone, `/reminders off` stops them. The bot process must be running for these to
arrive.

## Breaks

Mention a break anywhere in the message; unpaid breaks are deducted from paid hours,
paid breaks are not:

```
today 9am-6pm 1h unpaid break Roadshow    -> 8h paid
today 9am-6pm 1 hour paid break Roadshow  -> 9h paid
today 9am-6pm 30min break Roadshow        -> uses the /break default
today 9am-6pm no break Roadshow           -> ignores the /break default
```

`/break 1 unpaid` applies a default break to every shift that doesn't mention one.

## Commands

`/commands` lists everything in chat, and the same list is published to Telegram's
command menu on startup. Unknown commands get a nudge back to `/commands`.

| Command | Purpose |
| --- | --- |
| `/commands` | List every command (alias `/cmds`) |
| `/help` | How to log shifts (alias `/start`) |
| `/log <shift>` | Log a shift (or just send it as a plain message) |
| `/rate` | Show current rates |
| `/rate 25` | Set the default hourly rate |
| `/rate wedding gig 30` | Rate for a specific event name |
| `/clearrate wedding gig` | Remove an event rate |
| `/currency SGD` | Currency label |
| `/overtime 8 1.5` | ×1.5 beyond 8 hours (`/overtime off` to disable) |
| `/break 1 unpaid` | Default break for shifts that don't mention one (`/break off`) |
| `/upcoming [days]` | Shifts you're booked for (next 14 days by default) |
| `/reminders on\|off\|20:00 [+8]` | Message the evening before each shift |
| `/list [month]` | Recent shifts, or every shift in a month |
| `/month` | Summary per month; `/month aug` lists that month's shifts |
| `/total [month]` | Every shift in the month plus month and all-time totals (this month by default) |
| `/delete <id> [id ...]` | Delete shifts; the reply shows the recomputed totals |
| `/clear [month]` | Delete a whole month (or everything) after confirming |
| `/calendar [month\|all\|#id]` | `.ics` file + Google Calendar links (alias `/ics`) |
| `/calendarlink [new]` | Subscription URL that stays in sync (alias `/subscribe`) |
| `/export [month]` | CSV export |

Months can be written as `2026-08`, `aug`, `August 2025`, `8`, `this month`, or
`last month`.

## Setup

1. Message [@BotFather](https://t.me/BotFather) on Telegram → `/newbot` → copy the token.
2. Install and run:

```bash
pip install -r requirements.txt
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export PAYBOT_DB="paybot.sqlite3"   # optional, defaults to ./paybot.sqlite3
python -m paybot.bot
```

The bot uses long polling, so it works from any machine with outbound internet —
no public URL needed. Keep the process running (e.g. `systemd`, `tmux`, or a
small VPS) for the bot to stay responsive.

### Hosting bot + calendar feed together

`paybot.web` runs the bot and serves the subscription feed in one process, which
is what any host (Fly.io, Render, Railway, a VPS) needs:

```bash
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export PAYBOT_FEED_URL="https://your-app.example.com"   # public address of this service
uvicorn paybot.web:app --host 0.0.0.0 --port ${PORT:-8000}
```

The included `Dockerfile` does exactly that and keeps the database on a `/data`
volume, so shifts survive redeploys. `GET /healthz` is a health check and
`GET /<token>.ics` is the per-user feed.

## Tests

```bash
python -m pytest
```
