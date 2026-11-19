# Native feature coverage

| Function | Independent iOS app |
|---|---|
| Overview, live earnings, currency totals | Native |
| Hourly/fixed pay, breaks, overtime, overnight work | Native |
| Search/edit/delete/duplicate and multi-date jobs | Native |
| Calendar grid, selected-day jobs and overlaps | Native |
| Apple Calendar editor and ICS export | Native |
| Private calendar subscription and link rotation | Own account API |
| Paid status, payout dates, cab claims | Native and account sync |
| Profile, default rates/breaks, payer labels | Native and account sync |
| CSV import, CSV export, full archives/restore | Native; optional Telegram migration |
| Gmail connect/disconnect, scan, rules, auto-mark | Native screens, independent Google OAuth required |
| Receipt review/dismiss/undo | Own account API and payment audit |
| Upcoming, start/end and payment-due alerts | Account preferences; APNs plus local fallback |
| Unique account, sign-out and deletion | Mandatory Sign in with Apple |
| Offline edits and multi-device conflicts | Account cache, revision checks, explicit conflict review |

No live Telegram connection, pairing code, bot token or shared bot database is required. Backend engine modules are reused as independent source, with account ownership enforced by verified iOS sessions.

Apple capabilities and separate sign-in/production/sandbox keys are configured on the deployed independent service. Real user authentication and remote delivery still require signed physical-device verification. Gmail uses the separate howmuch-ios-2026 Google project and deployed credentials; its beta is restricted to approved OAuth test users and each user must connect their own mailbox. Live consent and scanning remain physical-device checks. Test-only accounts and preview sample data are Debug-only.
