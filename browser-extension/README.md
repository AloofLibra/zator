# Zator Browser Feedback (Beta)

This Manifest V3 extension is a browser-side sensor and manual retry control. It does not inspect page contents, cookies, request bodies, or successful browsing history. It never replays a request and currently does not reload tabs automatically.

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

This prototype reports eligible main-frame transport failures immediately and repeated critical script/XHR/media failures after the second occurrence in 30 seconds. A user can also press `Fix this site` on any supported current page without waiting for a particular network error. Strategy changes remain disabled until the separate browser API, scoped trial lifecycle, and production-flow evidence gates are implemented. The button sends an explicit user request and does not reload the tab or repeat its request.

The extension stores at most 64 sanitized recent events in trusted extension storage. It omits paths, query strings, tab IDs, client IPs, and successful visits from reports. Incognito is not monitored. Internal, local, and router hostnames are ignored. Certificate, DNS, offline, network-changed, cancellation, and HTTP response errors do not start an automatic trial; a user can still explicitly request help for a recent listed event.

## Permissions

- `webRequest`, `webNavigation`: observe failure metadata; no blocking listener is used.
- `storage`: keep bounded local events and the separate browser pairing token.
- `activeTab`: let the popup identify the selected tab without reading page content.
- Optional `<all_urls>` permission: explicitly granted by the user to observe eligible network errors on visited sites.
- Optional router-origin permission: granted only for the configured private LAN router address.

No production rollout or browser-store publication is implied by this source directory.
