/* Browser feedback v1. Only failed requests and explicit user actions leave this extension. */
(() => {
  const MAX_EVENTS = 64;
  const MAX_SEEN = 128;
  const DEDUPE_MS = 30_000;
  const RESOURCE_TYPES = new Set(["script", "xmlhttprequest", "media"]);
  const mainFrameErrors = new Set([
    "ERR_CONNECTION_RESET", "ERR_CONNECTION_TIMED_OUT", "ERR_TIMED_OUT", "ERR_EMPTY_RESPONSE",
    "ERR_CONNECTION_CLOSED", "ERR_SSL_PROTOCOL_ERROR",
    "ERR_QUIC_PROTOCOL_ERROR", "ERR_HTTP2_PROTOCOL_ERROR"
  ]);
  const ignoredErrors = new Set([
    "ERR_NAME_NOT_RESOLVED", "ERR_INTERNET_DISCONNECTED", "ERR_NETWORK_CHANGED",
    "ERR_ABORTED", "ERR_BLOCKED_BY_CLIENT", "ERR_BLOCKED_BY_RESPONSE",
    "ERR_CERT_AUTHORITY_INVALID", "ERR_CERT_COMMON_NAME_INVALID", "ERR_CERT_DATE_INVALID",
    "ERR_CERT_REVOKED", "ERR_CERTIFICATE_TRANSPARENCY_REQUIRED", "ERR_SSL_PINNED_KEY_NOT_IN_CERT_CHAIN"
  ]);

  function safeHost(value) {
    try {
      const url = new URL(value);
      if (url.protocol !== "http:" && url.protocol !== "https:") return "";
      const host = url.hostname.toLowerCase().replace(/\.$/, "");
      if (!host || host.includes(":") || /^(\d{1,3}\.){3}\d{1,3}$/.test(host) || host === "localhost" || !host.includes(".") ||
          /(^|\.)(local|lan|home\.arpa|localhost|internal)$/.test(host) ||
          /^(127\.|10\.|192\.168\.|169\.254\.)/.test(host) ||
          /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
          /^\[(::1|fc|fd|fe80):/i.test(host)) return "";
      return host;
    } catch { return ""; }
  }

  function failureClass(error) {
    const code = String(error || "").replace(/^net::/, "").toUpperCase();
    if (ignoredErrors.has(code) || /CERT|NAME_NOT_RESOLVED|INTERNET_DISCONNECTED|NETWORK_CHANGED/.test(code)) return "";
    if (mainFrameErrors.has(code) || /^(ERR_CONNECTION_(RESET|TIMED_OUT|CLOSED)|ERR_EMPTY_RESPONSE|ERR_(SSL|QUIC|HTTP2)_PROTOCOL_ERROR)$/.test(code)) {
      return "network_failure";
    }
    return "";
  }

  function safeMethod(method) { return method === "GET"; }
  function safeRemoteIp(ip) {
    return typeof ip === "string" && /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/.test(ip) &&
      ip.split(".").every(part => Number(part) <= 255);
  }
  function opaqueId() {
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") return crypto.randomUUID().replaceAll("-", "");
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, x => x.toString(16).padStart(2, "0")).join("");
  }

  async function loadState() {
    const state = await chrome.storage.local.get({ config: {}, events: [], seen: [], resourceErrors: [] });
    return {
      config: state.config && typeof state.config === "object" ? state.config : {},
      events: Array.isArray(state.events) ? state.events : [],
      seen: Array.isArray(state.seen) ? state.seen : [],
      resourceErrors: Array.isArray(state.resourceErrors) ? state.resourceErrors : []
    };
  }

  async function postRouterForm(config, form) {
    let endpoint;
    try { endpoint = new URL("/cgi-bin/adaptive-browser.cgi", config.router).toString(); }
    catch { return { ok: false, status: "invalid_router", data: {} }; }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 4000);
    try {
      const response = await fetch(endpoint, {
        method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8", Authorization: `Bearer ${config.token}` },
        body: new URLSearchParams(form), credentials: "omit", cache: "no-store", redirect: "error", signal: controller.signal
      });
      const data = await response.json().catch(() => ({}));
      return { ok: response.ok, status: response.status, data };
    } catch { return { ok: false, status: "unreachable", data: {} }; }
    finally { clearTimeout(timeout); }
  }

  async function rememberFailure(details, source = "webRequest") {
    if (!details || details.tabId < 0 || details.incognito === true) return { ignored: "private_or_no_tab" };
    const host = safeHost(details.url);
    const failure = failureClass(details.error);
    if (!host || !failure) return { ignored: "not_eligible" };
    const type = details.type === "main_frame" ? "main_frame" : details.type;
    const method = String(details.method || "GET").toUpperCase();
    const now = Number.isFinite(details.timeStamp) ? Math.trunc(details.timeStamp) : Date.now();
    const state = await loadState();
    const dedupe = [details.tabId, details.documentId || details.frameId || 0, details.requestId || "nav", host, failure].join("|");
    const seen = state.seen.filter(x => x && Number.isFinite(x.at) && now - x.at < DEDUPE_MS);
    if (seen.some(x => x.key === dedupe)) return { ignored: "duplicate" };
    seen.push({ key: dedupe, at: now });
    state.seen = seen.slice(-MAX_SEEN);

    let trigger = "";
    if (type === "main_frame" && method === "GET") trigger = "main_frame_network_failure";
    else if (RESOURCE_TYPES.has(type) && safeMethod(method)) {
      const resourceKey = `${details.tabId}|${details.documentId || details.frameId || 0}|${host}|${type}`;
      const recent = state.resourceErrors.filter(x => x && Number.isFinite(x.at) && now - x.at <= DEDUPE_MS);
      const matching = recent.filter(x => x.key === resourceKey);
      if (matching.length >= 1) trigger = "critical_resource_repeated_failure";
      recent.push({ key: resourceKey, at: now });
      state.resourceErrors = recent.slice(-MAX_SEEN);
    }
    const event = {
      id: opaqueId(), hostname: host, request_class: type, method: safeMethod(method) ? method : "UNSAFE",
      failure_class: failure, trigger, observed_at: now, tab_id: details.tabId
    };
    event.failure_count = trigger === "critical_resource_repeated_failure" ? 2 : 1;
    if (trigger && await captureAttemptResult(state, host, details.tabId, "network_failure", type, now, details.ip)) {
      await chrome.storage.local.set({ seen: state.seen, resourceErrors: state.resourceErrors });
      return { accepted: true, trigger: "attempt_result" };
    }
    state.events.push(event);
    state.events = state.events.slice(-MAX_EVENTS);
    await chrome.storage.local.set({ events: state.events, seen: state.seen, resourceErrors: state.resourceErrors });
    if (trigger) await reportFailure(event, false);
    return { accepted: true, trigger: trigger || "observe_only", event_id: event.id };
  }

  async function reportFailure(event, userRequested) {
    const state = await loadState();
    const { router, token } = state.config;
    if (!router || !token) return { paired: false };
    const form = new URLSearchParams({
      schema_version: "1", action: "browser_report_failure", browser_event_id: event.id,
      trigger: userRequested ? "user_fix" : event.trigger,
      request_class: event.request_class, hostname: event.hostname, method: event.method,
      failure_class: event.failure_class, failure_count: String(userRequested ? 1 : (event.failure_count || 1)),
      observed_at: String(event.observed_at)
    });
    const result = await postRouterForm(state.config, Object.fromEntries(form.entries()));
    const latest = await loadState();
    latest.events = latest.events.map(row => row.id === event.id
      ? { ...row, router_status: result.data.state || result.data.status || (result.ok ? "received" : result.status),
          attempt_id: result.data.attempt_id || row.attempt_id || null,
          attempt_expires_at: result.data.expires_at || row.attempt_expires_at || null,
          pending_result: row.pending_result || null }
      : row);
    await chrome.storage.local.set({ events: latest.events });
    if (result.data.attempt_id) void syncAttempt(event.id);
    return { paired: true, ok: result.ok, status: result.status, data: result.data };
  }

  async function syncAttempt(eventId) {
    const state = await loadState();
    const event = state.events.find(row => row && row.id === eventId && row.attempt_id);
    if (!event || !state.config.router || !state.config.token) return { ok: false, state: "NO_ATTEMPT" };
    const status = await postRouterForm(state.config, {
      schema_version: "1", action: "browser_attempt_status", attempt_id: event.attempt_id
    });
    if (!status.ok) return { ok: false, state: status.status };
    let latest = await loadState();
    latest.events = latest.events.map(row => row.id === eventId ? { ...row, router_status: status.data.state || row.router_status } : row);
    await chrome.storage.local.set({ events: latest.events });
    const current = latest.events.find(row => row && row.id === eventId);
    if (!current?.pending_result || !["FLOW_CONFIRMED", "PROVISIONAL_SUCCESS"].includes(status.data.state)) {
      return { ok: true, state: status.data.state || "UNKNOWN" };
    }
    const pending = current.pending_result;
    const result = await postRouterForm(latest.config, {
      schema_version: "1", action: "browser_report_result", attempt_id: current.attempt_id,
      browser_event_id: pending.id, result: pending.result, request_class: pending.request_class,
      browser_ip: pending.browser_ip, observed_at: String(pending.observed_at)
    });
    latest = await loadState();
    latest.events = latest.events.map(row => row.id === eventId ? {
      ...row,
      attempt_id: result.data.next_attempt?.attempt_id || row.attempt_id,
      attempt_expires_at: result.data.next_attempt?.expires_at || row.attempt_expires_at,
      router_status: result.data.next_attempt?.state || result.data.state || result.data.status || (result.ok ? status.data.state : result.status),
      pending_result: result.ok ? null : row.pending_result
    } : row);
    await chrome.storage.local.set({ events: latest.events });
    return { ok: result.ok, state: result.data.state || result.data.status || status.data.state };
  }

  async function cancelAttempt(eventId) {
    const state = await loadState();
    const event = state.events.find(row => row && row.id === eventId && row.attempt_id);
    if (!event || !state.config.router || !state.config.token) return { ok: false, state: "NO_ATTEMPT" };
    const result = await postRouterForm(state.config, {
      schema_version: "1", action: "browser_cancel_attempt", attempt_id: event.attempt_id
    });
    if (result.ok) {
      const latest = await loadState();
      latest.events = latest.events.map(row => row.id === eventId ? {
        ...row, router_status: result.data.state || "CANCELLED", pending_result: null
      } : row);
      await chrome.storage.local.set({ events: latest.events });
    }
    return { ok: result.ok, state: result.data.state || result.status };
  }

  async function captureAttemptResult(state, host, tabId, result, requestClass, observedAt, browserIp) {
    if (!safeRemoteIp(browserIp)) return false;
    const event = [...state.events].reverse().find(row => row && row.attempt_id && row.hostname === host && row.tab_id === tabId &&
      ["WAIT_NEW_FLOW", "FLOW_CONFIRMED", "WAIT_BROWSER_RESULT", "PROVISIONAL_SUCCESS"].includes(row.router_status));
    if (!event || (event.attempt_expires_at && observedAt > event.attempt_expires_at * 1000)) return false;
    event.pending_result = { id: opaqueId(), result, request_class: requestClass, browser_ip: browserIp, observed_at: observedAt };
    await chrome.storage.local.set({ events: state.events });
    void syncAttempt(event.id);
    return true;
  }

  async function requestFix(eventId) {
    const state = await loadState();
    const event = state.events.find(row => row.id === eventId && Date.now() - row.observed_at <= 120_000);
    if (!event) return { ok: false, reason: "failure_expired" };
    const result = await reportFailure(event, true);
    return { ok: result.ok === true, reason: result.status || "router_unreachable" };
  }

  async function requestCurrentPageFix(url, tabId) {
    const host = safeHost(url);
    if (!host || !Number.isInteger(tabId) || tabId < 0) return { ok: false, reason: "target_not_supported" };
    const event = { id: opaqueId(), hostname: host, request_class: "main_frame", method: "GET",
      failure_class: "user_requested", trigger: "user_fix", failure_count: 1, observed_at: Date.now(), tab_id: tabId };
    const state = await loadState();
    state.events.push(event);
    state.events = state.events.slice(-MAX_EVENTS);
    await chrome.storage.local.set({ events: state.events });
    const result = await reportFailure(event, true);
    return { ok: result.ok === true, reason: result.status || "router_unreachable" };
  }

  async function recordHttpResponse(details) {
    if (!details || details.tabId < 0 || details.incognito === true) return;
    const host = safeHost(details.url);
    if (!host) return;
    if (details.type === "main_frame" && details.method === "GET" && details.statusCode >= 200 && details.statusCode < 400 && details.statusCode !== 304 && details.fromCache !== true) {
      const state = await loadState();
      await captureAttemptResult(state, host, details.tabId, "network_success", "main_frame", Date.now(), details.ip);
      return;
    }
    if (![403, 451, 500, 502, 503, 504].includes(details.statusCode)) return;
    const state = await loadState();
    const row = { id: opaqueId(), hostname: host, request_class: details.type || "other", method: "GET",
      failure_class: `http_${details.statusCode}`, trigger: "manual_only", observed_at: Date.now(), tab_id: details.tabId };
    state.events.push(row);
    state.events = state.events.slice(-MAX_EVENTS);
    await chrome.storage.local.set({ events: state.events });
  }

  void Promise.resolve(chrome.storage.local.setAccessLevel?.({ accessLevel: "TRUSTED_CONTEXTS" })).catch(() => {});
  chrome.webRequest.onErrorOccurred.addListener(details => { void rememberFailure(details); }, { urls: ["http://*/*", "https://*/*"] });
  chrome.webRequest.onCompleted.addListener(details => { void recordHttpResponse(details); }, { urls: ["http://*/*", "https://*/*"] });
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message && message.type === "z2r:get-state") {
      void loadState().then(sendResponse).catch(() => sendResponse({ events: [], config: {} }));
      return true;
    }
    if (message && message.type === "z2r:fix" && typeof message.eventId === "string") {
      void requestFix(message.eventId).then(sendResponse).catch(() => sendResponse({ ok: false, reason: "error" }));
      return true;
    }
    if (message && message.type === "z2r:fix-current" && typeof message.url === "string") {
      void requestCurrentPageFix(message.url, message.tabId).then(sendResponse).catch(() => sendResponse({ ok: false, reason: "error" }));
      return true;
    }
    if (message && message.type === "z2r:sync-attempt" && typeof message.eventId === "string") {
      void syncAttempt(message.eventId).then(sendResponse).catch(() => sendResponse({ ok: false, state: "error" }));
      return true;
    }
    if (message && message.type === "z2r:cancel-attempt" && typeof message.eventId === "string") {
      void cancelAttempt(message.eventId).then(sendResponse).catch(() => sendResponse({ ok: false, state: "error" }));
      return true;
    }
  });

  if (globalThis.__Z2R_BROWSER_TEST__) {
    globalThis.__Z2R_BROWSER_TEST__.api = { safeHost, failureClass, rememberFailure, reportFailure, requestFix, requestCurrentPageFix, recordHttpResponse, syncAttempt, cancelAttempt };
  }
})();
