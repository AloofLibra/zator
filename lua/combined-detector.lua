-- Combined failure detector - extends standard detector with default page detection
-- Uses standard_failure_detector for RST/retransmission/redirect detection
-- Adds: HTTP status validation (any syntactically valid status proves transport success)
-- Adds: default page detection for HTTP (Apache/Nginx default pages)
-- Adds: DPI stub detection (fake 404 pages with wrong server names)
-- Adds: Block page detection in first 16KB

-- Lua 5.1 compatibility
if not bit32 then
    bit32 = {}
    function bit32.band(a, b)
        local result = 0
        local bitval = 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then
                result = result + bitval
            end
            bitval = bitval * 2
            a = math.floor(a / 2)
            b = math.floor(b / 2)
        end
        return result
    end
    function bit32.rshift(a, n)
        return math.floor(a / (2 ^ n))
    end
end

-- Fix misclassified payload types (e.g. Roblox detected as WireGuard by size)
-- WireGuard initiation: 148 bytes, first byte = 0x01
-- WireGuard response: 92 bytes, first byte = 0x02
-- WireGuard cookie: 64 bytes, first byte = 0x03
function fix_payload_type(desync)
    if not desync.dis.udp or not desync.dis.payload then
        return desync.l7payload
    end

    local payload = desync.dis.payload
    local l7 = desync.l7payload

    -- Check if classified as WireGuard but first byte doesn't match
    if l7 == "wireguard_initiation" and #payload == 148 then
        local first_byte = payload:byte(1)
        if first_byte ~= 0x01 then
            -- Not real WireGuard - probably Roblox or other game
            return "game_udp"
        end
    elseif l7 == "wireguard_response" and #payload == 92 then
        local first_byte = payload:byte(1)
        if first_byte ~= 0x02 then
            return "game_udp"
        end
    elseif l7 == "wireguard_cookie" and #payload == 64 then
        local first_byte = payload:byte(1)
        if first_byte ~= 0x03 then
            return "game_udp"
        end
    end

    return l7
end

-- Known default page markers (check in HTTP response body)
local DEFAULT_PAGE_MARKERS = {
    "apache2 ubuntu default",
    "apache2 debian default",
    "it works!",
    "welcome to nginx",
    "iis windows server",
    "test page for the apache",
    "index of /",
    "default web page",
    "<title>apache2",
    "<title>welcome to nginx"
}

-- Known DPI stub markers - fake servers that indicate DPI interception
-- These appear in Server: header or error page footer
local DPI_STUB_MARKERS = {
    "ov.google.com",        -- Russian ISP DPI stub
    "blocked.mgts.ru",      -- MGTS block page
    "warning.rt.ru",        -- Rostelecom block page
    "block.mts.ru",         -- MTS block page
    "zapret.mts.ru"         -- MTS block page
}

-- Known block page markers in 16KB (Russian ISP block pages)
local BLOCK_PAGE_MARKERS = {
    -- Russian ISP block pages
    "eais.rkn.gov.ru",
    "vigruzki.rkn.gov.ru",
    "blocklist.rkn.gov.ru",
    "reestr.rublacklist.net",
    "nap.rkn.gov.ru",
    "zapret-info.gov.ru",
    "blacklist.rkn.gov.ru",
    -- ISP specific block pages
    "rkn.megafon.ru",
    "blocked.beeline.ru",
    "block.beeline.ru",
    "blocked.tele2.ru",
    "restriction.tele2.ru",
    "blocked.yota.ru",
    "blocking.ttk.ru",
    "block.ttk.ru",
    "blocked.domru.ru",
    "block.domru.ru",
    "blocked.2kom.ru",
    "blocked.ugmk-telecom.ru",
    -- Generic block page markers
    "access denied",
    "access blocked",
    "blocked by",
    "blocked for",
    "prohibited by law",
    "restricted content",
    "content blocked",
    "website blocked",
    "resource blocked",
    "site blocked"
}

-- Detect default page markers in HTTP response payload
local function check_default_page(payload)
    if not payload or #payload < 50 then return false end

    -- Check entire payload (up to 2KB) for markers
    local check_len = math.min(#payload, 2048)
    local lower_payload = string.lower(string.sub(payload, 1, check_len))

    for _, marker in ipairs(DEFAULT_PAGE_MARKERS) do
        if string.find(lower_payload, marker, 1, true) then
            return true, marker
        end
    end

    return false
end

-- Detect DPI stub markers in HTTP response
local function check_dpi_stub(payload)
    if not payload or #payload < 50 then return false end

    local check_len = math.min(#payload, 2048)
    local lower_payload = string.lower(string.sub(payload, 1, check_len))

    for _, marker in ipairs(DPI_STUB_MARKERS) do
        if string.find(lower_payload, marker, 1, true) then
            return true, marker
        end
    end

    return false
end

-- Detect block page markers in first 16KB of response
local function check_block_page(payload)
    if not payload or #payload < 50 then return false end

    -- Check first 16KB for block page markers
    local check_len = math.min(#payload, 16384)
    local lower_payload = string.lower(string.sub(payload, 1, check_len))

    for _, marker in ipairs(BLOCK_PAGE_MARKERS) do
        if string.find(lower_payload, marker, 1, true) then
            return true, marker
        end
    end

    return false
end

-- Check HTTP/2 frame-level failures (GOAWAY / RST_STREAM with error)
-- We can't cheaply decode HPACK-compressed HEADERS frames in Lua to read a
-- ':status' pseudo-header, so this does NOT detect "HTTP/2 200 vs 404" the
-- way check_http_status() does for HTTP/1.x. But h2 responses never start
-- with the literal text "HTTP/1.1", so without this, an h2 (ALPN h2 over
-- TLS - the default for most modern HTTPS sites) connection got ZERO
-- benefit from the HTTP status/content checks below. Frame type + error
-- code needs no HPACK and still catches the two most common explicit h2
-- failure signals: server tearing down the connection (GOAWAY) or a
-- specific stream (RST_STREAM) with a non-zero error code.
-- HTTP/2 frame header (RFC 7540 4.1): 3 bytes length, 1 byte type,
-- 1 byte flags, 4 bytes stream id (top bit reserved) = 9 bytes total.
local H2_FRAME_HEADER_LEN = 9
local H2_FRAME_TYPE_RST_STREAM = 0x3
local H2_FRAME_TYPE_GOAWAY = 0x7

-- Read a 4-byte big-endian error code starting at absolute byte position
-- `pos` in payload. Returns nil (not 0) if any byte is out of bounds, so a
-- truncated buffer never gets silently coerced into error_code == 0 and
-- mistaken for "no error".
local function read_u32be(payload, pos)
    local b1, b2, b3, b4 = string.byte(payload, pos), string.byte(payload, pos + 1),
                           string.byte(payload, pos + 2), string.byte(payload, pos + 3)
    if not (b1 and b2 and b3 and b4) then return nil end
    return (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
end

local function check_http2_frame_failure(payload)
    if not payload or #payload < H2_FRAME_HEADER_LEN then return false, nil end

    local len = #payload
    local offset = 1

    for _ = 1, 8 do
        if offset + H2_FRAME_HEADER_LEN - 1 > len then break end

        local l1, l2, l3 = string.byte(payload, offset), string.byte(payload, offset + 1), string.byte(payload, offset + 2)
        local frame_len = l1 * 65536 + l2 * 256 + l3
        local frame_type = string.byte(payload, offset + 3)
        local frame_payload_start = offset + H2_FRAME_HEADER_LEN

        -- GOAWAY payload: 4 bytes last-stream-id, then 4 bytes error code.
        -- Error code starts 4 bytes into the frame payload, so it needs
        -- bytes [frame_payload_start+4 .. frame_payload_start+7] present.
        -- frame_len >= 8 guards against a malformed/truncated GOAWAY that
        -- declares a shorter payload than 8 bytes - without this check, a
        -- short frame_len followed by another frame right after it would
        -- have that next frame's header bytes misread as this GOAWAY's
        -- error code (frame_type==0x3 check below is correctly guarded by
        -- frame_len==4 already; this makes the GOAWAY check consistent).
        if frame_type == H2_FRAME_TYPE_GOAWAY and frame_len >= 8 and frame_payload_start + 7 <= len then
            local error_code = read_u32be(payload, frame_payload_start + 4)
            if error_code and error_code ~= 0 then
                return true, "GOAWAY", error_code
            end
        end

        -- RST_STREAM payload: exactly 4 bytes, the error code.
        if frame_type == H2_FRAME_TYPE_RST_STREAM and frame_len == 4 and frame_payload_start + 3 <= len then
            local error_code = read_u32be(payload, frame_payload_start)
            if error_code and error_code ~= 0 then
                return true, "RST_STREAM", error_code
            end
        end

        offset = frame_payload_start + frame_len
    end

    return false, nil
end

-- A syntactically valid HTTP response proves TCP/TLS transport. Status codes
-- are application semantics, not desync failures (including 3xx/4xx/5xx).
local function check_http_status(payload)
    if not payload or #payload < 12 then return false, nil end

    -- Parse HTTP response: HTTP/1.x NNN
    local http_prefix = string.sub(payload, 1, 8)
    if http_prefix ~= "HTTP/1.1" and http_prefix ~= "HTTP/1.0" then
        return false, nil  -- Not HTTP response
    end

    -- Extract status code (position 10-12)
    local status_str = string.match(payload, "^HTTP/1%.[01] (%d%d%d)")
    if not status_str then
        return false, nil
    end

    local status_code = tonumber(status_str)
    if not status_code then
        return false, nil
    end

    if status_code < 100 or status_code > 599 then return false, nil end
    return false, status_code
end

-- ==================== UDP Protocol Validation ====================

-- Check STUN Binding Response
-- Valid STUN response: first 2 bytes = 0x0101 (Binding Success Response)
-- Magic cookie at bytes 5-8 = 0x2112A442
local function check_stun_response(payload)
    if not payload or #payload < 20 then return false, nil end

    local b1 = string.byte(payload, 1)
    local b2 = string.byte(payload, 2)

    -- STUN Binding Success Response = 0x0101
    if b1 == 0x01 and b2 == 0x01 then
        -- Verify magic cookie (bytes 5-8)
        if #payload >= 8 then
            local m1 = string.byte(payload, 5)
            local m2 = string.byte(payload, 6)
            local m3 = string.byte(payload, 7)
            local m4 = string.byte(payload, 8)
            if m1 == 0x21 and m2 == 0x12 and m3 == 0xA4 and m4 == 0x42 then
                return true, "STUN_SUCCESS"
            end
        end
        return true, "STUN_RESPONSE"
    end

    -- STUN Error Response = 0x0111
    if b1 == 0x01 and b2 == 0x11 then
        return false, "STUN_ERROR"
    end

    return false, nil
end

-- Check QUIC Initial Response
-- QUIC long header: first bit = 1 (0x80-0xFF), then form + version
-- Valid response usually has same version as request
local function check_quic_response(payload)
    if not payload or #payload < 5 then return false, nil end

    local first_byte = string.byte(payload, 1)

    -- Long header form (bit 7 = 1)
    if first_byte >= 0x80 then
        -- Get packet type (bits 4-5 for QUIC v1)
        local packet_type = bit32.band(bit32.rshift(first_byte, 4), 0x03)

        -- 0 = Initial, 1 = 0-RTT, 2 = Handshake, 3 = Retry
        if packet_type == 0 or packet_type == 2 then
            -- Check version (bytes 2-5)
            local v1 = string.byte(payload, 2)
            local v2 = string.byte(payload, 3)
            local v3 = string.byte(payload, 4)
            local v4 = string.byte(payload, 5)

            -- QUIC v1 = 0x00000001, QUIC v2 = 0x6b3343cf
            if (v1 == 0x00 and v2 == 0x00 and v3 == 0x00 and v4 == 0x01) or
               (v1 == 0x6b and v2 == 0x33 and v3 == 0x43 and v4 == 0xcf) then
                return true, "QUIC_VALID"
            end

            -- Version negotiation (version = 0)
            if v1 == 0x00 and v2 == 0x00 and v3 == 0x00 and v4 == 0x00 then
                return false, "QUIC_VERSION_NEG"  -- Not a success, need retry
            end
        end

        return true, "QUIC_LONG_HEADER"
    end

    -- Short header (bit 7 = 0) - means handshake completed
    if first_byte < 0x80 and first_byte >= 0x40 then
        return true, "QUIC_SHORT_HEADER"
    end

    return false, nil
end

-- Check Discord voice response
-- Discord IP Discovery response: starts with specific pattern
local function check_discord_response(payload)
    if not payload or #payload < 8 then return false, nil end

    -- Discord IP Discovery response format:
    -- 2 bytes type (0x0002 = response), 2 bytes length, 4 bytes SSRC
    local b1 = string.byte(payload, 1)
    local b2 = string.byte(payload, 2)

    -- Type 0x0002 = IP Discovery Response
    if b1 == 0x00 and b2 == 0x02 then
        return true, "DISCORD_IP_DISCOVERY"
    end

    -- Check if it's RTP (voice data) - indicates success
    -- RTP version 2: first byte & 0xC0 == 0x80
    if bit32.band(b1, 0xC0) == 0x80 then
        local payload_type = bit32.band(string.byte(payload, 2), 0x7F)
        -- Common audio payload types: 0 (PCMU), 8 (PCMA), 96-127 (dynamic)
        if payload_type == 0 or payload_type == 8 or payload_type >= 96 then
            return true, "RTP_AUDIO"
        end
    end

    return false, nil
end

-- Check for UDP "black hole" indicators
-- Some DPIs just drop UDP or send ICMP unreachable (which we can't see here)
-- But we can detect suspiciously small/malformed responses
local function check_udp_anomaly(payload)
    if not payload then return true, "NO_PAYLOAD" end

    -- Suspiciously small response (< 4 bytes usually invalid)
    if #payload < 4 then
        return true, "TOO_SMALL"
    end

    -- All zeros payload (some DPI sends this)
    local all_zeros = true
    for i = 1, math.min(#payload, 20) do
        if string.byte(payload, i) ~= 0 then
            all_zeros = false
            break
        end
    end
    if all_zeros and #payload > 4 then
        return true, "ALL_ZEROS"
    end

    return false, nil
end

-- ==================== TLS Checks ====================

-- Check TLS Alert - indicates TLS handshake failure
-- TLS Alert record: ContentType=0x15, Version, Length, AlertLevel, AlertDescription
--
-- A single incoming packet can contain more than one TLS record (e.g. a
-- trailing ChangeCipherSpec followed by an Alert, or several coalesced
-- records after Nagle/segmentation). Checking only byte 1 misses an Alert
-- that isn't the very first record in the buffer, so we walk the record
-- chain using the standard 5-byte TLS record header (type, ver_major,
-- ver_minor, len_hi, len_lo) and inspect every record we can fully see.
local function check_tls_alert(payload)
    if not payload or #payload < 7 then return false, nil end

    local len = #payload
    local offset = 1

    -- Cap iterations defensively; a real TLS buffer won't have more than a
    -- handful of coalesced records.
    for _ = 1, 16 do
        if offset + 4 > len then break end

        local content_type = string.byte(payload, offset)
        local version_major = string.byte(payload, offset + 1)
        local version_minor = string.byte(payload, offset + 2)
        local len_hi = string.byte(payload, offset + 3)
        local len_lo = string.byte(payload, offset + 4)

        -- Sanity check: must look like a real TLS record header, otherwise
        -- stop walking (we've likely run into non-TLS bytes / app data we
        -- can't parse further, e.g. already-encrypted application data).
        if version_major ~= 0x03 or version_minor < 0x00 or version_minor > 0x04 then
            break
        end

        local record_len = len_hi * 256 + len_lo

        if content_type == 0x15 then
            -- Alert record found. Grab level/description if this record's
            -- body is actually present in our buffer.
            if offset + 6 <= len then
                local alert_level = string.byte(payload, offset + 5)
                local alert_desc = string.byte(payload, offset + 6)
                return true, alert_level, alert_desc
            end
            return true, nil, nil
        end

        -- Not an alert - only known content types are worth walking past
        -- (change_cipher_spec=20, alert=21, handshake=22, application_data=23).
        if content_type < 20 or content_type > 23 then
            break
        end

        offset = offset + 5 + record_len
    end

    return false, nil
end

-- ==================== Shared stall-baseline tracking ====================
-- Both this file's connection-stall check and silent-drop-detector.lua's
-- silent_drop_detector need the same "measure since last incoming progress"
-- algorithm. It lives here (silent-drop-detector.lua already documents that
-- it loads after combined-detector.lua) so both call one implementation
-- instead of maintaining two hand-copied versions that can quietly drift
-- apart. crec fields are still stored under the same names either caller
-- used before this refactor - only the *implementation* is now shared.
--
-- base_in_field/base_out_field: crec field names for this tracker's baseline
-- out_count/in_count: current absolute counters (never reset, only grow)
-- Returns out_since: outgoing-count delta relative to the last time in_count
-- grew (i.e. "how much have we sent since we last heard anything back").
--
-- NOTE: this used to also return in_since = in_count - baseline_in, intended
-- to let callers tolerate "a little" incoming progress (in_since <= some
-- threshold) rather than requiring exactly zero. That value is mathematically
-- always 0: the baseline is snapped to exactly match in_count the instant
-- in_count grows (see the update below), so by construction in_since is 0
-- immediately after every update, on every call, regardless of in_count's
-- history. Both call sites' "in_since <= tcp_in" / "in_since == 0" checks
-- were therefore tautologies - always true - and the tcp_in/threshold
-- parameter they appeared to gate on had no actual effect. Removed rather
-- than kept as dead code that looks like a real tolerance check.
function stall_baseline_update(crec, base_in_field, base_out_field, out_count, in_count)
    if not crec[base_in_field] or in_count > crec[base_in_field] then
        crec[base_in_field] = in_count
        crec[base_out_field] = out_count
    end
    return out_count - (crec[base_out_field] or 0)
end

-- Rate-limits re-firing of a stall/silent-drop detector: fires at most once
-- per `threshold` additional outgoing packets, so a persistent stall doesn't
-- report FAILURE on every single packet once past the threshold.
-- last_fire_field: crec field name tracking the out_count at last fire.
function stall_baseline_should_refire(crec, last_fire_field, out_count, threshold)
    local last = crec[last_fire_field] or 0
    if out_count >= last + threshold then
        crec[last_fire_field] = out_count
        return true
    end
    return false
end

-- ==================== Connection Stall Detection ====================
-- For TCP: if we sent multiple packets but got no response since the last
-- bit of incoming progress, it's likely blocked. Catches "silent drop" DPI
-- that doesn't send RST.
--
-- NOTE: this used to require tcp_in_count == 0, which meant the very first
-- incoming data packet permanently disarmed this check for the rest of the
-- connection - a stall that begins later (server replies a little, then DPI
-- cuts the connection) was never caught. We now track a baseline snapshot
-- taken at the last point incoming data increased, so a stall is measured
-- relative to "since we last heard back", and can re-trigger if the
-- connection stalls again after resuming.
local function check_connection_stall(desync, crec)
    if desync.dis.tcp and desync.outgoing and desync.track then
        -- TCP soft success proves that the peer made substantial progress.
        -- Do not turn normal post-response traffic into a synthetic timeout;
        -- hard failures are still checked by the surrounding detector.
        if not crec.provisional_success then
            -- Track outgoing packets with payload (actual data, not just ACKs)
            if desync.dis.payload and #desync.dis.payload > 0 then
                crec.tcp_out_with_payload = (crec.tcp_out_with_payload or 0) + 1
            end

            local stall_out_threshold = tonumber(desync.arg.stall_out) or 3
            local tcp_in_count = crec.tcp_in_count or 0
            local out_with_payload = crec.tcp_out_with_payload or 0

            local out_since = stall_baseline_update(
                crec, "stall_base_in", "stall_base_out", out_with_payload, tcp_in_count)

            if out_since >= stall_out_threshold then
                if stall_baseline_should_refire(crec, "last_stall_out", out_with_payload, stall_out_threshold) then
                    DLOG("combined_failure_detector: CONNECTION STALL out=" .. out_with_payload ..
                         " in=" .. tcp_in_count .. " (since_progress out=" .. out_since .. ", failure)")
                    return true
                end
            end
        end
    end

    -- Track incoming packets for stall detection
    if desync.dis.tcp and not desync.outgoing and desync.track then
        if desync.dis.payload and #desync.dis.payload > 0 then
            crec.tcp_in_count = (crec.tcp_in_count or 0) + 1
        end
    end

    return false
end

-- ==================== Extended RST Detection ====================
-- Detect RST even beyond standard inseq range (for TLS handshake failures)
-- DPI often sends RST after Client Hello, which may have seq > inseq
local function check_extended_rst(desync, crec)
    if desync.dis.tcp and not desync.outgoing and desync.track then
        if bitand(desync.dis.tcp.th_flags, TH_RST) ~= 0 then
            local seq = pos_get(desync, 's')
            -- Extended range: up to 16KB (covers most TLS handshakes)
            local extended_inseq = 0x4000
            if seq >= 1 and seq <= extended_inseq and not crec.rst_detected then
                crec.rst_detected = true
                DLOG("combined_failure_detector: RST detected at seq=" .. seq .. " (extended range)")
                return true
            end
        end
    end
    return false
end

-- A client RST after receiving TCP data can be the browser abort path for a
-- broken TLS handshake. This deliberately ignores FIN and any already
-- validated connection, so normal successful connection close stays benign.
local function check_early_client_tls_abort(desync, crec)
    if not desync.dis.tcp or not desync.outgoing or not desync.track then return false end
    if crec.validated_success or crec.client_tls_abort_recorded then return false end
    if (crec.tcp_in_count or 0) < 1 then return false end

    if bitand(desync.dis.tcp.th_flags or 0, TH_RST) ~= 0 then
        crec.client_tls_abort_recorded = true
        DLOG("combined_failure_detector: early client RST after TCP progress (failure)")
        return true
    end
    return false
end

-- ==================== TCP response content checks ====================
-- Runs once per incoming payload: TLS Alert, HTTP/2 frame errors, HTTP/1.x
-- status code, then (only once enough bytes are buffered) the content-marker
-- checks (DPI stub / block page / default page). Each sub-check is guarded
-- by its own "checked once" crec flag so repeat calls on the same connection
-- don't re-log or re-fire after the first verdict.
local function check_tcp_response_content_failure(payload, crec)
    -- Check TLS Alert - indicates TLS handshake failure (DPI interference)
    if not crec.tls_alert_checked then
        local is_alert, alert_level, alert_desc = check_tls_alert(payload)
        if is_alert then
            crec.tls_alert_checked = true
            local level_str = alert_level == 2 and "FATAL" or (alert_level == 1 and "WARNING" or "UNKNOWN")
            DLOG("combined_failure_detector: TLS ALERT " .. level_str .. " desc=" .. tostring(alert_desc) .. " (failure)")
            return true
        end
    end

    -- Need at least 12 bytes for HTTP status check
    if #payload < 12 then
        return false
    end

    -- Check HTTP/2 frame-level failures (GOAWAY / RST_STREAM with error code)
    -- HTTP/2 responses never match the HTTP/1.x "HTTP/1.1 ..." text check
    -- below, so without this, h2 connections (most modern HTTPS traffic)
    -- got zero benefit from any of the status/content checks in this
    -- function. This doesn't replace the HTTP/1.x check - it runs in
    -- addition, since a given payload will only ever match one or the other.
    if not crec.http2_checked then
        local is_h2_failure, h2_kind, h2_err = check_http2_frame_failure(payload)
        if is_h2_failure then
            crec.http2_checked = true
            DLOG("combined_failure_detector: HTTP/2 " .. h2_kind .. " error=" .. tostring(h2_err) .. " (failure)")
            return true
        end
    end

    -- Any valid HTTP status is transport success; block-page checks below
    -- still take priority on the same payload.
    if not crec.http_status_checked then
        local is_failure, status_code = check_http_status(payload)
        if status_code then
            crec.http_status_checked = true
            if is_failure then
                DLOG("combined_failure_detector: HTTP STATUS " .. status_code .. " (failure)")
                return true
            else
                DLOG("combined_failure_detector: HTTP STATUS " .. status_code .. " (transport ok)")
            end
        end
    end

    -- Need at least 50 bytes for content checks
    if #payload < 50 then
        return false
    end

    -- Check for DPI stub markers (fake servers like ov.google.com)
    -- This catches 404/other responses from DPI that masquerade as legitimate servers
    if not crec.dpi_stub_found then
        local is_stub, marker = check_dpi_stub(payload)
        if is_stub then
            crec.dpi_stub_found = true
            DLOG("combined_failure_detector: DPI STUB detected (marker: " .. marker .. ")")
            return true
        end
    end

    -- Check for block page markers in first 16KB
    if not crec.block_page_found then
        local is_block, marker = check_block_page(payload)
        if is_block then
            crec.block_page_found = true
            DLOG("combined_failure_detector: BLOCK PAGE detected (marker: " .. marker .. ")")
            return true
        end
    end

    -- Check for default page content in HTTP response
    -- Only mark failure once per connection to avoid spam
    if not crec.default_page_found then
        local is_default, marker = check_default_page(payload)
        if is_default then
            crec.default_page_found = true
            DLOG("combined_failure_detector: DEFAULT PAGE detected (marker: " .. marker .. ")")
            return true
        end
    end

    return false
end

-- Combined failure detector
-- Calls standard_failure_detector first, then adds HTTP/TLS status and content checks
-- Also detects connection stalls (no response after N outgoing packets)
function combined_failure_detector(desync, crec)
    if crec.nocheck then return false end

    -- First, call standard failure detector for RST/retrans/redirect
    if standard_failure_detector(desync, crec) then
        return true
    end

    if check_early_client_tls_abort(desync, crec) then
        return true
    end

    if check_connection_stall(desync, crec) then
        return true
    end

    if check_extended_rst(desync, crec) then
        return true
    end

    -- Additional checks for responses only (incoming packets)
    -- We only check incoming responses, NOT outgoing requests
    if not desync.dis.tcp or not desync.track then
        return false
    end

    -- Only check incoming (response) packets
    if desync.outgoing then
        return false
    end

    local payload = desync.dis.payload
    if not payload or #payload < 7 then
        return false
    end

    return check_tcp_response_content_failure(payload, crec)
end

-- ==================== TCP success/failure content checks ====================
-- Returns nil ("no verdict yet - keep checking") or a decided true/false.
-- Order matters: TLS Alert / HTTP2 / HTTP status / content markers are
-- checked before the "soft success" byte/packet thresholds, so an explicit
-- error signal always wins over merely "we got some bytes back".
local function check_tcp_success(desync, crec)
    if desync.outgoing or not desync.dis.tcp or not desync.track then
        return nil
    end

    local payload = desync.dis.payload

    -- Check TLS Alert FIRST - if we get TLS Alert, this is NOT a success
    if payload and #payload >= 7 then
        local is_alert, alert_level, alert_desc = check_tls_alert(payload)
        if is_alert then
            crec.tls_alert_detected = true
            local level_str = alert_level == 2 and "FATAL" or (alert_level == 1 and "WARNING" or "UNKNOWN")
            DLOG("combined_success_detector: TLS ALERT " .. level_str .. " desc=" .. tostring(alert_desc) .. " - NOT SUCCESS")
            return false
        end
    end

    -- Check HTTP/2 frame-level failures - if GOAWAY/RST_STREAM with
    -- error, this is NOT a success (mirrors the HTTP/1.x check below,
    -- but for h2 responses which never match "HTTP/1.1 ..." text)
    if payload and #payload >= 9 then
        local is_h2_failure, h2_kind, h2_err = check_http2_frame_failure(payload)
        if is_h2_failure then
            crec.http2_failure_detected = true
            DLOG("combined_success_detector: HTTP/2 " .. h2_kind .. " error=" .. tostring(h2_err) .. " - NOT SUCCESS")
            return false
        end
    end

    -- Check for DPI stub markers - if found, NOT a success
    if payload and #payload >= 50 then
        local is_stub, marker = check_dpi_stub(payload)
        if is_stub then
            crec.dpi_stub_detected = true
            DLOG("combined_success_detector: DPI STUB (" .. marker .. ") - NOT SUCCESS")
            return false
        end

        local is_block, block_marker = check_block_page(payload)
        if is_block then
            crec.block_page_detected = true
            DLOG("combined_success_detector: BLOCK PAGE (" .. block_marker .. ") - NOT SUCCESS")
            return false
        end
    end

    -- A valid HTTP response is a validated transport success, after the
    -- content checks above have ruled out known DPI/block responses.
    if payload and #payload >= 12 then
        local _, status_code = check_http_status(payload)
        if status_code then
            crec.http_status_validated = true
            crec.validated_success = true
            DLOG("combined_success_detector: HTTP STATUS " .. status_code .. " - SUCCESS")
            return true
        end
    end

    -- Soft success: prefer bytes threshold, fallback to packet count
    if payload and #payload > 0 then
        local in_threshold = tonumber(desync.arg.soft_success_in) or 3
        local bytes_threshold = tonumber(desync.arg.soft_success_bytes)
        if bytes_threshold == nil then bytes_threshold = 65536 end

        crec.tcp_soft_in_count = (crec.tcp_soft_in_count or 0) + 1
        crec.tcp_soft_in_bytes = (crec.tcp_soft_in_bytes or 0) + #payload

        if bytes_threshold > 0 and crec.tcp_soft_in_bytes >= bytes_threshold then
            DLOG("combined_success_detector: TCP SOFT SUCCESS bytes=" .. crec.tcp_soft_in_bytes)
            -- TCP progress alone is not terminal: keep failure detectors active
            -- for a later stall, RST, or block response.
            if not crec.provisional_success then
                crec.provisional_success = true
                return true
            end
            return nil
        end

        if in_threshold > 0 and crec.tcp_soft_in_count >= in_threshold then
            DLOG("combined_success_detector: TCP SOFT SUCCESS in=" .. crec.tcp_soft_in_count)
            if not crec.provisional_success then
                crec.provisional_success = true
                return true
            end
            return nil
        end
    end

    return nil
end

-- ==================== UDP success/failure content checks ====================
-- Returns nil ("no verdict yet") or a decided true/false, same convention
-- as check_tcp_success above.
local function check_udp_success(desync, crec)
    if desync.outgoing or not desync.dis.udp then
        return nil
    end

    local payload = desync.dis.payload

    -- Check for UDP anomalies first
    if not crec.udp_anomaly_checked then
        local is_anomaly, anomaly_type = check_udp_anomaly(payload)
        if is_anomaly then
            crec.udp_anomaly_checked = true
            DLOG("combined_success_detector: UDP ANOMALY (" .. tostring(anomaly_type) .. ") - NOT SUCCESS")
            return false
        end
    end

    -- Try to validate protocol-specific response
    if payload and #payload >= 8 and not crec.udp_protocol_validated then
        -- Check STUN response
        local is_stun, stun_type = check_stun_response(payload)
        if is_stun then
            crec.udp_protocol_validated = true
            crec.validated_success = true
            DLOG("combined_success_detector: STUN VALID (" .. tostring(stun_type) .. ") - SUCCESS")
            crec.nocheck = true
            return true
        elseif stun_type == "STUN_ERROR" then
            crec.udp_protocol_validated = true
            DLOG("combined_success_detector: STUN ERROR - NOT SUCCESS")
            return false
        end

        -- Check QUIC response
        local is_quic, quic_type = check_quic_response(payload)
        if is_quic then
            crec.udp_protocol_validated = true
            crec.validated_success = true
            DLOG("combined_success_detector: QUIC VALID (" .. tostring(quic_type) .. ") - SUCCESS")
            crec.nocheck = true
            return true
        elseif quic_type == "QUIC_VERSION_NEG" then
            -- Version negotiation is not a success
            crec.udp_protocol_validated = true
            DLOG("combined_success_detector: QUIC VERSION_NEG - NOT SUCCESS")
            return false
        end

        -- Check Discord response
        local is_discord, discord_type = check_discord_response(payload)
        if is_discord then
            crec.udp_protocol_validated = true
            crec.validated_success = true
            DLOG("combined_success_detector: DISCORD VALID (" .. tostring(discord_type) .. ") - SUCCESS")
            crec.nocheck = true
            return true
        end
    end

    return nil
end

-- Combined success detector
-- FIRST checks for failures (TLS Alert, HTTP errors, block pages)
-- For UDP: validates protocol-specific responses (STUN, QUIC, Discord)
-- ONLY then delegates to standard_success_detector
-- This prevents marking connections as successful when TLS Alert or other errors occur
function combined_success_detector(desync, crec)
    if crec.nocheck then return false end

    local tcp_verdict = check_tcp_success(desync, crec)
    if tcp_verdict ~= nil then return tcp_verdict end

    local udp_verdict = check_udp_success(desync, crec)
    if udp_verdict ~= nil then return udp_verdict end

    -- No failure indicators found - delegate to standard success detector.
    -- This can promote an earlier soft TCP result without adding another test.
    local is_success = standard_success_detector(desync, crec)
    if is_success then
        crec.validated_success = true
    end
    return is_success
end

-- ==================== UDP-Specific Detectors ====================
-- These solve the problem of:
-- 1. Standard detector only checks on outgoing packets
-- 2. Each IP = new key (Discord/Telegram use many servers)

-- Known service IP ranges (from ipset files)
-- Maps /16 subnet to service domain (for preload matching)
-- Format: ["o1.o2"] = "domain.tld"
local KNOWN_SERVICE_SUBNETS = {
    -- Roblox (from ipset-roblox.txt)
    ["18.165"] = "roblox.com",
    ["23.43"] = "roblox.com",
    ["23.173"] = "roblox.com",
    ["103.140"] = "roblox.com",
    ["103.142"] = "roblox.com",
    ["108.156"] = "roblox.com",
    ["128.116"] = "roblox.com",
    ["141.193"] = "roblox.com",
    ["185.105"] = "roblox.com",
    ["204.9"] = "roblox.com",
    ["204.13"] = "roblox.com",
    ["205.201"] = "roblox.com",
    ["212.188"] = "roblox.com",

    -- Discord (from ipset-discord.txt - main ranges)
    ["34.0"] = "discord.com",
    ["34.1"] = "discord.com",
    ["35.207"] = "discord.com",
    ["35.212"] = "discord.com",
    ["35.213"] = "discord.com",
    ["35.214"] = "discord.com",
    ["35.215"] = "discord.com",
    ["35.217"] = "discord.com",
    ["35.219"] = "discord.com",
    ["66.22"] = "discord.com",
    ["138.128"] = "discord.com",

    -- Telegram (from ipset-telegram.txt)
    ["91.105"] = "telegram.org",
    ["91.108"] = "telegram.org",
    ["149.154"] = "telegram.org",
    ["185.76"] = "telegram.org",

    -- League of Legends (from ipset-lol-*.txt)
    ["104.160"] = "leagueoflegends.com",

    -- WhatsApp (from ipset-whatsapp.txt - main ranges)
    ["157.240"] = "whatsapp.com",
    ["163.70"] = "whatsapp.com",
    ["179.60"] = "whatsapp.com",
    ["185.60"] = "whatsapp.com",
    ["31.13"] = "whatsapp.com",
    ["102.132"] = "whatsapp.com",

    -- Google STUN/TURN
    ["64.233"] = "google.com",
    ["74.125"] = "google.com",
    ["142.250"] = "google.com",
    ["142.251"] = "google.com",
    ["173.194"] = "google.com",
    ["209.85"] = "google.com",

    -- Cloudflare
    ["104.16"] = "cloudflare.com",
    ["104.17"] = "cloudflare.com",
    ["104.18"] = "cloudflare.com",
    ["104.21"] = "cloudflare.com",
    ["162.159"] = "cloudflare.com",
    ["172.64"] = "cloudflare.com",
    ["172.65"] = "cloudflare.com",
    ["172.66"] = "cloudflare.com",
    ["172.67"] = "cloudflare.com",
    ["188.114"] = "cloudflare.com",
}

-- Get service name by IP (returns nil if unknown)
local function get_service_by_ip(ip)
    if not ip then return nil end
    local o1, o2 = ip:match("^(%d+)%.(%d+)%.")
    if o1 and o2 then
        return KNOWN_SERVICE_SUBNETS[o1 .. "." .. o2]
    end
    return nil
end

-- Check if IP is local/private (should not be processed)
local function is_local_ip(ip)
    if not ip then return true end
    local o1 = tonumber(ip:match("^(%d+)%."))
    if not o1 then return true end
    -- 10.x.x.x, 127.x.x.x, 192.168.x.x, 172.16-31.x.x, 169.254.x.x
    if o1 == 10 or o1 == 127 then return true end
    if o1 == 192 then
        local o2 = tonumber(ip:match("^%d+%.(%d+)%."))
        if o2 == 168 then return true end
    end
    if o1 == 172 then
        local o2 = tonumber(ip:match("^%d+%.(%d+)%."))
        if o2 and o2 >= 16 and o2 <= 31 then return true end
    end
    if o1 == 169 then
        local o2 = tonumber(ip:match("^%d+%.(%d+)%."))
        if o2 == 254 then return true end
    end
    return false
end

-- UDP hostkey generator - groups by protocol and service
-- Uses desync.l7proto (set by C code via packet analysis) NOT ports
-- l7proto values: "quic", "stun", "discord", "wireguard", "dht", "unknown"
function udp_global_hostkey(desync)
    -- Skip local IPs - they don't need bypass
    local ip = host_ip(desync)
    if is_local_ip(ip) then
        return nil  -- Return nil to skip processing
    end

    -- Get protocol detected by C code (Magic Cookie for STUN, long header for QUIC, etc.)
    local l7proto = desync.l7proto or "unknown"
    DLOG("udp_global_hostkey: ip=" .. (ip or "nil") .. " l7proto=" .. l7proto)

    -- QUIC - detected by long header (byte[0] & 0xC0 == 0xC0)
    -- Use hostname if available (extracted from ClientHello)
    if l7proto == "quic" then
        local hostname = desync.track and desync.track.hostname
        if hostname and #hostname > 0 then
            -- Use NLD-cut hostname for QUIC
            local nld = desync.arg.nld and tonumber(desync.arg.nld) or 2
            local cut = dissect_nld(hostname, nld)
            if cut then
                return cut  -- Just hostname, no prefix needed
            end
            return hostname
        end
        -- QUIC without hostname - use service by IP or generic
        local service = get_service_by_ip(ip)
        if service then
            return slm_normalize_hostkey(service)
        end
        return "quic"  -- Generic QUIC (lowercase for consistency)
    end

    -- STUN - detected by Magic Cookie 0x2112A442 at bytes 4-7
    -- All STUN servers are interchangeable, use global key
    if l7proto == "stun" then
        -- Check if known service (Google STUN, Telegram, etc.)
        local service = get_service_by_ip(ip)
        if service then
            return slm_normalize_hostkey(service .. " stun")
        end
        return "stun"  -- Generic STUN (lowercase for consistency)
    end

    -- Discord - detected by IP Discovery packet format
    if l7proto == "discord" then
        return "discord voice"  -- Lowercase for consistency
    end

    -- WireGuard - detected by handshake format
    if l7proto == "wireguard" then
        return "wireguard"  -- Lowercase for consistency
    end

    -- DHT (BitTorrent) - detected by packet format
    if l7proto == "dht" then
        return "dht"  -- Lowercase for consistency
    end

    -- Unknown UDP protocol - use service by IP or /16 subnet
    if ip then
        -- Check if this is a known service
        local service = get_service_by_ip(ip)
        if service then
            return slm_normalize_hostkey(service)
        end

        -- Unknown service: use /16 subnet (already lowercase)
        local o1, o2 = ip:match("^(%d+)%.(%d+)%.")
        if o1 and o2 then
            return string.format("udp %s.%s.0.0", o1, o2)
        end
    end

    -- Fallback: use full IP (lowercase prefix)
    return ip or "udp unknown"
end

-- Aggressive UDP failure detector
-- Triggers failure much faster than standard detector
-- Key insight: if we sent packets and got nothing back, it's likely blocked
function udp_aggressive_failure_detector(desync, crec)
    if crec.nocheck then return false end

    -- First check standard failures (RST, etc)
    if standard_failure_detector(desync, crec) then
        return true
    end

    if not desync.dis.udp then
        return false
    end

    -- Track incoming packets independently of whatever success detector
    -- this failure detector happens to be paired with (it used to rely on
    -- udp_protocol_success_detector incrementing the same crec field as a
    -- side effect - if configured with a different success_detector, that
    -- never happened and in_count below was always 0, misclassifying every
    -- connection with real incoming traffic as a failure).
    if not desync.outgoing then
        crec.udp_in_count = (crec.udp_in_count or 0) + 1
        return false
    end

    -- Get packet counts
    local out_count = pos_get(desync, 'n') or 0  -- outgoing packet number
    local in_count = crec.udp_in_count or 0

    -- Aggressive threshold: 2 outgoing with 0 incoming = failure
    -- This is much faster than standard udp_out=5
    local threshold_out = tonumber(desync.arg.udp_fail_out) or 2
    local threshold_in = tonumber(desync.arg.udp_fail_in) or 0

    if out_count >= threshold_out and in_count <= threshold_in then
        DLOG("udp_aggressive_failure_detector: FAIL out=" .. out_count .. ">=" .. threshold_out .. " in=" .. in_count .. "<=" .. threshold_in)
        return true
    end

    return false
end

-- UDP success detector - immediate success on valid protocol response
function udp_protocol_success_detector(desync, crec)
    if crec.nocheck then return false end

    -- Only check incoming packets
    if desync.outgoing or not desync.dis.udp then
        return false
    end

    local payload = desync.dis.payload
    if not payload or #payload < 4 then
        return false
    end

    -- Check for UDP anomalies first
    local is_anomaly, anomaly_type = check_udp_anomaly(payload)
    if is_anomaly then
        DLOG("udp_protocol_success_detector: ANOMALY (" .. tostring(anomaly_type) .. ") - NOT SUCCESS")
        return false
    end

    -- Increment incoming counter
    crec.udp_in_count = (crec.udp_in_count or 0) + 1

    -- Any valid incoming packet = potential success
    -- But validate protocol if possible
    if #payload >= 8 then
        -- Check STUN
        local is_stun, stun_type = check_stun_response(payload)
        if is_stun then
            DLOG("udp_protocol_success_detector: STUN (" .. tostring(stun_type) .. ") - SUCCESS")
            crec.validated_success = true
            crec.nocheck = true
            return true
        elseif stun_type == "STUN_ERROR" then
            DLOG("udp_protocol_success_detector: STUN_ERROR - NOT SUCCESS")
            return false
        end

        -- Check QUIC
        local is_quic, quic_type = check_quic_response(payload)
        if is_quic then
            DLOG("udp_protocol_success_detector: QUIC (" .. tostring(quic_type) .. ") - SUCCESS")
            crec.validated_success = true
            crec.nocheck = true
            return true
        elseif quic_type == "QUIC_VERSION_NEG" then
            DLOG("udp_protocol_success_detector: QUIC_VERSION_NEG - NOT SUCCESS")
            return false
        end

        -- Check Discord
        local is_discord, discord_type = check_discord_response(payload)
        if is_discord then
            DLOG("udp_protocol_success_detector: DISCORD (" .. tostring(discord_type) .. ") - SUCCESS")
            crec.validated_success = true
            crec.nocheck = true
            return true
        end
    end

    -- Unknown protocol but got valid response - count as success after threshold
    local in_threshold = tonumber(desync.arg.udp_in) or 1
    if crec.udp_in_count >= in_threshold then
        DLOG("udp_protocol_success_detector: GENERIC UDP in=" .. crec.udp_in_count .. " - SUCCESS")
        crec.validated_success = true
        crec.nocheck = true
        return true
    end

    return false
end

-- ==================== Quality-Based Circular Orchestrator ====================
-- Uses strategy-lock-manager.lua for quality tracking and locking
-- slm_* functions handle: normalize, record, get_best, should_lock, get_locked, reset, get_stats
-- Alternative to standard circular that tracks success per strategy
-- and locks on the BEST one, not just the first working one
--
-- KEY DIFFERENCE: Failure takes priority over success!
-- If we see a failure (TLS Alert, RST, etc.) it overrides any previous "success"
-- This prevents locking on strategies that initially seem to work but then fail
--
-- arg: fails=N - failure count threshold to switch strategy (default 1)
-- arg: time=<sec> - failure counter reset timeout (default 60)
-- arg: lock_successes=N - minimum successes to lock on a strategy (default 3)
-- arg: lock_tests=N - minimum total tests before considering lock (default 5)
-- arg: lock_rate=N - minimum success rate to lock (default 0.6)
-- arg: skip_strategy=N - strategy to skip for locking (default 1 = pass)
-- arg: success_detector - success detector function name
-- arg: failure_detector - failure detector function name
-- arg: hostkey - hostkey generator function name
--
-- How it works:
-- 1. Rotates through strategies on failures (like standard circular)
-- 2. Records success/failure for each strategy
-- 3. FAILURE OVERRIDES SUCCESS - if failure detected, mark as fail even if success was seen
-- 4. After lock_tests tests, if a strategy has lock_successes successes
--    with lock_rate success rate, LOCK on that strategy (skip strategy 1/pass)
-- 5. Locked strategy is always used until reset

-- Counts the distinct strategy= tags declared across desync.plan and caches
-- the result on hrec (computed once per host, not per packet). Also
-- validates that strategy numbers start at 1 and have no gaps.
--
-- Previously this used `n ~= #uniq` to detect gaps, where uniq is a table
-- keyed by strategy number (e.g. uniq[1]=true, uniq[2]=true, uniq[4]=true
-- if strategy 3 is missing). Lua's # operator on a table with non-sequential
-- integer keys is explicitly unspecified by the reference manual - it can
-- return any "border" and is free to differ across Lua versions/table
-- history even for the same logical contents. An explicit loop that checks
-- every index from 1 to n is the only safe way to detect a gap.
local function count_strategies(hrec, plan)
    if hrec.ctstrategy then return end

    local uniq = {}
    local n = 0
    for i, instance in pairs(plan) do
        if instance.arg.strategy then
            local strat_n = tonumber(instance.arg.strategy)
            if not strat_n or strat_n < 1 then
                error("circular_quality: strategy number '" .. tostring(instance.arg.strategy) .. "' is invalid")
            end
            uniq[strat_n] = true
        end
    end
    for i, v in pairs(uniq) do
        n = n + 1
    end
    for i = 1, n do
        if not uniq[i] then
            error("circular_quality: strategies numbers must start from 1 and increment. gaps are not allowed.")
        end
    end
    hrec.ctstrategy = n
end

-- Logs a strategy switch to a small rotating RAM-disk file (last 3 entries).
-- Hoisted out of circular_quality (which runs per-packet) so this closure
-- isn't reallocated on every packet even when no switch happened - only the
-- rare "strategy actually changed" path calls it.
local function log_strategy_switch(desync, from_strat, to_strat)
    local path = "/tmp/strategy_switches.log"

    local askey = desync.arg and desync.arg.key or desync.func_instance or "unknown"
    local host = (desync.track and desync.track.hostname) or "unknown"
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("%s\tprofile=%s\thost=%s\t%s->%s\n", ts, askey, host, tostring(from_strat), tostring(to_strat))

    local existing = {}
    local f = io.open(path, "r")
    if f then
        for l in f:lines() do
            if l and l ~= "" then
                table.insert(existing, l)
            end
        end
        f:close()
    end

    local tmp_path = path .. ".tmp"
    local out = io.open(tmp_path, "w")
    if not out then return end
    local start = math.max(#existing - 1, 1)
    for i = start, #existing do
        out:write(existing[i], "\n")
    end
    out:write(line)
    out:close()
    if not os.rename(tmp_path, path) then
        os.remove(tmp_path)
    end
end

-- Optional asynchronous TLS validator. Packet handling only writes/reads
-- small files and starts the configured worker in the background; curl runs
-- exclusively in strategy-validator.sh.
local VALIDATOR_REQUEST_PREFIX = "/tmp/z2r-strategy-validation/request."
local VALIDATOR_RESULT_PREFIX = "/tmp/z2r-strategy-validation/result."
local validator_seq = 0

local function validator_token(value)
    return type(value) == "string" and #value > 0 and #value <= 253 and
           value:match("^[A-Za-z0-9_.%-]+$") ~= nil
end

local function validator_hostname(value)
    return validator_token(value) and value:match("^[A-Za-z0-9]") and
           value:match("[A-Za-z0-9]$") and not value:find("..", 1, true)
end

local function validator_path(value)
    return type(value) == "string" and value:match("^/[A-Za-z0-9_./%-]+$") and
           not value:find("..", 1, true) and value or nil
end

local function validator_clear(hrec)
    hrec.validator_pending = nil
end

local function validator_poll(hrec, desync, hostkey)
    local pending = hrec.validator_pending
    if not pending then return end

    local now = os.time()
    local result_path = VALIDATOR_RESULT_PREFIX .. pending.id
    local f = io.open(result_path, "r")
    if not f then
        if now >= pending.deadline then
            DLOG("circular_quality: validator timeout id=" .. pending.id .. " host=" .. pending.hostkey)
            os.remove(VALIDATOR_REQUEST_PREFIX .. pending.id)
            os.remove(VALIDATOR_RESULT_PREFIX .. pending.id)
            validator_clear(hrec)
        end
        return
    end
    local line = f:read("*l")
    f:close()
    os.remove(result_path)

    local id, status, askey, result_host, strategy
    if line then
        id, status, askey, result_host, strategy = line:match("^(%d+)\t([A-Z]+)\t([A-Za-z0-9_.%-]+)\t([A-Za-z0-9_.%-]+)\t(%d+)$")
    end
    strategy = tonumber(strategy)
    if id ~= pending.id or askey ~= pending.askey or result_host ~= pending.hostkey or strategy ~= pending.strategy then
        DLOG("circular_quality: validator invalid result id=" .. pending.id)
        validator_clear(hrec)
        return
    end
    validator_clear(hrec)

    local slm_askey = pending.slm_askey

    if status == "OK" then
        if slm_commit_auto_lock(slm_askey, hostkey, strategy, "validator") then
            hrec.nstrategy = strategy
            DLOG("circular_quality: validator OK " .. hostkey .. " -> strategy " .. strategy)
        end
    elseif status == "FAIL" then
        DLOG("circular_quality: validator FAIL " .. hostkey .. " strategy " .. strategy)
        slm_reset(slm_askey, hostkey)
        slm_preload_blocked(slm_askey, hostkey, { strategy })
        local next_strategy = strategy
        for _ = 1, hrec.ctstrategy do
            next_strategy = (next_strategy % hrec.ctstrategy) + 1
            if not slm_is_blocked(slm_askey, hostkey, next_strategy) then break end
        end
        hrec.nstrategy = next_strategy
    else
        DLOG("circular_quality: validator " .. status .. " id=" .. id .. ", retry allowed")
    end
end

local function validator_enqueue(hrec, desync, hostkey, strategy)
    local worker = validator_path(desync.arg.validator)
    local hostname = hrec.validator_hostname or (desync.track and desync.track.hostname)
    local slm_askey = desync.arg.key or "default"
    local askey = tostring(slm_askey)
    if not worker or hrec.validator_pending or not validator_token(askey) or
       not validator_token(hostkey) or not validator_hostname(hostname) then return false end

    validator_seq = validator_seq + 1
    local id = tostring(os.time()) .. string.format("%06d", validator_seq % 1000000)
    local request_path = VALIDATOR_REQUEST_PREFIX .. id
    local tmp_path = request_path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then return false end
    f:write(id, "\t", askey, "\t", hostkey, "\t", tostring(strategy), "\t", hostname, "\n")
    f:close()
    if not os.rename(tmp_path, request_path) then
        os.remove(tmp_path)
        return false
    end

    hrec.validator_pending = {
        id = id, askey = askey, hostkey = hostkey, strategy = strategy,
        slm_askey = slm_askey,
        deadline = os.time() + 30,
    }
    DLOG("circular_quality: validator request id=" .. id .. " host=" .. hostkey .. " strategy=" .. strategy)
    return true
end

function circular_quality(ctx, desync)
    -- Skip if we're in replay mode (desync.plan is empty after orchestrate())
    -- During replay, C code re-invokes the profile but execution plan is already consumed
    if desync.replay_seq then
        DLOG("circular_quality: skip replay packet #" .. desync.replay_seq)
        return VERDICT_PASS
    end

    -- AUTO profiles also pass payload_type=empty so an incoming TCP RST can
    -- reach the failure detector.  Empty ACK/SYN/FIN packets are common and
    -- carry no quality signal; reject them before orchestrate() to avoid doing
    -- the full strategy-plan work for every acknowledgement.
    local tcp = desync.dis and desync.dis.tcp
    local payload = desync.dis and desync.dis.payload
    if tcp and (not payload or #payload == 0)
        and bitand(tcp.th_flags or 0, TH_RST) == 0 then
        return VERDICT_PASS
    end

    -- CRITICAL: Take over execution FIRST! This populates desync.plan from C code
    -- Without this call, desync.plan is nil and we can't orchestrate strategies
    orchestrate(ctx, desync)

    -- Now check if plan is empty (nested call or no strategies defined)
    if not desync.plan or #desync.plan == 0 then
        DLOG("circular_quality: no execution plan after orchestrate, passing through")
        return VERDICT_PASS
    end

    -- These gates deliberately reuse circular_locked's helpers. config.default
    -- loads locked.lua first, so auto and manual counterparts stay equivalent.
    local allow_nohost = desync_allow_nohost(desync)
    if not desync.track and not allow_nohost then
        DLOG_ERR("circular_quality: conntrack is missing but required")
        return
    end

    local hostname = desync_hostname(desync)
    if hostname and hostname ~= "" then
        hostname = string.lower(hostname:gsub("%.$", ""))
    else
        hostname = nil
    end

    local route_substrings = desync.arg and desync.arg.route_substrings
    local route_key = desync.arg and desync.arg.route_key
    if route_substrings and route_key and substring_hostlist_matches_desync(desync, route_substrings, hostname) then
        desync.arg.key = tostring(route_key)
        DLOG("circular_quality: substring routed to profile=" .. desync.arg.key .. " host=" .. tostring(hostname))
    end
    if hostlist_has_host(desync.arg and desync.arg.exclude_hostlist, hostname) then
        DLOG("circular_quality: excluded by hostlist host=" .. tostring(hostname))
        return VERDICT_PASS
    end
    local include_substrings = desync.arg and desync.arg.include_substrings
    if include_substrings and not substring_hostlist_matches_desync(desync, include_substrings, hostname) then
        DLOG("circular_quality: no substring match host=" .. tostring(hostname))
        lua_cutoff(ctx)
        return VERDICT_PASS
    end

    local hrec = desync.track and automate_host_record(desync)
    if not hrec then
        if allow_nohost then
            hrec = {}
            DLOG("circular_quality: allow_nohost enabled, using local record")
        else
            DLOG("circular_quality: passing with no tampering")
            return
        end
    end

    -- Conntrack can retain the host record after hostname is absent from a
    -- later packet. Preserve only the observed hostname, never a grouped key.
    local observed_hostname = desync.track and desync.track.hostname or hostname
    if validator_hostname(observed_hostname) then
        hrec.validator_hostname = observed_hostname
    end

    -- Get hostkey for quality tracking (normalized via slm_normalize_hostkey)
    local hostkey
    if desync.arg.hostkey then
        if type(_G[desync.arg.hostkey])~="function" then
            error("circular_quality: invalid hostkey function '"..desync.arg.hostkey.."'")
        end
        hostkey = _G[desync.arg.hostkey](desync)
    else
        -- Check if this hostname should be kept full (not NLD-cut)
        local full_hostname = desync.track and desync.track.hostname or hostname
        if full_hostname and slm_should_keep_full_hostname(full_hostname) then
            hostkey = slm_normalize_hostkey(full_hostname)
            DLOG("circular_quality: keeping full hostname (special): " .. (hostkey or "?"))
        elseif not desync.track and hostname then
            hostkey = slm_normalize_hostkey(hostname)
        else
            hostkey = standard_hostkey(desync)
        end
    end
    -- Apply domain grouping if available (e.g., googlevideo.com)
    if hostkey and get_grouped_hostname then
        hostkey = get_grouped_hostname(hostkey) or hostkey
    end
    -- Normalize hostkey for slm_* functions
    hostkey = slm_normalize_hostkey(hostkey) or hostkey

    -- Count strategies from desync.plan (already populated by orchestrate() at function start)
    count_strategies(hrec, desync.plan)
    if hrec.ctstrategy==0 then
        error("circular_quality: add strategy=N tag argument to each following instance ! N must start from 1 and increment")
    end

    local skip_pass = false

    if not hrec.nstrategy then
        DLOG("circular_quality: start from strategy 1")
        hrec.nstrategy = 1
    end

    local validator_enabled = validator_path(desync.arg.validator) ~= nil
    if validator_enabled then
        validator_poll(hrec, desync, hostkey)
    end

    -- Initialize detectors ONCE (used for both locked and unlocked)
    local failure_detector, success_detector
    if desync.arg.failure_detector then
        if type(_G[desync.arg.failure_detector])~="function" then
            error("circular_quality: invalid failure detector function '"..desync.arg.failure_detector.."'")
        end
        failure_detector = _G[desync.arg.failure_detector]
    else
        failure_detector = standard_failure_detector
    end
    if desync.arg.success_detector then
        if type(_G[desync.arg.success_detector])~="function" then
            error("circular_quality: invalid success detector function '"..desync.arg.success_detector.."'")
        end
        success_detector = _G[desync.arg.success_detector]
    else
        success_detector = standard_success_detector
    end

    -- Get connection record and run detectors ALWAYS (even for locked strategies)
    local crec = automate_conn_record(desync)
    local is_failure = failure_detector(desync, crec)
    local is_success = not is_failure and success_detector(desync, crec)

    -- Check if we should use locked strategy
    local locked = slm_get_locked(desync.arg.key, hostkey)
    if locked then
        -- BLOCKED: If locked strategy is marked as blocked by user, reset and re-learn
        if slm_is_blocked(desync.arg.key, hostkey, locked) then
            DLOG("circular_quality: BLOCKED " .. (hostkey or "?") .. " -> locked=" .. locked .. " is blocked, resetting")
            -- Find next non-blocked strategy
            local next_strat = locked
            for i = 1, hrec.ctstrategy do
                next_strat = (next_strat % hrec.ctstrategy) + 1
                if not slm_is_blocked(desync.arg.key, hostkey, next_strat) then
                    break
                end
            end
            hrec.nstrategy = next_strat
            -- Reset quality tracking so it can find a better strategy
            slm_reset(desync.arg.key, hostkey)
        else
            -- Use locked strategy
            hrec.nstrategy = locked

            -- === AUTO-UNLOCK: Track failures for locked strategies ===
            -- If locked strategy keeps failing, unlock and re-learn
            local unlock_fails = tonumber(desync.arg.unlock_fails) or 3

            if is_failure and not crec.locked_failure_recorded then
                crec.locked_failure_recorded = true
                hrec.locked_fail_count = (hrec.locked_fail_count or 0) + 1
                slm_record_result(desync.arg.key, hostkey, locked, false)
                DLOG("circular_quality: LOCKED strat " .. locked .. " FAIL #" .. hrec.locked_fail_count .. "/" .. unlock_fails .. " for " .. (hostkey or "?"))

                if hrec.locked_fail_count >= unlock_fails then
                    -- Check if this is a user lock (protected from auto-unlock)
                    if slm_is_user_lock(desync.arg.key, hostkey) then
                        -- User lock: do NOT reset, just log and clear fail counter
                        DLOG("circular_quality: USER LOCK protected for " .. (hostkey or "?") .. ", skipping auto-unlock (fails=" .. hrec.locked_fail_count .. ")")
                        hrec.locked_fail_count = 0
                    else
                        -- Auto lock: reset and re-learn as usual
                        DLOG("circular_quality: AUTO-UNLOCK " .. (hostkey or "?") .. " after " .. hrec.locked_fail_count .. " consecutive fails")
                        slm_reset(desync.arg.key, hostkey)  -- This clears locked_strategy
                        hrec.locked_fail_count = 0
                        -- Start from next strategy (skip the failing one initially)
                        hrec.nstrategy = (locked % hrec.ctstrategy) + 1
                    end
                end

            elseif is_success and (not crec.provisional_success or crec.validated_success) and not crec.locked_success_recorded and not crec.locked_failure_recorded then
                crec.locked_success_recorded = true
                -- Success resets fail counter
                if hrec.locked_fail_count and hrec.locked_fail_count > 0 then
                    DLOG("circular_quality: LOCKED strat " .. locked .. " SUCCESS, reset fail counter (was " .. hrec.locked_fail_count .. ")")
                end
                hrec.locked_fail_count = 0
                slm_record_result(desync.arg.key, hostkey, locked, true)
            end

            DLOG("circular_quality: using LOCKED strategy " .. locked)
        end
    else
        -- Not locked yet - normal rotation with quality tracking

        -- If failure detected - override any previous success marking
        if is_failure then
            -- If we already recorded success for this connection, convert it to failure
            if crec.quality_success_recorded then
                DLOG("circular_quality: FAILURE overrides previous SUCCESS for strat " .. hrec.nstrategy)
                -- Decrement success via SLM_QUALITY global table (managed by strategy-lock-manager)
                -- Now uses two-level structure: SLM_QUALITY[askey][hostkey]
                local askey = desync.arg.key or "default"
                local as_table = SLM_QUALITY and SLM_QUALITY[askey]
                local qrec = as_table and as_table[hostkey]
                if qrec and qrec.strategy_successes and qrec.strategy_successes[hrec.nstrategy] then
                    qrec.strategy_successes[hrec.nstrategy] = math.max(0, qrec.strategy_successes[hrec.nstrategy] - 1)
                end
                -- Also roll back the test-count increment from the earlier
                -- slm_record_result(...,true) call - the slm_record_result(...,false)
                -- call below will add exactly one fresh test/failure entry, so this
                -- override should net to +1 test total for this connection, not +2.
                if qrec and qrec.strategy_tests and qrec.strategy_tests[hrec.nstrategy] then
                    qrec.strategy_tests[hrec.nstrategy] = math.max(0, qrec.strategy_tests[hrec.nstrategy] - 1)
                end
                if qrec and qrec.total_tests then
                    qrec.total_tests = math.max(0, qrec.total_tests - 1)
                end
                crec.quality_success_recorded = nil
            end

            if not crec.quality_failure_recorded then
                crec.quality_failure_recorded = true
                slm_record_result(desync.arg.key, hostkey, hrec.nstrategy, false)

                local fails = tonumber(desync.arg.fails) or 1
                local maxtime = tonumber(desync.arg.time) or 60
                if automate_failure_counter(hrec, crec, fails, maxtime) then
                    -- Rotate to next strategy, skipping blocked ones
                    local start_strat = hrec.nstrategy
                    repeat
                        hrec.nstrategy = (hrec.nstrategy % hrec.ctstrategy) + 1
                        -- Skip blocked strategies
                        if slm_is_blocked(desync.arg.key, hostkey, hrec.nstrategy) then
                            DLOG("circular_quality: skipping BLOCKED strategy " .. hrec.nstrategy)
                        else
                            break
                        end
                    until hrec.nstrategy == start_strat  -- Prevent infinite loop
                    DLOG("circular_quality: rotate to strategy " .. hrec.nstrategy .. " [" .. slm_get_stats(desync.arg.key, hostkey) .. "]")
                end
            end

        -- Success detected and no failure
        elseif is_success and not crec.quality_failure_recorded then
            if not crec.quality_success_recorded then
                crec.quality_success_recorded = true
                slm_record_result(desync.arg.key, hostkey, hrec.nstrategy, true)
            end

            -- Soft TCP progress contributes one learning result, but only a
            -- validated (or non-provisional) success can reset and auto-lock.
            if (not crec.provisional_success or crec.validated_success) and not crec.quality_success_finalized then
                crec.quality_success_finalized = true
                automate_failure_counter_reset(hrec)
                if not validator_enabled then
                    local should_lock_now, lock_strat = slm_should_lock(desync.arg.key, hostkey, desync.arg)
                    if should_lock_now then
                        DLOG("circular_quality: LOCKED on strategy " .. lock_strat .. " [" .. slm_get_stats(desync.arg.key, hostkey) .. "]")
                        hrec.nstrategy = lock_strat
                    end
                end
            end

            -- A provisional success is sufficient to ask for external proof:
            -- its one quality test can already make an established strategy a
            -- candidate, but it never commits the lock before validator OK.
            if validator_enabled and not hrec.validator_pending and not crec.quality_validator_checked then
                local eligible, candidate = slm_should_lock(desync.arg.key, hostkey, desync.arg)
                crec.quality_validator_checked = true
                if eligible and candidate == hrec.nstrategy then
                    validator_enqueue(hrec, desync, hostkey, candidate)
                end
            end
        end
    end

    DLOG("circular_quality: current strategy " .. hrec.nstrategy ..
         " profile=" .. (desync.arg.key or "default") .. " host=" .. (hostkey or "?"))
    -- Log strategy switches to RAM file (last 3 entries)
    if hrec._last_strategy and hrec._last_strategy ~= hrec.nstrategy then
        log_strategy_switch(desync, hrec._last_strategy, hrec.nstrategy)
    end
    hrec._last_strategy = hrec.nstrategy
    local verdict = VERDICT_PASS
    while true do
        local instance = plan_instance_pop(desync)
        if not instance then break end
        if instance.arg.strategy and tonumber(instance.arg.strategy)==hrec.nstrategy then
            verdict = plan_instance_execute(desync, verdict, instance)
        end
    end

    return verdict
end

DLOG("combined-detector v2 (strategy quality tracking) loaded")
