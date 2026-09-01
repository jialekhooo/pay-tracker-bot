---
name: testing-webapp-miniapp
description: How to run and end-to-end test the paybot Telegram Mini App frontend (paybot/static/webapp) locally in a phone-sized browser, with a seeded SQLite DB and a frozen clock, without Telegram credentials.
---

# Testing the paybot Mini App frontend locally

The Mini App is plain HTML/JS served by FastAPI from `paybot/static/webapp/` (`app.js`,
`index.html`, asset URLs are cache-busted like `?v=52` — hard-reload if you see stale JS/CSS).
No Telegram credentials are needed: a small local harness fakes `initData`, so all UI flows
(Overview, Earnings, Calendar, Add, editor sheet) can be driven from a normal browser.

## Harness pattern (recommended)

Write a throwaway FastAPI harness (e.g. `/home/ubuntu/webapp-test/harnessN.py`) that:

1. Sets a dedicated SQLite path (`harnessN.sqlite3`) and a dedicated port. Use a port nobody
   else is on — other agents/sessions may grab common ports (8111/8112/…); if UI data suddenly
   doesn't match your seed, suspect another server took your port and re-check with
   `ss -ltnp` / the sqlite contents before doubting the code.
2. Seeds shifts directly into the DB. Columns are `start_time` / `end_time` (not `start`/`end`).
3. Serves the real static webapp dir plus the real API routes, injecting a fake signed token
   for a seeded user id.
4. Optionally freezes the clock by monkeypatching `paybot.webapp.local_clock` to return a fixed
   `datetime`. This is essential for testing lists that depend on "now" (Worked this month,
   Upcoming ranges, `worked_by` done/running/upcoming states) — otherwise your seed data may
   collapse into a single day and multi-day code paths never render.

Start it detached:

```bash
cd /home/ubuntu/webapp-test && setsid env PYTHONPATH=/home/ubuntu/repos/pay-tracker-bot \
  nohup python harnessN.py > harnessN.log 2>&1 < /dev/null &
```

## Seeding for ordering / grouping tests

Seed at least two shifts on the same day at different times AND several distinct days across
two months. Same-day pairs are what expose bugs where only the day groups are reordered but
intra-day rows are not (or vice versa). Also seed an empty month/day to exercise empty states.

## Browser

Test in a phone-sized window (~390x700). Playwright's bundled Chromium may be missing
(`Executable doesn't exist at ~/.cache/ms-playwright/...`); reuse the running Chrome instead:

```python
browser = p.chromium.connect_over_cdp("http://localhost:29229")
```

Prefer native computer-use clicks for the actual demo/recording; use CDP only for setup/probing.

## Useful selectors in app.js

- tabs: `[data-view="summary"]` (Earnings), nav buttons for Overview/Calendar/Settings
- Earnings scopes: `[data-scope="today|week|month|all"]`
- Overview drill-downs: `[data-dashboard-stat="worked|upcoming"]`
- Upcoming ranges: `[data-upcoming-range="tomorrow|7|14|30|all"]`
- Calendar day: `[data-calendar-day="YYYY-MM-DD"]`
- event sort: `[data-event-sort="date|alphabetical"]`
- date order toggle: `[data-date-order="asc|desc"]`

Clicks are handled by one delegated document click handler, so re-render happens on any click on
these attributes — checking the DOM right after a click is reliable.

## Gotchas

- `/webapp?token=...` returns 307; use the harness root URL.
- Grouped lists render via `shiftGroupsSection()` which only prepends the "Order" toggle when the
  list spans >1 distinct day; single-day lists (Calendar selected day, Earnings Day, Overview
  "Tomorrow") show no toggle but their rows still follow the session `dateOrder` state, because
  `shiftDayCard` also sorts through `orderedByDay`. Expect that when asserting row order there.
- The editor sheet has no "pay" field — pay is derived from `Rate / hour` × hours; edit the rate
  to change a row's amount.

## Devin Secrets Needed

None — the harness fakes Telegram `initData` and signs its own token.
