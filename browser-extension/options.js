const routerInput = document.querySelector("#router");
const tokenInput = document.querySelector("#token");
const saveState = document.querySelector("#save-state");
const permissionState = document.querySelector("#permission-state");
const mediaQualityOptIn = document.querySelector("#media-quality-opt-in");

async function routerHello(origin, token) {
  const response = await fetch(new URL("/cgi-bin/adaptive-browser.cgi", origin), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8", Authorization: `Bearer ${token}` },
    body: new URLSearchParams({ schema_version: "1", action: "browser_hello" }),
    credentials: "omit", cache: "no-store", redirect: "error"
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Router returned HTTP ${response.status}.`);
  return data;
}

function routerOrigin(value) {
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.pathname !== "/" || url.search || url.hash) throw new Error("Enter a router origin only.");
  const host = url.hostname.toLowerCase();
  const privateHost = /^(10\.|192\.168\.|127\.|169\.254\.)/.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host) || /\.(lan|local|home\.arpa)$/.test(host);
  if (!privateHost) throw new Error("Use a private LAN address or a local router name.");
  return url.origin;
}

async function load() {
  const { config = {} } = await chrome.storage.local.get({ config: {} });
  routerInput.value = config.router || "";
  tokenInput.value = config.token || "";
  mediaQualityOptIn.checked = config.mediaQualityOptIn === true;
  permissionState.textContent = await chrome.permissions.contains({ origins: ["http://*/*", "https://*/*"] }) ? "Monitoring permission enabled." : "Monitoring permission is not enabled.";
}

document.querySelector("#grant-monitoring").addEventListener("click", async () => {
  const granted = await chrome.permissions.request({ origins: ["http://*/*", "https://*/*"] });
  permissionState.textContent = granted ? "Monitoring permission enabled." : "Permission was not granted.";
});

document.querySelector("#grant-router").addEventListener("click", async () => {
  try {
    const origin = routerOrigin(routerInput.value.trim());
    const granted = await chrome.permissions.request({ origins: [`${origin}/*`] });
    saveState.textContent = granted ? "Router access granted." : "Router permission was not granted.";
  } catch (error) { saveState.textContent = error.message; }
});

document.querySelector("#settings").addEventListener("submit", async event => {
  event.preventDefault();
  try {
    const origin = routerOrigin(routerInput.value.trim());
    const token = tokenInput.value.trim();
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error("The browser token must be the 64-character token created by Zator.");
    if (!await chrome.permissions.contains({ origins: [`${origin}/*`] })) throw new Error("Allow the router address first.");
    await chrome.storage.local.set({ config: { router: `${origin}/`, token, mediaQualityOptIn: mediaQualityOptIn.checked } });
    saveState.textContent = "Pairing saved.";
  } catch (error) { saveState.textContent = error.message; }
});

document.querySelector("#check-router").addEventListener("click", async () => {
  try {
    const origin = routerOrigin(routerInput.value.trim());
    const token = tokenInput.value.trim();
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error("Enter the browser token created by Zator.");
    if (!await chrome.permissions.contains({ origins: [`${origin}/*`] })) throw new Error("Allow the router address first.");
    const data = await routerHello(origin, token);
    saveState.textContent = `Paired to ${data.scope}; adaptive mode ${data.mode}; shared rankings ${data.ranking_opt_in ? "enabled" : "disabled"}. Change ranking consent with adaptive-browser-pair.sh rankings-on/off on the router.`;
  } catch (error) { saveState.textContent = error.message; }
});

void load();
