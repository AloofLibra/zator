const mode = document.querySelector("#mode");
const latest = document.querySelector("#latest");
const fix = document.querySelector("#fix");
let activeEvent = null;
let activeTab = null;

async function render() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tabId = tabs[0]?.id;
  activeTab = tabs[0] || null;
  const state = await chrome.runtime.sendMessage({ type: "z2r:get-state" });
  const row = (state.events || []).slice().reverse().find(item => item && item.hostname && item.tab_id === tabId);
  const permission = await chrome.permissions.contains({ origins: ["http://*/*", "https://*/*"] });
  mode.textContent = permission ? (state.config?.token ? "Paired · waiting for site errors" : "Monitoring enabled · pair a router") : "Enable error monitoring in Settings";
  fix.hidden = !activeTab?.url || !/^https?:\/\//i.test(activeTab.url);
  if (!row) {
    latest.textContent = "No recent eligible network error. You can still ask Zator to try this site.";
    return;
  }
  activeEvent = row;
  latest.textContent = `${row.hostname} · ${row.failure_class.replaceAll("_", " ")}${row.router_status ? ` · ${row.router_status}` : ""}`;
  fix.hidden = Date.now() - row.observed_at > 120_000;
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
document.querySelector("#options").addEventListener("click", () => chrome.runtime.openOptionsPage());
void render();
