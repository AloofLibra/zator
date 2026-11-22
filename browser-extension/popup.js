const mode = document.querySelector("#mode");
const latest = document.querySelector("#latest");
const fix = document.querySelector("#fix");
const cancel = document.querySelector("#cancel");
let activeEvent = null;
let activeTab = null;

async function render() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tabId = tabs[0]?.id;
  activeTab = tabs[0] || null;
  let state = await chrome.runtime.sendMessage({ type: "z2r:get-state" });
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
    latest.textContent = "No recent eligible network error. You can still ask Zator to try this site.";
    return;
  }
  activeEvent = row;
  const attemptActive = row.attempt_id && ["WAIT_NEW_FLOW", "FLOW_CONFIRMED", "WAIT_BROWSER_RESULT", "PROVISIONAL_SUCCESS"].includes(row.router_status);
  const autoRetryStarted = attemptActive && (state.autoRetriedAttempts || []).includes(row.attempt_id);
  const status = ({
    WAIT_NEW_FLOW: "waiting for a new connection",
    FLOW_CONFIRMED: "new connection and strategy confirmed",
    WAIT_BROWSER_RESULT: "waiting for browser result",
    PROVISIONAL_SUCCESS: "provisional recovery",
    CONFIRMED_SUCCESS: "recovery confirmed",
    CONFIRMED_FAILURE: "failure confirmed",
    UNKNOWN: "outcome unknown; no candidate advanced",
    NOT_TESTED: "not counted; no confirmed new flow",
    TARGET_NOT_MANAGED: "target is not managed by Zator",
    MANUAL_LOCKED: "manual lock prevents a trial",
    COOLDOWN: "trial cooldown is active"
  })[row.router_status] || row.router_status;
  const rampEvidence = row.ramp_treatment
    ? ` · Ramp ${({ applied: "applied on SYN", bypassed: "bypassed for exact target", unchanged: "no SYN change", no_window_scale: "no window-scale option", unknown: "not observed" })[row.ramp_treatment] || "not observed"}${row.ramp_treatment === "applied" ? ` · late ACK ${row.ramp_ack_evidence === "confirmed" ? "confirmed" : row.ramp_ack_evidence === "pending" ? "pending" : "unknown"}` : ""}`
    : "";
  latest.textContent = attemptActive
    ? `${row.hostname} · ${status}${rampEvidence}${row.pending_result ? " · browser result received" : autoRetryStarted ? " · retrying the failed GET once" : ""}`
    : `${row.hostname} · ${(row.failure_class || "user requested").replaceAll("_", " ")}${row.router_status ? ` · ${status}` : ""}${row.router_reason === "ambiguous_recent_flows" ? " · multiple recent connections match; no trial started" : ""}`;
  fix.hidden = attemptActive || Date.now() - row.observed_at > 120_000;
  cancel.hidden = !attemptActive;
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
