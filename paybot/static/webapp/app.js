(() => {
  "use strict";

  const tg = window.Telegram ? window.Telegram.WebApp : null;
  const els = {
    avatar: document.getElementById("avatar"),
    profileButton: document.getElementById("profile-button"),
    greeting: document.getElementById("greeting"),
    asof: document.getElementById("asof"),
    refresh: document.getElementById("refresh"),
    bottomNav: document.getElementById("bottom-nav"),
    loading: document.getElementById("loading"),
    error: document.getElementById("error"),
    errorText: document.getElementById("error-text"),
    contentWrap: document.getElementById("content-wrap"),
    contentHead: document.getElementById("content-head"),
    contentList: document.getElementById("content-list"),
    editBackdrop: document.getElementById("edit-backdrop"),
    editSheet: document.getElementById("edit-sheet"),
    editForm: document.getElementById("edit-form"),
    editBadge: document.getElementById("edit-badge"),
    editCurrency: document.getElementById("edit-currency"),
    editBreakPaid: document.getElementById("edit-break-paid"),
    editTitle: document.getElementById("edit-title"),
    editError: document.getElementById("edit-error"),
    editSave: document.getElementById("edit-save"),
    editCancel: document.getElementById("edit-cancel"),
    editDuplicate: document.getElementById("edit-duplicate"),
    editDelete: document.getElementById("edit-delete"),
    editShiftActions: document.getElementById("edit-shift-actions"),
    editPaymentBadge: document.getElementById("edit-payment-status-badge"),
    editPaidRow: document.getElementById("edit-paid-row"),
    searchOpen: document.getElementById("search-open"),
    searchBackdrop: document.getElementById("search-backdrop"),
    searchInput: document.getElementById("search-input"),
    searchResults: document.getElementById("search-results"),
    searchClose: document.getElementById("search-close"),
    toast: document.getElementById("toast"),
    toastText: document.getElementById("toast-text"),
    toastAction: document.getElementById("toast-action"),
  };

  // Clean line icons (stroke = currentColor) used instead of emoji throughout the app.
  const ICONS = {
    calendar: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M3.5 9.5h17"/><path d="M8 3.2v3.6M16 3.2v3.6"/></svg>`,
    calendarDays: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M3.5 9.5h17"/><path d="M8 3.2v3.6M16 3.2v3.6"/><path d="M7.7 13.3h1.6M11.2 13.3h1.6M14.7 13.3h1.6M7.7 16.6h1.6M11.2 16.6h1.6"/></svg>`,
    sun: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v3M12 18.5v3M4.4 4.4l2.1 2.1M17.5 17.5l2.1 2.1M2.5 12h3M18.5 12h3M4.4 19.6l2.1-2.1M17.5 6.5l2.1-2.1"/></svg>`,
    wallet: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="6.5" width="18" height="12.5" rx="2.5"/><path d="M3 10.3h18"/><circle cx="16.3" cy="14.6" r="1" fill="currentColor" stroke="none"/></svg>`,
    user: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8.3" r="3.5"/><path d="M4.5 20.2c1.35-3.6 4.24-5.5 7.5-5.5s6.15 1.9 7.5 5.5"/></svg>`,
    bell: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6.2 10a5.8 5.8 0 0 1 11.6 0c0 3.9 1.4 5.3 1.4 5.3H4.8S6.2 13.9 6.2 10Z"/><path d="M10.2 18.8a1.9 1.9 0 0 0 3.6 0"/></svg>`,
    download: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.5v11"/><path d="m7.8 10.8 4.2 4.2 4.2-4.2"/><path d="M4 16.5v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>`,
  };

  const SCOPES = {
    today: { label: "Day", icon: ICONS.sun },
    week: { label: "Week", icon: ICONS.calendar },
    month: { label: "Month", icon: ICONS.calendarDays },
    all: { label: "All time", icon: ICONS.wallet },
  };

  let summaryData = null;
  let view = "dashboard"; // dashboard | summary | calendar | settings
  let dashboardDetail = null; // null | "worked" | "upcoming" — drill-down from the Overview cards
  let scope = "today"; // which quick action is selected within the Earnings workspace
  let monthDetail = null; // set when drilled into a month from the "Months" view
  let eventsData = null; // fetched lazily the first time the Events tab is opened
  let eventDetail = null; // set when drilled into one event from the "Events" view
  let settingsData = null; // fetched lazily the first time the Settings tab is opened
  let settingsSection = null; // null | "profile" | "pay" | "reminders" | "calendar" | "export" — drill-down within Settings
  let telegramFirstName = ""; // fallback greeting name when no display name is set
  let telegramUsername = ""; // @handle, shown under the name in Settings (absent for users without one)
  let telegramPhotoUrl = ""; // Telegram profile photo, shown in the avatar when available
  const shiftsById = new Map(); // repopulated on every render, keyed by shift id
  let editingShiftId = null;
  let editorMode = null; // "edit" | "create"
  let editingShiftSnapshot = null; // the shift currently open for editing, for live badge sync
  let paymentDueTouched = false; // true once the user edits the due-date field themselves
  let activeEditField = null; // focused input inside the edit sheet, while the keyboard is up
  let overviewMonth = null; // "YYYY-MM" shown by the Month quick action; null = the live current month
  let overviewMonthData = null; // fetched /month/{key} detail when overviewMonth isn't the live month
  let overviewWeekStart = null; // Monday (YYYY-MM-DD) shown by the Week quick action; null = the live week
  let overviewWeekData = null; // fetched /week/{start} detail when overviewWeekStart isn't the live week
  let overviewDay = null; // "YYYY-MM-DD" shown by the Day quick action; null = the live current day
  let overviewDayData = null; // fetched /day/{date} detail when overviewDay isn't the live day
  let allTimeGroupBy = "month"; // "month" | "event" — how the All Time scope's list is grouped
  let eventSort = "date"; // "date" | "alphabetical" — ordering for the All time Events list
  let dateOrder = "asc"; // "asc" | "desc" — date order for grouped shift lists
  let upcomingRange = "tomorrow"; // "tomorrow" | "7" | "14" | "30" | "all" — the Upcoming tab's selected range
  let upcomingRangeData = null; // fetched /upcoming/{scope} detail when upcomingRange isn't the default "14"
  let calendarMonth = null; // "YYYY-MM" currently visible in Calendar
  let calendarMonthData = null; // /month/{key} payload used by the calendar grid
  let calendarSelectedDay = null; // "YYYY-MM-DD" selected inside the calendar grid
  let searchDebounce = null; // setTimeout handle for debouncing the search input
  let toastTimeout = null; // setTimeout handle for auto-dismissing the undo toast

  function initTelegram() {
    if (!tg) return;
    tg.ready();
    tg.expand();
    // Without this, Telegram treats vertical drags on our content as its own
    // swipe-to-collapse/close gesture, dragging the whole app instead of scrolling the list.
    if (tg.disableVerticalSwipes) tg.disableVerticalSwipes();
    // The app ships a fixed palette, so pin Telegram's own chrome to it instead of letting
    // the client theme frame the app: the header matches the top of the header artwork.
    // Hex colours here need Bot API 6.9; older clients (mostly Android) reject the call.
    const canPinChrome = !tg.isVersionAtLeast || tg.isVersionAtLeast("6.9");
    if (canPinChrome && tg.setHeaderColor) tg.setHeaderColor("#123047");
    if (canPinChrome && tg.setBackgroundColor) tg.setBackgroundColor("#f2f2f7");
    const user = tg.initDataUnsafe && tg.initDataUnsafe.user;
    if (user && user.username) telegramUsername = user.username;
    if (user && user.first_name) {
      telegramFirstName = user.first_name;
      updateGreeting();
      loadAvatarPhoto();
    }
  }

  // initDataUnsafe.user.photo_url is frequently missing (older clients, privacy
  // settings), so fetch the photo ourselves via the bot's server-side Bot API access.
  async function loadAvatarPhoto() {
    const headers = authHeader();
    if (!headers) return;
    try {
      const response = await fetch("/webapp/api/avatar", { headers });
      telegramPhotoUrl = response.ok ? URL.createObjectURL(await response.blob()) : "";
    } catch (err) {
      telegramPhotoUrl = "";
    }
    updateGreeting();
  }

  function updateGreeting() {
    const name = (settingsData && settingsData.display_name) || telegramFirstName || "You";
    const header = {
      dashboard: ["Overview", "This month at a glance"],
      summary: ["Earnings", "Detailed earnings"],
      calendar: ["Calendar", "Your shifts by date"],
      settings: ["Settings", "Profile and settings"],
    }[view] || ["HowMuch", "Pay tracker"];
    els.greeting.textContent = header[0];
    els.asof.textContent = header[1];
    els.profileButton.classList.toggle("hidden", view !== "dashboard");
    paintAvatar(els.avatar, name.trim()[0].toUpperCase());
    const preview = document.getElementById("settings-avatar-preview");
    if (preview) paintAvatar(preview, name.trim()[0].toUpperCase());
  }

  function paintAvatar(el, initial) {
    if (telegramPhotoUrl) {
      const img = document.createElement("img");
      img.src = telegramPhotoUrl;
      img.alt = "";
      img.onerror = () => {
        telegramPhotoUrl = "";
        el.textContent = initial;
      };
      el.textContent = "";
      el.appendChild(img);
    } else {
      el.textContent = initial;
    }
  }

  // Keep the modal pinned above the on-screen keyboard instead of letting it cover the buttons.
  function syncAppHeight() {
    const height = window.visualViewport ? window.visualViewport.height : window.innerHeight;
    document.documentElement.style.setProperty("--app-height", `${height}px`);
  }

  // The keyboard shrinks the visual viewport but not the sheet's own scroll content, so a
  // field near the bottom of the form has nowhere to scroll to once the keyboard covers it.
  // Pad the sheet by the keyboard's height so every field can still scroll clear of it.
  function adjustForKeyboard() {
    const sheet = els.editSheet;
    const viewport = window.visualViewport;
    if (!sheet || !viewport) return;
    const keyboardHeight = Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop);
    sheet.style.paddingBottom = keyboardHeight ? `${keyboardHeight + 24}px` : "";
    if (activeEditField) {
      activeEditField.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  }

  function initViewport() {
    syncAppHeight();
    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", () => {
        syncAppHeight();
        adjustForKeyboard();
      });
      window.visualViewport.addEventListener("scroll", syncAppHeight);
    } else {
      window.addEventListener("resize", syncAppHeight);
    }
  }

  function authHeader() {
    const initData = tg && tg.initData;
    if (!initData) return null;
    return { Authorization: `tma ${initData}` };
  }

  async function api(path, options = {}) {
    const headers = authHeader();
    if (!headers) throw new Error("no-init-data");
    const init = { headers };
    if (options.method) init.method = options.method;
    if (options.body !== undefined) {
      init.headers = { ...headers, "Content-Type": "application/json" };
      init.body = JSON.stringify(options.body);
    }
    const response = await fetch(path, init);
    if (!response.ok) {
      let detail;
      try {
        detail = (await response.json()).detail;
      } catch (parseErr) {
        detail = undefined;
      }
      const error = new Error(`http-${response.status}`);
      error.detail = detail;
      throw error;
    }
    return response.status === 204 ? null : response.json();
  }

  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  function money(amount, currency) {
    return `${currency} ${Number(amount).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })}`;
  }

  function hours(value) {
    const n = Number(value);
    return `${Number.isInteger(n) ? n : n.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")}h`;
  }

  function currentMonthKey(data) {
    return (data.now || "").slice(0, 7);
  }

  function shiftMonthKey(key, delta) {
    const [year, month] = key.split("-").map(Number);
    const date = new Date(Date.UTC(year, month - 1 + delta, 1));
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
  }

  function monthKeyLabel(key) {
    const [year, month] = key.split("-").map(Number);
    return new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString(undefined, {
      month: "long",
      year: "numeric",
      timeZone: "UTC",
    });
  }

  function monthNavBar(label, unit = "month") {
    return `
      <div class="month-nav">
        <button type="button" class="month-nav-btn" data-month-nav="prev" aria-label="Previous ${unit}">\u2039</button>
        <div class="month-nav-label">${escapeHtml(label)}</div>
        <button type="button" class="month-nav-btn" data-month-nav="next" aria-label="Next ${unit}">\u203a</button>
      </div>`;
  }

  function currentWeekStart(data) {
    return mondayOf((data.now || "").slice(0, 10));
  }

  function currentDayKey(data) {
    return (data.now || "").slice(0, 10);
  }

  function shiftDayKey(dateStr, deltaDays) {
    const [year, month, day] = dateStr.split("-").map(Number);
    return isoDateUTC(new Date(Date.UTC(year, month - 1, day) + deltaDays * 86400000));
  }

  function dayKeyLabel(dateStr) {
    const [year, month, day] = dateStr.split("-").map(Number);
    return new Date(Date.UTC(year, month - 1, day)).toLocaleDateString(undefined, {
      weekday: "short",
      day: "2-digit",
      month: "short",
      timeZone: "UTC",
    });
  }

  function isoDateUTC(d) {
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(
      d.getUTCDate()
    ).padStart(2, "0")}`;
  }

  // Best-effort client-side preview only (matches a single shift's own day) — the real
  // default, based on the last day of the whole event, is computed server-side at save time
  // whenever the user hasn't touched this field themselves. Two weeks out, rolled to a Friday.
  function defaultPaymentDue(dayStr) {
    const [year, month, day] = dayStr.split("-").map(Number);
    const due = new Date(Date.UTC(year, month - 1, day) + 14 * 86400000);
    const daysUntilFriday = (5 - due.getUTCDay() + 7) % 7; // Friday = 5 in getUTCDay()
    due.setUTCDate(due.getUTCDate() + daysUntilFriday);
    return isoDateUTC(due);
  }

  function mondayOf(dateStr) {
    const [year, month, day] = dateStr.split("-").map(Number);
    const utc = Date.UTC(year, month - 1, day);
    const weekday = new Date(utc).getUTCDay(); // 0=Sun..6=Sat
    const sinceMonday = (weekday + 6) % 7;
    return isoDateUTC(new Date(utc - sinceMonday * 86400000));
  }

  function shiftWeekStart(startStr, deltaWeeks) {
    const [year, month, day] = startStr.split("-").map(Number);
    return isoDateUTC(new Date(Date.UTC(year, month - 1, day) + deltaWeeks * 7 * 86400000));
  }

  function weekLabel(startStr) {
    const [year, month, day] = startStr.split("-").map(Number);
    const monday = new Date(Date.UTC(year, month - 1, day));
    return `Week of ${monday.toLocaleDateString(undefined, {
      day: "2-digit",
      month: "short",
      timeZone: "UTC",
    })}`;
  }

  const STATE_ICON = { done: "✓", running: "⏳", upcoming: "📅" };

  // Every shift is always in exactly one of these three payment states.
  const PAYMENT_STATUS_META = {
    upcoming: { label: "Upcoming", cls: "tag-upcoming" },
    pending_payment: { label: "Pending payment", cls: "tag-pending" },
    payment_completed: { label: "Payment completed", cls: "tag-paid" },
  };

  // Falls back to computing the status client-side for shifts fetched before this field
  // existed, or wherever a caller only has a bare {state, paid} pair to hand.
  function paymentStatusOf(shift, state) {
    if (shift.payment_status) return shift.payment_status;
    const effectiveState = state || shift.state;
    if (effectiveState && effectiveState !== "done") return "upcoming";
    return shift.paid ? "payment_completed" : "pending_payment";
  }

  function paymentStatusBadge(status) {
    const meta = PAYMENT_STATUS_META[status] || PAYMENT_STATUS_META.pending_payment;
    return `<span class="tag ${meta.cls}">${meta.label}</span>`;
  }

  // A consistent color per event name, so the same gig always looks the same in every list.
  const EVENT_COLORS = [
    { bg: "#ffe0e6", fg: "#c2185b" },
    { bg: "#e3f2fd", fg: "#1565c0" },
    { bg: "#fff3e0", fg: "#ef6c00" },
    { bg: "#e8f5e9", fg: "#2e7d32" },
    { bg: "#f3e5f5", fg: "#7b1fa2" },
    { bg: "#e0f7fa", fg: "#00838f" },
    { bg: "#fce4ec", fg: "#ad1457" },
    { bg: "#ede7f6", fg: "#4527a0" },
  ];

  function eventColor(event) {
    let hash = 0;
    for (let i = 0; i < event.length; i += 1) {
      hash = (hash * 31 + event.charCodeAt(i)) >>> 0;
    }
    return EVENT_COLORS[hash % EVENT_COLORS.length];
  }

  function eventInitial(event) {
    const trimmed = (event || "").trim();
    return trimmed ? trimmed[0].toUpperCase() : "?";
  }

  function eventBadge(event) {
    const color = eventColor(event);
    return `<div class="icon" style="background:${color.bg};color:${color.fg}">${escapeHtml(
      eventInitial(event)
    )}</div>`;
  }

  function shiftRow(shift, currency, options = {}) {
    shiftsById.set(shift.id, shift);
    const state = options.state || "done";
    const status = paymentStatusOf(shift, state);
    const displayPay = options.earnedPay !== undefined ? options.earnedPay : shift.pay;
    const clash = shift.clash ? '<span class="clash-badge">⚠ clash</span>' : "";
    const when = options.hideDate ? "" : `${shift.date_label} \u00b7 `;
    return `
      <div class="row editable state-${state}" data-id="${shift.id}">
        ${eventBadge(shift.event)}
        <div class="info">
          <div class="title">${escapeHtml(shift.event)}${clash}</div>
          <div class="sub">${when}${shift.start}\u2013${shift.end} \u00b7 ${hours(shift.hours)}${
      shift.location ? ` \u00b7 ${escapeHtml(shift.location)}` : ""
    }</div>
        </div>
        <div class="value">
          <div class="amount">${money(displayPay, currency)}</div>
          ${paymentStatusBadge(status)}
        </div>
      </div>`;
  }

  function dayHead(label, shifts, currency, payOf = (shift) => shift.pay) {
    const pay = shifts.reduce((total, shift) => total + Number(payOf(shift)), 0);
    const worked = shifts.reduce((total, shift) => total + Number(shift.hours), 0);
    return `
      <div class="day-head">
        <span class="day-when">${escapeHtml(label)}</span>
        <span class="day-total">${money(pay, currency)} \u00b7 ${hours(worked)}</span>
      </div>`;
  }

  // Shifts split into one card per calendar day, headed by the day and its own total, so a
  // long list reads as a schedule instead of a wall of repeated dates.
  function shiftGroups(shifts, currency, options = {}) {
    const payOf = options.payOf || ((shift) => shift.pay);
    const ordered = (options.order || orderedByDay)(shifts);
    const days = [];
    const byDay = new Map();
    ordered.forEach((shift) => {
      if (!byDay.has(shift.day)) {
        byDay.set(shift.day, []);
        days.push(shift.day);
      }
      byDay.get(shift.day).push(shift);
    });
    return days
      .map((day) => {
        const dayShifts = byDay.get(day);
        const rows = dayShifts
          .map((shift) =>
            shiftRow(shift, currency, {
              state: shift.state,
              earnedPay: payOf(shift),
              hideDate: true,
            })
          )
          .join("");
        return `
      <div class="day-group">
        ${dayHead(dayKeyLabel(day), dayShifts, currency, payOf)}
        <div class="card-list shift-card">${rows}</div>
      </div>`;
      })
      .join("");
  }

  function byDayDirection(direction) {
    return (left, right) =>
      direction *
      (left.day.localeCompare(right.day) || left.start.localeCompare(right.start));
  }

  function orderedByDay(shifts) {
    return [...shifts].sort(byDayDirection(dateOrder === "asc" ? 1 : -1));
  }

  function chronological(shifts) {
    return [...shifts].sort(byDayDirection(1));
  }

  function shiftGroupsSection(shifts, currency, options = {}) {
    const multiDay = new Set(shifts.map((shift) => shift.day)).size > 1;
    const groups = shiftGroups(
      shifts,
      currency,
      multiDay ? options : { ...options, order: chronological }
    );
    return multiDay ? dateOrderToggle() + groups : groups;
  }

  function shiftDayCard(shifts, currency, options = {}) {
    const payOf = options.payOf || ((shift) => shift.pay);
    const rows = chronological(shifts)
      .map((shift) =>
        shiftRow(shift, currency, {
          state: shift.state,
          earnedPay: payOf(shift),
          hideDate: true,
        })
      )
      .join("");
    return `<div class="card-list shift-card">${rows}</div>`;
  }

  // A tally block's whole-period figures, counting shifts that haven't happened yet, so a
  // live period's hero reads the same as a browsed one (which comes from a plain totals API).
  function tallyTotals(block) {
    if (!Array.isArray(block.shifts)) return { hours: block.hours, count: Number(block.shifts) };
    return {
      hours: block.shifts.reduce((sum, shift) => sum + Number(shift.hours), 0),
      count: block.shifts.length,
    };
  }

  function heroBlock(block, currency, options = {}) {
    const totals = tallyTotals(block);
    const split =
      Number(block.to_come) > 0
        ? `<div class="projected">${money(block.earned, currency)} earned \u00b7 ${money(
            block.to_come,
            currency
          )} still to come</div>`
        : "";
    const label = options.label === false ? "" : `<div class="label">${escapeHtml(block.label)}</div>`;
    return `
      <div class="hero">
        ${label}
        <div class="amount">${money(block.projected, currency)}</div>
        <div class="meta">${hours(totals.hours)} \u00b7 ${totals.count} shift${
      totals.count === 1 ? "" : "s"
    }</div>
        ${split}
      </div>`;
  }

  function quickActionsBar() {
    const buttons = Object.entries(SCOPES)
      .map(
        ([key, meta]) => `
      <button class="quick-action${key === scope ? " active" : ""}" data-scope="${key}">
        <span class="qi">${meta.icon}</span>
        <span>${meta.label}</span>
      </button>`
      )
      .join("");
    return `<div class="quick-actions">${buttons}</div>`;
  }

  function groupByToggle() {
    return `
      <div class="group-toggle">
        <button type="button" class="group-toggle-btn${
          allTimeGroupBy === "month" ? " active" : ""
        }" data-groupby="month">Months</button>
        <button type="button" class="group-toggle-btn${
          allTimeGroupBy === "event" ? " active" : ""
        }" data-groupby="event">Events</button>
      </div>`;
  }

  function eventSortToggle() {
    return `
      <div class="event-sort">
        <span>Sort events</span>
        <div class="event-sort-toggle">
          <button type="button" class="event-sort-btn${
            eventSort === "date" ? " active" : ""
          }" data-event-sort="date">Event date</button>
          <button type="button" class="event-sort-btn${
            eventSort === "alphabetical" ? " active" : ""
          }" data-event-sort="alphabetical">A–Z</button>
        </div>
      </div>`;
  }

  function dateOrderToggle() {
    return `
    <div class="event-sort">
      <span>Order</span>
      <div class="event-sort-toggle">
        <button type="button" class="event-sort-btn${
          dateOrder === "asc" ? " active" : ""
        }" data-date-order="asc">Earliest first</button>
        <button type="button" class="event-sort-btn${
          dateOrder === "desc" ? " active" : ""
        }" data-date-order="desc">Latest first</button>
      </div>
    </div>`;
  }

  function sortedEvents(events) {
    return [...events].sort((left, right) => {
      if (eventSort === "alphabetical") return left.event.localeCompare(right.event);
      return (left.first_day || "9999-12-31").localeCompare(right.first_day || "9999-12-31") ||
        left.event.localeCompare(right.event);
    });
  }

  function dashboardView(data) {
    const tomorrow = shiftDayKey(currentDayKey(data), 1);
    const tomorrowShifts = data.upcoming.filter((shift) => shift.day === tomorrow);
    const tomorrowLabel = dayKeyLabel(tomorrow);
    const tomorrowBody = tomorrowShifts.length
      ? shiftDayCard(tomorrowShifts, data.currency)
      : `<div class="dashboard-empty">Nothing booked for ${escapeHtml(tomorrowLabel)}.</div>`;
    const month = data.month;
    const planned = Number(month.to_come) > 0 ? money(month.to_come, data.currency) : "No upcoming pay";

    return {
      // The hero and the two stat cards sit in the head so they stay inside the header
      // artwork while the list below them scrolls.
      head: `
        ${heroBlock(month, data.currency)}
        <div class="dashboard-glance">
          <div class="dashboard-stat" data-dashboard-stat="worked">
            <span>Worked this month</span>
            <strong>${hours(month.hours)}</strong>
            <div class="chevron">\u203a</div>
          </div>
          <div class="dashboard-stat" data-dashboard-stat="upcoming">
            <span>Upcoming shifts</span>
            <strong>${planned}</strong>
            <div class="chevron">\u203a</div>
          </div>
        </div>`,
      body: `
        <div class="section-title">Tomorrow · ${escapeHtml(tomorrowLabel)}</div>
        ${tomorrowBody}
      `,
    };
  }

  function dashboardDetailView(data) {
    const back = `<div class="back-row" id="back-to-overview">\u2039 Overview</div>`;
    if (dashboardDetail === "worked") {
      const worked = data.month.shifts
        .filter((s) => s.state !== "upcoming");
      // This drill-down is explicitly about work already done, so its hero counts what has
      // been earned rather than the month's full booked total.
      const earnedSoFar = {
        ...data.month,
        projected: data.month.earned,
        to_come: "0",
        shifts: worked.map((shift) => ({ hours: shift.earned_hours })),
      };
      return {
        head: back + heroBlock(earnedSoFar, data.currency),
        body: `
          <div class="section-title">Worked this month</div>
          ${
            worked.length
              ? shiftGroupsSection(worked, data.currency, { payOf: (s) => s.earned_pay })
              : `<div class="empty">No shifts worked this month yet.</div>`
          }`,
      };
    }

    const upcoming = upcomingView(data, { excludeDone: true });
    return { head: back + upcoming.head, body: upcoming.body };
  }

  function overviewView(data) {
    if (scope === "today") return dayScopeView(data);
    if (scope === "month") return monthScopeView(data);
    if (scope === "week") return weekScopeView(data);
    const bar = quickActionsBar();
    const hero = heroBlock(data.all_time, data.currency);
    const toggle = groupByToggle();
    if (allTimeGroupBy === "event") {
      if (!eventsData) {
        return { head: bar + hero + toggle, body: `<div class="empty">Loading…</div>` };
      }
      const body = eventsData.events.length
        ? `${eventSortToggle()}<div class="section-title">By event</div><div class="card-list">${eventListRows(
            sortedEvents(eventsData.events)
          )}</div>`
        : `<div class="empty">Nothing logged yet.</div>`;
      return { head: bar + hero + toggle, body };
    }
    const body = data.months.length
      ? `<div class="section-title">By month</div><div class="card-list">${monthListRows(
          data.months
        )}</div>`
      : `<div class="empty">Nothing logged yet.</div>`;
    return { head: bar + hero + toggle, body };
  }

  function dayScopeView(data) {
    const bar = quickActionsBar();
    const liveKey = currentDayKey(data);
    const activeKey = overviewDay || liveKey;
    const nav = monthNavBar(dayKeyLabel(activeKey), "day");

    if (activeKey === liveKey) {
      const block = data.today;
      const body = block.shifts.length
        ? shiftDayCard(block.shifts, data.currency, { payOf: scopePay })
        : `<div class="empty">Nothing logged yet.</div>`;
      const hero = heroBlock(block, data.currency, { label: false });
      return { head: bar + nav + hero, body };
    }

    if (!overviewDayData || overviewDayData.day !== activeKey) {
      return { head: bar + nav, body: `<div class="empty">Loading…</div>` };
    }
    return {
      head: bar + nav + periodHero(overviewDayData),
      body: periodBody(overviewDayData, { grouped: false }),
    };
  }

  function monthScopeView(data) {
    const bar = quickActionsBar();
    const liveKey = currentMonthKey(data);
    const activeKey = overviewMonth || liveKey;
    const nav = monthNavBar(monthKeyLabel(activeKey));

    if (activeKey === liveKey) {
      const block = data.month;
      const body = block.shifts.length
        ? shiftGroupsSection(block.shifts, data.currency, { payOf: scopePay })
        : `<div class="empty">Nothing logged yet.</div>`;
      const hero = heroBlock(block, data.currency, { label: false });
      return { head: bar + nav + hero, body };
    }

    if (!overviewMonthData || overviewMonthData.month !== activeKey) {
      return { head: bar + nav, body: `<div class="empty">Loading…</div>` };
    }
    return { head: bar + nav + periodHero(overviewMonthData), body: periodBody(overviewMonthData) };
  }

  function weekScopeView(data) {
    const bar = quickActionsBar();
    const liveStart = currentWeekStart(data);
    const activeStart = overviewWeekStart || liveStart;
    const nav = monthNavBar(weekLabel(activeStart), "week");

    if (activeStart === liveStart) {
      const block = data.week;
      const body = block.shifts.length
        ? shiftGroupsSection(block.shifts, data.currency, { payOf: scopePay })
        : `<div class="empty">Nothing logged yet.</div>`;
      const hero = heroBlock(block, data.currency, { label: false });
      return { head: bar + nav + hero, body };
    }

    if (!overviewWeekData || overviewWeekData.start !== activeStart) {
      return { head: bar + nav, body: `<div class="empty">Loading…</div>` };
    }
    return { head: bar + nav + periodHero(overviewWeekData), body: periodBody(overviewWeekData) };
  }

  function scopePay(shift) {
    return shift.state === "upcoming" ? shift.pay : shift.earned_pay;
  }

  // The hero card for a period detail (used once pinned above its list, and once inline).
  function periodHero(detail) {
    return `<div class="hero">
        <div class="amount">${money(detail.pay, detail.currency)}</div>
        <div class="meta">${hours(detail.hours)} \u00b7 ${detail.shifts.length} shift${
      detail.shifts.length === 1 ? "" : "s"
    }</div>
      </div>`;
  }

  function periodBody(detail, { grouped = true } = {}) {
    if (!detail.shifts.length) {
      return `<div class="empty">Nothing logged for ${escapeHtml(detail.label)}.</div>`;
    }
    return grouped
      ? shiftGroupsSection(detail.shifts, detail.currency)
      : shiftDayCard(detail.shifts, detail.currency);
  }

  const UPCOMING_RANGES = [
    ["tomorrow", "Tomorrow"],
    ["7", "7 days"],
    ["14", "14 days"],
    ["30", "30 days"],
    ["all", "All time"],
  ];

  function upcomingRangeToggle() {
    const buttons = UPCOMING_RANGES.map(
      ([key, label]) => `
      <button type="button" class="range-toggle-btn${
        key === upcomingRange ? " active" : ""
      }" data-upcoming-range="${key}">${label}</button>`
    ).join("");
    return `<div class="range-toggle">${buttons}</div>`;
  }

  function upcomingView(data, { excludeDone = false } = {}) {
    const visibleShifts = (shifts) =>
      excludeDone ? shifts.filter((s) => s.state !== "done") : shifts;
    const toggle = upcomingRangeToggle();
    if (upcomingRange === "14") {
      const shifts = visibleShifts(data.upcoming);
      if (!shifts.length) {
        return {
          head: toggle,
          body: `<div class="empty">${
            excludeDone
              ? "Nothing still to come in the next 14 days."
              : "Nothing booked in the next 14 days."
          }</div>`,
        };
      }
      return { head: toggle, body: shiftGroupsSection(shifts, data.currency) };
    }
    if (!upcomingRangeData || upcomingRangeData.scope !== upcomingRange) {
      return { head: toggle, body: `<div class="empty">Loading…</div>` };
    }
    const shifts = visibleShifts(upcomingRangeData.shifts);
    if (!shifts.length) {
      return {
        head: toggle,
        body: `<div class="empty">${
          excludeDone
            ? `Nothing still to come for ${escapeHtml(upcomingRangeData.label.toLowerCase())}.`
            : `Nothing booked for ${escapeHtml(upcomingRangeData.label)}.`
        }</div>`,
      };
    }
    return { head: toggle, body: shiftGroupsSection(shifts, upcomingRangeData.currency) };
  }

  function monthListRows(months) {
    return months
      .map(
        (m) => `
      <div class="row" data-month="${m.month}">
        <div class="icon">${ICONS.calendar}</div>
        <div class="info">
          <div class="title">${escapeHtml(m.label)}</div>
          <div class="sub">${m.shifts} shift${m.shifts === 1 ? "" : "s"} \u00b7 ${hours(m.hours)}</div>
        </div>
        <div class="value">${money(m.pay, m.currency)}</div>
        <div class="chevron">\u203a</div>
      </div>`
      )
      .join("");
  }

  function calendarView(data) {
    const activeMonth = calendarMonth || currentMonthKey(data);
    const header = `
      <div class="calendar-nav">
        <button type="button" class="month-nav-btn" data-calendar-nav="prev" aria-label="Previous month">‹</button>
        <div class="calendar-nav-label">${escapeHtml(monthKeyLabel(activeMonth))}</div>
        <button type="button" class="month-nav-btn" data-calendar-nav="next" aria-label="Next month">›</button>
      </div>`;
    if (!calendarMonthData || calendarMonthData.month !== activeMonth) {
      return { head: header, body: `<div class="empty">Loading calendar…</div>` };
    }

    const selectedDay = calendarSelectedDay || `${activeMonth}-01`;
    const shiftsByDay = calendarMonthData.shifts.reduce((grouped, shift) => {
      (grouped[shift.day] ||= []).push(shift);
      return grouped;
    }, {});
    const [year, month] = activeMonth.split("-").map(Number);
    const firstWeekday = (new Date(Date.UTC(year, month - 1, 1)).getUTCDay() + 6) % 7;
    const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
    const today = currentDayKey(data);
    const blanks = Array.from({ length: firstWeekday }, () => '<div class="calendar-day blank"></div>');
    const days = Array.from({ length: daysInMonth }, (_, index) => {
      const day = index + 1;
      const key = `${activeMonth}-${String(day).padStart(2, "0")}`;
      const count = (shiftsByDay[key] || []).length;
      return `
        <button type="button" class="calendar-day${key === today ? " today" : ""}${
          key === selectedDay ? " selected" : ""
        }${count ? " has-shifts" : ""}" data-calendar-day="${key}" aria-label="${day} ${
        count ? `with ${count} shift${count === 1 ? "" : "s"}` : ""
      }">
          <span>${day}</span>${count ? `<i>${count}</i>` : ""}
        </button>`;
    });
    const dayLabel = dayKeyLabel(selectedDay);
    const selectedShifts = shiftsByDay[selectedDay] || [];
    const selectedBody = selectedShifts.length
      ? `<div class="day-group">
          ${dayHead(dayLabel, selectedShifts, calendarMonthData.currency)}
          ${shiftDayCard(selectedShifts, calendarMonthData.currency)}
        </div>`
      : `<div class="day-group">
          <div class="day-head"><span class="day-when">${escapeHtml(dayLabel)}</span></div>
          <div class="empty calendar-empty">Nothing booked for ${escapeHtml(dayLabel)}.</div>
        </div>`;

    return {
      head: header,
      body: `
        <div class="calendar-card">
          <div class="calendar-weekdays"><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span><span>Sat</span><span>Sun</span></div>
          <div class="calendar-grid">${blanks.join("")}${days.join("")}</div>
        </div>
        ${selectedBody}
      `,
    };
  }

  function monthsView(data) {
    if (!data.months.length) {
      return { head: "", body: `<div class="empty">No shifts logged yet.</div>` };
    }
    const allTime = heroBlock(data.all_time, data.currency);
    const rows = monthListRows(data.months);
    return {
      head: allTime,
      body: `<div class="section-title">By month</div><div class="card-list">${rows}</div>`,
    };
  }

  function monthDetailView(detail) {
    return {
      head: `<div class="back-row" id="back-to-months">\u2039 Months</div>${monthNavBar(
        detail.label
      )}${periodHero(detail)}`,
      body: periodBody(detail),
    };
  }

  function eventListRows(events) {
    return events
      .map(
        (e) => `
      <div class="row" data-event="${encodeURIComponent(e.event)}">
        ${eventBadge(e.event)}
        <div class="info">
          <div class="title">${escapeHtml(e.event)}</div>
          <div class="sub">${e.shifts} shift${e.shifts === 1 ? "" : "s"} \u00b7 ${hours(e.hours)}</div>
        </div>
        <div class="value">${money(e.pay, e.currency)}</div>
        <div class="chevron">\u203a</div>
      </div>`
      )
      .join("");
  }

  function eventsView(data) {
    if (!data) {
      return { head: "", body: `<div class="empty">Loading…</div>` };
    }
    if (!data.events.length) {
      return { head: "", body: `<div class="empty">No shifts logged yet.</div>` };
    }
    const allTime = heroBlock(data.all_time, data.currency);
    const rows = eventListRows(data.events);
    return {
      head: allTime,
      body: `<div class="section-title">By event</div><div class="card-list">${rows}</div>`,
    };
  }

  function eventDetailView(detail) {
    const status = detail.payment_status || "upcoming";
    const meta = PAYMENT_STATUS_META[status] || PAYMENT_STATUS_META.pending_payment;
    const markPaidButton =
      status === "payment_completed"
        ? ""
        : `<button type="button" class="event-mark-paid-btn" data-mark-event-paid="${encodeURIComponent(
            detail.event
          )}">Mark event as paid</button>`;
    return {
      head: `<div class="back-row" id="back-to-events">\u2039 Events</div>${periodHero(detail)}
        <div class="event-payment-row">
          <span class="tag ${meta.cls}">${meta.label}</span>
          ${markPaidButton}
        </div>`,
      body: periodBody(detail),
    };
  }

  const SETTINGS_SECTIONS = [
    { key: "profile", icon: ICONS.user, label: "Account Settings" },
    { key: "pay", icon: ICONS.wallet, label: "Pay Rate" },
    { key: "reminders", icon: ICONS.bell, label: "Reminders" },
    { key: "calendar", icon: ICONS.calendar, label: "Calendar Sync" },
    { key: "export", icon: ICONS.download, label: "Export shifts" },
  ];

  function settingsSectionHint(key, data) {
    if (key === "pay") return `${money(data.default_rate, data.currency)} / hour`;
    if (key === "reminders") {
      return data.reminders.enabled ? `On \u00b7 ${data.reminders.send_at}` : "Off";
    }
    if (key === "calendar") return data.calendar_url ? "Connected" : "Not available";
    if (key === "export") return "Calendar or CSV";
    return "";
  }

  function avatarPreviewHtml() {
    return telegramFirstName ? escapeHtml(telegramFirstName.trim()[0].toUpperCase()) : "";
  }

  function settingsView(data) {
    if (!data) {
      return { head: "", body: `<div class="empty">Loading…</div>` };
    }
    return settingsSection ? settingsSectionView(data, settingsSection) : settingsHomeView(data);
  }

  function settingsHomeView(data) {
    const name = data.display_name || telegramFirstName || "You";
    const rows = SETTINGS_SECTIONS.map((section) => {
      const hint = settingsSectionHint(section.key, data);
      return `
      <div class="row editable" data-settings-section="${section.key}">
        <div class="icon">${section.icon}</div>
        <div class="info">
          <div class="title">${section.label}</div>
          ${hint ? `<div class="sub">${escapeHtml(hint)}</div>` : ""}
        </div>
        <div class="chevron">\u203a</div>
      </div>`;
    }).join("");

    return {
      head: "",
      body: `
      <div class="profile-card">
        <div class="avatar avatar-lg" id="settings-avatar-preview">${avatarPreviewHtml()}</div>
        <div class="profile-card-info">
          <div class="profile-card-name">${escapeHtml(name)}</div>
          ${
            telegramUsername
              ? `<div class="profile-card-sub">@${escapeHtml(telegramUsername)}</div>`
              : ""
          }
        </div>
      </div>
      <div class="card-list">${rows}</div>
    `,
    };
  }

  function settingsSectionView(data, section) {
    const back = `<div class="back-row" id="back-to-settings">\u2039 Settings</div>`;
    if (section === "profile") {
      return {
        head: back,
        body: `
        <div class="section-title">Avatar</div>
        <div class="card-list settings-card">
          <div class="settings-row avatar-row">
            <div class="avatar avatar-lg" id="settings-avatar-preview">${avatarPreviewHtml()}</div>
            <div class="avatar-actions">
              <button type="button" class="btn secondary" data-action="choose-avatar">Choose photo</button>
              ${
                data.has_custom_avatar
                  ? `<button type="button" class="btn destructive" data-action="remove-avatar">Remove</button>`
                  : ""
              }
            </div>
          </div>
          <input type="file" id="avatar-file-input" accept="image/png,image/jpeg,image/webp" class="hidden" />
        </div>
        <p class="modal-error hidden" id="settings-avatar-error"></p>

        <div class="section-title">Display name</div>
        <div class="card-list settings-card">
          <div class="settings-row">
            <label for="settings-display-name">Display name</label>
            <input
              type="text"
              id="settings-display-name"
              maxlength="60"
              placeholder="${escapeHtml(telegramFirstName || "Your name")}"
              value="${escapeHtml(data.display_name)}"
            />
          </div>
        </div>
        <button type="button" class="btn primary settings-btn" data-action="save-profile">Save</button>
        <p class="modal-error hidden" id="settings-profile-error"></p>
      `,
      };
    }
    if (section === "pay") {
      return {
        head: back,
        body: `
        <div class="section-title">Pay</div>
        <div class="card-list settings-card">
          <div class="settings-row">
            <label for="settings-rate">Default rate / hour</label>
            <input type="number" id="settings-rate" min="0" step="0.01" value="${data.default_rate}" />
          </div>
          <div class="settings-row">
            <label for="settings-currency">Currency</label>
            <input type="text" id="settings-currency" maxlength="8" value="${escapeHtml(data.currency)}" />
          </div>
        </div>
        <button type="button" class="btn primary settings-btn" data-action="save-pay">Save</button>
        <p class="modal-error hidden" id="settings-pay-error"></p>
      `,
      };
    }
    if (section === "reminders") {
      return {
        head: back,
        body: `
        <div class="section-title">Reminders</div>
        <div class="card-list settings-card">
          <div class="settings-row toggle-row">
            <label for="settings-reminders-enabled">Day-before reminder</label>
            <label class="switch">
              <input type="checkbox" id="settings-reminders-enabled" ${
                data.reminders.enabled ? "checked" : ""
              } />
              <span class="slider"></span>
            </label>
          </div>
          <div class="settings-row">
            <label for="settings-reminders-time">Send at</label>
            <input type="time" id="settings-reminders-time" value="${data.reminders.send_at}" />
          </div>
          <div class="settings-row">
            <label for="settings-reminders-offset">Timezone (e.g. +8)</label>
            <input
              type="text"
              id="settings-reminders-offset"
              value="${escapeHtml(data.reminders.utc_offset_label.replace("UTC", ""))}"
            />
          </div>
        </div>
        <button type="button" class="btn primary settings-btn" data-action="save-reminders">Save</button>
        <p class="modal-error hidden" id="settings-reminders-error"></p>
      `,
      };
    }
    if (section === "export") {
      return {
        head: back,
        body: `
          <div class="section-title">Export shifts</div>
          <div class="card-list settings-card export-card">
            <div class="settings-row">
              <label>Calendar</label>
              <p>Subscribe to keep your calendar automatically in sync with every shift.</p>
              ${
                data.calendar_url
                  ? `<button type="button" class="btn primary" data-action="export-calendar" data-calendar-url="${escapeHtml(
                      data.calendar_url
                    )}">Export to calendar</button>`
                  : `<span class="settings-muted">Calendar export is not available on this deployment.</span>`
              }
            </div>
            <div class="settings-row">
              <label>Spreadsheet</label>
              <p>Download every logged shift as a CSV file for Excel, Numbers, or Google Sheets.</p>
              <button type="button" class="btn secondary" data-action="export-csv">Download CSV</button>
            </div>
          </div>
          <p class="modal-error hidden" id="settings-export-error"></p>
        `,
      };
    }
    // section === "calendar"
    return {
      head: back,
      body: `
        <div class="section-title">Calendar</div>
        <div class="card-list settings-card">
          <div class="settings-row">
            <label>Subscription link</label>
            <div class="calendar-link" id="settings-calendar-link">${
              data.calendar_url ? escapeHtml(data.calendar_url) : "Not available on this deployment"
            }</div>
          </div>
        </div>
        ${
          data.calendar_url
            ? `<button type="button" class="btn primary settings-btn" data-action="add-to-calendar" data-calendar-url="${escapeHtml(
                data.calendar_url
              )}">Add to Calendar</button>`
            : ""
        }
        ${
          data.calendar_url
            ? `<div class="settings-actions">
                <button type="button" class="btn secondary" data-action="copy-calendar">Copy link</button>
                <button type="button" class="btn secondary" data-action="rotate-calendar">New link</button>
              </div>`
            : ""
        }
        <p class="section-hint">
          Telegram opens calendar files in its own viewer instead of handing them to your
          Calendar app. To actually import your shifts: tap "Add to Calendar", choose
          <strong>Save to Files</strong>, then open that saved file from the Files app —
          that's what triggers your phone's native "Add to Calendar" screen. For live syncing
          instead of a one-time import, use "Copy link" and paste it into your calendar app's
          own "Add Subscribed Calendar" / "From URL" option (Settings → Calendar → Accounts →
          Add Account → Other on iPhone; Other calendars → From URL on Google Calendar).
        </p>
      `,
    };
  }

  function render() {
    if (!summaryData) return;
    els.asof.textContent = `As of ${new Date(summaryData.now).toLocaleString(undefined, {
      weekday: "short",
      day: "2-digit",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    })}`;

    let result;
    if (monthDetail) {
      result = monthDetailView(monthDetail);
    } else if (eventDetail) {
      result = eventDetailView(eventDetail);
    } else if (view === "dashboard" && dashboardDetail) {
      result = dashboardDetailView(summaryData);
    } else if (view === "dashboard") {
      result = dashboardView(summaryData);
    } else if (view === "summary") {
      result = overviewView(summaryData);
    } else if (view === "calendar") {
      result = calendarView(summaryData);
    } else if (view === "events") {
      result = eventsView(eventsData);
    } else if (view === "settings") {
      result = settingsView(settingsData);
    } else {
      result = monthsView(summaryData);
    }
    els.contentHead.innerHTML = result.head;
    els.contentList.innerHTML = result.body;
    // Settings previews are freshly created above; repaint it after every render.
    updateGreeting();
  }

  async function loadEvents() {
    try {
      eventsData = await api("/webapp/api/events");
      render();
    } catch (err) {
      showError(err);
    }
  }

  async function loadCalendarMonth(month, selectedDay = null) {
    calendarMonth = month;
    calendarMonthData = null;
    if (selectedDay) calendarSelectedDay = selectedDay;
    render();
    try {
      const result = await api(`/webapp/api/month/${month}`);
      if (calendarMonth === month) {
        calendarMonthData = result;
        const today = currentDayKey(summaryData);
        if (!calendarSelectedDay || !calendarSelectedDay.startsWith(`${month}-`)) {
          calendarSelectedDay = today.startsWith(`${month}-`) ? today : `${month}-01`;
        }
        render();
      }
    } catch (err) {
      showError(err);
    }
  }

  function navigateCalendarMonth(direction) {
    const activeMonth = calendarMonth || currentMonthKey(summaryData);
    const nextMonth = shiftMonthKey(activeMonth, direction);
    const today = currentDayKey(summaryData);
    loadCalendarMonth(nextMonth, today.startsWith(`${nextMonth}-`) ? today : `${nextMonth}-01`);
  }

  async function loadSettings() {
    try {
      settingsData = await api("/webapp/api/settings");
      render();
      updateGreeting();
    } catch (err) {
      // a background/lazy fetch — the Settings tab just keeps showing "Loading…" and
      // retries next time it's opened, without hijacking whatever view is on screen
    }
  }

  async function openMonth(month) {
    if (tg && tg.BackButton) tg.BackButton.show();
    try {
      monthDetail = await api(`/webapp/api/month/${month}`);
      render();
    } catch (err) {
      showError(err);
    }
  }

  async function navigateMonthDetail(direction) {
    if (!monthDetail) return;
    const nextKey = shiftMonthKey(monthDetail.month, direction);
    try {
      monthDetail = await api(`/webapp/api/month/${nextKey}`);
      render();
    } catch (err) {
      showError(err);
    }
  }

  async function navigateOverviewMonth(direction) {
    const liveKey = currentMonthKey(summaryData);
    const activeKey = overviewMonth || liveKey;
    const nextKey = shiftMonthKey(activeKey, direction);
    if (nextKey === liveKey) {
      overviewMonth = null;
      overviewMonthData = null;
      render();
      return;
    }
    overviewMonth = nextKey;
    overviewMonthData = null;
    render();
    try {
      overviewMonthData = await api(`/webapp/api/month/${nextKey}`);
      render();
    } catch (err) {
      showError(err);
    }
  }

  async function navigateOverviewWeek(direction) {
    const liveStart = currentWeekStart(summaryData);
    const activeStart = overviewWeekStart || liveStart;
    const nextStart = shiftWeekStart(activeStart, direction);
    if (nextStart === liveStart) {
      overviewWeekStart = null;
      overviewWeekData = null;
      render();
      return;
    }
    overviewWeekStart = nextStart;
    overviewWeekData = null;
    render();
    try {
      overviewWeekData = await api(`/webapp/api/week/${nextStart}`);
      render();
    } catch (err) {
      showError(err);
    }
  }

  async function navigateOverviewDay(direction) {
    const liveKey = currentDayKey(summaryData);
    const activeKey = overviewDay || liveKey;
    const nextKey = shiftDayKey(activeKey, direction);
    if (nextKey === liveKey) {
      overviewDay = null;
      overviewDayData = null;
      render();
      return;
    }
    overviewDay = nextKey;
    overviewDayData = null;
    render();
    try {
      overviewDayData = await api(`/webapp/api/day/${nextKey}`);
      render();
    } catch (err) {
      showError(err);
    }
  }

  function setMonthDetail(value) {
    monthDetail = value;
    if (tg && tg.BackButton) {
      if (value) tg.BackButton.show();
      else tg.BackButton.hide();
    }
    render();
  }

  function setDashboardDetail(value) {
    dashboardDetail = value;
    if (value === "upcoming") upcomingRange = "14";
    if (tg && tg.BackButton) {
      if (value) tg.BackButton.show();
      else tg.BackButton.hide();
    }
    render();
  }

  async function openEvent(name) {
    if (tg && tg.BackButton) tg.BackButton.show();
    try {
      eventDetail = await api(`/webapp/api/event/${encodeURIComponent(name)}`);
      render();
    } catch (err) {
      showError(err);
    }
  }

  function setEventDetail(value) {
    eventDetail = value;
    if (tg && tg.BackButton) {
      if (value) tg.BackButton.show();
      else tg.BackButton.hide();
    }
    render();
  }

  // Gigs are almost always paid out as one lump sum, not shift by shift — one click marks
  // every shift for this event as paid instead of opening each one individually.
  async function markEventPaid(eventName) {
    const confirmed = await confirmDialog(`Mark every shift for "${eventName}" as paid?`);
    if (!confirmed) return;
    try {
      await api(`/webapp/api/event/${encodeURIComponent(eventName)}/mark-paid`, {
        method: "POST",
      });
      await refreshAfterEdit();
      showSuccessToast("Marked as paid");
    } catch (err) {
      showToast(err.detail || "Couldn't mark as paid — try again.");
    }
  }

  function setSettingsSection(value) {
    settingsSection = value;
    if (tg && tg.BackButton) {
      if (value) tg.BackButton.show();
      else tg.BackButton.hide();
    }
    render();
  }

  function selectScope(next) {
    scope = next;
    if (next === "month") {
      overviewMonth = null;
      overviewMonthData = null;
    }
    if (next === "week") {
      overviewWeekStart = null;
      overviewWeekData = null;
    }
    if (next === "today") {
      overviewDay = null;
      overviewDayData = null;
    }
    render();
  }

  function selectAllTimeGroupBy(next) {
    allTimeGroupBy = next;
    if (next === "event" && !eventsData) {
      render();
      loadEvents();
    } else {
      render();
    }
  }

  function selectEventSort(next) {
    eventSort = next;
    render();
  }

  function selectDateOrder(next) {
    dateOrder = next;
    render();
  }

  function selectUpcomingRange(next) {
    upcomingRange = next;
    if (next === "14") {
      render();
      return;
    }
    upcomingRangeData = null;
    render();
    loadUpcomingRange(next);
  }

  async function loadUpcomingRange(scope) {
    try {
      const result = await api(`/webapp/api/upcoming/${scope}`);
      if (scope === upcomingRange) {
        upcomingRangeData = result;
        render();
      }
    } catch (err) {
      showError(err);
    }
  }

  function selectView(next) {
    if (next === "add") {
      openCreator(view === "calendar" ? calendarSelectedDay : null);
      return;
    }
    view = next;
    dashboardDetail = null;
    monthDetail = null;
    eventDetail = null;
    overviewMonth = null;
    overviewMonthData = null;
    overviewWeekStart = null;
    overviewWeekData = null;
    settingsSection = null;
    if (tg && tg.BackButton) tg.BackButton.hide();
    [...els.bottomNav.querySelectorAll(".nav-btn")].forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.view === next);
    });
    if (next === "calendar") {
      const month = calendarMonth || currentMonthKey(summaryData);
      if (!calendarMonthData || calendarMonthData.month !== month) {
        loadCalendarMonth(month);
      } else {
        render();
      }
    } else if (next === "events" && !eventsData) {
      render();
      loadEvents();
    } else if (next === "settings" && !settingsData) {
      render();
      loadSettings();
    } else {
      render();
    }
  }

  function showError(err) {
    els.loading.classList.add("hidden");
    els.contentWrap.classList.add("hidden");
    els.error.classList.remove("hidden");
    if (err && err.message === "no-init-data") {
      els.errorText.textContent = "Open this from the HowMuch bot in Telegram.";
    } else {
      els.errorText.textContent = "Couldn't load your shifts — tap ⟳ to try again.";
    }
  }

  async function load() {
    els.loading.classList.remove("hidden");
    els.error.classList.add("hidden");
    els.contentWrap.classList.add("hidden");
    try {
      summaryData = await api("/webapp/api/summary");
      els.loading.classList.add("hidden");
      els.contentWrap.classList.remove("hidden");
      render();
      checkDuePayments();
    } catch (err) {
      showError(err);
    }
  }

  // Session-only — a shift skipped this way is asked about again next time the app opens,
  // as long as it's still unpaid and its due date has passed.
  const dismissedPaymentPrompts = new Set();

  // Surfaces unpaid shifts whose payment due date has arrived, one at a time, so the user
  // can confirm marking each as paid instead of it silently flipping on its own.
  async function checkDuePayments() {
    try {
      const result = await api("/webapp/api/payments/due");
      const next = result.shifts.find((s) => !dismissedPaymentPrompts.has(s.id));
      if (!next) return;
      dismissedPaymentPrompts.add(next.id);
      const confirmed = await confirmDialog(
        `Mark "${next.event}" (${next.date_label}) as paid — ${money(next.pay, next.currency)}?`
      );
      if (confirmed) {
        await api(`/webapp/api/shifts/${next.id}`, { method: "PATCH", body: { paid: true } });
        await refreshAfterEdit();
      }
      checkDuePayments();
    } catch (err) {
      // a background nicety — silently skip if it fails, the shift will surface again next load
    }
  }

  // iOS renders native date/time inputs with no custom styling ability, so we mirror
  // their value into a compact custom display (see .field-control in style.css).
  function formatDayDisplay(value) {
    if (!value) return "";
    const [year, month, day] = value.split("-");
    if (!year || !month || !day) return "";
    return `${day}/${month}/${year}`;
  }

  function formatTimeDisplay(value) {
    if (!value) return "";
    const [hourStr, minuteStr] = value.split(":");
    const hour = Number(hourStr);
    if (Number.isNaN(hour) || !minuteStr) return "";
    const period = hour >= 12 ? "pm" : "am";
    const hour12 = hour % 12 === 0 ? 12 : hour % 12;
    return `${hour12}:${minuteStr} ${period}`;
  }

  function syncFieldDisplay(input) {
    const control = input.closest(".field-control");
    const valueEl = control && control.querySelector(".field-value");
    if (!valueEl) return;
    valueEl.textContent = input.type === "date" ? formatDayDisplay(input.value) : formatTimeDisplay(input.value);
  }

  function syncScheduleDisplays() {
    [els.editForm.day, els.editForm.start, els.editForm.end, els.editForm.payment_due].forEach(
      syncFieldDisplay
    );
  }

  // Reflects the paid checkbox and the shift's own state (upcoming shifts are never
  // "pending"/"completed", however the paid flag happens to be set) as a nicer status pill.
  function syncPaymentBadge() {
    if (!els.editPaymentBadge) return;
    const state = editingShiftSnapshot ? editingShiftSnapshot.state : "upcoming";
    const status = paymentStatusOf({ paid: els.editForm.paid.checked }, state);
    const meta = PAYMENT_STATUS_META[status] || PAYMENT_STATUS_META.pending_payment;
    els.editPaymentBadge.className = `tag ${meta.cls}`;
    els.editPaymentBadge.textContent = meta.label;
  }

  function syncEventBadge() {
    const event = els.editForm.event.value.trim();
    const color = event ? eventColor(event) : { bg: "var(--fill)", fg: "var(--hint)" };
    els.editBadge.style.background = color.bg;
    els.editBadge.style.color = color.fg;
    els.editBadge.textContent = event ? eventInitial(event) : "+";
  }

  function syncRateWidth() {
    const input = els.editForm.rate;
    const shown = input.value || input.placeholder || "0";
    input.style.width = `${Math.max(shown.length, 1) + 0.5}ch`;
  }

  function setBreakPaid(value) {
    els.editForm.break_paid.value = value;
    els.editBreakPaid.querySelectorAll("[data-break-paid]").forEach((button) => {
      button.classList.toggle("active", button.dataset.breakPaid === value);
    });
  }

  function openEditor(shift) {
    if (!shift) return;
    editorMode = "edit";
    editingShiftId = shift.id;
    editingShiftSnapshot = shift;
    els.editTitle.textContent = "Edit Shift";
    els.editForm.event.value = shift.event;
    syncEventBadge();
    els.editForm.location.value = shift.location || "";
    els.editForm.day.value = shift.day;
    els.editForm.start.value = shift.start;
    els.editForm.end.value = shift.end;
    els.editForm.rate.value = shift.rate;
    els.editForm.break_hours.value = shift.break_hours;
    setBreakPaid(shift.break_paid ? "yes" : "no");
    els.editForm.payment_due.value = shift.payment_due || defaultPaymentDue(shift.day);
    els.editForm.paid.checked = Boolean(shift.paid);
    els.editPaidRow.classList.remove("hidden");
    paymentDueTouched = false;
    syncPaymentBadge();
    els.editCurrency.textContent = (summaryData && summaryData.currency) || "";
    syncScheduleDisplays();
    els.editError.classList.add("hidden");
    els.editShiftActions.classList.remove("hidden");
    els.editSheet.scrollTop = 0;
    syncRateWidth();
    els.editBackdrop.classList.remove("hidden");
  }

  function openCreator(presetDay) {
    editorMode = "create";
    editingShiftId = null;
    editingShiftSnapshot = null;
    els.editForm.reset();
    els.editTitle.textContent = "New Shift";
    syncEventBadge();
    els.editCurrency.textContent = (summaryData && summaryData.currency) || "";
    const today = ((summaryData && summaryData.now) || new Date().toISOString()).slice(0, 10);
    els.editForm.day.value = presetDay || today;
    els.editForm.start.value = "09:00";
    els.editForm.end.value = "17:00";
    setBreakPaid("yes");
    els.editForm.payment_due.value = defaultPaymentDue(els.editForm.day.value);
    els.editForm.paid.checked = false;
    els.editPaidRow.classList.add("hidden");
    paymentDueTouched = false;
    syncPaymentBadge();
    syncScheduleDisplays();
    els.editError.classList.add("hidden");
    els.editShiftActions.classList.add("hidden");
    els.editSheet.scrollTop = 0;
    syncRateWidth();
    els.editBackdrop.classList.remove("hidden");
  }

  function closeEditor() {
    els.editBackdrop.classList.add("hidden");
    editingShiftId = null;
    editorMode = null;
    editingShiftSnapshot = null;
    activeEditField = null;
    els.editSheet.style.paddingBottom = "";
  }

  async function refreshAfterEdit() {
    if (monthDetail) {
      try {
        monthDetail = await api(`/webapp/api/month/${monthDetail.month}`);
      } catch (err) {
        monthDetail = null;
      }
    }
    if (eventDetail) {
      try {
        eventDetail = await api(`/webapp/api/event/${encodeURIComponent(eventDetail.event)}`);
      } catch (err) {
        eventDetail = null;
      }
    }
    if (calendarMonth) {
      try {
        calendarMonthData = await api(`/webapp/api/month/${calendarMonth}`);
      } catch (err) {
        calendarMonthData = null;
      }
    }
    if (overviewMonthData && overviewMonth) {
      try {
        overviewMonthData = await api(`/webapp/api/month/${overviewMonth}`);
      } catch (err) {
        overviewMonthData = null;
      }
    }
    if (overviewWeekData && overviewWeekStart) {
      try {
        overviewWeekData = await api(`/webapp/api/week/${overviewWeekStart}`);
      } catch (err) {
        overviewWeekData = null;
      }
    }
    if (overviewDayData && overviewDay) {
      try {
        overviewDayData = await api(`/webapp/api/day/${overviewDay}`);
      } catch (err) {
        overviewDayData = null;
      }
    }
    if (upcomingRangeData) {
      try {
        const result = await api(`/webapp/api/upcoming/${upcomingRange}`);
        if (result.scope === upcomingRange) upcomingRangeData = result;
      } catch (err) {
        upcomingRangeData = null;
      }
    }
    if (eventsData) {
      loadEvents();
    }
    await load();
  }

  async function submitCreate() {
    const form = els.editForm;
    const payload = {
      event: form.event.value.trim(),
      location: form.location.value.trim(),
      day: form.day.value,
      start: form.start.value,
      end: form.end.value,
    };
    if (form.rate.value) payload.rate = form.rate.value;
    if (form.break_hours.value) {
      payload.break_hours = form.break_hours.value;
      payload.break_paid = form.break_paid.value === "yes";
    }
    // Left untouched — the server computes the real default from the whole event's last day.
    if (paymentDueTouched && form.payment_due.value) payload.payment_due = form.payment_due.value;
    return api("/webapp/api/shifts", { method: "POST", body: payload });
  }

  async function submitUpdate() {
    const shift = shiftsById.get(editingShiftId);
    if (!shift) return null;
    const form = els.editForm;
    const payload = {};
    if (form.event.value.trim() !== shift.event) payload.event = form.event.value.trim();
    if (form.location.value.trim() !== (shift.location || ""))
      payload.location = form.location.value.trim();
    if (form.day.value !== shift.day) payload.day = form.day.value;
    if (form.start.value !== shift.start) payload.start = form.start.value;
    if (form.end.value !== shift.end) payload.end = form.end.value;
    if (form.rate.value !== shift.rate) payload.rate = form.rate.value;
    if (form.break_hours.value !== shift.break_hours)
      payload.break_hours = form.break_hours.value || "0";
    const breakPaid = form.break_paid.value === "yes";
    if (breakPaid !== shift.break_paid) payload.break_paid = breakPaid;
    const currentPaymentDue = shift.payment_due || defaultPaymentDue(shift.day);
    if (form.payment_due.value && form.payment_due.value !== currentPaymentDue)
      payload.payment_due = form.payment_due.value;
    if (form.paid.checked !== Boolean(shift.paid)) payload.paid = form.paid.checked;
    if (!Object.keys(payload).length) return null;
    return api(`/webapp/api/shifts/${shift.id}`, { method: "PATCH", body: payload });
  }

  function showClashWarning(clashes) {
    const lines = clashes
      .map((c) => `\u2022 ${c.event} — ${c.day} ${c.start}–${c.end}`)
      .join("\n");
    const message = `⚠️ This overlaps with:\n${lines}`;
    if (tg && tg.showAlert) {
      tg.showAlert(message);
    } else {
      window.alert(message);
    }
  }

  async function submitEditor(event) {
    event.preventDefault();
    els.editSave.disabled = true;
    els.editError.classList.add("hidden");
    try {
      let result;
      if (editorMode === "create") {
        result = await submitCreate();
      } else {
        result = await submitUpdate();
      }
      closeEditor();
      await refreshAfterEdit();
      if (result && result.clashes && result.clashes.length) {
        showClashWarning(result.clashes);
      }
    } catch (err) {
      const fallback =
        editorMode === "create"
          ? "Couldn't add the shift — check the fields and try again."
          : "Couldn't save — check the fields and try again.";
      els.editError.textContent = err.detail || fallback;
      els.editError.classList.remove("hidden");
    } finally {
      els.editSave.disabled = false;
    }
  }

  // Prefills the create-shift form from the shift currently open for editing, advancing the
  // date by a day, so logging the same event across several days doesn't mean retyping
  // the location/time/rate each time.
  function duplicateEditingShift() {
    if (editorMode !== "edit" || !editingShiftId) return;
    const form = els.editForm;
    const duplicated = {
      event: form.event.value,
      location: form.location.value,
      day: form.day.value,
      start: form.start.value,
      end: form.end.value,
      rate: form.rate.value,
      break_hours: form.break_hours.value,
      break_paid: form.break_paid.value,
    };
    openCreator();
    form.event.value = duplicated.event;
    form.location.value = duplicated.location;
    if (duplicated.day) {
      const [year, month, dayNum] = duplicated.day.split("-").map(Number);
      form.day.value = isoDateUTC(new Date(Date.UTC(year, month - 1, dayNum) + 86400000));
    }
    form.start.value = duplicated.start;
    form.end.value = duplicated.end;
    form.rate.value = duplicated.rate;
    form.break_hours.value = duplicated.break_hours;
    setBreakPaid(duplicated.break_paid);
    form.payment_due.value = defaultPaymentDue(form.day.value);
    syncScheduleDisplays();
    syncRateWidth();
  }

  async function deleteEditingShift() {
    if (editorMode !== "edit" || !editingShiftId) return;
    const shift = shiftsById.get(editingShiftId);
    els.editDelete.disabled = true;
    els.editError.classList.add("hidden");
    try {
      await api(`/webapp/api/shifts/${editingShiftId}`, { method: "DELETE" });
      closeEditor();
      await refreshAfterEdit();
      if (shift) showUndoToast(shift);
    } catch (err) {
      els.editError.textContent = err.detail || "Couldn't delete — try again.";
      els.editError.classList.remove("hidden");
    } finally {
      els.editDelete.disabled = false;
    }
  }

  function hideToast() {
    els.toast.classList.add("hidden");
    if (toastTimeout) {
      clearTimeout(toastTimeout);
      toastTimeout = null;
    }
  }

  function showToast(message, actionLabel, onAction) {
    hideToast();
    els.toast.classList.remove("success");
    els.toastText.textContent = message;
    els.toastAction.textContent = actionLabel || "";
    els.toastAction.classList.toggle("hidden", !actionLabel);
    els.toastAction.onclick = () => {
      hideToast();
      if (onAction) onAction();
    };
    els.toast.classList.remove("hidden");
    toastTimeout = setTimeout(hideToast, 8000);
  }

  function showSuccessToast(message) {
    hideToast();
    els.toast.classList.add("success");
    els.toastText.textContent = message;
    els.toastAction.textContent = "";
    els.toastAction.classList.add("hidden");
    els.toastAction.onclick = null;
    els.toast.classList.remove("hidden");
    toastTimeout = setTimeout(hideToast, 2600);
  }

  function setButtonSaving(button, saving, label = "Updating…") {
    if (!button) return;
    if (saving) {
      button.dataset.label = button.textContent;
      button.disabled = true;
      button.classList.add("is-saving");
      button.innerHTML = `<span class="button-spinner" aria-hidden="true"></span>${label}`;
      return;
    }
    button.disabled = false;
    button.classList.remove("is-saving");
    if (button.dataset.label) button.textContent = button.dataset.label;
  }

  function showUndoToast(shift) {
    showToast("Shift deleted — Undo", "Undo", async () => {
      try {
        await api("/webapp/api/shifts", {
          method: "POST",
          body: {
            event: shift.event,
            location: shift.location || "",
            day: shift.day,
            start: shift.start,
            end: shift.end,
            rate: shift.rate,
            break_hours: shift.break_hours,
            break_paid: shift.break_paid,
          },
        });
        await refreshAfterEdit();
      } catch (err) {
        showError(err);
      }
    });
  }

  function confirmDialog(message) {
    return new Promise((resolve) => {
      if (tg && tg.showConfirm) {
        tg.showConfirm(message, (ok) => resolve(ok));
      } else {
        resolve(window.confirm(message));
      }
    });
  }

  function showSettingsError(id, message) {
    const el = document.getElementById(id);
    if (el) {
      el.textContent = message;
      el.classList.remove("hidden");
    }
  }

  function hideSettingsError(id) {
    const el = document.getElementById(id);
    if (el) el.classList.add("hidden");
  }

  function chooseAvatar() {
    const input = document.getElementById("avatar-file-input");
    if (input) input.click();
  }

  async function handleAvatarFileSelected(event) {
    const file = event.target.files && event.target.files[0];
    event.target.value = ""; // allow choosing the same file again later
    if (!file) return;
    hideSettingsError("settings-avatar-error");
    if (file.size > 2 * 1024 * 1024) {
      showSettingsError("settings-avatar-error", "Image is too large (max 2 MB).");
      return;
    }
    const chooseButton = document.querySelector('[data-action="choose-avatar"]');
    setButtonSaving(chooseButton, true, "Uploading…");
    try {
      const dataUrl = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(file);
      });
      await api("/webapp/api/avatar", { method: "POST", body: { data_url: dataUrl } });
      settingsData = await api("/webapp/api/settings");
      await loadAvatarPhoto();
      render();
      showSuccessToast("Avatar updated successfully");
    } catch (err) {
      showSettingsError("settings-avatar-error", err.detail || "Couldn't upload — try a smaller image.");
    } finally {
      setButtonSaving(chooseButton, false);
    }
  }

  async function removeAvatar(button) {
    hideSettingsError("settings-avatar-error");
    setButtonSaving(button, true, "Removing…");
    try {
      await api("/webapp/api/avatar", { method: "DELETE" });
      settingsData = await api("/webapp/api/settings");
      await loadAvatarPhoto();
      render();
      showSuccessToast("Avatar removed successfully");
    } catch (err) {
      showSettingsError("settings-avatar-error", err.detail || "Couldn't remove — try again.");
    } finally {
      setButtonSaving(button, false);
    }
  }

  async function saveProfile(button) {
    hideSettingsError("settings-profile-error");
    const value = document.getElementById("settings-display-name").value.trim();
    setButtonSaving(button, true);
    try {
      settingsData = await api("/webapp/api/settings", {
        method: "PATCH",
        body: { display_name: value },
      });
      updateGreeting();
      showSuccessToast("Display name updated successfully");
    } catch (err) {
      showSettingsError("settings-profile-error", err.detail || "Couldn't save — try again.");
    } finally {
      setButtonSaving(button, false);
    }
  }

  async function savePay(button) {
    hideSettingsError("settings-pay-error");
    const rate = document.getElementById("settings-rate").value;
    const currency = document.getElementById("settings-currency").value;
    setButtonSaving(button, true);
    try {
      settingsData = await api("/webapp/api/settings", {
        method: "PATCH",
        body: { default_rate: rate, currency },
      });
      render();
      showSuccessToast("Pay settings updated successfully");
    } catch (err) {
      showSettingsError("settings-pay-error", err.detail || "Couldn't save — check the rate.");
    } finally {
      setButtonSaving(button, false);
    }
  }

  async function saveReminders(button) {
    hideSettingsError("settings-reminders-error");
    const enabled = document.getElementById("settings-reminders-enabled").checked;
    const sendAt = document.getElementById("settings-reminders-time").value;
    const offset = document.getElementById("settings-reminders-offset").value;
    setButtonSaving(button, true);
    try {
      settingsData = await api("/webapp/api/reminders", {
        method: "PATCH",
        body: { enabled, send_at: sendAt, utc_offset: offset },
      });
      render();
      showSuccessToast("Reminder settings updated successfully");
    } catch (err) {
      showSettingsError(
        "settings-reminders-error",
        err.detail || "Couldn't save — check the time and timezone."
      );
    } finally {
      setButtonSaving(button, false);
    }
  }

  // Telegram only reliably opens http(s) links via tg.openLink() (custom schemes like webcal:
  // get swallowed as a generic document share instead). Serving the feed without a forced
  // download means Safari/Calendar recognize text/calendar and show their own import screen.
  function openCalendarSubscription(button) {
    const url = button.dataset.calendarUrl;
    if (!url) return;
    if (tg && tg.openLink) {
      tg.openLink(url);
    } else {
      window.location.href = url;
    }
  }

  async function exportCsv(button) {
    const headers = authHeader();
    if (!headers) return;
    hideSettingsError("settings-export-error");
    setButtonSaving(button, true, "Preparing…");
    try {
      const response = await fetch("/webapp/api/export/csv", { headers });
      if (!response.ok) {
        let detail;
        try {
          detail = (await response.json()).detail;
        } catch (err) {
          detail = undefined;
        }
        const error = new Error("csv-export-failed");
        error.detail = detail;
        throw error;
      }
      const url = URL.createObjectURL(await response.blob());
      const link = document.createElement("a");
      link.href = url;
      link.download = "howmuch-shifts.csv";
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
      showSuccessToast("CSV downloaded successfully");
    } catch (err) {
      showSettingsError("settings-export-error", err.detail || "Couldn't export CSV — try again.");
    } finally {
      setButtonSaving(button, false);
    }
  }

  async function copyCalendarLink(button) {
    if (!settingsData || !settingsData.calendar_url) return;
    try {
      await navigator.clipboard.writeText(settingsData.calendar_url);
      const original = button.textContent;
      button.textContent = "Copied!";
      setTimeout(() => {
        button.textContent = original;
      }, 1500);
    } catch (err) {
      // clipboard API unavailable — the link is already shown on screen to copy by hand
    }
  }

  async function rotateCalendarLink(button) {
    const ok = await confirmDialog("Get a new calendar link? The old one will stop working.");
    if (!ok) return;
    button.disabled = true;
    try {
      const result = await api("/webapp/api/calendar/rotate", { method: "POST" });
      settingsData = {
        ...settingsData,
        calendar_url: result.calendar_url,
        webcal_url: result.webcal_url,
      };
      render();
    } catch (err) {
      showSettingsError("settings-reminders-error", err.detail || "Couldn't rotate the link.");
    } finally {
      button.disabled = false;
    }
  }

  els.bottomNav.addEventListener("click", (event) => {
    const btn = event.target.closest(".nav-btn");
    if (btn) selectView(btn.dataset.view);
  });

  els.profileButton.addEventListener("click", () => selectView("settings"));

  els.refresh.addEventListener("click", () => {
    load();
    if (view === "events") loadEvents();
    if (view === "calendar") loadCalendarMonth(calendarMonth || currentMonthKey(summaryData));
    if (view === "settings") loadSettings();
  });

  function openSearch() {
    els.searchBackdrop.classList.remove("hidden");
    els.searchInput.value = "";
    els.searchResults.innerHTML = '<p class="hint">Type to search event or location…</p>';
    setTimeout(() => els.searchInput.focus(), 100);
  }

  function closeSearch() {
    els.searchBackdrop.classList.add("hidden");
    if (searchDebounce) {
      clearTimeout(searchDebounce);
      searchDebounce = null;
    }
  }

  async function runSearch(keyword) {
    if (!keyword.trim()) {
      els.searchResults.innerHTML = '<p class="hint">Type to search event or location…</p>';
      return;
    }
    try {
      const data = await api(`/webapp/api/search?q=${encodeURIComponent(keyword.trim())}`);
      if (!data.shifts.length) {
        els.searchResults.innerHTML = '<p class="hint">No shifts found.</p>';
        return;
      }
      els.searchResults.innerHTML = data.shifts
        .map((s) => shiftRow(s, s.currency))
        .join("");
    } catch (err) {
      els.searchResults.innerHTML = '<p class="hint">Couldn\u2019t search — try again.</p>';
    }
  }

  els.searchOpen.addEventListener("click", openSearch);
  els.searchClose.addEventListener("click", closeSearch);
  els.searchBackdrop.addEventListener("click", (event) => {
    if (event.target === els.searchBackdrop) closeSearch();
  });
  els.searchInput.addEventListener("input", (event) => {
    if (searchDebounce) clearTimeout(searchDebounce);
    const value = event.target.value;
    searchDebounce = setTimeout(() => runSearch(value), 250);
  });
  els.searchResults.addEventListener("click", (event) => {
    const row = event.target.closest("[data-id]");
    if (!row) return;
    closeSearch();
    openEditor(shiftsById.get(Number(row.dataset.id)));
  });

  els.contentWrap.addEventListener("change", (event) => {
    if (event.target.id === "avatar-file-input") handleAvatarFileSelected(event);
  });

  els.contentWrap.addEventListener("click", (event) => {
    const actionBtn = event.target.closest("[data-action]");
    if (actionBtn) {
      const actions = {
        "save-profile": saveProfile,
        "save-pay": savePay,
        "save-reminders": saveReminders,
        "copy-calendar": copyCalendarLink,
        "rotate-calendar": rotateCalendarLink,
        "add-to-calendar": openCalendarSubscription,
        "export-calendar": openCalendarSubscription,
        "export-csv": exportCsv,
        "choose-avatar": chooseAvatar,
        "remove-avatar": removeAvatar,
      };
      const handler = actions[actionBtn.dataset.action];
      if (handler) handler(actionBtn);
      return;
    }
    const markEventPaidBtn = event.target.closest("[data-mark-event-paid]");
    if (markEventPaidBtn) {
      markEventPaid(decodeURIComponent(markEventPaidBtn.dataset.markEventPaid));
      return;
    }
    const scopeBtn = event.target.closest("[data-scope]");
    if (scopeBtn) {
      selectScope(scopeBtn.dataset.scope);
      return;
    }
    const groupByBtn = event.target.closest("[data-groupby]");
    if (groupByBtn) {
      selectAllTimeGroupBy(groupByBtn.dataset.groupby);
      return;
    }
    const eventSortBtn = event.target.closest("[data-event-sort]");
    if (eventSortBtn) {
      selectEventSort(eventSortBtn.dataset.eventSort);
      return;
    }
    const dateOrderBtn = event.target.closest("[data-date-order]");
    if (dateOrderBtn) {
      selectDateOrder(dateOrderBtn.dataset.dateOrder);
      return;
    }
    const upcomingRangeBtn = event.target.closest("[data-upcoming-range]");
    if (upcomingRangeBtn) {
      selectUpcomingRange(upcomingRangeBtn.dataset.upcomingRange);
      return;
    }
    const monthNavBtn = event.target.closest("[data-month-nav]");
    if (monthNavBtn) {
      const direction = monthNavBtn.dataset.monthNav === "next" ? 1 : -1;
      if (monthDetail) {
        navigateMonthDetail(direction);
      } else if (scope === "week") {
        navigateOverviewWeek(direction);
      } else if (scope === "today") {
        navigateOverviewDay(direction);
      } else {
        navigateOverviewMonth(direction);
      }
      return;
    }
    const calendarNavBtn = event.target.closest("[data-calendar-nav]");
    if (calendarNavBtn) {
      navigateCalendarMonth(calendarNavBtn.dataset.calendarNav === "next" ? 1 : -1);
      return;
    }
    const calendarDay = event.target.closest("[data-calendar-day]");
    if (calendarDay) {
      calendarSelectedDay = calendarDay.dataset.calendarDay;
      render();
      return;
    }
    const dashboardStat = event.target.closest("[data-dashboard-stat]");
    if (dashboardStat) {
      setDashboardDetail(dashboardStat.dataset.dashboardStat);
      return;
    }
    const backToOverviewRow = event.target.closest("#back-to-overview");
    if (backToOverviewRow) {
      setDashboardDetail(null);
      return;
    }
    const backRow = event.target.closest("#back-to-months");
    if (backRow) {
      setMonthDetail(null);
      return;
    }
    const backToEventsRow = event.target.closest("#back-to-events");
    if (backToEventsRow) {
      setEventDetail(null);
      return;
    }
    const backToSettingsRow = event.target.closest("#back-to-settings");
    if (backToSettingsRow) {
      setSettingsSection(null);
      return;
    }
    const settingsSectionEl = event.target.closest("[data-settings-section]");
    if (settingsSectionEl) {
      setSettingsSection(settingsSectionEl.dataset.settingsSection);
      return;
    }
    const monthRow = event.target.closest("[data-month]");
    if (monthRow) {
      openMonth(monthRow.dataset.month);
      return;
    }
    const eventRow = event.target.closest("[data-event]");
    if (eventRow) {
      openEvent(decodeURIComponent(eventRow.dataset.event));
      return;
    }
    const shiftRowEl = event.target.closest("[data-id]");
    if (shiftRowEl) {
      openEditor(shiftsById.get(Number(shiftRowEl.dataset.id)));
    }
  });

  els.editCancel.addEventListener("click", closeEditor);
  els.editDuplicate.addEventListener("click", duplicateEditingShift);
  els.editDelete.addEventListener("click", deleteEditingShift);
  els.editBackdrop.addEventListener("click", (event) => {
    if (event.target === els.editBackdrop) closeEditor();
  });
  els.editForm.addEventListener("submit", submitEditor);
  els.editForm.event.addEventListener("input", syncEventBadge);
  els.editForm.rate.addEventListener("input", syncRateWidth);
  els.editBreakPaid.addEventListener("click", (event) => {
    const button = event.target.closest("[data-break-paid]");
    if (button) setBreakPaid(button.dataset.breakPaid);
  });
  els.editForm.addEventListener("focusin", (event) => {
    activeEditField = event.target;
    // Run once immediately (helps on Android, where the viewport often resizes right away)
    // and again after the iOS keyboard has finished animating in.
    adjustForKeyboard();
    setTimeout(adjustForKeyboard, 320);
  });
  els.editForm.addEventListener("focusout", (event) => {
    // Defer clearing so a click that moves focus to another field in the same form doesn't
    // momentarily reset the sheet's padding before the new field's focusin fires.
    setTimeout(() => {
      if (!els.editForm.contains(document.activeElement)) {
        activeEditField = null;
        els.editSheet.style.paddingBottom = "";
      }
    }, 0);
  });
  [els.editForm.day, els.editForm.start, els.editForm.end, els.editForm.payment_due].forEach(
    (input) => {
      input.addEventListener("input", () => syncFieldDisplay(input));
      input.addEventListener("change", () => syncFieldDisplay(input));
    }
  );
  els.editForm.paid.addEventListener("change", syncPaymentBadge);
  els.editForm.payment_due.addEventListener("input", () => {
    paymentDueTouched = true;
  });

  if (tg && tg.BackButton) {
    tg.BackButton.onClick(() => {
      if (eventDetail) setEventDetail(null);
      else if (monthDetail) setMonthDetail(null);
      else if (dashboardDetail) setDashboardDetail(null);
      else if (settingsSection) setSettingsSection(null);
    });
  }

  initTelegram();
  initViewport();
  load();
  loadSettings();
})();
