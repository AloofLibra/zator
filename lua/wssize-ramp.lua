-- Reduce the advertised receive window until the client ACKs server data,
-- then compensate for the reduced Window Scale on every later outbound packet.
local wssize_ramp_ip_cache = {}

function wssize_ramp(ctx, desync)
	local dis = desync.dis
	if not dis.tcp then
		if not dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	-- Only outgoing packets carry the client receive window we adjust.
	if not desync.outgoing then return end
	if not direction_check(desync) then return end
	local ip = desync.arg.ip
	if not ip then return end
	local ipraw = wssize_ramp_ip_cache[ip]
	if not ipraw then
		local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
		if not a or a > 255 or b > 255 or c > 255 or d > 255 then error("wssize_ramp: ip must be an IPv4 address") end
		ipraw = string.char(a, b, c, d)
		wssize_ramp_ip_cache[ip] = ipraw
	end
	local hdr = dis.ip
	if not hdr then return end
	local packet_ip = desync.outgoing and hdr.ip_dst or hdr.ip_src
	if packet_ip ~= ipraw then return end

	local track = desync.track
	if not track then
		instance_cutoff_shim(ctx, desync)
		return
	end
	-- nfqws2 does not pre-create this per-flow Lua table on the first SYN.
	-- The track object itself is per connection and exposes writable fields.
	if not track.lua_state then track.lua_state = {} end
	local tcp, state = dis.tcp, track.lua_state
	local flags = tcp.th_flags
	if bitand(flags, TH_FIN + TH_RST) ~= 0 then return end
	if not state.wssize_ramp_cutoff then
		direction_cutoff_opposite(ctx, desync)
		state.wssize_ramp_cutoff = true
	end

	if bitand(tcp.th_flags, TH_SYN) ~= 0 then
		local i = find_tcp_option(tcp.options, TCP_KIND_SCALE)
		if not i then
			instance_cutoff_shim(ctx, desync)
			return
		end
		local original = u8(tcp.options[i].data)
		if state.wssize_ramp_shift == nil then
			local wsize = tonumber(desync.arg.wsize) or 1
			local scale = tonumber(desync.arg.scale) or 1
			local open = tonumber(desync.arg.open) or 1
			local mode = desync.arg.mode or "full"
			if mode ~= "full" and mode ~= "lite" then error("wssize_ramp: mode must be full or lite") end
			if wsize < 0 or wsize > 65535 or wsize % 1 ~= 0 then error("wssize_ramp: wsize must be 0..65535") end
			if scale < 0 or scale > 14 or scale % 1 ~= 0 then error("wssize_ramp: scale must be 0..14") end
			if open < 1 or open % 1 ~= 0 then error("wssize_ramp: open must be a positive integer") end
			scale = math.min(original, scale)
			state.wssize_ramp_wsize = wsize
			state.wssize_ramp_open = open
			state.wssize_ramp_mode = mode
			state.wssize_ramp_shift = original - scale
			state.wssize_ramp_multiplier = 2 ^ state.wssize_ramp_shift
			state.wssize_ramp_opened = false
		end
		local scale = original - state.wssize_ramp_shift
		local changed = false
		if original > scale then tcp.options[i].data = bu8(scale); changed = true end
		if tcp.th_win ~= state.wssize_ramp_wsize then tcp.th_win = state.wssize_ramp_wsize; changed = true end
		if changed then return VERDICT_MODIFY end
		return
	end
	local shift = state.wssize_ramp_shift
	if shift == nil then
		instance_cutoff_shim(ctx, desync)
		return
	end

	if not state.wssize_ramp_opened and bitand(flags, TH_ACK) ~= 0 then
		local server = track.pos and track.pos.server and track.pos.server.tcp
		if not server or not server.seq0 then
			-- Missing sequence tracking must fail open instead of pinning a flow at wsize.
			state.wssize_ramp_opened = true
		else
			local acked = (tcp.th_ack - server.seq0 - 1) % 4294967296
			if acked < 2147483648 and acked >= state.wssize_ramp_open then state.wssize_ramp_opened = true end
		end
	end
	if not state.wssize_ramp_opened then
		if tcp.th_win ~= state.wssize_ramp_wsize then tcp.th_win = state.wssize_ramp_wsize; return VERDICT_MODIFY end
		return
	end
	if state.wssize_ramp_mode == "lite" then
		-- Lite is pass-through after opening; stop scheduling this Lua callback
		-- for the rest of the outgoing flow as well.
		instance_cutoff_shim(ctx, desync, true)
		return
	end
	if shift == 0 then return end
	-- The multiplier is always an integral power of two, so no rounding is needed.
	local win = tcp.th_win * state.wssize_ramp_multiplier
	win = win > 65535 and 65535 or win
	if tcp.th_win ~= win then tcp.th_win = win; return VERDICT_MODIFY end
end
