# App Store submission — HowMuch 1.0

Everything App Store Connect asks for, ready to paste. App record: `6830079731`
("HowMuch: Work & Pay"), bundle `com.jialekhoo.howmuch`.

## Listing

**Name** (30): `HowMuch: Work & Pay`

**Subtitle** (30): `Track shifts, pay and payouts` (29)

**Promotional text** (170, can change without review):
> Paste a job message from WhatsApp and HowMuch fills in every date, time and rate. See your pay live on the Lock Screen while you work.

**Description**:
> HowMuch keeps track of the shifts you work and the money you're owed — built for event crew, promoters, part-timers and anyone paid by the shift.
>
> ADD JOBS IN SECONDS
> • Paste a job offer from WhatsApp or Telegram, or share it straight to HowMuch. Dates, times, venue and pay are filled in for you to check.
> • Multi-day jobs, overnight shifts, breaks, hourly or fixed pay, and overtime.
> • Add a job from Siri, Spotlight or Control Center.
>
> KNOW WHAT YOU'VE EARNED
> • Earnings by day, week, month and event, kept separate by currency.
> • See what's been worked, what's still booked and what's awaiting payment.
> • Mark shifts paid, set payment due dates and get reminded when pay is late.
> • Ask Siri "How much did I earn this week?" or "How much am I owed?"
>
> WHILE YOU WORK
> • A Lock Screen and Dynamic Island card shows time left and your pay for the shift.
> • Staying late? Tap +30 min and the pay updates, overtime included.
> • Reminders before each shift, and a time-to-leave alert with directions.
>
> STAY ORGANISED
> • Work calendar, widgets for your next shift and this month, and Apple Calendar export.
> • Keep cab and meal claims with receipt photos alongside each job.
> • CSV import and export, and full backups.
>
> Your records belong to your Apple account and sync across your devices. No ads, no tracking.

**Keywords** (100): `shift,pay,tracker,timesheet,part time,gig,event crew,earnings,hours,wage,overtime,payslip,freelance` (98)

**Support URL**: https://howmuch-ios.fly.dev/support
**Marketing URL**: (optional, leave blank)
**Privacy Policy URL**: https://howmuch-ios.fly.dev/privacy
**Copyright**: `2026 Jia Le Khoo`
**Category**: Primary *Productivity*, secondary *Finance*
**Price**: Free. **Availability**: Singapore first (the copy, currency and DBS alerts are Singapore-focused), or all regions.
**Age rating**: answer *None* to every content question → 4+.

## Screenshots

Upload `output/app-store/real-6.9in/` (1320 × 2868, 6.9" display) in this order:
1. `01-overview.png` — Overview with today's shift
2. `02-calendar.png` — Work calendar
3. `03-earnings.png` — Earnings by event
4. `04-paste-job.png` — Add shift filled in from a pasted message

These are real captures of build 33's screens with demo data. The AI artwork in
`marketing-v2/` shows UI that doesn't exactly match the app (older "$" amounts,
invented details); Apple rejects screenshots that misrepresent the app, so use it
only if every screen is checked against the real app first. iPad screenshots are
not needed (iPhone only). Apple scales the 6.9" set for smaller iPhones.

## App Privacy (nutrition label)

Tracking: **No**. For each type below: *Linked to the user*, purpose *App Functionality*, not used for tracking.

| Data type | Why |
|---|---|
| Contact Info → Name | Sign in with Apple name on the profile |
| Contact Info → Email Address | Sign in with Apple email (may be a relay address) |
| Identifiers → User ID | Apple account identifier for the HowMuch account |
| Financial Info → Other Financial Info | Shift pay, rates, payment status |
| User Content → Photos or Videos | Receipt photos attached to claims (optional) |
| User Content → Other User Content | Shifts, events, venues, claims and notes synced to the account |
| Location → Precise Location | Only with Time to leave on: the saved departure address, to work out when to leave |

Not collected in 1.0: Emails or Text Messages (Payment detection was left out of 1.0).

**From 1.1** add *User Content → Emails or Text Messages* (linked, App Functionality, no tracking): Pay-in tracking reads DBS alert emails from a connected Gmail/Outlook/iCloud mailbox or forwarded to the private address, and bank notification text. Before submitting 1.1, note in App Review that Gmail connection only works for accounts added as Google test users until Google verifies the restricted Gmail scope (Outlook and iCloud work for everyone).
This matches `HowMuch/PrivacyInfo.xcprivacy` and the privacy policy at /privacy.

## App Review information

**Sign-in required**: Yes, Sign in with Apple only. No demo account is needed —
reviewers sign in with their own Apple ID. Write this in the notes:

> HowMuch uses Sign in with Apple only; please sign in with any Apple ID. A new account starts empty: tap + to add a shift, or copy this message and tap Paste in Add shift:
>
> Location: Raffles City
> 20th Nov 1000-1900hrs
> 21st Nov 1000-1900hrs
> Pay: $14/hr
>
> Payment detection (email alerts) is not part of version 1.0.
>
> Features to try: Lock Screen Live Activity (add a shift starting within 30 minutes), Siri ("How much did I earn this week in HowMuch"), Control Center "Add a job" control, Share → HowMuch from Notes or Messages, home-screen widgets. Accounts can be deleted in Settings → Account & sync → Delete account.

**Contact**: name, phone and email of the account holder (same as the TestFlight beta review contact).

## Export compliance

Already answered in the build (`ITSAppUsesNonExemptEncryption = NO`): only standard HTTPS.

## Submission steps (App Store Connect → HowMuch: Work & Pay)

1. Distribution → iOS App → **1.0 Prepare for Submission**.
2. Paste the listing text above; upload the 4 screenshots.
3. Build → choose the latest processed build (34 or later, which removes the "iOS beta" footer).
4. App Information: categories, age rating, privacy policy URL.
5. App Privacy: fill in the table above, then Publish.
6. Pricing and Availability: Free, regions.
7. App Review Information: notes and contact above.
8. Version Release: *Manually release* (recommended for a first launch) or automatic.
9. **Add for Review** → **Submit to App Review**. Review usually takes 1–3 days.

## Before submitting

- [x] Payment detection left out of App Store builds until Google verifies Gmail access (still in debug builds).
- [x] Support and privacy pages rewritten for launch with a contact email (deploy the API to publish them).
- [ ] Upload build 34 (no "iOS beta" label, no Payment detection) and wait for processing.
- [ ] Check on a real iPhone: sign-in, add/edit/delete a shift, Live Activity, Delete account.

## Version 1.1 — review notes and privacy changes

**App Privacy answers to update before submitting 1.1** (App Store Connect → App Privacy):
- Add **Emails or Text Messages** (linked, not tracking, App Functionality): bank notification text passed by the user's Shortcuts automation, and bank alert emails the user forwards or connects.
- Add **Identifiers → Device ID** (linked, not tracking, App Functionality): a random installation ID used to deliver notifications to that iPhone.
- Keep everything else as in 1.0. Apple Intelligence features run on-device and send nothing.

**Review notes for 1.1** (paste into App Review Information → Notes):

> HowMuch uses Sign in with Apple only; please sign in with any Apple ID. A new account starts empty: tap + to add a shift, or copy this message and tap Paste in Add shift:
>
> Location: Raffles City
> 20th Nov 1000-1900hrs
> 21st Nov 1000-1900hrs
> Pay: $14/hr
>
> New in 1.1 — Pay-in tracking (Settings → Pay-in tracking), optional and off until the user sets it up:
> • Bank app notifications (iOS 27): the user creates a Shortcuts automation "When I receive a notification from <bank app>" that runs HowMuch's "Record pay received" action. To try it without a bank account, open Shortcuts, add the "Record pay received" action from HowMuch to a new shortcut, type this text into its Notification field and run it: "You have received SGD 14.00 from REFIX PTE. LTD." (first add a shift and set Paid by to REFIX PTE. LTD.). HowMuch checks the text on the iPhone and sends only money-received alerts.
> • Email forwarding: each account has a private address; forwarded bank alert emails appear in Pay-in tracking for the user to confirm.
> • Gmail mailbox connection is hidden in this version while Google verification is in progress. Outlook and iCloud connections use read-only access to find bank alerts only.
> • Apple Intelligence (iOS 26+, supported devices) reads job messages, bank alerts and receipts and writes a monthly recap, entirely on-device.
> • Calendar sync: Settings → Calendar sync creates a private calendar feed for Apple Calendar or Google Calendar.
>
> Accounts can be deleted in Settings → Account & sync → Delete account, which also revokes any connected Gmail access.
