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
    editForm: document.getElementById("edit-form"),
    editError: document.getElementById("edit-error"),
    editSave: document.getElementById("edit-save"),
    editCancel: document.getElementById("edit-cancel"),
  };

  const SCOPES = {
    today: { label: "Today", icon: "☀️" },
    week: { label: "Week", icon: "📆" },
    month: { label: "Month", icon: "🗓️" },
    all: { label: "All time", icon: "💰" },
  };

  let summaryData = null;
  let view = "overview"; // overview | upcoming | months
  let scope = "today"; // which quick action is selected within overview
  let monthDetail = null; // set when drilled into a month from the "Months" view
  const shiftsById = new Map(); // repopulated on every render, keyed by shift id
  let editingShiftId = null;

  function initTelegram() {
    if (!tg) return;
    tg.ready();
    tg.expand();
    const user = tg.initDataUnsafe && tg.initDataUnsafe.user;
    if (user && user.first_name) {
      els.greeting.textContent = `Hi ${user.first_name} 👋`;
      els.avatar.textContent = user.first_name.trim()[0].toUpperCase();
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

  const STATE_ICON = { done: "✓", running: "⏳", upcoming: "📅" };

  function shiftRow(shift, currency, options = {}) {
    shiftsById.set(shift.id, shift);
    const state = options.state || "done";
    const tagText = { running: "in progress", upcoming: "to come" }[state] || "";
    const displayPay = options.earnedPay !== undefined ? options.earnedPay : shift.pay;
    const clash = shift.clash ? '<span class="clash-badge">⚠ clash</span>' : "";
    return `
      <div class="row editable state-${state}" data-id="${shift.id}">
        <div class="icon">${STATE_ICON[state]}</div>
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
    const bar = quickActionsBar();
    if (scope === "all") {
      const hero = `
        <div class="hero">
          <div class="label">All time</div>
          <div class="amount">${money(data.all_time.earned, data.currency)}</div>
          <div class="meta">${hours(data.all_time.hours)} \u00b7 ${data.all_time.shifts} shift${
        data.all_time.shifts === 1 ? "" : "s"
      }</div>
        </div>`;
      const month = data.month;
      const rows = month.shifts.length
        ? month.shifts
            .map((s) =>
              shiftRow(s, data.currency, {
                state: s.state,
                earnedPay: s.state === "upcoming" ? s.pay : s.earned_pay,
              })
            )
            .join("")
        : `<div class="empty">Nothing logged yet.</div>`;
      return (
        bar +
        hero +
        `<div class="section-title">This month</div><div class="card-list">${rows}</div>`
      );
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

  function upcomingView(data) {
    if (!data.upcoming.length) {
      return `<div class="empty">Nothing booked in the next 14 days.</div>`;
    }
    const rows = data.upcoming.map((s) => shiftRow(s, data.currency)).join("");
    return `<div class="section-title">Next 14 days</div><div class="card-list">${rows}</div>`;
  }

  function monthsView(data) {
    if (!data.months.length) {
      return `<div class="empty">No shifts logged yet.</div>`;
    }
    const allTime = `
      <div class="hero">
        <div class="label">All time</div>
        <div class="amount">${money(data.all_time.earned, data.currency)}</div>
        <div class="meta">${hours(data.all_time.hours)} \u00b7 ${data.all_time.shifts} shifts</div>
      </div>`;
    const rows = data.months
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
    return allTime + `<div class="section-title">By month</div><div class="card-list">${rows}</div>`;
  }

  function monthDetailView(detail) {
    const rows = detail.shifts.length
      ? detail.shifts.map((s) => shiftRow(s, detail.currency)).join("")
      : `<div class="empty">Nothing logged for ${escapeHtml(detail.label)}.</div>`;
    return `
      <div class="back-row" id="back-to-months">\u2039 Months</div>
      <div class="hero">
        <div class="label">${escapeHtml(detail.label)}</div>
        <div class="amount">${money(detail.pay, detail.currency)}</div>
        <div class="meta">${hours(detail.hours)} \u00b7 ${detail.shifts.length} shifts</div>
      </div>
      <div class="card-list">${rows}</div>`;
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

    if (view === "overview") {
      els.content.innerHTML = overviewView(summaryData);
    } else if (view === "upcoming") {
      els.content.innerHTML = upcomingView(summaryData);
    } else {
      els.content.innerHTML = monthsView(summaryData);
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

  function setMonthDetail(value) {
    monthDetail = value;
    if (tg && tg.BackButton) {
      if (value) tg.BackButton.show();
      else tg.BackButton.hide();
    }
    render();
  }

  function selectScope(next) {
    scope = next;
    render();
  }

  function selectView(next) {
    view = next;
    monthDetail = null;
    if (tg && tg.BackButton) tg.BackButton.hide();
    [...els.bottomNav.querySelectorAll(".nav-btn")].forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.view === next);
    });
    render();
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
    editingShiftId = shift.id;
    els.editForm.event.value = shift.event;
    els.editForm.location.value = shift.location || "";
    els.editForm.day.value = shift.day;
    els.editForm.start.value = shift.start;
    els.editForm.end.value = shift.end;
    els.editForm.rate.value = shift.rate;
    els.editError.classList.add("hidden");
    els.editBackdrop.classList.remove("hidden");
  }

  function closeEditor() {
    els.editBackdrop.classList.add("hidden");
    editingShiftId = null;
  }

  async function refreshAfterEdit() {
    if (monthDetail) {
      try {
        monthDetail = await api(`/webapp/api/month/${monthDetail.month}`);
      } catch (err) {
        monthDetail = null;
      }
    }
    await load();
  }

  async function submitEditor(event) {
    event.preventDefault();
    const shift = shiftsById.get(editingShiftId);
    if (!shift) {
      closeEditor();
      return;
    }
    const form = els.editForm;
    const payload = {};
    if (form.event.value.trim() !== shift.event) payload.event = form.event.value.trim();
    if (form.location.value.trim() !== (shift.location || ""))
      payload.location = form.location.value.trim();
    if (form.day.value !== shift.day) payload.day = form.day.value;
    if (form.start.value !== shift.start) payload.start = form.start.value;
    if (form.end.value !== shift.end) payload.end = form.end.value;
    if (form.rate.value !== shift.rate) payload.rate = form.rate.value;
    if (!Object.keys(payload).length) {
      closeEditor();
      return;
    }
    els.editSave.disabled = true;
    els.editError.classList.add("hidden");
    try {
      await api(`/webapp/api/shifts/${shift.id}`, { method: "PATCH", body: payload });
      closeEditor();
      await refreshAfterEdit();
    } catch (err) {
      els.editError.textContent = err.detail || "Couldn't save — check the fields and try again.";
      els.editError.classList.remove("hidden");
    } finally {
      els.editSave.disabled = false;
    }
  }

  els.bottomNav.addEventListener("click", (event) => {
    const btn = event.target.closest(".nav-btn");
    if (btn) selectView(btn.dataset.view);
  });

  els.refresh.addEventListener("click", () => load());

  els.content.addEventListener("click", (event) => {
    const scopeBtn = event.target.closest("[data-scope]");
    if (scopeBtn) {
      selectScope(scopeBtn.dataset.scope);
      return;
    }
    const backRow = event.target.closest("#back-to-months");
    if (backRow) {
      setMonthDetail(null);
      return;
    }
    const monthRow = event.target.closest("[data-month]");
    if (monthRow) {
      openMonth(monthRow.dataset.month);
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

  if (tg && tg.BackButton) {
    tg.BackButton.onClick(() => setMonthDetail(null));
  }

  initTelegram();
  load();
})();
