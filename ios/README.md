# HowMuch for iPhone

Native SwiftUI app for iOS 17+. A unique Sign in with Apple account is required. This app uses its own service and database; it never pairs with or signs in through the Telegram bot. Existing Telegram shifts can be imported once from CSV.

## Run and verify

Open `HowMuch.xcodeproj`, select HowMuch and an installed iPhone simulator. Real Apple sign-in requires the registered app identifier, entitlements and signing. Debug launch argument `--preview` opens an in-memory sample account without touching saved records, requesting notification permissions or contacting a mailbox. Preview and UI test bypasses are excluded from Release builds.

```sh
swift test --package-path ios
xcodebuild -project ios/HowMuch.xcodeproj -scheme HowMuch -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO test
```

Core tests cover pay, calendars, CSV imports, archive compatibility, account merge conflicts and notification schedules. UI tests cover navigation, shift/claim persistence, account switching and mandatory sign-in. See QA.md for verification and limitations.

## Independent accounts

The permanent bundle identifier is `com.jialekhoo.howmuch`, team `8FSHKXDVJ2`. The API is `https://howmuch-ios.fly.dev`. Apple subjects identify accounts; matching emails never merge accounts. The backend validates Apple signatures, audience, issuer, expiry and a single-use nonce. API sessions use hashed opaque tokens and rotating refresh tokens. Keychain stores this device’s session; protected caches live in separate account UUID directories.

Account sync uses revision checks and three-way merges. Conflicting versions are preserved and require review. Offline edits remain in the signed-in account cache. Sign-out hides its records and clears reminders, with scoped server revocation retried after an offline sign-out. Account deletion requires fresh Apple authentication, deletes owned records and disconnects payment/notification access. Apple token revocation failures are queued for retry without blocking deletion.

## Functions

Overview, Earnings, Add, Calendar and Settings retain hourly/fixed pay, overtime, breaks, overnight shifts, multiple dates, duplicate/search/edit/delete, event rates, paid status, payout dates, cab/food/miscellaneous claims, overlaps, calendar export, Apple Calendar editor, profile, archive backup/restore and undo. Currency totals stay separate. The account’s private calendar subscription can be rotated.

Gmail payment detection has native connect/disconnect, scan, payer rules, auto-marking, receipt review/dismiss/undo. It operates only on this app account and requires separate Google OAuth configuration. The dedicated howmuch-ios-2026 Google project and encrypted standalone service credentials are configured. Google OAuth remains External/Testing, limited to approved test users; each user must connect their own Gmail. Live mailbox consent and scanning still require device verification. The Telegram bot’s Gmail connection is never reused.

## Import Telegram data

Export all shifts with `/export` in Telegram or download the all-shifts CSV in the Mini App. Save to Files, then HowMuch → Settings → Import Telegram CSV. Imports are validated and additive; identical rows are skipped. Changed exported content is a new record. Telegram exports lack original rate/overtime settings, paid status, due dates and cab claims: imported amounts become fixed payouts, initially unpaid. There is no live Telegram sync.

Export full archive preserves settings, paid status, claims and rates. Restore validates and confirms replacement for the current account. An earlier anonymous beta cache is only imported explicitly and can be claimed by one account. The new bundle ID installs separately from earlier builds; export an archive from an earlier installation before removing it.

## Job notifications

Upcoming/day-before shifts, start reminders (30 minutes before), end reminders and payment due alerts are enabled in account preferences by default. The user must grant iOS notification permission. Types, timing and lock-screen details are configurable; details are hidden by default. APNs uses the independent server’s durable queue, scoped device registration, retries and invalid-token removal. Until the server has APNs credentials, the app truthfully uses local reminders and reports push as unavailable. Only one transport is active to avoid duplicate reminders.

## TestFlight activation

The developer membership is active. HowMuch is registered with Sign in with Apple and Push Notifications enabled. With the account holder’s confirmation, a Sign in with Apple key plus separate production and sandbox APNs keys were created and configured as encrypted secrets on the independent service. Each APNs key is topic-specific to `com.jialekhoo.howmuch`. Private backups are outside the repository with owner-only permissions. See ../howmuch_api/README.md for configuration.

Xcode is connected to the team. A verified distribution IPA can be produced without a registered iPhone using `python3 ios/scripts/export_testflight.py` from the repository root. This builds Release, preserves capability entitlements for export, uses Apple cloud-managed distribution signing and verifies the final IPA signature, profile, Apple sign-in capability and production push environment. It does not upload or accept agreements. The output is `ios/build/TestFlight/HowMuch.ipa`.

The account holder accepted App Store Connect terms. The app record is [HowMuch: Work & Pay](https://appstoreconnect.apple.com/apps/6830079731), Apple app ID `6830079731`, SKU `howmuch-ios-001`. The shorter name was unavailable; the installed display name remains HowMuch. Version 1.0 build 1 uploaded successfully on 3 November 2026 and completed Apple processing. Build 1 is assigned to Internal Beta with automatic distribution off; the account holder was added as the first tester with explicit permission. App Store Connect confirms version 1.0 (1) installed on an iPhone 17 Pro Max running iOS 27.0.1. Full beta contact/privacy information and physical-device verification remain necessary before wider testing. An unsigned archive cannot be uploaded. Verify real Apple sign-in, returning accounts, account deletion, APNs delivery and file/Calendar flows on a physical iPhone before inviting testers. Gmail additionally needs its own Google consent flow.

The privacy manifest declares account identity, name/email and app content for functionality, with no tracking or analytics SDK. The beta privacy/support endpoints are live service routes. Review App Store privacy answers and the final policy before public release.

External beta: Friends Beta contains two requested testers and version 1.0 (1), submitted for Beta App Review with automatic notification after approval. Its current confirmed status is Waiting for Review; the existing internal beta remains available.

Build 2 fixes Settings touch targets: each navigation row responds across its full width with a minimum 48-point height, the profile card has an explicit touch shape, and decorative card outlines do not intercept touches. Six UI tests passed, including the new full-row navigation and Settings-control regressions. Build 2 uploaded successfully on 3 November 2026; build 1 was withdrawn from external beta review for replacement.

Build 2 completed processing and was assigned to Internal Beta. Use TestFlight → HowMuch: Work & Pay → Update to install version 1.0 (2). The corrected build was also submitted to replace build 1 for Friends Beta; external access remains subject to Apple beta review.


Build 4 uses the supplied H logo for the App Store/home-screen icon and sign-in screen. Job notifications include exact start/end times, a tomorrow digest routed to the earliest shift, useful payment/hours review wording and per-job grouping. Native notification actions open the appropriate job; routing waits for account restoration and rechecks ownership after sync. Settings previews the privacy choice and can schedule a local test in five seconds without claiming to test APNs. Names and locations remain opt-in, and iOS controls lock-screen presentation, sound and Focus behavior. Existing scheduled server copy refreshes when work or notification preferences change; existing delivered notifications retain their original content/icon until replaced by iOS.


Build 5 allows multiple independent start reminders (2h, 1h, 30m, 15m, 5m and at start). Select the desired switches in Settings → Job notifications, then Save notification preferences. New lists skip already-passed times and each future selected time sends one alert per job. Existing single-time preferences and old archives still load. Older app versions preserve the new list during unrelated preference saves; explicitly changing their single-time picker replaces the multi-time choice. Server and local schedules support the same offsets. Day-before/end/payment-due reminders remain separately configurable.


Build 6 refreshes the screen chrome: one full-screen jade backdrop extends behind the status bar/home indicator; the four navigation destinations sit in a floating glass capsule beside a separate Add button. Search/profile controls use native SwiftUI Liquid Glass on iOS 26+, with a material fallback on earlier versions and opaque surfaces when Reduce Transparency is enabled. Content cards remain readable surfaces with explicit touch areas. Filter pills are at least 44 points high. All navigation identifiers and destinations remain intact. Reference: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views .

Build 7 extends that palette to job and cab details. Job cards prioritize payout, schedule, location and status; pay breakdown expands on demand. Cab reimbursements have dedicated ride cards and an amount/date/note editor, plus edit/delete actions with confirmation and undo. Existing claim IDs and attached jobs survive edits. Estimated bank credit shows work payout plus reimbursements while paid status continues to track work only. Full-width glass action labels preserve generous touch areas.

Version 1.0 (7) uploaded and assigned to Internal Beta on 3 November 2026. It replaces build 6 in Friends Beta review, with automatic tester notification after approval. Verification: 246 Python tests and four targeted native UI workflows passed; see QA.md for scope and physical-device limitations.

Build 8 redesigns Add/Edit Shift to match the cab editor: work, schedule, pay, break and payment cards on the jade background, native toolbar actions, glass additional-date controls and a payout preview. Existing pay options and multi-date behavior remain. Four targeted native workflows pass. The unsigned Release archive is ready; signing/export requires refreshing the expired Xcode Apple account session before upload. Build 7 remains the last assigned TestFlight release.

After Xcode reauthentication, build 8 signed/exported and uploaded successfully. Internal Beta confirms Testing; Friends Beta review submission replaces build 7, with automatic notification after approval.

Build 9 adds native Apple Maps integration. In Add/Edit Shift, Find a place in Apple Maps offers address/place suggestions and full search; selecting a place saves a readable address in the existing location field. Typed locations and old imports still work. Job details → Map & directions resolves the address, lets the user choose between matches, and shows a map preview before offering public transport, driving and walking in Apple Maps. Apple Maps handles the route from the user's current location and its location permission. HowMuch does not request device GPS access or track background location. Searches are sent directly to Apple only when the user opens these map features; no API key or new account is needed. Search is initially biased toward Singapore, without excluding other destinations. No account document/schema change or Telegram dependency was introduced.

Version 1.0 (9) signed, uploaded and assigned to Internal Beta. It replaces build 8 in Friends Beta review, with automatic notification after approval. Native tests verified real Apple place search/map rendering, saved address, typed fallback/cancel and launching the real Maps app for Walking. Full route rendering/GPS navigation remains a physical-device check. See QA.md for verification scope and logs.

Build 10 makes event name and location shared across all shifts in the same named event, including other currencies. Changing either field from a shift editor updates the event together; schedule/pay remain specific to that shift. Renaming preserves attached cab claims, saved rate/payer preferences and exact payer rules, and does not silently merge another existing event. Earnings shows event locations and offers Edit event details plus map access. Mixed legacy locations remain until a location change explicitly replaces them. Rename-only edits keep their existing locations. Shared edits save atomically and support Undo; the current Earnings group follows renames without losing its shifts.

Build 11 includes the shared-event fix and removes misleading chevrons from static event summaries. Navigable Earnings/shift cards retain their chevrons. Pay breakdown shows Paid hours, Break and Hourly Rate or Lump Sum Rate with the applicable value, plus an overtime caption when relevant. Build 10 uploaded before this follow-up request; build 11 is the intended combined distribution.

Version 1.0 (11) is uploaded and assigned to Internal Beta. It replaces build 9 in Friends Beta review with automatic notification after approval; build 10 stayed unassigned. Verification: 248 Python tests, 27 core tests and four unique targeted native UI workflows passed across the shared-event and presentation changes. The standalone backend payer-rule fix is deployed and healthy. See QA.md for logs and scope.

Build 12 adds Cab, Food and Miscellaneous categories to the shared Reimbursements section. Each claim retains its own amount, date, optional note and attached shift; categories can be edited without creating a new claim. Existing claims decode as Cab. Work earnings remain separate from reimbursements; estimated bank credit and exact optional Gmail payment matching include every claim category. Older clients omitting category metadata preserve the saved type on unrelated sync writes. Archive round-trips retain types.

Upcoming adds a Group by events switch in the Overview upcoming list, Browse → Upcoming and Earnings → Upcoming. It is saved per account and defaults off for existing users. Grouped cards show the next shift, count, location and scheduled work pay within the active date range and currency. Opening a group lists its upcoming shifts; View all event earnings opens the full event history. Completed work and claims are excluded from scheduled work pay. Switching grouping changes presentation only.

Version 1.0 (12) is uploaded and assigned to Internal Beta. It replaces build 11 in Friends Beta review, with automatic notification after approval. Verification: 255 Python tests, 30 core tests and three unique targeted native UI workflows passed; standalone API deployed and healthy. See QA.md for logs and scope.

Build 13 uses the supplied H logo in a distinctly named HowMuchHIcon catalog with explicit notification sizes (20pt @2x and @3x) and the corresponding Settings/Spotlight/Home Screen assets. Signed export verifies the compiled notification renditions in the IPA. The icon update addresses reported stale notification branding without changing account records or reminder schedules; actual installed-device caching still needs a fresh notification check after updating.

Version 1.0 (13) is uploaded and assigned to Internal Beta; it replaces build 12 in Friends Beta review with automatic notification after approval. A real local iOS simulator notification banner clearly displayed the H icon, and the signed IPA passed explicit 40px/60px notification icon verification. See QA.md for logs and device limitations.

Build 14 adds a native WidgetKit extension (com.jialekhoo.howmuch.widgets) and three widget types: Next Shift (small/medium and inline/rectangular Lock Screen), Upcoming Events (medium/large), and This Month (small/medium). Edit Widget offers an optional account-currency filter, optional pay (off by default), and location detail where space permits. This Month shows scheduled paid hours or scheduled work pay; completed unpaid work is separate and claims are excluded. Events group case-insensitively within each currency; ended shifts drop out at timeline transitions. Next Shift links to a job; event rows open event earnings; This Month opens Earnings. Deep links require the active account ID.

Settings → Widgets has live previews, installation instructions and Refresh widget data. It shares only current-month/upcoming shift projections in group.com.jialekhoo.howmuch.widgets, using protected local files. Credentials, mail, photos, payer settings and claim details are excluded. Account activation, local edits, sync and foreground entry publish snapshots and request WidgetKit reloads. Sign-out/deletion/revocation clear them. WidgetKit controls actual rendering/refresh timing, and remote changes need an app sync. Snapshots expire after seven days without opening HowMuch. Light/dark and removable widget backgrounds use native WidgetKit behavior.

Version 1.0 (14) is uploaded, processed and assigned to Internal Beta (2 testers), with widget testing instructions saved. Build 13 stays in Friends Beta review; build 14 has not replaced that external submission. Open the updated app once, then Home Screen → Edit → Add Widget → HowMuch. Physical-device Lock Screen, dark/tinted and configuration checks remain beta testing tasks; see QA.md for the simulator verification scope.

Build 16 adds Work Calendar (medium/large): a Monday-first month grid matching the app, today highlighted, booked-day dots including overnight spillovers, and the next one/three shifts. Optional currency, pay and location settings carry over. Dates deep-link to the selected day in Calendar; shift panels open job details. The local snapshot now also retains shifts overlapping the start of the current month, so completed cross-month overnight work is marked.

Version 1.0 (16) is uploaded, processed and assigned to Internal Beta (2 testers). Testing notes saved. Select Work Calendar in HowMuch’s Home Screen widget gallery after opening the updated app. Existing Friends Beta review remains build 13.

Build 17 reliability update: CSV export/import preserves paid status and due dates when present; earlier Telegram CSV remains supported. Monthly Earnings detail tracks live month/currency records after edits and deletion. Payment detection retains payer input after errors, provides an error/retry state on load failure and serializes requests. Sign-out waits for local reminder scheduling cancellation before clearing alerts, and stale sync errors cannot sign out a replacement account. Settings shows the installed version/build. Verification: Python 255, core 40, 26 broad native workflows and six focused fix checks; see QA.md for build scope and physical-device limitations.

Build 18 includes build 17’s reliability fixes and aligns the app Calendar with its widget: overnight work appears on both occupied dates, including across month boundaries; a shift ending at midnight does not spill into the following date. Calendar month counts include work overlapping the month. Earnings attribution still follows the shift’s starting date.

Version 1.0 (18) is uploaded, processed and available to Internal Beta (2 testers), with reliability-audit testing notes saved. Build 17 was uploaded but not distributed. Existing Friends Beta build 13 review remains in place.

Time to leave reminders are optional under Settings → Time to leave. They use a saved departure address, a job location and an arrival buffer, with Apple Maps server estimates for driving, walking or cycling. Save and consent first, allow notifications, then use Check saved route for work within 24 hours. Confirm the resolved places. The service checks upcoming work in the six hours before a shift and sends preparation/departure alerts through the existing per-account APNs service. Maps estimates and notification delivery are not guaranteed; public-transport routing remains a manual Apple Maps action. No background GPS permission or AI API is required.

The standalone server needs HOWMUCH_MAPS_KEY_ID and HOWMUCH_MAPS_PRIVATE_KEY (Maps-only Apple Developer key), plus its existing HOWMUCH_APPLE_TEAM_ID. Store keys only in encrypted server secrets; never bundle them in the app. Server-only Maps JWT scope is `server_api`. Its new account routes are GET /v1/travel/status and POST /v1/travel/check with a shiftID from the signed-in account. Error responses omit route addresses and provider details. The worker backs off failures, cancels stale forecasts, limits checks, and uses existing APNs delivery receipts for deduplication.

Build 20 adds daily/weekly/fortnightly shift series (2–52 dates), reusable job templates in Settings, receipt-photo attachments on claims, and event net-earnings summaries with separately recorded unreimbursed personal expenses. Photos are resized on the iPhone and stored encrypted through authenticated account endpoints, separately from work sync/exports. Text recognition is on-device and suggestions require review. Receipt image files are not included in work JSON/CSV exports. Removing a photo unlinks it; deleting the account removes all its stored receipts.

Public transport in Time to leave uses native Apple Maps ETA estimates, refreshed when the app opens, for up to four upcoming journeys within 24 hours. It schedules iPhone notifications that can fire while closed; live closed-app bus/MRT delay monitoring is not included. Driving/walking/cycling retain the existing server route checks. No Google Maps billing/API key or background GPS permission is needed for transit. Always confirm resolved addresses and current service conditions in Apple Maps.

Build 21 adds provider selection in Payment detection: Gmail, iCloud/me.com/mac.com (Apple app-specific password), and Microsoft Outlook/Hotmail (when service configuration is available). iCloud consent explains encrypted server storage and provider-side revocation. New-provider alerts require explicit bank confirmation before marking paid; verified Gmail auto-matching is unchanged. One mailbox per account.

Build 22 adds Settings → Payers: reusable company display names and multiple exact bank-transfer aliases. Select a saved company in the event or shift editor; all shifts share the event assignment. Payer selection is remembered by job templates. Legacy per-event company entries and standalone matching rules migrate into saved payers. Removing a saved company clears linked event/template selections, retains payment history, and supports undo.


Build 23 treats all cab/food/miscellaneous entries as reimbursements. Legacy personal expenses migrate idempotently to claims on archive/local/cloud decoding and backend reads/writes, retaining receipt IDs. Work earnings are never reduced by reimbursements. Receipt OCR runs on a sharper on-device copy, joins right-aligned total labels/prices by visual row, and fills an unedited amount automatically. Ambiguous/missing totals remain manual. Saved private receipt copies can be viewed from claim actions or the editor and exported as JPEG using Save to Files; JSON/CSV exports still exclude image bytes.

Build 27 adds two features:

- **Paste a job message.** Add shift now starts with a Paste card. Copy a job offer from WhatsApp or Telegram and tap Paste (or Type or edit). The message is read on the iPhone: labelled venue/address/event/pay/break lines, dates such as `12th Nov`, `13-14th Nov`, `Nov 20-22`, `12/8`, `30 Nov - 2 Dec`, `today`, and times such as `1200-2100hrs`, `9am-6pm`, `11-2pm`, `10pm-2am`. Each date keeps its own times. Hourly (`$15/hr`), per-day (`$150/day`) and lump-sum pay (split across the dates) are recognised; without pay, the usual rate is kept. Nothing is saved until Save, and unread lines are listed so they can be checked. The parser is `JobMessageParser` in HowMuchCore.
- **Live shift.** While a shift is on, a Live Activity shows the event, venue, pay for the shift, a progress bar and the time left on the Lock Screen and in the Dynamic Island. iOS only lets the app start it while open, so it appears when HowMuch is opened from 30 minutes before a shift (for example from the start reminder). After an hourly shift ends, the app asks once what time you finished; a later finish recalculates that shift's pay including overtime. Both can be turned off in Settings → Live shift. Live Activity push-to-start (no need to open the app) would need server work and is not included.

Build 28 removes the main limits of build 27:

- **Live shift starts without opening the app.** The app registers a Live Activity push-to-start token (iOS 17.2+) and each running card's update token with the account service (`PUT /v1/devices/live-start`, `PUT /v1/devices/live-activity`). The service's push worker (`howmuch_api/live_activity.py`) starts the card 15 minutes before each shift over APNs (`liveactivity` push type), skips shifts that already have a card the app started, and starts a fresh card at 7 h 45 min so shifts longer than iOS's 8-hour Live Activity limit stay live, ending the old one. Deleted shifts end their card. Turning off Settings → Live shift → Show on Lock Screen withdraws the start token. Card names follow the Job notifications privacy setting ("Shift in progress" when details are hidden). Card dates are Unix timestamps in both the app and the push payload.
- **Dimmed Lock Screen** shows "Ends 7:00 AM" instead of a countdown whose seconds iOS hides as "--".
- **Share → HowMuch.** A Share extension (`HowMuchShare`, bundle `com.jialekhoo.howmuch.share`, shared app group) reads text shared from WhatsApp, Telegram, Mail or Notes, shows the dates, times, venue and pay it found, and hands the message to the app through the app group. A "Job ready to review" notification (or simply opening HowMuch) opens Add shift filled in; nothing is saved until Save. The release script signs and verifies the new extension.

Build 30 adds three shortcuts that work without opening HowMuch first:

- **Live card buttons.** While a shift is on, the Lock Screen card and expanded Dynamic Island show **Staying late? +30 min**; once it's over they show **Finished on time** and **+30 min**. The buttons are `LiveActivityIntent`s (`Shared/HowMuchIntents.swift`) that iOS runs inside the app: +30 min moves the shift's finish 30 minutes later (`Shift.extended(byMinutes:)`), recalculates pay including overtime, updates the card and syncs the account straight away; Finished on time confirms the booked time (so the app won't ask) and closes the card. +30 min asks for Face ID / passcode first, because shift records are only readable on an unlocked iPhone.
- **Siri and Shortcuts.** "How much did I earn this week in HowMuch", "...this month", "How much am I owed in HowMuch" and "Add a job in HowMuch" (App Shortcuts, also in Spotlight and the Shortcuts app). Answers come from `SpokenSummary` in HowMuchCore: pay from shifts already worked vs still booked, and unpaid finished shifts with the overdue part; currencies stay separate.
- **Control Center button** (iOS 18+): "Add a job" opens Add shift. If the clipboard holds a job message with dates it's filled in for review, otherwise Add shift opens empty. It can also go on the Lock Screen or Action button. iOS asks once to allow pasting from other apps.

Build 31 tidies the screens: a Today section on Overview, amounts shown as "SGD 1,664.00" in the app and widgets, singular counts ("1 shift"), hours as "13h 32m", Mark as paid only after a shift ends and Time to leave only before it starts, Live shift settings styled like the other pages, Earnings filter pills that scroll to the screen edge, page headers that scroll away, aligned tab labels, and "Apple Calendar" in place of "Calendar & sync".

Build 32 makes Add shift on this day clear Liquid Glass like the other in-page actions, and the remaining primary buttons teal-tinted glass.

Build 33 adds Next up to Overview: when nothing is booked tomorrow, it shows the next booked day and how many days away it is.

Build 34 is the App Store 1.0 candidate: no "iOS beta" footer, Payment detection left out until Google verifies Gmail access, updated privacy manifest. See AppStore.md.

Version 1.1 (build 35) adds:

- **Pay-in tracking** (Settings, replacing Payment detection). *Bank app notifications*: an iOS 27 Shortcuts automation on the bank app's notifications runs HowMuch's **Record pay received** action (`RecordPayReceivedIntent`), which posts the notification text (and optional amount/payer from an Apple Intelligence step) to `POST /v1/payment-detection/notification`. The server (`howmuch_api/pay_in.py`) ignores anything that isn't money received, requires a saved payer, and either marks the one matching unpaid event paid (when "Mark matching pay as paid" is on) or keeps it in Payment review; the app shows a notification either way. *Email forwarding*: a private `pay+…@domain` address per account; forwarded DBS alerts arrive at `POST /v1/inbound-email/{secret}` and always wait for confirmation. It needs an inbound mail domain, see `docs/email-forwarding.md`; until then the app shows "Coming soon". Mailbox connection (Gmail/Outlook/iCloud) stays debug-only until Google verifies Gmail access.
- **Pet.** Penny, a coin creature on Overview (`PetCard`, `PetView.swift`): egg → hatchling (30 XP) → coinling (150 XP) → golden coin (500 XP), +10 XP per shift worked and +15 XP and a coin per shift paid, a weekly streak, and a mood (happy, sleepy, or worried about overdue pay). Computed from shifts by `PetProgress` in HowMuchCore; only the pet's name is stored, on the phone.

Penny update: endless levels (one every 40 XP), coins (5 per shift worked, 10 per paid shift, 25 per badge), 11 badges, and a wardrobe of 18 items (hats, glasses, neckwear, backgrounds) bought with coins or unlocked by level or badge. Tap Penny for a hop, hearts and a line. The wardrobe is saved on the phone per account (`pet.closet.<account>`).

Build 37: Penny, live shift choices and widget previews sync with the account (AppPreferences.pet / liveShift / widgetPreview); on-phone values from earlier builds move into the account after its first sync.

Build 38: Connect Gmail, Outlook or iCloud Mail is back in Pay-in tracking for every build.

Build 39: Pay-in tracking shows Gmail's forwarding confirmation code and link for the HowMuch address.

Build 40: Settings is tidied into small labelled groups with one-line rows.

Build 41: A personal Profile page with work stats, and a Pioneer badge and Penny skin for accounts made before launch.

Build 42: Simpler Record pay received shortcut and an iOS 27 step-by-step bank notification guide.

Build 43: Bank notification setup is a step-by-step wizard (built like SmartSpend's) with drawn iOS 27 Shortcuts screens and a live check.

Build 44: Calendar sync (live feed for Apple, Google and TimeTree), Gmail code clears once confirmed, bank alerts screened on the iPhone with a linked status, 10-step wizard.

Build 45: Penny gets six new skins, a cuter blinking face and a rename pencil; the earnings card counts only worked pay, split into paid, owed and booked.

Build 46: The earnings card calls unpaid worked pay "Pending payment".

Build 47: Apple Intelligence on the iPhone: smarter job reading, bank alerts in any wording, and a monthly recap.

Build 48: Receipts read more total labels; Apple Intelligence suggests the date, claim type and a note.

Penny rework (SmartSpend-style): pixel-art Penny (`PetSprite`/`PetPixels`) in a scene, five stages (egg 0, hatchling 60, coinling 300, golden coin 900, treasure 2000 XP), XP per shift worked, per day worked and per shift paid, level = 1 + √(XP/20), moods from days since the last shift (thriving, happy, peckish, hungry, lonely; worried while pay is overdue; a shift in the next week cheers Penny up), a weekly streak of worked weeks with +25 coins every 4 weeks, +10 coins for a week of 3+ shifts, this week's missions, a shop that opens up by stage, an evolution sheet and "+N" coins on the Overview card. The coin balance can go below zero when coins are taken back, and Penny's page explains why.

Build 49: Fixes from the full app review (sync, locked-phone logging, receipts, travel and Gmail safety), combined, some-shifts and short-paid payment matching, Share my availability, and Penny reworked in SmartSpend's style at the top of Overview; Delete shift is centred.

Build 50: One type and button scale across the app: rounded headings, consistent amount sizes, chevrons, settings rows and text buttons, and bank setup buttons sized like the rest.

Build 51: Penny no longer celebrates old progress on a new iPhone, nested settings merge across devices, correct coins-needed message, availability range matches the day grid, and a Developer badge with developer-only Terminal and Holographic skins and every skin unlocked.

Build 52: Connect Gmail with a Google app password (no Google verification needed), and each Connect button opens its own form.

Build 53: Penny gift codes (developers make codes, anyone redeems them) with five code-only specials, and developer accounts own the whole wardrobe.

Build 54: Consistent sizing on every page: one text size, compact rows, matching section titles and notes on form and card pages.

Build 55: Job messages with a time for each day ("19th: 3.30pm - 6pm", "21,22nd: 9am - 6pm") are read correctly, plus the venue after a "|".

Build 56: Job messages with the event name on its own first line ("Nike Pop-up", "Crew wanted for Nike Pop-up") now fill in the event name.

Build 57: Penny has 30 new items across every category: hats, glasses, neckwear, scenes and skins.

Build 58: Swipe a gift code in Your codes to revoke it.
Build 59: Press and hold a revoked gift code in Your codes to delete it. Active codes have to be revoked first, and anyone who redeemed a code keeps its items.
Build 60: Penny is the new app icon. Shifts can carry an extra (bonus, allowance or tip) that counts in earnings and in bank-transfer matching; older app versions keep it. Optional Face ID lock in Settings → Privacy. Pasted job posts now keep the venue from "at"/"@" headings and 📍 lines.
Build 61: Penny replaces the H logo everywhere else too: the sign-in screen, the notification preview in Settings and the widgets.
Build 62: New users see five intro pages (what HowMuch does, adding jobs, getting paid, reminders, Penny) with Next and Skip, ending in Sign up. Shown once per install and never to someone already signed in.
