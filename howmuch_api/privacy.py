"""The public privacy policy at /privacy, in the website's shared look (site.py)."""
from .site import CONTACT, page, page_head

UPDATED = '27 November 2026'

BODY = page_head('Privacy policy', 'HowMuch keeps track of your shifts and pay. This page explains what that involves, in plain language: what we store, why, who else handles it, and how to get a copy or delete it.',
                 f'<p class="date">Last updated {UPDATED}</p>') + '<div class="narrow">' + f"""

<section aria-labelledby="short">
 <h2 id="short">The short version</h2>
 <ul class="short">
  <li><strong>Your records are yours</strong>They sync to your account so they are on all your devices. You can export or delete them in the app.</li>
  <li><strong>No ads, no tracking</strong>No advertising or analytics tools, and we never sell your data.</li>
  <li><strong>Extras are opt-in</strong>Email, bank alerts, travel reminders, calendars and Telegram stay off until you set them up.</li>
  <li><strong>Friends see Penny, not your work</strong>They never see your shifts, pay, payers or places.</li>
 </ul>
</section>

<nav class="toc" aria-label="On this page">
<section>
 <h2>On this page</h2>
 <ol>
  <li><a href="#store">What we store</a></li>
  <li><a href="#optional">Optional features</a></li>
  <li><a href="#google">Google user data</a></li>
  <li><a href="#device">What stays on your iPhone</a></li>
  <li><a href="#others">Who else handles data</a></li>
  <li><a href="#never">What we never do</a></li>
  <li><a href="#security">How data is protected</a></li>
  <li><a href="#keep">How long we keep it</a></li>
  <li><a href="#choices">Your choices and rights</a></li>
  <li><a href="#contact">Changes and contact</a></li>
 </ol>
</section>
</nav>

<section aria-labelledby="store">
 <h2 id="store">1. What we store</h2>
 <p>Using HowMuch means signing in with Apple. These records are kept with your account to run the app.</p>
 <table>
  <thead><tr><th scope="col">Data</th><th scope="col">What it includes</th><th scope="col">Why</th></tr></thead>
  <tbody>
   <tr><td>Account</td><td>Your Apple account identifier, and any name and email you choose to share</td><td>To sign you in and keep your records yours</td></tr>
   <tr><td>Profile</td><td>Your display name and an optional photo</td><td>To show your profile. Friends can see your display name</td></tr>
   <tr><td>Work records</td><td>Shifts, events, venues, pay rates, payment status, payers, claims, notes and preferences</td><td>To work out your pay and sync across your devices</td></tr>
   <tr><td>Job briefs</td><td>A shift's call time, dress code and contact person, if you add them. The contact can include another person's name and phone number</td><td>To show you the brief with the shift. Only add contact details you were given for the job</td></tr>
   <tr><td>Device details</td><td>A random installation ID, push tokens and your reminder preferences</td><td>To send notifications and Lock Screen updates to your iPhone</td></tr>
  </tbody>
 </table>
 <p class="note">Importing earlier work records from a CSV file is optional. Anything you import becomes part of your HowMuch account.</p>
</section>

<section aria-labelledby="optional">
 <h2 id="optional">2. Optional features</h2>
 <p>Each of these collects extra information only if you use it.</p>

 <h3>Notifications</h3>
 <p>We use your push token to send job and payment alerts through Apple, and alerts about friends. Job details are hidden on the Lock Screen by default. You can turn alerts off in Settings.</p>

 <h3>Time to leave</h3>
 <p>Off by default. If you turn it on, your saved departure address, job destination, travel mode and arrival time go to the HowMuch service and Apple Maps to estimate a route. The service checks upcoming work periodically while you are signed in. Public-transport estimates are requested from Apple Maps on your iPhone when the app is open. HowMuch does not track your live location. Estimates can vary and delivery is not guaranteed. Turning this off cancels pending travel reminders.</p>

 <h3>Receipt photos</h3>
 <p>Photos you attach are resized on your iPhone and uploaded to encrypted storage tied to your account. Text recognition runs on your iPhone. Photos are not sent to an AI service. A photo no longer attached to any claim is deleted from the service after a day.</p>

 <h3>Full backups</h3>
 <p>A ZIP backup contains your account records and receipt photos, and is saved wherever you choose. Keep it private. It never contains account credentials. Earlier JSON archives and CSV exports contain no receipt photos.</p>

 <h3>Pay-in tracking</h3>
 <p>This matches money you receive to your jobs. You can use any of these three ways:</p>
 <ul>
  <li><strong>Bank notifications.</strong> If you set up the shortcut, the text of the bank notifications it passes to HowMuch is sent to the service to match payments from your saved payers. Notifications that are not money received are discarded.</li>
  <li><strong>Forwarded emails.</strong> Bank alert emails sent to your private HowMuch address are read the same way and wait for your confirmation.</li>
  <li><strong>Connected mailbox.</strong> You can connect one Gmail, Microsoft Outlook or iCloud Mail account. HowMuch only looks for DBS transfer alerts from payers you saved, and reads the amount, payer and time. Other email is not stored.</li>
 </ul>
 <p>Gmail and Microsoft connections use read-only permission. iCloud needs an Apple app-specific password, and Gmail can also connect with a Google app password. Those passwords are encrypted on our service. They are not technically read-only, but HowMuch opens the inbox read-only and never sends, changes or deletes email. Matches from Outlook, iCloud and Gmail app passwords need your confirmation before a job is marked paid. Matched payments are kept with your payment history so you can undo them.</p>
 <p>Disconnecting in Pay-in tracking removes the stored credentials. Disconnecting Gmail or deleting your account also withdraws HowMuch's access at Google. You can also revoke access at Google, Microsoft or your Apple Account at any time.</p>

 <h3>Calendar feeds</h3>
 <p>A private calendar link lets Apple Calendar, Google Calendar or TimeTree read your shifts. Anyone with the link can see that calendar, so treat it like a password. Rotate the link in the app to cancel the old one.</p>

 <h3>Friends and Penny</h3>
 <p>Your friend code connects you with people you choose, and both sides must agree. Friends see your display name, your pet's name, look, level, mood, streak and badges, whether you said hi today, and when your pet visits them or they give it a treat. Anyone who has your invite link can see your display name. We store your pet's card, friend list, requests, hellos and pet visits, and use your display name in notifications to friends. Friends never see your shifts, pay, payers or places.</p>
 <p>If you redeem a gift code, we store that you used it and the coins or items it gave you.</p>

 <h3>Purchases</h3>
 <p>HowMuch Pro, Penny's item packs and coins are bought through Apple, which handles payment. We never see your card or Apple Account details. When you buy, the app sends us Apple's signed record of the purchase: the product, its transaction ID, purchase and renewal dates, and whether it was refunded. We keep it with your HowMuch account so your purchases follow you to your other devices, and coins are added once. Deleting your account deletes these records, except a one-way hash of each coin purchase's transaction ID, kept so the same coins can't be added twice. If you use a TestFlight beta build, the app also sends Apple's signed record that it is a beta install (no personal details), so beta testers keep Pro free as early supporters; we keep only that your account is a tester. To cancel a subscription or ask for a refund, use your Apple Account settings or Apple's support.</p>

 <h3>Telegram bot</h3>
 <p>If you use @paytracker1_bot, your messages pass through Telegram, and the bot stores your Telegram ID and the shifts you send it. If you link it to HowMuch, we also store your Telegram user ID and username, and the bot can add shifts to your account and read what is owed and what is coming up. A schedule key created in the bot can only reach shifts in that account, and you can revoke it.</p>
 <p>You can unlink in Settings. The bot keeps its own records, so deleting your HowMuch account does not delete them. Use /clear in the bot, or email us.</p>
</section>

<section aria-labelledby="google">
 <h2 id="google">3. Google user data</h2>
 <p>HowMuch's use and transfer of information received from Google APIs adheres to the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including the Limited Use requirements. Gmail data is used only to find your payment alerts. It is not used for advertising, not used to train AI models, not sold, and not read by people except with your permission for support or where required by law.</p>
</section>

<section aria-labelledby="device">
 <h2 id="device">4. What stays on your iPhone</h2>
 <p>Apple Intelligence features (reading job messages, bank alerts and receipts, and the monthly recap) run on your iPhone with Apple's on-device model. That text is not sent to HowMuch or any AI service for those features. Your iPhone also keeps a protected copy of your account's records so the app works quickly and offline.</p>
</section>

<section aria-labelledby="others">
 <h2 id="others">5. Who else handles data</h2>
 <p>We use these services only to run the features above.</p>
 <table>
  <thead><tr><th scope="col">Service</th><th scope="col">What for</th></tr></thead>
  <tbody>
   <tr><td>Fly.io</td><td>Hosts the HowMuch service and database in Singapore</td></tr>
   <tr><td>Apple</td><td>Sign in with Apple, push notifications, Apple Maps routes and App Store purchases</td></tr>
   <tr><td>Google, Microsoft, Apple iCloud</td><td>Only if you connect that mailbox</td></tr>
   <tr><td>Cloudflare</td><td>Email Routing delivers emails you forward to your private HowMuch address</td></tr>
   <tr><td>Telegram</td><td>Only if you use the bot</td></tr>
  </tbody>
 </table>
 <p class="note">Some of these companies may process data outside Singapore under their own privacy policies. We may also disclose information where the law requires it.</p>
</section>

<section aria-labelledby="never">
 <h2 id="never">6. What we never do</h2>
 <ul>
  <li>Use advertising or analytics tools</li>
  <li>Sell your data or share it for tracking</li>
  <li>Show your work or pay to friends</li>
  <li>Send, change or delete your email</li>
 </ul>
</section>

<section aria-labelledby="security">
 <h2 id="security">7. How data is protected</h2>
 <p>Data travels over HTTPS and the database disks are encrypted. Receipt photos and stored mailbox credentials have an extra layer of encryption on the service. Sign-in tokens are stored only as one-way hashes. No system is perfectly secure, so please keep your Apple Account and any exported backups safe.</p>
</section>

<section aria-labelledby="keep">
 <h2 id="keep">8. How long we keep it</h2>
 <table>
  <thead><tr><th scope="col">Data</th><th scope="col">Kept</th></tr></thead>
  <tbody>
   <tr><td>Account and work records</td><td>Until you remove them or delete your account</td></tr>
   <tr><td>Unattached receipt photos</td><td>One day</td></tr>
   <tr><td>Sign-in sessions</td><td>30 days after your last refresh</td></tr>
   <tr><td>Rate-limit counters</td><td>About 10 minutes, using a one-way hash of your IP address</td></tr>
   <tr><td>Server backups</td><td>Normally about 5 days, so deleted data can remain in a backup until then</td></tr>
  </tbody>
 </table>
</section>

<section aria-labelledby="choices">
 <h2 id="choices">9. Your choices and rights</h2>
 <ul>
  <li><strong>See and correct</strong> your records in the app at any time.</li>
  <li><strong>Export</strong> them from Settings &rarr; Data &amp; backups.</li>
  <li><strong>Turn off</strong> notifications, Time to leave, Pay-in tracking and calendar links whenever you like.</li>
  <li><strong>Delete your account</strong> in Settings &rarr; Account &amp; sync &rarr; Delete account. This removes your account and its work, payment, friends and notification records from the active service and this device, and withdraws HowMuch's Sign in with Apple access. Exported files and copies on other devices stay under your control.</li>
 </ul>
 <p>Wherever you live, you can email us to ask for a copy of your data, to correct or delete it, or to stop using it for an optional feature. Turning a feature off withdraws your consent for it. Depending on where you live, for example under Singapore's Personal Data Protection Act or the GDPR in the EU and UK, you may also have the right to receive your data in a portable format, to object to how it is used, and to complain to your data protection authority. We won't treat you differently for asking.</p>
</section>

<section aria-labelledby="contact">
 <h2 id="contact">10. Changes and contact</h2>
 <p>HowMuch is a tool for people who work shifts and is not directed at children under 13. We don't knowingly collect their data, and if we learn we have, we delete it. If this policy changes, we will update this page and the date at the top.</p>
 <p>HowMuch is run by Jia Le Khoo. For questions or requests about your data, email <a href="mailto:{CONTACT}">{CONTACT}</a>. We will reply within 7 days.</p>
</section>

</div>
"""

PAGE = page('/privacy', 'Privacy policy | HowMuch', 'What HowMuch stores, why, who handles it, and how to export or delete it.', BODY)
