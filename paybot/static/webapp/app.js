(() => {
  "use strict";

  const tg = window.Telegram ? window.Telegram.WebApp : null;
  const els = {
    avatar: document.getElementById("avatar"),
    greeting: document.getElementById("greeting"),
    asof: document.getElementById("asof"),
    refresh: document.getElementById("refresh"),
    bottomNav: document.getElementById("bottom-nav"),
    loading: document.getElementById("loading"),
    error: document.getElementById("error"),
    errorText: document.getElementById("error-text"),
    content: document.getElementById("content"),
    editBackdrop: document.getElementById("edit-backdrop"),
    editSheet: document.getElementById("edit-sheet"),
    editForm: document.getElementById("edit-form"),
    editTitle: document.getElementById("edit-title"),
    editError: document.getElementById("edit-error"),
    editSave: document.getElementById("edit-save"),
    editCancel: document.getElementById("edit-cancel"),
    fabAdd: document.getElementById("fab-add"),
  };

  const SCOPES = {
    today: { label: "Today", icon: "☀️" },
    week: { label: "Week", icon: "📆" },
    month: { label: "Month", icon: "🗓️" },
    all: { label: "All time", icon: "💰" },
  };

  let summaryData = null;
  let view = "overview"; // overview | upcoming | months | events | settings
  let scope = "today"; // which quick action is selected within overview
  let monthDetail = null; // set when drilled into a month from the "Months" view
  let eventsData = null; // fetched lazily the first time the Events tab is opened
  let eventDetail = null; // set when drilled into one event from the "Events" view
  let settingsData = null; // fetched lazily the first time the Settings tab is opened
  let telegramFirstName = ""; // fallback greeting name when no display name is set
  const shiftsById = new Map(); // repopulated on every render, keyed by shift id
  let editingShiftId = null;
  let editorMode = null; // "edit" | "create"
  let overviewMonth = null; // "YYYY-MM" shown by the Month quick action; null = the live current month
  let overviewMonthData = null; // fetched /month/{key} detail when overviewMonth isn't the live month
  let overviewWeekStart = null; // Monday (YYYY-MM-DD) shown by the Week quick action; null = the live week
  let overviewWeekData = null; // fetched /week/{start} detail when overviewWeekStart isn't the live week

  function initTelegram() {
    if (!tg) return;
    tg.ready();
    tg.expand();
    const user = tg.initDataUnsafe && tg.initDataUnsafe.user;
    if (user && user.first_name) {
      telegramFirstName = user.first_name;
      updateGreeting();
    }
  }

  function updateGreeting() {
    const name = (settingsData && settingsData.display_name) || telegramFirstName;
    if (!name) return;
    els.greeting.textContent = `Hi ${name} 👋`;
    els.avatar.textContent = name.trim()[0].toUpperCase();
  }

  // Keep the modal pinned above the on-screen keyboard instead of letting it cover the buttons.
  function syncAppHeight() {
    const height = window.visualViewport ? window.visualViewport.height : window.innerHeight;
    document.documentElement.style.setProperty("--app-height", `${height}px`);
  }

  function initViewport() {
    syncAppHeight();
    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", syncAppHeight);
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

  function shiftWhere(shift) {
    return shift.location ? `${shift.event} @ ${shift.location}` : shift.event;
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

  function isoDateUTC(d) {
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(
      d.getUTCDate()
    ).padStart(2, "0")}`;
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
    const tagText = { running: "in progress", upcoming: "to come" }[state] || "";
    const displayPay = options.earnedPay !== undefined ? options.earnedPay : shift.pay;
    const clash = shift.clash ? '<span class="clash-badge">⚠ clash</span>' : "";
    return `
      <div class="row editable state-${state}" data-id="${shift.id}">
        ${eventBadge(shift.event)}
        <div class="info">
          <div class="title">${escapeHtml(shiftWhere(shift))}${clash}</div>
          <div class="sub">${shift.date_label} \u00b7 ${shift.start}\u2013${shift.end} \u00b7 ${hours(shift.hours)}</div>
        </div>
        <div class="value">
          ${money(displayPay, currency)}
          ${tagText ? `<span class="tag">${tagText}</span>` : ""}
        </div>
      </div>`;
  }

  function heroBlock(block, currency) {
    const projected =
      Number(block.to_come) > 0
        ? `<div class="projected">+ ${money(block.to_come, currency)} to come \u2192 ${money(
            block.projected,
            currency
          )} projected</div>`
        : "";
    return `
      <div class="hero">
        <div class="label">${escapeHtml(block.label)}</div>
        <div class="amount">${money(block.earned, currency)}</div>
        <div class="meta">${hours(block.hours)} \u00b7 ${block.finished} shift${
      block.finished === 1 ? "" : "s"
    }</div>
        ${projected}
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

  function overviewView(data) {
    if (scope === "month") return monthScopeView(data);
    if (scope === "week") return weekScopeView(data);
    const bar = quickActionsBar();
    if (scope === "all") {
      const hero = heroBlock(data.all_time, data.currency);
      const body = data.months.length
        ? `<div class="card-list">${monthListRows(data.months)}</div>`
        : `<div class="empty">Nothing logged yet.</div>`;
      return bar + hero + `<div class="section-title">Every month</div>` + body;
    }
    const block = data[scope];
    if (!block.shifts.length) {
      return bar + heroBlock(block, data.currency) + `<div class="empty">Nothing logged yet.</div>`;
    }
    const rows = block.shifts
      .map((s) =>
        shiftRow(s, data.currency, {
          state: s.state,
          earnedPay: s.state === "upcoming" ? s.pay : s.earned_pay,
        })
      )
      .join("");
    return bar + heroBlock(block, data.currency) + `<div class="card-list">${rows}</div>`;
  }

  function monthScopeView(data) {
    const bar = quickActionsBar();
    const liveKey = currentMonthKey(data);
    const activeKey = overviewMonth || liveKey;
    const nav = monthNavBar(monthKeyLabel(activeKey));

    if (activeKey === liveKey) {
      const block = data.month;
      const rows = block.shifts.length
        ? block.shifts
            .map((s) =>
              shiftRow(s, data.currency, {
                state: s.state,
                earnedPay: s.state === "upcoming" ? s.pay : s.earned_pay,
              })
            )
            .join("")
        : "";
      const body = block.shifts.length
        ? `<div class="card-list">${rows}</div>`
        : `<div class="empty">Nothing logged yet.</div>`;
      const projected =
        Number(block.to_come) > 0
          ? `<div class="projected">+ ${money(block.to_come, data.currency)} to come \u2192 ${money(
              block.projected,
              data.currency
            )} projected</div>`
          : "";
      return (
        bar +
        nav +
        `<div class="hero">
          <div class="amount">${money(block.earned, data.currency)}</div>
          <div class="meta">${hours(block.hours)} \u00b7 ${block.finished} shift${
          block.finished === 1 ? "" : "s"
        }</div>
          ${projected}
        </div>` +
        body
      );
    }

    if (!overviewMonthData || overviewMonthData.month !== activeKey) {
      return bar + nav + `<div class="empty">Loading…</div>`;
    }
    return bar + nav + plainPeriodBody(overviewMonthData);
  }

  function weekScopeView(data) {
    const bar = quickActionsBar();
    const liveStart = currentWeekStart(data);
    const activeStart = overviewWeekStart || liveStart;
    const nav = monthNavBar(weekLabel(activeStart), "week");

    if (activeStart === liveStart) {
      const block = data.week;
      const rows = block.shifts.length
        ? block.shifts
            .map((s) =>
              shiftRow(s, data.currency, {
                state: s.state,
                earnedPay: s.state === "upcoming" ? s.pay : s.earned_pay,
              })
            )
            .join("")
        : "";
      const body = block.shifts.length
        ? `<div class="card-list">${rows}</div>`
        : `<div class="empty">Nothing logged yet.</div>`;
      const projected =
        Number(block.to_come) > 0
          ? `<div class="projected">+ ${money(block.to_come, data.currency)} to come \u2192 ${money(
              block.projected,
              data.currency
            )} projected</div>`
          : "";
      return (
        bar +
        nav +
        `<div class="hero">
          <div class="amount">${money(block.earned, data.currency)}</div>
          <div class="meta">${hours(block.hours)} \u00b7 ${block.finished} shift${
          block.finished === 1 ? "" : "s"
        }</div>
          ${projected}
        </div>` +
        body
      );
    }

    if (!overviewWeekData || overviewWeekData.start !== activeStart) {
      return bar + nav + `<div class="empty">Loading…</div>`;
    }
    return bar + nav + plainPeriodBody(overviewWeekData);
  }

  function plainPeriodBody(detail) {
    const rows = detail.shifts.length
      ? detail.shifts.map((s) => shiftRow(s, detail.currency, { state: s.state })).join("")
      : "";
    const body = detail.shifts.length
      ? `<div class="card-list">${rows}</div>`
      : `<div class="empty">Nothing logged for ${escapeHtml(detail.label)}.</div>`;
    return (
      `<div class="hero">
        <div class="amount">${money(detail.pay, detail.currency)}</div>
        <div class="meta">${hours(detail.hours)} \u00b7 ${detail.shifts.length} shift${
        detail.shifts.length === 1 ? "" : "s"
      }</div>
      </div>` + body
    );
  }

  function upcomingView(data) {
    if (!data.upcoming.length) {
      return `<div class="empty">Nothing booked in the next 14 days.</div>`;
    }
    const rows = data.upcoming
      .map((s) => shiftRow(s, data.currency, { state: s.state }))
      .join("");
    return `<div class="section-title">Next 14 days</div><div class="card-list">${rows}</div>`;
  }

  function monthListRows(months) {
    return months
      .map(
        (m) => `
      <div class="row" data-month="${m.month}">
        <div class="icon">📆</div>
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

  function monthsView(data) {
    if (!data.months.length) {
      return `<div class="empty">No shifts logged yet.</div>`;
    }
    const allTime = heroBlock(data.all_time, data.currency);
    const rows = monthListRows(data.months);
    return allTime + `<div class="section-title">By month</div><div class="card-list">${rows}</div>`;
  }

  function monthDetailView(detail) {
    return `
      <div class="back-row" id="back-to-months">\u2039 Months</div>
      ${monthNavBar(detail.label)}
      ${plainPeriodBody(detail)}`;
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
      return `<div class="empty">Loading…</div>`;
    }
    if (!data.events.length) {
      return `<div class="empty">No shifts logged yet.</div>`;
    }
    const rows = eventListRows(data.events);
    return `<div class="section-title">By event</div><div class="card-list">${rows}</div>`;
  }

  function eventDetailView(detail) {
    return `
      <div class="back-row" id="back-to-events">\u2039 Events</div>
      ${plainPeriodBody(detail)}`;
  }

  function settingsView(data) {
    if (!data) {
      return `<div class="empty">Loading…</div>`;
    }
    return `
      <div class="section-title">Profile</div>
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

      <div class="section-title">Calendar</div>
      <div class="card-list settings-card">
        <div class="settings-row">
          <label>Subscription link</label>
          <div class="calendar-link" id="settings-calendar-link">${
            data.calendar_url
              ? escapeHtml(data.calendar_url)
              : "Not available on this deployment"
          }</div>
        </div>
      </div>
      ${
        data.calendar_url
          ? `<div class="settings-actions">
              <button type="button" class="btn secondary" data-action="copy-calendar">Copy link</button>
              <button type="button" class="btn secondary" data-action="rotate-calendar">New link</button>
            </div>`
          : ""
      }
      <p class="section-hint">
        Subscribe once in Google/Apple Calendar or TimeTree and every shift you log stays in
        sync automatically.
      </p>
    `;
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

    if (monthDetail) {
      els.content.innerHTML = monthDetailView(monthDetail);
      return;
    }
    if (eventDetail) {
      els.content.innerHTML = eventDetailView(eventDetail);
      return;
    }

    if (view === "overview") {
      els.content.innerHTML = overviewView(summaryData);
    } else if (view === "upcoming") {
      els.content.innerHTML = upcomingView(summaryData);
    } else if (view === "events") {
      els.content.innerHTML = eventsView(eventsData);
    } else if (view === "settings") {
      els.content.innerHTML = settingsView(settingsData);
    } else {
      els.content.innerHTML = monthsView(summaryData);
    }
  }

  async function loadEvents() {
    try {
      eventsData = await api("/webapp/api/events");
      render();
    } catch (err) {
      showError(err);
    }
  }

  async function loadSettings() {
    try {
      settingsData = await api("/webapp/api/settings");
      updateGreeting();
      render();
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

  function setMonthDetail(value) {
    monthDetail = value;
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
    render();
  }

  function selectView(next) {
    view = next;
    monthDetail = null;
    eventDetail = null;
    overviewMonth = null;
    overviewMonthData = null;
    overviewWeekStart = null;
    overviewWeekData = null;
    if (tg && tg.BackButton) tg.BackButton.hide();
    [...els.bottomNav.querySelectorAll(".nav-btn")].forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.view === next);
    });
    if (next === "events" && !eventsData) {
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
    els.content.classList.add("hidden");
    els.error.classList.remove("hidden");
    if (err && err.message === "no-init-data") {
      els.errorText.textContent = "Open this from the Pay tracker bot in Telegram.";
    } else {
      els.errorText.textContent = "Couldn't load your shifts — tap ⟳ to try again.";
    }
  }

  async function load() {
    els.loading.classList.remove("hidden");
    els.error.classList.add("hidden");
    els.content.classList.add("hidden");
    try {
      summaryData = await api("/webapp/api/summary");
      els.loading.classList.add("hidden");
      els.content.classList.remove("hidden");
      render();
    } catch (err) {
      showError(err);
    }
  }

  function openEditor(shift) {
    if (!shift) return;
    editorMode = "edit";
    editingShiftId = shift.id;
    els.editTitle.textContent = "Edit shift";
    els.editSave.textContent = "Save";
    els.editForm.event.value = shift.event;
    els.editForm.location.value = shift.location || "";
    els.editForm.day.value = shift.day;
    els.editForm.start.value = shift.start;
    els.editForm.end.value = shift.end;
    els.editForm.rate.value = shift.rate;
    els.editForm.break_hours.value = shift.break_hours;
    els.editForm.break_paid.checked = shift.break_paid;
    els.editError.classList.add("hidden");
    els.editSheet.scrollTop = 0;
    els.editBackdrop.classList.remove("hidden");
  }

  function openCreator() {
    editorMode = "create";
    editingShiftId = null;
    els.editForm.reset();
    els.editTitle.textContent = "Add shift";
    els.editSave.textContent = "Add shift";
    const today = ((summaryData && summaryData.now) || new Date().toISOString()).slice(0, 10);
    els.editForm.day.value = today;
    els.editForm.start.value = "09:00";
    els.editForm.end.value = "17:00";
    els.editError.classList.add("hidden");
    els.editSheet.scrollTop = 0;
    els.editBackdrop.classList.remove("hidden");
  }

  function closeEditor() {
    els.editBackdrop.classList.add("hidden");
    editingShiftId = null;
    editorMode = null;
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
      payload.break_paid = form.break_paid.checked;
    }
    await api("/webapp/api/shifts", { method: "POST", body: payload });
  }

  async function submitUpdate() {
    const shift = shiftsById.get(editingShiftId);
    if (!shift) return;
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
    if (form.break_paid.checked !== shift.break_paid) payload.break_paid = form.break_paid.checked;
    if (!Object.keys(payload).length) return;
    await api(`/webapp/api/shifts/${shift.id}`, { method: "PATCH", body: payload });
  }

  async function submitEditor(event) {
    event.preventDefault();
    els.editSave.disabled = true;
    els.editError.classList.add("hidden");
    try {
      if (editorMode === "create") {
        await submitCreate();
      } else {
        await submitUpdate();
      }
      closeEditor();
      await refreshAfterEdit();
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

  async function saveProfile(button) {
    hideSettingsError("settings-profile-error");
    const value = document.getElementById("settings-display-name").value.trim();
    button.disabled = true;
    try {
      settingsData = await api("/webapp/api/settings", {
        method: "PATCH",
        body: { display_name: value },
      });
      updateGreeting();
    } catch (err) {
      showSettingsError("settings-profile-error", err.detail || "Couldn't save — try again.");
    } finally {
      button.disabled = false;
    }
  }

  async function savePay(button) {
    hideSettingsError("settings-pay-error");
    const rate = document.getElementById("settings-rate").value;
    const currency = document.getElementById("settings-currency").value;
    button.disabled = true;
    try {
      settingsData = await api("/webapp/api/settings", {
        method: "PATCH",
        body: { default_rate: rate, currency },
      });
      render();
    } catch (err) {
      showSettingsError("settings-pay-error", err.detail || "Couldn't save — check the rate.");
    } finally {
      button.disabled = false;
    }
  }

  async function saveReminders(button) {
    hideSettingsError("settings-reminders-error");
    const enabled = document.getElementById("settings-reminders-enabled").checked;
    const sendAt = document.getElementById("settings-reminders-time").value;
    const offset = document.getElementById("settings-reminders-offset").value;
    button.disabled = true;
    try {
      settingsData = await api("/webapp/api/reminders", {
        method: "PATCH",
        body: { enabled, send_at: sendAt, utc_offset: offset },
      });
      render();
    } catch (err) {
      showSettingsError(
        "settings-reminders-error",
        err.detail || "Couldn't save — check the time and timezone."
      );
    } finally {
      button.disabled = false;
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
      settingsData = { ...settingsData, calendar_url: result.calendar_url };
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

  els.refresh.addEventListener("click", () => {
    load();
    if (view === "events") loadEvents();
    if (view === "settings") loadSettings();
  });
  els.fabAdd.addEventListener("click", () => openCreator());

  els.content.addEventListener("click", (event) => {
    const actionBtn = event.target.closest("[data-action]");
    if (actionBtn) {
      const actions = {
        "save-profile": saveProfile,
        "save-pay": savePay,
        "save-reminders": saveReminders,
        "copy-calendar": copyCalendarLink,
        "rotate-calendar": rotateCalendarLink,
      };
      const handler = actions[actionBtn.dataset.action];
      if (handler) handler(actionBtn);
      return;
    }
    const scopeBtn = event.target.closest("[data-scope]");
    if (scopeBtn) {
      selectScope(scopeBtn.dataset.scope);
      return;
    }
    const monthNavBtn = event.target.closest("[data-month-nav]");
    if (monthNavBtn) {
      const direction = monthNavBtn.dataset.monthNav === "next" ? 1 : -1;
      if (monthDetail) {
        navigateMonthDetail(direction);
      } else if (scope === "week") {
        navigateOverviewWeek(direction);
      } else {
        navigateOverviewMonth(direction);
      }
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
  els.editBackdrop.addEventListener("click", (event) => {
    if (event.target === els.editBackdrop) closeEditor();
  });
  els.editForm.addEventListener("submit", submitEditor);
  els.editForm.addEventListener("focusin", (event) => {
    // give the keyboard time to animate in before scrolling the field into view
    setTimeout(() => event.target.scrollIntoView({ block: "center", behavior: "smooth" }), 300);
  });

  if (tg && tg.BackButton) {
    tg.BackButton.onClick(() => {
      if (eventDetail) setEventDetail(null);
      else setMonthDetail(null);
    });
  }

  initTelegram();
  initViewport();
  load();
  loadSettings();
})();
