# Pay tracker Telegram bot

Log a shift in Telegram and the bot calculates the pay and stores it in SQLite.

```
12/8 6pm-11.30pm Wedding gig
2026-08-12 18:00 23:30 Wedding gig
today 9am to 5pm Roadshow
```

Reply: `Logged #3: Wedding gig — 5.5h @ SGD 25.00/h — Pay: SGD 137.50`

Shifts ending after midnight (e.g. `10pm - 2am`) roll over to the next day.

## Commands

| Command | Purpose |
| --- | --- |
| `/rate` | Show current rates |
| `/rate 25` | Set the default hourly rate |
| `/rate wedding gig 30` | Rate for a specific event name |
| `/clearrate wedding gig` | Remove an event rate |
| `/currency SGD` | Currency label |
| `/overtime 8 1.5` | ×1.5 beyond 8 hours (`/overtime off` to disable) |
| `/list [YYYY-MM]` | Recent shifts |
| `/total [YYYY-MM]` | Total hours and pay |
| `/delete <id>` | Delete a shift |
| `/export [YYYY-MM]` | CSV export |

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
