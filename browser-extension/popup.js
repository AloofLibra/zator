const mode = document.querySelector("#mode");
const latest = document.querySelector("#latest");
const fix = document.querySelector("#fix");
const cancel = document.querySelector("#cancel");
const targets = document.querySelector("#targets");
const features = document.querySelector("#features");
let activeEvent = null;
let activeTab = null;
let cachedRouterStatus = null;
let lastRouterStatusAt = 0;

function addStatusItem(list, text, muted = false) {
  const item = document.createElement("li");
  item.textContent = text;
  if (muted) item.className = "muted";
  list.append(item);
}

function routerStatusError(status) {
  if (status === "not_paired") return "Pair a router to see managed domains.";
  if (status === "unreachable") return "Router API is unreachable. Check the router address, network, and API service.";
  if (status === 401 || status === 403) return "Router rejected this pairing. Pair the extension again in Settings.";
  if (status === 404) return "Router browser API is unavailable. Update or enable it on the router.";
  return "Router status request failed. Check pairing and router service.";
}

function renderRouterStatus(state) {
  targets.replaceChildren();
  features.replaceChildren();
  if (!state?.ok) {
    addStatusItem(targets, routerStatusError(state?.status), true);
    addStatusItem(features, "Connect to the router to see feature status.", true);
    return;
  }
  const status = state.data;
  const active = ["AGENT_BETA", "AUTO"].includes(status.mode);
  if (!Array.isArray(status.targets) || status.targets.length === 0) {
    addStatusItem(targets, active ? "No recent managed domains yet. Open sites to populate observations." : `Learning is off (${status.mode || "unknown"}).`, true);
  } else {
    for (const row of status.targets.slice(0, 24)) {
      const proto = row.protocol === "quic" ? "QUIC" : row.protocol === "googlevideo-tcp" ? "Googlevideo TCP" : "TLS";
      const strategy = row.strategy_source === "active_trial" ? `#${row.strategy_number} · temporary trial` :
        row.strategy_source === "verified_rule" ? `#${row.strategy_number} · confirmed` :
        row.strategy_source === "router_auto_trial" ? `#${row.strategy_number} · router trial` :
        row.strategy_source === "profile_lock" ? (row.strategy_number === 0 ? "profile disabled" : `#${row.strategy_number} · profile lock`) :
        `#${row.strategy_number} · automatic start`;
      addStatusItem(targets, `${row.hostname} · ${proto} · ${strategy}`);
    }
  }
  const local = cachedConfig || {};
  addStatusItem(features, `Browser learning: ${active ? "active" : status.mode || "off"}`);
  addStatusItem(features, `Media quality sampling: ${local.mediaQualityOptIn === true ? "enabled" : "off"}`);
  addStatusItem(features, `Ramp canary: ${status.ramp_configured && local.mediaQualityOptIn === true && local.rampCanaryOptIn === true ? "enabled by consent" : "off"}`);
  addStatusItem(features, `Shared rankings: ${status.ranking_opt_in ? "enabled" : "off"}`);
  addStatusItem(features, `Browser outcome upload: ${status.stats_opt_in ? "enabled" : "off"}`);
  addStatusItem(features, `QUIC profile: ${status.quic_profile_available ? "available" : "not configured"}`);
}
let cachedConfig = {};

async function render() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tabId = tabs[0]?.id;
  activeTab = tabs[0] || null;
  let state = await chrome.runtime.sendMessage({ type: "z2r:get-state" });
  cachedConfig = state.config || {};
  if (!cachedRouterStatus || Date.now() - lastRouterStatusAt > 15_000) {
    cachedRouterStatus = await chrome.runtime.sendMessage({ type: "z2r:get-learning-status" }).catch(() => ({ ok: false, status: "unavailable" }));
    lastRouterStatusAt = Date.now();
  }
  renderRouterStatus(cachedRouterStatus);
  let row = (state.events || []).slice().reverse().find(item => item && item.hostname && item.tab_id === tabId);
  if (row?.attempt_id) {
    await chrome.runtime.sendMessage({ type: "z2r:sync-attempt", eventId: row.id });
    state = await chrome.runtime.sendMessage({ type: "z2r:get-state" });
    row = (state.events || []).slice().reverse().find(item => item && item.hostname && item.tab_id === tabId);
  }
  const permission = await chrome.permissions.contains({ origins: ["http://*/*", "https://*/*"] });
  mode.textContent = permission ? (state.config?.token ? "Paired · waiting for site errors" : "Monitoring enabled · pair a router") : "Enable error monitoring in Settings";
  fix.hidden = !activeTab?.url || !/^https?:\/\//i.test(activeTab.url);
  cancel.hidden = true;
  if (!row) {
    activeEvent = null;
    latest.textContent = "No recent eligible network error.";
    return;
  }
  activeEvent = row;
  const attemptActive = ["ACTIVE_ATTEMPT", "WAIT_NEW_FLOW", "FLOW_CONFIRMED", "WAIT_BROWSER_RESULT", "PROVISIONAL_SUCCESS"].includes(row.router_status);
  const autoRetryStarted = attemptActive && (state.autoRetriedAttempts || []).includes(row.attempt_id);
  const status = ({
    ACTIVE_ATTEMPT: "a trial is already running for this scope",
    WAIT_NEW_FLOW: "waiting for a new connection",
    FLOW_CONFIRMED: "new connection and strategy confirmed",
    WAIT_BROWSER_RESULT: "waiting for browser result",
    PROVISIONAL_SUCCESS: "provisional recovery",
    CONFIRMED_SUCCESS: "recovery confirmed",
    CONFIRMED_FAILURE: "failure confirmed",
    TCP_FALLBACK: "browser used TCP; QUIC strategy was not tested",
    UNKNOWN: "outcome unknown; no candidate advanced",
    NOT_TESTED: "not counted; no confirmed new flow",
    TARGET_NOT_MANAGED: "target is not managed by Zator",
    MANUAL_LOCKED: "manual lock prevents a trial",
    COOLDOWN: "trial cooldown is active"
  })[row.router_status] || row.router_status;
  const rampEvidence = row.ramp_treatment
    ? ` · Ramp ${({ applied: "applied on SYN", bypassed: "bypassed for exact target", unchanged: "no SYN change", no_window_scale: "no window-scale option", unknown: "not observed" })[row.ramp_treatment] || "not observed"}${row.ramp_treatment === "applied" ? ` · late ACK ${row.ramp_ack_evidence === "confirmed" ? "confirmed" : row.ramp_ack_evidence === "pending" ? "pending" : "unknown"}` : ""}`
    : "";
  const mediaEvidence = row.media_quality ? ` · media playback ${row.media_quality}` : "";
  const reason = ({
    h3_protocol_evidence_unavailable: "H3 protocol evidence unavailable; QUIC success not confirmed",
    ambiguous_recent_flows: "multiple recent connections match; no trial started",
    strategy_fingerprint_changed_or_promotion_failed: "strategy changed or could not be confirmed"
  })[row.router_reason] || "";
  latest.textContent = attemptActive
    ? `${row.hostname} · ${status}${reason ? ` · ${reason}` : ""}${rampEvidence}${mediaEvidence}${row.pending_result ? " · browser result received" : autoRetryStarted ? " · reloading once for retry" : ""}`
    : `${row.hostname} · ${(row.failure_class || "user requested").replaceAll("_", " ")}${row.router_status ? ` · ${status}` : ""}${reason ? ` · ${reason}` : ""}${rampEvidence}${mediaEvidence}`;
  fix.hidden = attemptActive || Date.now() - row.observed_at > 120_000;
  cancel.hidden = !row.attempt_id || !attemptActive;
}

fix.addEventListener("click", async () => {
  if (!activeEvent && !activeTab?.url) return;
  fix.disabled = true;
  const result = activeEvent && Date.now() - activeEvent.observed_at <= 120_000
    ? await chrome.runtime.sendMessage({ type: "z2r:fix", eventId: activeEvent.id })
    : await chrome.runtime.sendMessage({ type: "z2r:fix-current", url: activeTab.url, tabId: activeTab.id });
  latest.textContent = result.ok ? "Request sent. Waiting for router status." : `Could not start: ${result.reason}`;
  fix.disabled = false;
});
cancel.addEventListener("click", async () => {
  if (!activeEvent?.attempt_id) return;
  cancel.disabled = true;
  const result = await chrome.runtime.sendMessage({ type: "z2r:cancel-attempt", eventId: activeEvent.id });
  latest.textContent = result.ok ? "Trial cancelled." : `Could not cancel: ${result.state}`;
  cancel.disabled = false;
  await render();
});
document.querySelector("#options").addEventListener("click", () => chrome.runtime.openOptionsPage());
void render();
setInterval(() => { void render(); }, 2500);
