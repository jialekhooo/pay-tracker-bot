# Monetization

HowMuch sells three things through the App Store. Tracking shifts (in up to 5 events), earnings, the calendar and Penny stay free.

## Products

| Product ID | Type | Price (SGD base) | What it gives |
| --- | --- | --- | --- |
| `com.jialekhoo.howmuch.pro.yearly` | Auto-renewing, group "HowMuch Pro" (level 1) | S$19.98/year, 1-week free trial | Pro |
| `com.jialekhoo.howmuch.pro.monthly` | Auto-renewing, group "HowMuch Pro" (level 2) | S$2.98/month, 1-week free trial | Pro |
| `com.jialekhoo.howmuch.pro.lifetime` | Non-consumable | S$49.98 | Pro forever |
| `com.jialekhoo.howmuch.penny.celebration` | Non-consumable | S$2.98 | Halo, heart glasses, flower lei, Fireworks, Galaxy skin |
| `com.jialekhoo.howmuch.penny.wonder` | Non-consumable | S$2.98 | Bunny ears, 3D glasses, lucky bell, Aurora, Frost skin |
| `com.jialekhoo.howmuch.coins.150` / `.400` / `.1000` | Consumable | S$1.48 / S$2.98 / S$5.98 | Coins for Penny's shop |

All are set up in App Store Connect (name, description, price in 175 countries, availability). `HowMuch.storekit` mirrors them for the simulator (the scheme's Run action uses it).

## What Pro unlocks

- Unlimited events. Free accounts keep up to 5 events (jobs, told apart by name ignoring case). More shifts in an existing event are always free. An account above 5 (for example after Pro ends) keeps its events but can't add new ones until it's back under. The app refuses the save and shows the plans (`FreePlan`, `TrackerStore.update`); the server refuses any document save that would do it with 402 (`store.check_event_limit`, in `commit_document`, so bot-added shifts count too).
- Pay-in tracking (bank notifications, forwarded emails, mailbox connection). The server ignores alerts, skips mailbox polling and refuses scans without Pro.
- Reminders and live shift: job notifications, time to leave, the Lock Screen shift card. The server plans none of them without Pro, and plans them as soon as Pro is bought.
- Calendar sync and exports: the calendar feed, CSV and .ics export. Full-archive backup and restore stay free.
- Insights and widgets: the monthly recap, earnings by month, Home Screen widgets (they show a "part of HowMuch Pro" card without it).

Without Pro the Settings rows carry a PRO tag and open the plans instead (`ProGate`).

## Who has Pro

Pro is on when any of these is true (`ProStore.hasPro`, server `store.pro_status`):

1. A live subscription or lifetime on this Apple Account (StoreKit).
2. A purchase the server has on record for the HowMuch account (follows the account to other iPhones).
3. The account is a pioneer (early supporter): it used a TestFlight build before launch. TestFlight builds send Apple's signed app transaction to `POST /v1/store/app-transaction`; the server checks Apple's signature and, if the environment is Sandbox and HowMuch Pro hasn't launched, marks the account (`accounts.tester`). **Until the launch time `HOWMUCH_PIONEER_UNTIL` has passed, every account is a pioneer**, so everyone has Pro free. After it, only marked accounts are, and no new accounts are marked, so App Review (also Sandbox) sees the paywall. Testers must open build 86 or later before launch to be marked.
4. The account is a developer (`HOWMUCH_DEVELOPERS`).

## How purchases are checked

The app sends each StoreKit transaction (Apple's signed JWS) to `POST /v1/store/transactions`. The server verifies the chain to Apple Root CA - G3 (`howmuch_api/AppleRootCA-G3.cer`), Apple's marker extensions, the ES256 signature, the bundle ID and the purchase's `appAccountToken` (the HowMuch account ID). Coins are credited once per transaction ID, ever. A coin purchase stays unfinished in StoreKit until the server confirms it, so coins bought offline arrive on the next launch.

## App Review

- Guideline 3.1.1: Penny gift codes can't unlock items or coins sold in the app, so only developers see and redeem them; after launch the server refuses everyone else (403). Codes redeemed earlier are kept. Use App Store offer codes for promotions.
- Guideline 3.1.2: the plans show each plan's name, length and price (the most prominent price), trial terms, Restore purchases, Terms of Use and Privacy Policy.
- Guideline 2.1: App Review must be able to find and buy the products, so set `HOWMUCH_PIONEER_UNTIL` before submitting (otherwise the reviewer has Pro free and never sees the plans). Review notes: "Settings → HowMuch Pro shows the subscriptions and lifetime unlock. Penny's store (Overview → Penny → Store) sells the two item packs and coin bundles. A new account can keep 5 events; adding a 6th shows the plans."

## Launch checklist

1. **Paid Apps agreement** (you): App Store Connect → Business. Update the legal entity, sign the Paid Apps Agreement, add bank and tax details. Nothing can be bought, even in the sandbox, until it is active.
2. **Review screenshots** (you): each of the 8 products needs a screenshot under Review Information. Use the paywall (Settings → HowMuch Pro) for the Pro products, and Penny's store for packs and coins.
3. **Deploy the server** before the app build that sells anything.
4. **Set the cutoff** just before submitting the paid version for review: `flyctl secrets set HOWMUCH_PIONEER_UNTIL=YYYY-MM-DD --app howmuch-ios`. After that moment only accounts seen in a TestFlight build keep Pro free, and App Review's account sees the paywall.
5. **Submit** the products with the new app version (the first subscription and in-app purchases must go with a version). Add the Terms of Use link to the App Store description: `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`.
6. **App Privacy** in App Store Connect: add Purchases → Purchase History (linked to the user, for app functionality).

## Testing

- Simulator: run from Xcode; `HowMuch.storekit` supplies the products. Coin purchases made here are signed by Xcode, so the server refuses them (expected).
- TestFlight: testers are pioneers (once they open build 86 or later before launch), so they have Pro free. Settings → HowMuch Pro → Testing → "Test as a new user" ignores that on the iPhone so the paywall and sandbox purchases can be tried.
- UI tests: `--ui-test-free` shows HowMuch without Pro; previews and other UI tests have Pro.
- Review screenshots: set `TEST_RUNNER_STORE_SHOTS=<folder>` and run `testStoreReviewScreenshots`; it saves the plans and Penny's store with prices from `HowMuch.storekit`.
