/* Gateway Panel UI (#66) - a thin client of the contracted /v1 API.
   No build, no external requests. The dashboard deep-link is built at
   runtime from location.hostname + /health's dashboard_port (no URL
   literal lives in this tree). Badges are HONEST: confirmed/drift come
   from the API's applied/parity answer, never assumed after a write. */
"use strict";

const $ = (sel) => document.querySelector(sel);
let DICT = {};
let LANG = localStorage.getItem("panel_lang")
  || (navigator.language && navigator.language.toLowerCase().startsWith("zh")
      ? "zh" : "en");
// per-cidr apply state for this session: saved | applying | confirmed | drift
const applyState = new Map();
let PARITY = "unknown";

function t(key) { return DICT[key] || key; }

async function loadI18n() {
  const res = await fetch(`i18n/${LANG}.json`);
  DICT = await res.json();
  document.documentElement.lang = LANG === "zh" ? "zh-CN" : "en";
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll("[data-i18n-placeholder]").forEach((el) => {
    el.placeholder = t(el.dataset.i18nPlaceholder);
  });
}

function token() { return localStorage.getItem("panel_token") || ""; }

// Singleton: a second 403 while the dialog is open must share the SAME
// pending prompt - showModal() on an already-open dialog throws.
let tokenPromise = null;
function askToken() {
  if (tokenPromise) return tokenPromise;
  tokenPromise = new Promise((resolve) => {
    const dlg = $("#token-dialog");
    dlg.returnValue = "";
    dlg.showModal();
    dlg.addEventListener("close", function handler() {
      dlg.removeEventListener("close", handler);
      tokenPromise = null;
      if (dlg.returnValue === "save") {
        localStorage.setItem("panel_token", $("#token-input").value);
        $("#token-input").value = "";
        resolve(true);
      } else { resolve(false); }
    });
  });
  return tokenPromise;
}

/* IPv4 CIDR overlap for the pre-add band confirm (mirrors the server's
   canonical form; a non-IPv4 input just skips the client-side gate - the
   server validates for real). */
function cidrRange(cidr) {
  const [ip, lenRaw] = cidr.split("/");
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => Number.isNaN(n) || n > 255)) {
    return null;
  }
  const len = lenRaw === undefined ? 32 : Number(lenRaw);
  if (Number.isNaN(len) || len < 0 || len > 32) return null;
  const base = ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8)
                | parts[3]) >>> 0;
  const mask = len === 0 ? 0 : (0xFFFFFFFF << (32 - len)) >>> 0;
  const lo = (base & mask) >>> 0;
  return [lo, (lo | (~mask >>> 0)) >>> 0];
}

function inBand(address, band) {
  const range = cidrRange(address);
  if (!range) return false;
  return band.some((entry) => {
    const b = cidrRange(entry);
    return b && range[0] <= b[1] && b[0] <= range[1];
  });
}

async function api(method, path, body) {
  const headers = {};
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const mutating = method !== "GET";
  if (mutating && token()) headers["Authorization"] = `Bearer ${token()}`;
  // A DOWN backend rejects the promise rather than answering, so without
  // this catch the failure escapes every caller and the UI silently keeps
  // showing stale data. Status 0 means "never reached the panel" and is
  // falsy for every `status === 200` check already in this file.
  let res;
  try {
    res = await fetch(path, {
      method, headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch (e) {
    return { status: 0, data: null };
  }
  if (res.status === 403 && mutating) {
    const entered = await askToken();
    if (entered) return api(method, path, body);
  }
  let data = null;
  try { data = await res.json(); } catch (e) { data = null; }
  return { status: res.status, data };
}

/* ---- badges -------------------------------------------------------- */
function badgeFor(cidr) {
  const state = applyState.get(cidr)
    || (PARITY === "failed" ? "drift" : "saved");
  return state;
}

function noteApplyResult(cidr, body) {
  if (body && body.applied === true && body.parity === "ok") {
    applyState.set(cidr, "confirmed");
  } else {
    applyState.set(cidr, "drift");
  }
}

/* ---- devices ------------------------------------------------------- */
let BAND = [];

async function renderDevices() {
  const { status, data } = await api("GET", "/v1/devices");
  // Clear only once the answer is good: a failed refresh must not wipe a
  // correctly-rendered list and leave the user staring at nothing.
  if (status !== 200) return;
  const list = $("#device-list");
  list.textContent = "";
  BAND = data.band || [];
  $("#devices-empty").classList.toggle("hidden", data.devices.length !== 0);
  const tpl = $("#device-row-template");
  for (const dev of data.devices) {
    const row = tpl.content.cloneNode(true);
    const li = row.querySelector(".device-row");
    li.dataset.cidr = dev.cidr;
    li.dataset.testid = `device-${dev.cidr}`;
    row.querySelector(".device-name").textContent = dev.name || t("unnamed");
    row.querySelector(".device-cidr").textContent = dev.cidr;
    row.querySelector(".band-badge").classList.toggle(
      "hidden", !dev.band_member);
    const badge = row.querySelector(".state-badge");
    const state = badgeFor(dev.cidr);
    badge.textContent = t(`state_${state}`);
    badge.className = `badge state-badge ${state}`;
    row.querySelectorAll(".mode-btn").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.mode === dev.mode);
      btn.addEventListener("click", () => setMode(dev, btn.dataset.mode));
    });
    row.querySelector(".rename-btn").addEventListener(
      "click", () => renameDevice(dev));
    row.querySelector(".history-btn").addEventListener(
      "click", () => toggleHistory(li, dev));
    list.appendChild(row);
  }
}

async function renameDevice(dev) {
  const name = window.prompt(t("rename_prompt"), dev.name || "");
  if (name === null || name === dev.name) return;
  const result = await api("PATCH", `/v1/devices/${dev.id}`, { name });
  if (result.status !== 200 && result.status !== 403) {
    window.alert((result.data && result.data.detail) || t("error_generic"));
  }
  await renderDevices();
}

async function setMode(dev, mode) {
  if (mode === dev.mode) return;
  if (dev.band_member && !window.confirm(t("band_confirm"))) return;
  applyState.set(dev.cidr, "applying");
  await renderDevices();
  let result;
  if (mode === "default") {
    result = await api("DELETE", `/v1/devices/${dev.id}`);
  } else {
    result = await api("PATCH", `/v1/devices/${dev.id}`, { mode });
  }
  if (result.status === 200) {
    noteApplyResult(dev.cidr, result.data);
    if (mode === "default" && result.data && result.data.applied === false) {
      // the row is gone, so no per-row badge can carry this drift - say
      // it out loud (the parity banner stays up via refreshHealth too)
      window.alert(t("delete_drift_warn"));
    }
  } else if (result.status !== 403) {
    applyState.set(dev.cidr, "drift");
    window.alert((result.data && result.data.detail) || t("error_generic"));
  } else {
    applyState.delete(dev.cidr);
  }
  await refreshHealth();
  await renderDevices();
}

async function addDevice(evt) {
  evt.preventDefault();
  const address = $("#add-address").value.trim();
  const name = $("#add-name").value.trim();
  const mode = $("#add-mode").value;
  // DEC-4 covers ADDS too: a new override on a router-band address needs
  // the same explicit confirm as a flip on a listed band member. The
  // decision must rest on a FRESH server answer (a cached band goes stale
  // the moment the knob changes), and an unreadable band fails CLOSED -
  // ask rather than silently skip the gate.
  const check = await api("GET", "/v1/devices");
  if (check.status === 200) {
    BAND = check.data.band || [];
  } else if (!window.confirm(t("band_confirm_unknown"))) {
    return;
  }
  if (inBand(address, BAND) && !window.confirm(t("band_confirm"))) return;
  const result = await api("POST", "/v1/devices", { address, name, mode });
  if (result.status === 201) {
    noteApplyResult(result.data.device.cidr, result.data);
    $("#add-form").reset();
  } else if (result.status !== 403) {
    window.alert((result.data && result.data.detail) || t("error_generic"));
  }
  await refreshHealth();
  await renderDevices();
}

async function toggleHistory(li, dev) {
  const svg = li.querySelector(".device-sparkline");
  if (!svg.classList.contains("hidden")) {
    svg.classList.add("hidden");
    return;
  }
  const device = dev.cidr.split("/")[0];
  const { status, data } = await api(
    "GET", `/v1/stats/timeline?tier=minute&device=${encodeURIComponent(device)}`);
  if (status === 200) drawSparkline(svg, data.rows);
  svg.classList.remove("hidden");
}

/* ---- stats --------------------------------------------------------- */
function drawSparkline(svg, rows) {
  svg.textContent = "";
  if (!rows.length) return;
  const vb = svg.viewBox.baseVal;
  const max = Math.max(...rows.map((r) => r.up + r.down), 1);
  const step = vb.width / Math.max(rows.length - 1, 1);
  let points = rows.map((r, i) => {
    const y = vb.height - ((r.up + r.down) / max) * (vb.height - 4) - 2;
    return `${(i * step).toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  if (rows.length === 1) {
    // a single bucket has no line segment - draw a flat visible stroke
    const y = points.split(",")[1];
    points = `0,${y} ${vb.width},${y}`;
  }
  const line = document.createElementNS("http://www.w3.org/2000/svg",
                                        "polyline");
  line.setAttribute("points", points);
  svg.appendChild(line);
}

function fmtBytes(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
  return `${n.toFixed(n >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

async function renderStats() {
  const tier = $("#stats-tier").value;
  const [devices, timeline, gaps, domains] = await Promise.all([
    api("GET", `/v1/stats/devices?tier=${tier}`),
    api("GET", `/v1/stats/timeline?tier=${tier}`),
    api("GET", "/v1/stats/gaps"),
    api("GET", "/v1/stats/domains"),
  ]);
  if (devices.status === 200) {
    // same rule as the device list: only discard rows once a good answer
    // is in hand
    const tbody = $("#stats-rows");
    tbody.textContent = "";
    for (const row of devices.data.rows) {
      const tr = document.createElement("tr");
      for (const value of [row.device, fmtBytes(row.up), fmtBytes(row.down)]) {
        const td = document.createElement("td");
        td.textContent = value;
        tr.appendChild(td);
      }
      tbody.appendChild(tr);
    }
  }
  if (timeline.status === 200) {
    drawSparkline($("#stats-sparkline"), timeline.data.rows);
  }
  // Same rule again: a failed sub-fetch says nothing about the gaps or
  // the domain switch, so it must not silently retract a note that is
  // still true. Only a good answer may change what these claim.
  if (gaps.status === 200) {
    const gapsNote = $("#gaps-note");
    gapsNote.textContent = gaps.data.rows.length
      ? `${t("gaps_note")}: ${gaps.data.rows.length}` : "";
    gapsNote.classList.toggle("hidden", !gaps.data.rows.length);
  }
  if (domains.status === 200) {
    $("#domains-note").classList.toggle(
      "hidden", domains.data.enabled !== false);
  }
}

async function purgeStats() {
  if (!window.confirm(t("purge_confirm"))) return;
  const result = await api("POST", "/v1/stats/purge");
  if (result.status === 200) await renderStats();
}

/* ---- audit --------------------------------------------------------- */
// One screenful at a time instead of the server's 200-row default. The
// column order matches the <thead>; the labels ride along per cell so the
// card fold below the breakpoint can name each field without a second
// dictionary.
const AUDIT_PAGE = 50;
const AUDIT_COLUMNS = [
  { cls: "col-time", label: "col_time" },
  { cls: "col-action", label: "col_action" },
  { cls: "col-target", label: "col_target" },
  { cls: "col-requester", label: "col_requester" },
  { cls: "col-note", label: "col_note" },
];
let auditOffset = 0;
// The offset actually PAINTED, which is not always the one we asked for:
// a superseded or failed render leaves the table showing an older page.
// Rolling back to this rather than to the previously-intended offset is
// what keeps the pager honest after a rapid turn whose answer never came.
let auditShown = 0;
// Monotonic request id: a slow answer for an abandoned page must never
// repaint over a newer one, or the rows and the pager disagree.
let auditRequest = 0;

async function renderAudit() {
  const offset = auditOffset;
  const generation = ++auditRequest;
  // Ask for one more row than we show: its presence is the only honest
  // "there is a next page" signal the API offers, and without it a log
  // whose length is an exact multiple of the page size leaves Next
  // enabled onto a blank page.
  const { status, data } = await api(
    "GET", `/v1/audit?limit=${AUDIT_PAGE + 1}&offset=${offset}`);
  if (generation !== auditRequest) return true;
  const stale = $("#audit-stale");
  if (status !== 200) {
    // Keep whatever is on screen, but never let it pass for current -
    // a silently frozen audit log is the bug this replaced. Reporting
    // false lets a failed page turn put the offset back, so the pager
    // never claims a page the table is not showing.
    stale.textContent = t("audit_stale");
    stale.classList.remove("hidden");
    return false;
  }
  stale.classList.add("hidden");
  const hasMore = data.entries.length > AUDIT_PAGE;
  const entries = data.entries.slice(0, AUDIT_PAGE);
  const tbody = $("#audit-rows");
  tbody.textContent = "";
  for (const e of entries) {
    const tr = document.createElement("tr");
    tr.setAttribute("role", "row");
    const action = t(`action_${e.action}`) === `action_${e.action}`
      ? e.action : t(`action_${e.action}`);
    const values = [e.ts, action, [e.cidr, e.mode].filter(Boolean).join(" "),
                    e.requester, e.note || e.details || ""];
    AUDIT_COLUMNS.forEach((col, i) => {
      const td = document.createElement("td");
      td.setAttribute("role", "cell");
      td.className = col.cls;
      td.dataset.label = t(col.label);
      td.textContent = values[i];
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  }
  // Say something whenever there is nothing to show. A later page can
  // still come back empty if entries were removed under us, and a blank
  // table with no explanation is exactly the silence this ticket is about.
  $("#audit-empty").classList.toggle("hidden", entries.length !== 0);
  $("#audit-range").textContent = entries.length
    ? `${offset + 1}-${offset + entries.length}` : "";
  $("#audit-prev").disabled = offset === 0;
  $("#audit-next").disabled = !hasMore;
  // Older pages are a snapshot: re-fetching a raw offset under the user
  // while new entries push rows down would duplicate some and skip
  // others. Freeze the auto-refresh there and say so, rather than
  // shuffling the page they are reading.
  const paused = $("#audit-paused");
  paused.textContent = offset === 0 ? "" : t("audit_paused");
  paused.classList.toggle("hidden", offset === 0);
  auditShown = offset;
  return true;
}

async function pageAudit(delta) {
  const next = auditOffset + delta * AUDIT_PAGE;
  if (next < 0) return;
  auditOffset = next;
  // A page turn that never landed must not leave the offset ahead of the
  // table, or the next click jumps two pages and quietly skips the one in
  // between. Fall back to what is actually on screen - the page we last
  // INTENDED may itself never have been painted.
  if (await renderAudit() === false) auditOffset = auditShown;
}

/* ---- health + shell ------------------------------------------------ */
async function refreshHealth() {
  const { status, data } = await api("GET", "/health");
  const dot = $("#health-dot");
  if (status !== 200 || !data) {
    dot.className = "bad";
    return;
  }
  PARITY = data.parity;
  const healthy = data.db_ok && data.parity === "ok";
  dot.className = healthy ? "ok" : (data.db_ok ? "warn" : "bad");
  dot.title = `parity=${data.parity} collector=${data.collector}`;
  $("#parity-banner").classList.toggle("hidden", data.parity !== "failed");
  const link = $("#dashboard-link");
  link.href = `//${location.hostname}:${data.dashboard_port}`;
}

async function reapply() {
  const result = await api("POST", "/v1/apply");
  if (result.status === 200 && result.data.applied) {
    applyState.clear();
  }
  await refreshHealth();
  await renderDevices();
}

// `resetPaging` separates "the user just entered this tab", where landing
// on the newest page is right, from a re-render of the tab they are
// already on (the language toggle), where throwing away their page is not.
function switchView(name, resetPaging = true) {
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.view === name);
  });
  document.querySelectorAll(".view").forEach((view) => {
    view.classList.toggle("hidden", view.id !== `view-${name}`);
  });
  if (name === "devices") renderDevices();
  if (name === "stats") renderStats();
  if (name === "audit") {
    if (resetPaging) auditOffset = 0;
    renderAudit();
  }
}

function activeView() {
  const tab = document.querySelector(".tab.active");
  return tab ? tab.dataset.view : "devices";
}

async function main() {
  await loadI18n();
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => switchView(tab.dataset.view));
  });
  $("#add-form").addEventListener("submit", addDevice);
  $("#stats-refresh").addEventListener("click", renderStats);
  $("#stats-tier").addEventListener("change", renderStats);
  $("#stats-purge").addEventListener("click", purgeStats);
  $("#audit-prev").addEventListener("click", () => pageAudit(-1));
  $("#audit-next").addEventListener("click", () => pageAudit(1));
  $("#reapply-btn").addEventListener("click", reapply);
  $("#lang-toggle").addEventListener("click", async () => {
    LANG = LANG === "zh" ? "en" : "zh";
    localStorage.setItem("panel_lang", LANG);
    await loadI18n();
    // a repaint, not a fresh entry - keep the page the user is reading
    switchView(activeView(), false);
  });
  await refreshHealth();
  switchView("devices");
  // coarse live updates: health + the active view every 10s
  setInterval(async () => {
    await refreshHealth();
    if (activeView() === "stats") renderStats();
    if (activeView() === "devices") renderDevices();
    // page 1 only - see renderAudit: refreshing a deeper offset would
    // reshuffle rows under the reader
    if (activeView() === "audit" && auditOffset === 0) renderAudit();
  }, 10000);
}

main();
