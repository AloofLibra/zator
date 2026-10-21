-- RST injection guard.
-- Drops suspicious incoming TCP RST packets using independent per-connection checks.

local function z2r_rst_state(desync)
    if not desync.track then
        return nil
    end

    desync.track.lua_state = desync.track.lua_state or {}
    desync.track.lua_state.z2r_rst_guard = desync.track.lua_state.z2r_rst_guard or {
        rst_count = 0,
        seen_real_response = false,
        first_response_ttl = nil
    }

    return desync.track.lua_state.z2r_rst_guard
end

local function z2r_packet_ttl(dis)
    if not dis then
        return nil
    end

    if dis.ip then
        return tonumber(dis.ip.ip_ttl or dis.ip.ttl)
    end

    if dis.ip6 then
        return tonumber(dis.ip6.ip6_hlim or dis.ip6.hlim or dis.ip6.hop_limit)
    end

    return nil
end

local function z2r_abs(n)
    return n < 0 and -n or n
end

local function z2r_is_real_response(desync)
    return desync.dis
        and desync.dis.tcp
        and not desync.outgoing
        and bitand(desync.dis.tcp.th_flags, TH_RST) == 0
        and desync.dis.payload
        and #desync.dis.payload > 0
end

function rst_guard(ctx, desync)
    if not desync.dis or not desync.dis.tcp or desync.outgoing then
        return VERDICT_PASS
    end

    local st = z2r_rst_state(desync)
    if not st then
        DLOG("rst_guard: no conntrack, passing")
        return VERDICT_PASS
    end

    if z2r_is_real_response(desync) then
        if not st.seen_real_response then
            st.seen_real_response = true
            st.first_response_ttl = z2r_packet_ttl(desync.dis)
            DLOG("rst_guard: first real response ttl=" .. tostring(st.first_response_ttl))
        end
        return VERDICT_PASS
    end

    if bitand(desync.dis.tcp.th_flags, TH_RST) == 0 then
        return VERDICT_PASS
    end

    st.rst_count = (st.rst_count or 0) + 1

    local reasons = {}
    if not st.seen_real_response then
        table.insert(reasons, "before_response")
    end

    if st.rst_count >= 2 then
        table.insert(reasons, "repeated_rst")
    end

    local ttl = z2r_packet_ttl(desync.dis)
    local ttl_delta = tonumber(desync.arg and desync.arg.ttl_delta) or 3
    if ttl and st.first_response_ttl and z2r_abs(ttl - st.first_response_ttl) > ttl_delta then
        table.insert(reasons, "ttl_delta=" .. tostring(z2r_abs(ttl - st.first_response_ttl)))
    end

    if #reasons > 0 then
        DLOG("rst_guard: dropping RST count=" .. st.rst_count .. " ttl=" .. tostring(ttl) .. " reasons=" .. table.concat(reasons, ","))
        return VERDICT_DROP
    end

    DLOG("rst_guard: passing RST count=" .. st.rst_count .. " ttl=" .. tostring(ttl))
    return VERDICT_PASS
end

function rst_guard_locked(ctx, desync)
    local verdict = rst_guard(ctx, desync)
    if verdict == VERDICT_DROP then
        circular_locked_passthrough(ctx, desync)
        return verdict
    end

    return circular_locked(ctx, desync)
end

DLOG("rst-guard loaded")
