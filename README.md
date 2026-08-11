# Pay tracker Telegram bot

Log a shift in Telegram and the bot calculates the pay and stores it in SQLite.

To log, key in the event name, the date and time, and (optionally) the pay rate —
in any order:

```
Wedding gig 12/8 6pm-11.30pm 25/h
12/8 6pm-11.30pm Wedding gig
2026-08-12 18:00 23:30 Wedding gig
Roadshow today 9am to 5pm
```

Without a rate in the line, the stored rate for that event (or your default) is used.

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

| Command | Purpose |
| --- | --- |
| `/rate` | Show current rates |
| `/rate 25` | Set the default hourly rate |
| `/rate wedding gig 30` | Rate for a specific event name |
| `/clearrate wedding gig` | Remove an event rate |
| `/currency SGD` | Currency label |
| `/overtime 8 1.5` | ×1.5 beyond 8 hours (`/overtime off` to disable) |
| `/break 1 unpaid` | Default break for shifts that don't mention one (`/break off`) |
| `/list [month]` | Recent shifts, or every shift in a month |
| `/month` | Summary per month; `/month aug` lists that month's shifts |
| `/total [month]` | Every shift in the month plus month and all-time totals (this month by default) |
| `/delete <id> [id ...]` | Delete shifts; the reply shows the recomputed totals |
| `/clear [month]` | Delete a whole month (or everything) after confirming |
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

## Tests

```bash
python -m pytest
```
