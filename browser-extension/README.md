# Zator Browser Feedback (Beta)

This Manifest V3 extension is a browser-side sensor and retry control. It does not inspect cookies or request bodies and does not send successful browsing history. It never replays a request. After an eligible failed main-frame GET, it may perform one automatic reload for each server-issued `WAIT_NEW_FLOW` candidate, only while the tab remains on the same hostname. Retry IDs persist locally to prevent loops. A reload does not guarantee a new TCP or QUIC connection; the router must verify a new production flow before accepting an outcome.

For an active QUIC trial only, it may read `PerformanceResourceTiming.nextHopProtocol` for the exact matching response to distinguish observed H3 from observed TCP. It sends only `h3` or `tcp`, never the URL or timing entries. Missing cross-origin timing permission, multiple matching entries, or unsupported protocols remain unknown. This requires the extension's `scripting` permission and optional access to the target site.

## Load unpacked

1. Open `chrome://extensions` in Chromium and enable Developer mode.
2. Choose **Load unpacked** and select this `browser-extension` directory.
3. Open the extension's **Settings** page and grant site-error monitoring. This is a broad browser permission because the extension must observe failures before it knows the affected hostname. Only eligible failure metadata is retained or sent.
4. Pair with a router through its browser-specific pairing command, then enter the LAN address and browser token. Do not enter the Windows-agent token.

To create a separate extension archive and checksum from the reviewed allowlist, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\package-browser-extension.ps1
```

The output is written to `webui-src/dist/` and is not part of a router deployment archive.

The extension reports eligible main-frame transport/TLS/QUIC handshake failures immediately and repeated critical script/XHR/media failures after the second occurrence in 30 seconds. A user can also press `Fix this site` on any supported current page without waiting for a particular network error. In `AGENT_BETA`, Zator may start a short scoped trial only for a managed target and only when policy, manual-lock, transport, scope and cooldown checks allow it. After the router confirms `WAIT_NEW_FLOW`, the extension retries a failed main-frame GET once per server-issued candidate, only if that tab is still on the same hostname; it never automatically retries POST or subresource failures. Candidate advances require a confirmed new flow and a corresponding failed browser outcome. For a critical-resource trial, a later uncached success or transport failure is reported only when it matches the same resource class and a local hash of the same origin/path; the URL and hash never leave the browser. Retry IDs persist locally to prevent loops, and retries are skipped if the user navigated elsewhere. The manual button does not itself replay a request. Success or failure is assessed only after a new production flow proves the selected strategy; without that proof, the result is `NOT_TESTED`/`UNKNOWN`.

Browser pairing is separate from the Windows-agent token:

```sh
/opt/zator/tools/adaptive-browser-pair.sh create 192.168.1.42 mark:7
```

Shared Redis rankings are a second, independent opt-in and are disabled by default. To enable them, run `adaptive-browser-pair.sh rankings-on` on the router and confirm the typed prompt; `rankings-off` revokes this choice. When enabled, trial selection may request only provider/profile/protocol rankings and maps returned fingerprints to the router's current local catalog. It never sends the target hostname, destination IP, browser token, or result history. The stats host can see the router's public source IP. The extension Settings page reports the current consent state.

Uploading aggregate browser outcomes is a third, independent router-side opt-in and is disabled by default. It requires a separately issued browser-flow installation token; only after receiving one, enable it with `adaptive-browser-pair.sh stats-on`. Use `stats-status`, `stats-flush`, and `stats-off` to inspect, send, or revoke consent and erase the local queue/token. The uploader sends only bounded profile/protocol/fingerprint/outcome dimensions; it does not send target hostnames, destination IPs, URLs, the browser pairing token, or visit history. No browser-flow token is provisioned for this beta, so no browser outcomes have been uploaded.

The extension stores at most 64 sanitized recent events in trusted extension storage. It omits paths, query strings, tab IDs, client IPs, and successful visits from reports. Incognito is not monitored. Internal, local, and router hostnames are ignored. Certificate/client-certificate, DNS, offline, network-changed, no-route (`ERR_ADDRESS_UNREACHABLE`), cancellation, and HTTP response errors do not start an automatic trial; a user can still explicitly request help for a recent listed event.

## Permissions

- `webRequest`: observe failure metadata; no blocking listener is used. The extension uses the request's tab/frame/document IDs directly and does not request the separate `webNavigation` permission.
- `storage`: keep bounded local events and the separate browser pairing token.
- `activeTab`: let the popup identify the selected tab without reading page content.
- Optional `<all_urls>` permission: explicitly granted by the user to observe eligible network errors on visited sites.
- Optional router-origin permission: granted only for the configured private LAN router address.

No production rollout or browser-store publication is implied by this source directory.
