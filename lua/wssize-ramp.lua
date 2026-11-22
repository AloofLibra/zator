-- This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
-- Reduce the advertised receive window until the client ACKs server data,
-- then compensate for the reduced Window Scale on every later outbound packet.
local function adaptive_ramp_audit(stage)
	local path = os.getenv("Z2R_ADAPTIVE_RAMP_AUDIT_PATH")
	if type(path) ~= "string" or #path > 512
		or not (path:match("^%a:/[A-Za-z0-9_./-]+$") or path:match("^/[A-Za-z0-9_./-]+$"))
		or path:find("/%.%./") then return end
	local f = io.open(path, "r")
	local syn, ack = "0", "0"
	if f then
		local line = f:read("*l")
		f:close()
		if line then
			local s, a = line:match("^1\t([01])\t([01])$")
			if s and a then syn, ack = s, a end
		end
	end
	if stage == "syn" then syn = "1" elseif stage == "ack" then ack = "1" end
	f = io.open(path, "w")
	if f then f:write("1\t", syn, "\t", ack, "\n"); f:close() end
end

function z2r_wssize_ramp_hostname_valid(host)
	if type(host) ~= "string" or #host > 253 or not host:match("%.googlevideo%.com$") then return false end
	local suffix = ".googlevideo.com"
	local prefix = host:sub(1, #host - #suffix)
	for label in (prefix .. "."):gmatch("(.-)%.") do
		if #label < 1 or #label > 63 or
			(not label:match("^[a-z0-9]$") and not label:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$")) then return false end
	end
	return true
end

function z2r_wssize_ramp_exempt_for_new_flow(ip)
	local root = os.getenv("ZATOR_ROOT") or "/opt/zator"
	local mode = io.open(root .. "/extra_strats/cache/adaptive/mode", "r")
	if not mode then return false end
	local active = mode:read("*l") == "AGENT_BETA"
	mode:close()
	if not active then return false end
	local consent = io.open(root .. "/extra_strats/cache/adaptive/apply-default-scope", "r")
	if not consent then return false end
	active = consent:read("*l") == "1"
	consent:close()
	if not active then return false end
	local path = os.getenv("Z2R_ADAPTIVE_RAMP_EXEMPT_FILE") or "/tmp/z2r-adaptive/ramp-exempt.tsv"
	if #path > 512 or not (path:match("^/[A-Za-z0-9_./-]+$") or path:match("^%a:/[A-Za-z0-9_./-]+$")) or path:find("/%.%./") then return false end
	local now = os.time()
	local file = io.open(path, "r")
	if not file then return false end
	local candidate_host, candidate_scope
	local count = 0
	for line in file:lines() do
		count = count + 1
		if count > 128 then file:close(); return false end
		local ver, host, dst, scope, expires, fingerprint = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
		if ver == "1" and dst == ip and z2r_wssize_ramp_hostname_valid(host)
			and (scope == "default" or scope:match("^mark:[1-9]%d?%d?%d?%d?$"))
			and expires:match("^[1-9]%d*$") and tonumber(expires) > now
			and fingerprint:match("^[a-f0-9]+$") and #fingerprint == 64 then
			candidate_host, candidate_scope = host, scope
			break
		end
	end
	file:close()
	if not candidate_host then return false end
	local targets = io.open(os.getenv("Z2R_ADAPTIVE_RAMP_TARGETS_FILE") or "/tmp/z2r-adaptive/ramp-targets.tsv", "r")
	if not targets then return false end
	local exact, conflict = false, false
	count = 0
	for line in targets:lines() do
		count = count + 1
		if count > 128 then targets:close(); return false end
		local ver, host, dst, scope, seen, provenance, group, status = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)")
		if ver == "1" and seen and seen:match("^%d+$") and tonumber(seen) >= now - 604800 and provenance == "tls-observed" then
			if host == candidate_host and dst == ip and scope == candidate_scope then
				exact = true
				if status == "conflict" or status == "uncertain" then conflict = true end
			end
			if (dst == ip and host ~= candidate_host) or (host == candidate_host and dst ~= ip) then conflict = true end
		end
	end
	targets:close()
	return exact and not conflict
end

function wssize_ramp(ctx, desync)
	local dis = desync.dis
	if not dis.tcp then
		if not dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	-- Only outgoing packets carry the client receive window we adjust.
	if not desync.outgoing then return end
	if not direction_check(desync) then return end
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
	if state.wssize_ramp_exempt then
		instance_cutoff_shim(ctx, desync, true)
		return
	end
	if bitand(flags, TH_SYN) ~= 0 and type(dis_ipdst) == "function" and type(ntop) == "function" then
		local dst = dis_ipdst(dis)
		if dst and z2r_wssize_ramp_exempt_for_new_flow(ntop(dst)) then
			state.wssize_ramp_exempt = true
			state.wssize_ramp_treatment = "bypassed"
			instance_cutoff_shim(ctx, desync, true)
			return
		end
	end
	if not state.wssize_ramp_cutoff then
		direction_cutoff_opposite(ctx, desync)
		state.wssize_ramp_cutoff = true
	end

	if bitand(tcp.th_flags, TH_SYN) ~= 0 then
		local i = find_tcp_option(tcp.options, TCP_KIND_SCALE)
		if not i then
			if state.wssize_ramp_treatment == nil then state.wssize_ramp_treatment = "no_window_scale" end
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
		if state.wssize_ramp_treatment == nil then
			state.wssize_ramp_treatment = changed and "applied" or "unchanged"
		end
		if changed then
			adaptive_ramp_audit("syn")
			return VERDICT_MODIFY
		end
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
			if acked < 2147483648 and acked >= state.wssize_ramp_open then
				state.wssize_ramp_opened = true
				state.wssize_ramp_late_ack_confirmed = true
				adaptive_ramp_audit("ack")
			end
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

-- Reuse zapret2's stock syndata implementation only after Ramp initialized the
-- same flow. desync.arg.blob is forwarded unchanged; stock syndata uses its
-- default 16 zero bytes only when no named blob is supplied.
-- The enclosing profile's mark filter limits this to Googlevideo IPv4.
function z2r_googlevideo_syndata(ctx, desync)
	local tcp = desync.dis.tcp
	if not tcp or not desync.outgoing or not direction_check(desync) then return end
	if bitand(tcp.th_flags, TH_SYN + TH_ACK) ~= TH_SYN then return end
	local track = desync.track
	local state = track and track.lua_state
	if not state or state.wssize_ramp_shift == nil or state.wssize_ramp_syndata_attempted then return end
	-- Keep retries/replays from injecting multiple copies. A failed raw send leaves
	-- this original SYN eligible for normal NFQUEUE delivery.
	state.wssize_ramp_syndata_attempted = true
	if type(syndata) == "function" then return syndata(ctx, desync) end
	DLOG("z2r_googlevideo_syndata: stock syndata is unavailable; passing original SYN")
end
