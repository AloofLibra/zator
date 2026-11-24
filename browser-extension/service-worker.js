/* Browser feedback v1. Only failed requests and explicit user actions leave this extension. */
(() => {
  const MAX_EVENTS = 64;
  const MAX_SEEN = 128;
  const DEDUPE_MS = 30_000;
  const RESOURCE_TYPES = new Set(["script", "xmlhttprequest", "media"]);
  const attemptSyncQueues = new Map();
  const mainFrameErrors = new Set([
    "ERR_CONNECTION_RESET", "ERR_CONNECTION_TIMED_OUT", "ERR_TIMED_OUT", "ERR_EMPTY_RESPONSE",
    "ERR_CONNECTION_CLOSED", "ERR_CONNECTION_REFUSED", "ERR_CONNECTION_FAILED", "ERR_SSL_PROTOCOL_ERROR",
    "ERR_SSL_HANDSHAKE_NOT_COMPLETED", "ERR_SSL_VERSION_OR_CIPHER_MISMATCH",
    "ERR_QUIC_PROTOCOL_ERROR", "ERR_QUIC_HANDSHAKE_FAILED", "ERR_HTTP2_PROTOCOL_ERROR",
    "ERR_SOCKET_NOT_CONNECTED"
  ]);
  const ignoredErrors = new Set([
    "ERR_NAME_NOT_RESOLVED", "ERR_INTERNET_DISCONNECTED", "ERR_NETWORK_CHANGED",
    "ERR_ABORTED", "ERR_BLOCKED_BY_CLIENT", "ERR_BLOCKED_BY_RESPONSE",
    "ERR_CERT_AUTHORITY_INVALID", "ERR_CERT_COMMON_NAME_INVALID", "ERR_CERT_DATE_INVALID",
    "ERR_CERT_REVOKED", "ERR_CERTIFICATE_TRANSPARENCY_REQUIRED", "ERR_SSL_PINNED_KEY_NOT_IN_CERT_CHAIN",
    "ERR_SSL_CLIENT_AUTH_CERT_NEEDED", "ERR_BAD_SSL_CLIENT_AUTH_CERT", "ERR_SSL_CLIENT_AUTH_SIGNATURE_FAILED"
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

  function failureTransport(error) {
    const code = String(error || "").replace(/^net::/, "").toUpperCase();
    if (code.startsWith("ERR_QUIC_")) return "quic";
    if (code.startsWith("ERR_SSL_") || code.startsWith("ERR_HTTP2_")) return "tls";
    return "unknown";
  }

  function safeMethod(method) { return method === "GET"; }
  function safeRemoteIp(ip) {
    return typeof ip === "string" && /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/.test(ip) &&
      ip.split(".").every(part => Number(part) <= 255);
  }
  async function resourceIdentity(value) {
    try {
      const url = new URL(value);
      const hostKey = url.hostname.endsWith(".googlevideo.com") ? "googlevideo.com" : url.origin;
      const path = `${hostKey}${url.pathname}`;
      const bytes = new TextEncoder().encode(path);
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      return Array.from(new Uint8Array(digest), x => x.toString(16).padStart(2, "0")).join("");
    } catch { return ""; }
  }

  async function readBrowserProtocol(tabId, url) {
    if (!chrome.scripting?.executeScript) return "";
    try {
      const [{ result }] = await chrome.scripting.executeScript({
        target: { tabId },
        args: [url],
        func: targetUrl => {
          let target;
          try { target = new URL(targetUrl); } catch { return ""; }
          const entries = [...performance.getEntriesByType("resource"), ...performance.getEntriesByType("navigation")];
          const matches = entries.filter(entry => {
            try {
              const entryUrl = new URL(entry.name);
              return entryUrl.origin === target.origin && entryUrl.pathname === target.pathname;
            } catch { return false; }
          });
          return matches.length === 1 ? matches[0].nextHopProtocol || "" : "";
        }
      });
      if (/^h3(?:-\d+)?$/.test(result || "")) return "h3";
      return ["h2", "h2c", "http/1.0", "http/1.1"].includes(result) ? "tcp" : "";
    } catch { return ""; }
  }
  async function readMediaQuality(tabId) {
    const unknown = { quality: "unknown", sample_ms: 0, progress_ms: 0, stall_ms: 0, dropped_frames: 0, total_frames: 0 };
    if (!chrome.scripting?.executeScript) return unknown;
    try {
      const [{ result }] = await chrome.scripting.executeScript({
        target: { tabId },
        func: async () => {
          const videos = [...document.querySelectorAll("video")].filter(video => {
            if (video.ended || video.readyState === 0 || video.getClientRects().length === 0) return false;
            const rect = video.getBoundingClientRect();
            const style = getComputedStyle(video);
            return rect.width >= 160 && rect.height >= 90 && style.visibility !== "hidden" && style.display !== "none";
          });
          if (videos.length !== 1) return null;
          const video = videos[0];
          const startedAt = performance.now();
          const initialTime = video.currentTime;
          const samples = [];
          let waiting = false;
          let waitingStartedAt = 0;
          let waitingEvents = 0;
          let stallMs = 0;
          const onWaiting = () => {
            if (!waiting) { waiting = true; waitingStartedAt = performance.now(); waitingEvents += 1; }
          };
          const onPlaying = () => {
            if (waiting) { stallMs += performance.now() - waitingStartedAt; waiting = false; }
          };
          video.addEventListener("waiting", onWaiting);
          video.addEventListener("playing", onPlaying);
          try {
            for (let i = 0; i <= 8; i += 1) {
              const playback = typeof video.getVideoPlaybackQuality === "function" ? video.getVideoPlaybackQuality() : null;
              samples.push({
                at: performance.now(), time: video.currentTime, paused: video.paused, seeking: video.seeking,
                ready: video.readyState, dropped: Number(playback?.droppedVideoFrames ?? video.webkitDroppedFrameCount ?? 0),
                frames: Number(playback?.totalVideoFrames ?? video.webkitDecodedFrameCount ?? 0)
              });
              if (i < 8) await new Promise(resolve => setTimeout(resolve, 1000));
            }
          } finally {
            video.removeEventListener("waiting", onWaiting);
            video.removeEventListener("playing", onPlaying);
            if (waiting) stallMs += performance.now() - waitingStartedAt;
          }
          const elapsed = Math.max(0, Math.min(12000, Math.round(performance.now() - startedAt)));
          const active = samples.filter(sample => !sample.paused && !sample.seeking);
          const end = samples[samples.length - 1];
          const progress = Math.round((end.time - initialTime) * 1000);
          const dropped = Math.max(0, Math.min(999999, Math.round(end.dropped - samples[0].dropped)));
          const frames = Math.max(0, Math.min(999999, Math.round(end.frames - samples[0].frames)));
          const boundedStall = Math.max(0, Math.min(12000, Math.round(stallMs)));
          let quality = "unknown";
          if (elapsed >= 5000 && active.length >= 4 && samples.filter(sample => sample.paused || sample.seeking).length < 3 && progress >= 0) {
            if (waitingEvents >= 2 || boundedStall >= 1500 || (active.length >= 5 && progress < 2000)) quality = "degraded";
            else if (elapsed >= 7500 && active.length >= 6 && progress >= 5000 && boundedStall < 1000) quality = "healthy";
          }
          return {
            quality, sample_ms: elapsed, progress_ms: Math.max(0, Math.min(12000, progress)),
            stall_ms: boundedStall, dropped_frames: dropped, total_frames: frames
          };
        }
      });
      if (!result || !["healthy", "degraded", "unknown"].includes(result.quality)) return unknown;
      return {
        quality: result.quality,
        sample_ms: Number.isInteger(result.sample_ms) && result.sample_ms >= 0 && result.sample_ms <= 12000 ? result.sample_ms : 0,
        progress_ms: Number.isInteger(result.progress_ms) && result.progress_ms >= 0 && result.progress_ms <= 12000 ? result.progress_ms : 0,
        stall_ms: Number.isInteger(result.stall_ms) && result.stall_ms >= 0 && result.stall_ms <= 12000 ? result.stall_ms : 0,
        dropped_frames: Number.isInteger(result.dropped_frames) && result.dropped_frames >= 0 && result.dropped_frames <= 999999 ? result.dropped_frames : 0,
        total_frames: Number.isInteger(result.total_frames) && result.total_frames >= 0 && result.total_frames <= 999999 ? result.total_frames : 0
      };
    } catch { return unknown; }
  }
  function opaqueId() {
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") return crypto.randomUUID().replaceAll("-", "");
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, x => x.toString(16).padStart(2, "0")).join("");
  }

  async function loadState() {
    const state = await chrome.storage.local.get({ config: {}, events: [], seen: [], resourceErrors: [], autoRetriedAttempts: [] });
    return {
      config: state.config && typeof state.config === "object" ? state.config : {},
      events: Array.isArray(state.events) ? state.events : [],
      seen: Array.isArray(state.seen) ? state.seen : [],
      resourceErrors: Array.isArray(state.resourceErrors) ? state.resourceErrors : [],
      autoRetriedAttempts: Array.isArray(state.autoRetriedAttempts) ? state.autoRetriedAttempts.filter(x => /^[a-f0-9]{32}$/.test(x)).slice(-64) : []
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
    let resourceId = "";
    if (type === "main_frame" && method === "GET") trigger = "main_frame_network_failure";
    else if (RESOURCE_TYPES.has(type) && safeMethod(method)) {
      resourceId = await resourceIdentity(details.url);
      if (resourceId) {
        const resourceHost = type === "media" && host.endsWith(".googlevideo.com") ? "googlevideo.com" : host;
        const resourceKey = `${details.tabId}|${details.documentId || details.frameId || 0}|${resourceHost}|${type}|${resourceId}`;
        const recent = state.resourceErrors.filter(x => x && Number.isFinite(x.at) && now - x.at <= DEDUPE_MS);
        const matching = recent.filter(x => x.key === resourceKey);
        if (matching.length >= 1) trigger = "critical_resource_repeated_failure";
        recent.push({ key: resourceKey, at: now });
        state.resourceErrors = recent.slice(-MAX_SEEN);
      }
    }
    const event = {
      id: opaqueId(), hostname: host, request_class: type, method: safeMethod(method) ? method : "UNSAFE",
      failure_class: failure, trigger, observed_at: now, tab_id: details.tabId,
      resource_identity: trigger === "critical_resource_repeated_failure" ? resourceId : undefined
    };
    event.failure_transport = failureTransport(details.error);
    event.failure_count = trigger === "critical_resource_repeated_failure" ? 2 : 1;
    const feedbackEligible = (type === "main_frame" && method === "GET") || (RESOURCE_TYPES.has(type) && method === "GET");
    if (feedbackEligible && await captureAttemptResult(state, host, details.tabId, "network_failure", type, now, details.ip, resourceId)) {
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
      failure_class: event.failure_class, failure_transport: event.failure_transport || "unknown",
      failure_count: String(userRequested ? 1 : (event.failure_count || 1)),
      observed_at: String(event.observed_at)
    });
    const result = await postRouterForm(state.config, Object.fromEntries(form.entries()));
    const latest = await loadState();
    latest.events = latest.events.map(row => row.id === event.id
      ? { ...row, router_status: result.data.state || result.data.status || (result.ok ? "received" : result.status),
          router_reason: result.data.reason || null,
          attempt_id: result.data.attempt_id || row.attempt_id || null,
          candidate_protocol: result.data.candidate?.protocol || row.candidate_protocol || null,
          candidate_profile: result.data.candidate?.profile_id || row.candidate_profile || null,
          attempt_expires_at: result.data.expires_at || row.attempt_expires_at || null,
          pending_result: row.pending_result || null }
      : row);
    await chrome.storage.local.set({ events: latest.events });
    if (result.data.attempt_id) {
      await retryFailedGetOnce(event, result);
      void queueSyncAttempt(event.id);
    }
    return { paired: true, ok: result.ok, status: result.status, data: result.data };
  }

  async function retryFailedGetOnce(event, result) {
    const attemptId = result?.data?.attempt_id;
    const mainFrameRetry = event.trigger === "main_frame_network_failure" && event.request_class === "main_frame";
    const youtubeMediaRetry = event.trigger === "critical_resource_repeated_failure" && event.request_class === "media" &&
      typeof event.hostname === "string" && event.hostname.endsWith(".googlevideo.com");
    if (!result?.ok || result.data.state !== "WAIT_NEW_FLOW" || !/^[a-f0-9]{32}$/.test(attemptId || "") ||
        (!mainFrameRetry && !youtubeMediaRetry) || event.method !== "GET" || event.failure_class !== "network_failure" ||
        !Number.isInteger(event.tab_id) || event.tab_id < 0) return false;
    const latest = await loadState();
    if (latest.autoRetriedAttempts.includes(attemptId)) return false;
    let tab;
    try { tab = await chrome.tabs.get(event.tab_id); } catch { return false; }
    const tabHost = safeHost(tab?.url);
    if (mainFrameRetry && tabHost !== event.hostname) return false;
    if (youtubeMediaRetry && !(tabHost === "youtube.com" || tabHost.endsWith(".youtube.com"))) return false;
    latest.autoRetriedAttempts.push(attemptId);
    latest.autoRetriedAttempts = latest.autoRetriedAttempts.slice(-64);
    await chrome.storage.local.set({ autoRetriedAttempts: latest.autoRetriedAttempts });
    try {
      await chrome.tabs.reload(event.tab_id, { bypassCache: true });
      return true;
    } catch { return false; }
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
    const terminal = ["CANCELLED", "EXPIRED", "CONFIRMED_SUCCESS", "CONFIRMED_FAILURE", "TCP_FALLBACK", "UNKNOWN"].includes(status.data.state);
    latest.events = latest.events.map(row => row.id === eventId ? {
      ...row,
      router_status: status.data.state || row.router_status,
      ramp_treatment: status.data.ramp_treatment || row.ramp_treatment,
      ramp_ack_evidence: status.data.ramp_ack_evidence || row.ramp_ack_evidence,
      ...(terminal ? { pending_results: [], pending_result: null } : {})
    } : row);
    await chrome.storage.local.set({ events: latest.events });
    const current = latest.events.find(row => row && row.id === eventId);
    const pendingResult = current?.pending_results?.[0] || current?.pending_result;
    if (!pendingResult || !["FLOW_CONFIRMED", "PROVISIONAL_SUCCESS"].includes(status.data.state)) {
      return { ok: true, state: status.data.state || "UNKNOWN" };
    }
    const pending = pendingResult;
    const result = await postRouterForm(latest.config, {
      schema_version: "1", action: "browser_report_result", attempt_id: current.attempt_id,
      browser_event_id: pending.id, result: pending.result, request_class: pending.request_class,
      browser_ip: pending.browser_ip, observed_at: String(pending.observed_at),
      ...(pending.browser_protocol ? { browser_protocol: pending.browser_protocol } : {}),
      ...(latest.config.rampCanaryOptIn === true && latest.config.mediaQualityOptIn === true &&
          current.candidate_protocol === "googlevideo-tcp" && pending.request_class === "media"
        ? { ramp_canary_opt_in: "1" } : {}),
      ...(pending.media_quality ? {
        media_quality: pending.media_quality.quality,
        media_sample_ms: String(pending.media_quality.sample_ms),
        media_progress_ms: String(pending.media_quality.progress_ms),
        media_stall_ms: String(pending.media_quality.stall_ms),
        media_dropped_frames: String(pending.media_quality.dropped_frames),
        media_total_frames: String(pending.media_quality.total_frames)
      } : {})
    });
    latest = await loadState();
    latest.events = latest.events.map(row => {
      if (row.id !== eventId) return row;
      const queue = Array.isArray(row.pending_results)
        ? row.pending_results
        : row.pending_result ? [row.pending_result] : [];
      const remaining = result.ok
        ? result.data.next_attempt?.attempt_id ? [] : queue.filter(item => item.id !== pending.id)
        : queue;
      const nextAttemptId = result.data.next_attempt?.attempt_id || row.attempt_id;
      const attemptChanged = nextAttemptId !== row.attempt_id;
      return {
        ...row,
        attempt_id: nextAttemptId,
        candidate_protocol: result.data.next_attempt?.candidate?.protocol || row.candidate_protocol || null,
        candidate_profile: result.data.next_attempt?.candidate?.profile_id || row.candidate_profile || null,
        attempt_expires_at: result.data.next_attempt?.expires_at || row.attempt_expires_at,
        router_status: result.data.next_attempt?.state || result.data.state || result.data.status || (result.ok ? status.data.state : result.status),
        router_reason: result.data.reason || row.router_reason || null,
        media_quality: result.data.media_quality || row.media_quality || null,
        ...(attemptChanged ? { media_quality_sampled: false, media_quality: null } : {}),
        pending_results: remaining,
        pending_result: remaining[0] || null
      };
    });
    await chrome.storage.local.set({ events: latest.events });
    const nextAttempt = result.data.next_attempt;
    if (result.ok && nextAttempt?.state === "WAIT_NEW_FLOW" && nextAttempt.retry_hint !== "observe_natural_flow" &&
        typeof nextAttempt.attempt_id === "string") {
      const retryEvent = latest.events.find(row => row && row.id === eventId);
      await retryFailedGetOnce(retryEvent, { ok: true, data: { state: nextAttempt.state, attempt_id: nextAttempt.attempt_id } });
    }
    return { ok: result.ok, state: result.data.state || result.data.status || status.data.state };
  }

  function queueSyncAttempt(eventId) {
    const previous = attemptSyncQueues.get(eventId) || Promise.resolve();
    const next = previous.catch(() => {}).then(() => syncAttempt(eventId));
    attemptSyncQueues.set(eventId, next);
    const cleanup = () => {
      if (attemptSyncQueues.get(eventId) === next) attemptSyncQueues.delete(eventId);
    };
    void next.then(cleanup, cleanup);
    return next;
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
        ...row, router_status: result.data.state || "CANCELLED", pending_result: null, pending_results: []
      } : row);
      await chrome.storage.local.set({ events: latest.events });
    }
    return { ok: result.ok, state: result.data.state || result.status };
  }

  async function getLearningStatus() {
    const state = await loadState();
    if (!state.config.router || !state.config.token) return { ok: false, status: "not_paired", data: {} };
    return postRouterForm(state.config, { schema_version: "1", action: "browser_learning_status" });
  }

  function findAttemptForCapture(state, host, tabId, requestClass, observedAt, resourceId = "") {
    const event = [...state.events].reverse().find(row => row && row.attempt_id &&
      (row.hostname === host || (row.candidate_protocol === "googlevideo-tcp" && row.candidate_profile === 2 &&
        typeof row.hostname === "string" && typeof host === "string" &&
        row.hostname.endsWith(".googlevideo.com") && host.endsWith(".googlevideo.com"))) && row.tab_id === tabId &&
      ["WAIT_NEW_FLOW", "FLOW_CONFIRMED", "WAIT_BROWSER_RESULT", "PROVISIONAL_SUCCESS"].includes(row.router_status));
    if (!event || (event.attempt_expires_at && observedAt > event.attempt_expires_at * 1000)) return null;
    if (requestClass !== "main_frame" && !(event.trigger === "critical_resource_repeated_failure" &&
        requestClass === event.request_class && typeof event.resource_identity === "string" && event.resource_identity === resourceId)) return null;
    return event;
  }

  async function browserProtocolForAttempt(state, host, tabId, requestClass, observedAt, url, resourceId = "") {
    const event = findAttemptForCapture(state, host, tabId, requestClass, observedAt, resourceId);
    if (!event || event.candidate_protocol !== "quic") return "";
    return readBrowserProtocol(tabId, url);
  }

  async function browserMediaQualityForAttempt(state, host, tabId, requestClass, observedAt, resourceId = "") {
    if (state.config.mediaQualityOptIn !== true || !host.endsWith(".googlevideo.com") ||
        !["media", "xmlhttprequest"].includes(requestClass)) return null;
    const event = findAttemptForCapture(state, host, tabId, requestClass, observedAt, resourceId);
    if (!event || event.candidate_protocol !== "googlevideo-tcp" || event.media_quality_sampled === true) return null;
    const attemptId = event.attempt_id;
    event.media_quality_sampled = true;
    await chrome.storage.local.set({ events: state.events });
    await queueSyncAttempt(event.id);
    const latest = await loadState();
    const current = latest.events.find(row => row && row.id === event.id && row.attempt_id === attemptId);
    if (!current || !["applied", "bypassed"].includes(current.ramp_treatment) ||
        !["FLOW_CONFIRMED", "WAIT_BROWSER_RESULT", "PROVISIONAL_SUCCESS"].includes(current.router_status)) return null;
    return readMediaQuality(tabId);
  }

  async function captureAttemptResult(state, host, tabId, result, requestClass, observedAt, browserIp, resourceId = "", browserProtocol = "", mediaQuality = null) {
    const event = findAttemptForCapture(state, host, tabId, requestClass, observedAt, resourceId);
    if (!event || (!safeRemoteIp(browserIp) && result !== "network_failure")) return false;
    const queue = Array.isArray(event.pending_results)
      ? event.pending_results
      : event.pending_result ? [event.pending_result] : [];
    if (queue.length >= 4) return false;
    queue.push({ id: opaqueId(), result, request_class: requestClass, browser_ip: safeRemoteIp(browserIp) ? browserIp : "", observed_at: observedAt,
      ...(browserProtocol ? { browser_protocol: browserProtocol } : {}),
      ...(mediaQuality ? { media_quality: mediaQuality } : {}) });
    event.pending_results = queue;
    event.pending_result = queue[0];
    await chrome.storage.local.set({ events: state.events });
    void queueSyncAttempt(event.id);
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
    if (details.method === "GET" && details.statusCode >= 200 && details.statusCode < 400 && details.statusCode !== 304 && details.fromCache !== true) {
      const state = await loadState();
      if (details.type === "main_frame") {
        const observedAt = Date.now();
        const protocol = await browserProtocolForAttempt(state, host, details.tabId, "main_frame", observedAt, details.url);
        await captureAttemptResult(state, host, details.tabId, "network_success", "main_frame", observedAt, details.ip, "", protocol);
      } else if (RESOURCE_TYPES.has(details.type)) {
        const identity = await resourceIdentity(details.url);
        const observedAt = Date.now();
        const mediaQuality = await browserMediaQualityForAttempt(state, host, details.tabId, details.type, observedAt, identity);
        const latest = await loadState();
        const protocol = await browserProtocolForAttempt(latest, host, details.tabId, details.type, observedAt, details.url, identity);
        await captureAttemptResult(latest, host, details.tabId, "network_success", details.type, observedAt, details.ip, identity, protocol, mediaQuality);
      }
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
    if (message && message.type === "z2r:get-learning-status") {
      void getLearningStatus().then(sendResponse).catch(() => sendResponse({ ok: false, status: "error", data: {} }));
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
      void queueSyncAttempt(message.eventId).then(sendResponse).catch(() => sendResponse({ ok: false, state: "error" }));
      return true;
    }
    if (message && message.type === "z2r:cancel-attempt" && typeof message.eventId === "string") {
      void cancelAttempt(message.eventId).then(sendResponse).catch(() => sendResponse({ ok: false, state: "error" }));
      return true;
    }
  });

  if (globalThis.__Z2R_BROWSER_TEST__) {
  globalThis.__Z2R_BROWSER_TEST__.api = { safeHost, failureClass, failureTransport, readBrowserProtocol, readMediaQuality, rememberFailure, reportFailure, retryFailedGetOnce, requestFix, requestCurrentPageFix, recordHttpResponse, captureAttemptResult, syncAttempt, queueSyncAttempt, cancelAttempt, getLearningStatus };
  }
})();
