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
  latest.textContent = attemptActive
    ? `${row.hostname} · ${row.router_status}${row.pending_result ? " · browser result received" : autoRetryStarted ? " · retrying the failed GET once" : " · waiting for a new connection"}`
    : `${row.hostname} · ${(row.failure_class || "user requested").replaceAll("_", " ")}${row.router_status ? ` · ${row.router_status}` : ""}`;
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
