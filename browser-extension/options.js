const routerInput = document.querySelector("#router");
const tokenInput = document.querySelector("#token");
const saveState = document.querySelector("#save-state");
const permissionState = document.querySelector("#permission-state");

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
    if (!/^[A-Za-z0-9_-]{40,96}$/.test(token)) throw new Error("The browser token format is invalid.");
    if (!await chrome.permissions.contains({ origins: [`${origin}/*`] })) throw new Error("Allow the router address first.");
    await chrome.storage.local.set({ config: { router: `${origin}/`, token } });
    saveState.textContent = "Pairing saved.";
  } catch (error) { saveState.textContent = error.message; }
});

void load();
