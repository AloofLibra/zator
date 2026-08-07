-- Custom failure detector for TCP silent drop (DPI drops packets without RST)
-- Works by counting outgoing vs incoming DATA packets (excluding SYN-ACK handshake)
-- If many outgoing data packets and few incoming data = failure
--
-- Uses the shared stall-baseline helpers from combined-detector.lua (this
-- file must load after it - see combined_silent_drop_detector below) so the
-- "measure since last incoming progress" algorithm has exactly one
-- implementation instead of being hand-copied per detector.

function silent_drop_detector(desync, crec, arg)
    if crec.nocheck then return false end

    local tcp_out = tonumber(arg.tcp_out) or 4  -- outgoing data packets threshold
    local tcp_in = tonumber(arg.tcp_in)

    -- tcp_in used to gate a supposed "tolerate a little incoming progress"
    -- check (in_since <= tcp_in), but that comparison was mathematically
    -- always true (see stall_baseline_update in combined-detector.lua for
    -- why), so tcp_in never actually affected behavior even before this
    -- refactor. Kept as a recognized (but inert) argument for backward
    -- compatibility with existing configs; warn once if someone set it to
    -- a non-default value, since it silently does nothing.
    if tcp_in and tcp_in ~= 1 and not crec.silent_tcp_in_deprecation_warned then
        crec.silent_tcp_in_deprecation_warned = true
        DLOG("silent_drop_detector: WARNING tcp_in=" .. tcp_in .. " has no effect (was always a no-op; see source comment)")
    end

    if desync.dis.tcp and desync.outgoing and desync.track then
        -- Use dcounter (data packets) if available, otherwise pcounter
        local out_count = desync.track.pos.direct.dcounter or desync.track.pos.direct.pcounter or 0
        local in_count = desync.track.pos.reverse.dcounter or desync.track.pos.reverse.pcounter or 0

        -- Baseline = the (out,in) snapshot taken the last time we saw the peer
        -- make progress (in_count increase). This lets us detect a stall that
        -- starts partway through the connection (e.g. server sent a few bytes,
        -- then DPI silently drops everything afterwards), not just a stall at
        -- the very beginning. Without this, once in_count > tcp_in the
        -- detector could never fire again for the rest of the connection.
        local out_since = stall_baseline_update(
            crec, "silent_base_in", "silent_base_out", out_count, in_count)

        -- Silent drop: many outgoing data packets since the last bit of
        -- incoming progress. Trigger FAILURE every tcp_out packets after threshold.
        if out_since >= tcp_out then
            if stall_baseline_should_refire(crec, "last_fail_out", out_count, tcp_out) then
                -- Reset failure flag to allow multiple rotations in same connection
                crec.failure = nil
                DLOG("silent_drop_detector: FAILURE out="..out_count.." in="..in_count..
                     " (since_progress out="..out_since..")")
                return true
            end
        end

        if b_debug and out_count > 2 then
            DLOG("silent_drop_detector: out="..out_count.." in="..in_count..
                 " since_progress out="..out_since)
        end
    end

    return false
end

-- Combined failure detector: first run combined_failure_detector, then silent drop.
-- Requires combined-detector.lua to be loaded before this file.
function combined_silent_drop_detector(desync, crec)
    if combined_failure_detector and combined_failure_detector(desync, crec) then
        return true
    end
    return silent_drop_detector(desync, crec, desync.arg or {})
end
