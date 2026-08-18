(() => {
  "use strict";

  const tg = window.Telegram ? window.Telegram.WebApp : null;
  const els = {
    greeting: document.getElementById("greeting"),
    asof: document.getElementById("asof"),
    tabs: document.getElementById("tabs"),
    loading: document.getElementById("loading"),
    error: document.getElementById("error"),
    errorText: document.getElementById("error-text"),
    content: document.getElementById("content"),
  };

  let summaryData = null;
  let activeTab = "today";
  let monthDetail = null; // set when drilled into a month from the "By month" tab

  function initTelegram() {
    if (!tg) return;
    tg.ready();
    tg.expand();
    const name = tg.initDataUnsafe && tg.initDataUnsafe.user && tg.initDataUnsafe.user.first_name;
    if (name) els.greeting.textContent = `Hi ${name} 👋`;
  }

  function authHeader() {
    const initData = tg && tg.initData;
    if (!initData) return null;
    return { Authorization: `tma ${initData}` };
  }

  async function api(path) {
    const headers = authHeader();
    if (!headers) throw new Error("no-init-data");
    const response = await fetch(path, { headers });
    if (!response.ok) throw new Error(`http-${response.status}`);
    return response.json();
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

  function shiftRow(shift, currency, options = {}) {
    const state = options.state || "done";
    const tagText = { running: "in progress", upcoming: "to come" }[state] || "";
    const displayPay = options.earnedPay !== undefined ? options.earnedPay : shift.pay;
    const clash = shift.clash
      ? '<span class="clash-badge">⚠ clash</span>'
      : "";
    return `
      <div class="shift state-${state}">
        <div class="date">
          <div class="weekday">${shift.weekday}</div>
          <div class="day">${shift.date_label.split(" ")[0]}</div>
        </div>
        <div class="info">
          <div class="title">#${shift.id} ${escapeHtml(shiftWhere(shift))}${clash}</div>
          <div class="sub">${shift.start}\u2013${shift.end} \u00b7 ${hours(shift.hours)} \u00b7 ${shift.date_label}</div>
        </div>
        <div class="amount">
          ${money(displayPay, currency)}
          ${tagText ? `<span class="tag">${tagText}</span>` : ""}
        </div>
      </div>`;
  }

  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
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

  function tallyView(block, currency) {
    if (!block.shifts.length) {
      return heroBlock(block, currency) + `<div class="empty">Nothing logged yet.</div>`;
    }
    const rows = block.shifts
      .map((s) =>
        shiftRow(s, currency, { state: s.state, earnedPay: s.state === "upcoming" ? s.pay : s.earned_pay })
      )
      .join("");
    return heroBlock(block, currency) + `<div class="card-list">${rows}</div>`;
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
      <div class="month-row" data-month="${m.month}">
        <div>
          <div class="label">${escapeHtml(m.label)}</div>
          <div class="count">${m.shifts} shift${m.shifts === 1 ? "" : "s"} \u00b7 ${hours(m.hours)}</div>
        </div>
        <div style="display:flex;align-items:center;">
          <div class="pay">${money(m.pay, m.currency)}</div>
          <div class="chevron">\u203a</div>
        </div>
      </div>`
      )
      .join("");
    return allTime + `<div class="card-list">${rows}</div>`;
  }

  function monthDetailView(detail) {
    const rows = detail.shifts.length
      ? detail.shifts.map((s) => shiftRow(s, detail.currency)).join("")
      : `<div class="empty">Nothing logged for ${escapeHtml(detail.label)}.</div>`;
    return `
      <div class="back-row" id="back-to-months">\u2039 By month</div>
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
      const back = document.getElementById("back-to-months");
      if (back) back.addEventListener("click", () => setMonthDetail(null));
      return;
    }

    const currency = summaryData.currency;
    switch (activeTab) {
      case "today":
        els.content.innerHTML = tallyView(summaryData.today, currency);
        break;
      case "week":
        els.content.innerHTML = tallyView(summaryData.week, currency);
        break;
      case "month":
        els.content.innerHTML = tallyView(summaryData.month, currency);
        break;
      case "upcoming":
        els.content.innerHTML = upcomingView(summaryData);
        break;
      case "months":
        els.content.innerHTML = monthsView(summaryData);
        summaryData.months.forEach((m) => {
          const row = els.content.querySelector(`[data-month="${m.month}"]`);
          if (row) row.addEventListener("click", () => openMonth(m.month));
        });
        break;
    }
  }

  async function openMonth(month) {
    if (tg && tg.BackButton) {
      tg.BackButton.show();
    }
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

  function selectTab(tab) {
    activeTab = tab;
    monthDetail = null;
    if (tg && tg.BackButton) tg.BackButton.hide();
    [...els.tabs.querySelectorAll(".tab")].forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.tab === tab);
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
      els.errorText.textContent = "Couldn't load your shifts — pull down to try again.";
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

  els.tabs.addEventListener("click", (event) => {
    const btn = event.target.closest(".tab");
    if (btn) selectTab(btn.dataset.tab);
  });

  if (tg && tg.BackButton) {
    tg.BackButton.onClick(() => setMonthDetail(null));
  }

  initTelegram();
  load();
})();
