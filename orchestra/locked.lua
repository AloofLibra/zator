local LOCKED_PATH = "/opt/zator/extra_strats/cache/orchestra/locked.tsv"
local LOCKED_MANUAL_PATH = "/opt/zator/extra_strats/cache/orchestra/locked.manual.tsv"
local last_load = 0
local cache_ttl = 2
local LOCKED_TLS = {}
local LOCKED_HTTP = {}
local LOCKED_UDP = {}
local LOCKED_CONFLICTS = {}
local LOCKED_CONFLICTS_TOTAL = 0
local CLIENT_SCOPE_SCOPED_LOCK_COUNT = 0
local LOCKED_TEST_LINES = nil
local EXCLUDE_HOSTLISTS = {}
local SUBSTRING_HOSTLISTS = {}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function locked_parse_line(line)
  if type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  if line == "" or string.match(line, "^%s*#") then return nil end
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = trim(field) end
  local scope, profile, proto, raw_strategy
  if #fields == 4 then
    scope, profile, proto, raw_strategy = fields[1], fields[2], fields[3], fields[4]
    if scope == "" then return nil end
  elseif #fields == 3 then
    scope, profile, proto, raw_strategy = "default", fields[1], fields[2], fields[3]
  elseif #fields == 2 then
    scope, profile, proto, raw_strategy = "default", fields[1], "tls", fields[2]
  else
    return nil
  end
  if profile == "" or proto == "" or raw_strategy == "" then return nil end
  proto = string.lower(proto)
  if proto ~= "tls" and proto ~= "http" and proto ~= "udp" then return nil end
  local strategy = tonumber(raw_strategy)
  if not strategy or strategy < 0 or strategy % 1 ~= 0 then return nil end
  return string.lower(scope), string.lower(profile), proto, strategy
end

local function lock_table(proto)
  if proto == "http" then return LOCKED_HTTP end
  if proto == "udp" then return LOCKED_UDP end
  return LOCKED_TLS
end

local function store_locked(scope, profile, proto, strategy)
  local values = lock_table(proto)
  values[scope] = values[scope] or {}
  LOCKED_CONFLICTS[scope] = LOCKED_CONFLICTS[scope] or {}
  LOCKED_CONFLICTS[scope][proto] = LOCKED_CONFLICTS[scope][proto] or {}
  local conflict = LOCKED_CONFLICTS[scope][proto]
  local previous = values[scope][profile]
  if conflict[profile] then return end
  if previous ~= nil and previous ~= strategy then
    conflict[profile] = true
    values[scope][profile] = nil
    LOCKED_CONFLICTS_TOTAL = LOCKED_CONFLICTS_TOTAL + 1
    if type(DLOG_ERR) == "function" then
      DLOG_ERR("locked.lua: conflicting lock scope="..scope.." profile="..profile.." proto="..proto)
    end
  elseif previous == nil then
    values[scope][profile] = strategy
  end
end

local function load_locked_lines(lines)
  for _, line in ipairs(lines) do
    local scope, profile, proto, strategy = locked_parse_line(line)
    if scope then
      if scope ~= "default" then CLIENT_SCOPE_SCOPED_LOCK_COUNT = CLIENT_SCOPE_SCOPED_LOCK_COUNT + 1 end
      store_locked(scope, profile, proto, strategy)
    end
  end
end

local function load_locked_file(path)
  local f = io.open(path, "r")
  if not f then return end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  load_locked_lines(lines)
end

local function load_locked_tables()
  local now = os.time()
  if now and (now - last_load) < cache_ttl then return end
  last_load = now or 0
  LOCKED_TLS = {}
  LOCKED_HTTP = {}
  LOCKED_UDP = {}
  LOCKED_CONFLICTS = {}
  LOCKED_CONFLICTS_TOTAL = 0
  CLIENT_SCOPE_SCOPED_LOCK_COUNT = 0

  if LOCKED_TEST_LINES then
    load_locked_lines(LOCKED_TEST_LINES)
  else
    load_locked_file(LOCKED_PATH)
    load_locked_file(LOCKED_MANUAL_PATH)
  end
end

function locked_strategy_for_profile(profile, proto, scope)
  if not profile then return nil end
  profile = string.lower(tostring(profile))
  proto = string.lower(tostring(proto or "tls"))
  scope = string.lower(tostring(scope or "default"))
  load_locked_tables()
  local values = lock_table(proto)
  local function lookup(candidate)
    local conflicts = LOCKED_CONFLICTS[candidate]
    if conflicts and conflicts[proto] and conflicts[proto][profile] then return nil, true end
    return values[candidate] and values[candidate][profile], false
  end
  local result, conflict = lookup(scope)
  if result ~= nil or conflict or scope == "default" then return result end
  return lookup("default")
end

function locked_strategy_for_scope(scope, profile, proto)
  return locked_strategy_for_profile(profile, proto, scope)
end

function locked_conflict_count()
  load_locked_tables()
  return LOCKED_CONFLICTS_TOTAL
end

function locked_load_lines_for_tests(lines)
  LOCKED_TEST_LINES = lines or {}
  last_load = 0
  load_locked_tables()
end

local function load_exclude_hostlist(path)
  local cached = EXCLUDE_HOSTLISTS[path]
  local now = os.time() or 0
  if cached and (now - cached.loaded_at) < cache_ttl then
    return cached.hosts
  end

  local hosts = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      local host = string.match(line, "^%s*([^#%s]+)")
      if host and host ~= "" then
        host = string.lower(host:gsub("%.+$", ""))
        if host ~= "" then hosts[host] = true end
      end
    end
    f:close()
  end
  EXCLUDE_HOSTLISTS[path] = { loaded_at = now, hosts = hosts }
  return hosts
end

-- These three helpers are also used by circular_quality.  Keep their
-- hostname and per-connection cache semantics in one place.
function hostlist_has_host(path, host)
  if not path or path == "" or not host or host == "" then return false end
  host = string.lower(tostring(host):gsub("%.+$", ""))
  local hosts = load_exclude_hostlist(path)
  while host and host ~= "" do
    if hosts[host] then return true end
    host = string.match(host, "^[^.]+%.(.+)$")
  end
  return false
end

local function load_substring_hostlist(path)
  local cached = SUBSTRING_HOSTLISTS[path]
  local now = os.time() or 0
  if cached and (now - cached.checked_at) < cache_ttl then
    return cached
  end

  local file_stat
  if type(stat) == "function" then
    file_stat = stat(path)
  end
  if cached and file_stat and cached.mtime == file_stat.mtime and cached.size == file_stat.size then
    cached.checked_at = now
    return cached
  end

  local needles = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      local needle = string.match(line, "^%s*([^#%s]+)")
      if needle and needle ~= "" then
        needle = string.lower(needle)
        needles[#needles + 1] = needle
      end
    end
    f:close()
  end
  cached = {
    checked_at = now,
    mtime = file_stat and file_stat.mtime,
    size = file_stat and file_stat.size,
    needles = needles,
    matches = {}
  }
  SUBSTRING_HOSTLISTS[path] = cached
  return cached
end

-- Literal, case-insensitive substring matching. Unlike a regular hostlist,
-- "cdn" matches cdn-delivery.com, mycdn.com and extracdnnetwork.com.
function substring_hostlist_matches(path, host)
  if not path or path == "" or not host or host == "" then return false end
  host = string.lower(tostring(host):gsub("%.+$", ""))
  local list = load_substring_hostlist(path)
  local matched = list.matches[host]
  if matched ~= nil then return matched end
  for _, needle in ipairs(list.needles) do
    if string.find(host, needle, 1, true) then
      list.matches[host] = true
      return true
    end
  end
  list.matches[host] = false
  return false
end

function substring_hostlist_matches_desync(desync, path, host)
  local lua_state = desync.track and desync.track.lua_state
  if not lua_state then return substring_hostlist_matches(path, host) end
  lua_state.substring_hostlists = lua_state.substring_hostlists or {}
  local matched = lua_state.substring_hostlists[path]
  if matched == nil then
    matched = substring_hostlist_matches(path, host)
    lua_state.substring_hostlists[path] = matched
  end
  return matched
end

-- Client scopes use a dedicated firewall-mark namespace.  Keep this helper
-- self-contained: locked.lua is loaded before the other Lua extensions and
-- must also work with Lua 5.1, where bit32 is not guaranteed to exist.
local CLIENT_SCOPE_DEFAULT = "default"
local CLIENT_SCOPE_DEFAULT_MARK = 0x40000000
local CLIENT_SCOPE_DEFAULT_POSTNAT_MARK = 0x20000000
local CLIENT_SCOPE_UINT32_MAX = 4294967295
local CLIENT_SCOPE_LAST_SEEN = CLIENT_SCOPE_DEFAULT
local CLIENT_SCOPE_LAST_REASON = "disabled"
local function client_scope_value(name)
  return rawget(_G, name)
end

local function client_scope_number(value)
  local number
  if type(value) == "number" then
    number = value
  elseif type(value) == "string" then
    local text = string.match(value, "^%s*(.-)%s*$")
    if string.match(text, "^0[xX][0-9a-fA-F]+$") then
      number = tonumber(string.sub(text, 3), 16)
    elseif string.match(text, "^%d+$") then
      number = tonumber(text, 10)
    end
  end
  if not number or number < 0 or number ~= math.floor(number)
      or number > CLIENT_SCOPE_UINT32_MAX then return nil end
  return number
end

local function client_scope_band(left, right)
  local result, bit = 0, 1
  while left > 0 and right > 0 do
    if left % 2 == 1 and right % 2 == 1 then result = result + bit end
    left, right, bit = math.floor(left / 2), math.floor(right / 2), bit * 2
  end
  return result
end

local function client_scope_config_status()
  local enabled = client_scope_value("CLIENT_SCOPE_ENABLE")
  local mask = client_scope_number(client_scope_value("CLIENT_SCOPE_MARK_MASK"))
  local shift = client_scope_number(client_scope_value("CLIENT_SCOPE_MARK_SHIFT"))
  local max_scope = client_scope_number(client_scope_value("CLIENT_SCOPE_MARK_MAX"))
  if not (enabled == 1 or enabled == "1" or enabled == true) then return nil, "disabled" end
  if not mask or mask == 0 then return nil, "missing-mask" end
  if not shift or shift > 31 or not max_scope or max_scope == 0 then return nil, "invalid-mask" end
  local service_mark = client_scope_number(client_scope_value("DESYNC_MARK")) or CLIENT_SCOPE_DEFAULT_MARK
  local postnat_mark = client_scope_number(client_scope_value("DESYNC_MARK_POSTNAT")) or CLIENT_SCOPE_DEFAULT_POSTNAT_MARK
  if client_scope_band(mask, service_mark) ~= 0 or client_scope_band(mask, postnat_mark) ~= 0 then
    return nil, "mask-conflict"
  end
  if mask % (2 ^ shift) ~= 0 then return nil, "invalid-mask" end
  return { mask = mask, shift = shift, max_scope = max_scope }, nil
end

local function client_scope_record(scope, reason)
  CLIENT_SCOPE_LAST_SEEN = scope or CLIENT_SCOPE_DEFAULT
  CLIENT_SCOPE_LAST_REASON = reason or "no-scoped-lock"
end

local function client_scope_store(desync, scope)
  if type(desync.track) == "table" then
    desync.track.lua_state = desync.track.lua_state or {}
    desync.track.lua_state.client_scope = scope
  end
  return scope
end

function desync_client_scope(desync)
  if type(desync) ~= "table" then
    client_scope_record(CLIENT_SCOPE_DEFAULT, "missing-mark")
    return CLIENT_SCOPE_DEFAULT
  end
  local config, config_reason = client_scope_config_status()
  if not config then
    client_scope_record(CLIENT_SCOPE_DEFAULT, config_reason)
    return client_scope_store(desync, CLIENT_SCOPE_DEFAULT)
  end
  local state = type(desync.track) == "table" and desync.track.lua_state
  if type(state) == "table" and state.client_scope == CLIENT_SCOPE_DEFAULT then
    client_scope_record(state.client_scope, "missing-mark")
    return state.client_scope
  end
  if type(state) == "table" then
    local saved = string.match(tostring(state.client_scope), "^mark:(%d+)$")
    local number = client_scope_number(saved)
    if number and number > 0 and number <= config.max_scope then
      client_scope_record(state.client_scope, "no-scoped-lock")
      return state.client_scope
    end
  end
  local fwmark = client_scope_number(desync.fwmark)
  if not fwmark then
    client_scope_record(CLIENT_SCOPE_DEFAULT, "missing-mark")
    return client_scope_store(desync, CLIENT_SCOPE_DEFAULT)
  end
  local scope_number = math.floor(client_scope_band(fwmark, config.mask) / (2 ^ config.shift))
  if scope_number == 0 or scope_number > config.max_scope then
    client_scope_record(CLIENT_SCOPE_DEFAULT, "invalid-mark")
    return client_scope_store(desync, CLIENT_SCOPE_DEFAULT)
  end
  local scope = "mark:" .. tostring(scope_number)
  client_scope_record(scope, "no-scoped-lock")
  return client_scope_store(desync, scope)
end

-- Deliberately returns only aggregate, scope-safe fields.  Payloads and source
-- addresses must never become part of normal diagnostics.
function client_scope_diagnostics()
  local config, reason = client_scope_config_status()
  load_locked_tables()
  local mode = config and "mark" or "disabled"
  return {
    mode = mode,
    mask = config and config.mask or 0,
    shift = config and config.shift or 0,
    max_scope = config and config.max_scope or 0,
    scoped_lock_count = CLIENT_SCOPE_SCOPED_LOCK_COUNT,
    conflicts = LOCKED_CONFLICTS_TOTAL,
    last_seen_scope = CLIENT_SCOPE_LAST_SEEN,
    fallback_reason = config and (CLIENT_SCOPE_LAST_REASON == "disabled" and "no-scoped-lock" or CLIENT_SCOPE_LAST_REASON) or reason,
  }
end

function desync_profile_key(desync)
  if desync.profile then return tostring(desync.profile) end
  if desync.profile_id then return tostring(desync.profile_id) end
  if desync.profileid then return tostring(desync.profileid) end
  if desync.profile_num then return tostring(desync.profile_num) end
  if desync.profile_name then return tostring(desync.profile_name) end
  if desync.arg and desync.arg.profile then return tostring(desync.arg.profile) end
  if desync.arg and desync.arg.key then return tostring(desync.arg.key) end
  if desync.func_instance then return tostring(desync.func_instance) end
  return "default"
end

local function desync_proto(desync)
  if desync.dis and desync.dis.udp then
    return "udp"
  end
  if desync.arg and desync.arg.proto then
    local proto = string.lower(tostring(desync.arg.proto))
    if proto == "udp" or proto == "http" or proto == "tls" then
      return proto
    end
  end
  local key = desync_profile_key(desync)
  if key == "5" or key == "6" or key == "7" then
    return "udp"
  end
  if desync.l7payload == "http_req" or desync.l7payload == "http_reply" then
    return "http"
  end
  return "tls"
end

function desync_allow_nohost(desync)
  local allow_nohost = desync.arg and desync.arg.allow_nohost
  return allow_nohost == "1" or allow_nohost == 1 or allow_nohost == true
end

function desync_hostname(desync)
  if desync.hostname then return tostring(desync.hostname) end
  if desync.host then return tostring(desync.host) end
  if desync.track and desync.track.hostname then return tostring(desync.track.hostname) end
  if desync.track and desync.track.host then return tostring(desync.track.host) end
  if desync.http_host then return tostring(desync.http_host) end
  if desync.sni then return tostring(desync.sni) end
  if desync.tls_sni then return tostring(desync.tls_sni) end
  if desync.server_name then return tostring(desync.server_name) end
  if desync.tls and desync.tls.sni then return tostring(desync.tls.sni) end
  if desync.tls and desync.tls.server_name then return tostring(desync.tls.server_name) end
  if desync.http and desync.http.host then return tostring(desync.http.host) end
  if desync.arg and desync.arg.host then return tostring(desync.arg.host) end
  if desync.arg and desync.arg.hostname then return tostring(desync.arg.hostname) end
  if desync.arg and desync.arg.sni then return tostring(desync.arg.sni) end
  if desync.arg and desync.arg.tls_sni then return tostring(desync.arg.tls_sni) end
  if desync.arg and desync.arg.server_name then return tostring(desync.arg.server_name) end
  if desync.arg and desync.arg.http_host then return tostring(desync.arg.http_host) end
  return nil
end

function circular_locked(ctx, desync)
  orchestrate(ctx, desync)
  local allow_nohost_enabled = desync_allow_nohost(desync)
  if not desync.track and not allow_nohost_enabled then
    DLOG_ERR("circular_locked: conntrack is missing but required")
    return
  end

  local proto = desync_proto(desync)
  local base_profile = desync_profile_key(desync)
  local host
  if allow_nohost_enabled then
    host = desync_hostname(desync)
    if host and host ~= "" then
      host = host:gsub("%.$", "")
      host = string.lower(host)
      if host ~= "" then
        DLOG("circular_locked: allow_nohost profile from host "..host)
      end
    end
  end
  -- Hostname for list gates. Extracted even without allow_nohost so every
  -- profile can apply exclude lists; does not participate in profile choice.
  local gate_host = host
  if not gate_host or gate_host == "" then
    gate_host = desync_hostname(desync)
    if gate_host and gate_host ~= "" then
      gate_host = string.lower(tostring(gate_host):gsub("%.$", ""))
    end
  end
  local route_substrings = desync.arg and desync.arg.route_substrings
  local route_key = desync.arg and desync.arg.route_key
  if route_substrings and route_key and substring_hostlist_matches_desync(desync, route_substrings, gate_host) then
    base_profile = tostring(route_key)
    desync.arg.key = base_profile
    DLOG("circular_locked: substring routed to profile="..base_profile.." host="..tostring(gate_host))
  end
  local profile = (host and host ~= "") and host or base_profile
  if hostlist_has_host(desync.arg and desync.arg.exclude_hostlist, gate_host) then
    DLOG("circular_locked: excluded by hostlist profile="..profile.." host="..tostring(gate_host))
    return VERDICT_PASS
  end
  local exclude_substrings = desync.arg and desync.arg.exclude_substrings
  if exclude_substrings and substring_hostlist_matches_desync(desync, exclude_substrings, gate_host) then
    DLOG("circular_locked: excluded by substring profile="..profile.." host="..tostring(gate_host))
    return VERDICT_PASS
  end
  local include_substrings = desync.arg and desync.arg.include_substrings
  if include_substrings and not substring_hostlist_matches_desync(desync, include_substrings, gate_host) then
    DLOG("circular_locked: no substring match profile="..profile.." host="..tostring(gate_host))
    lua_cutoff(ctx)
    return VERDICT_PASS
  end

  local hrec
  if desync.track then
    hrec = automate_host_record(desync)
  end
  if not hrec then
    if allow_nohost_enabled then
      hrec = {}
      DLOG("circular_locked: allow_nohost enabled, using local record")
    else
      DLOG("circular_locked: passing with no tampering")
      return
    end
  end

  if not hrec.ctstrategy then
    local uniq = {}
    local n = 0
    for i, instance in pairs(desync.plan) do
      if instance.arg.strategy then
        n = tonumber(instance.arg.strategy)
        if not n or n < 1 then
          error("circular_locked: strategy number '"..tostring(instance.arg.strategy).."' is invalid")
        end
        uniq[tonumber(instance.arg.strategy)] = true
        if instance.arg.final then
          hrec.final = n
        end
      end
    end
    n = 0
    for i, v in pairs(uniq) do
      n = n + 1
    end
    if n ~= #uniq then
      error("circular_locked: strategies numbers must start from 1 and increment. gaps are not allowed.")
    end
    hrec.ctstrategy = n
  end

  if hrec.ctstrategy == 0 then
    error("circular_locked: add strategy=N tag argument to each following instance ! N must start from 1 and increment")
  end

  local scope = desync_client_scope(desync)
  local locked = locked_strategy_for_profile(profile, proto, scope)
  if (not locked) and profile ~= base_profile then
    locked = locked_strategy_for_profile(base_profile, proto, scope)
    if locked then
      DLOG("circular_locked: fallback lock profile="..base_profile.." for host profile="..profile)
    end
  end
  if locked == 0 then
    DLOG("circular_locked: profile disabled by lock 0 profile="..profile)
    return VERDICT_PASS
  elseif locked and locked >= 1 and locked <= hrec.ctstrategy then
    hrec.nstrategy = locked
    if scope ~= "default" then
      DLOG("circular_locked: locked strategy "..hrec.nstrategy.." scope="..scope.." profile="..profile)
    else
      DLOG("circular_locked: locked strategy "..hrec.nstrategy.." profile="..profile)
    end
  else
    hrec.nstrategy = 1
    DLOG("circular_locked: start from strategy 1 profile="..profile)
  end

  local verdict = VERDICT_PASS
  DLOG("circular_locked: current strategy "..hrec.nstrategy.." profile="..profile)
  while true do
    local instance = plan_instance_pop(desync)
    if not instance then break end
    if instance.arg.strategy and tonumber(instance.arg.strategy) == hrec.nstrategy then
      verdict = plan_instance_execute(desync, verdict, instance)
    end
  end

  return verdict
end


-- Additional TCP desync methods kept in the already deployed z2r Lua extension.
local function z2r_fake_segment_part(fake_data, fake_pat, pos_start, part_len)
	local part = ""
	if fake_data and pos_start <= #fake_data then
		part = string.sub(fake_data, pos_start, pos_start + part_len - 1)
	end
	if #part < part_len then
		part = part .. pattern(fake_pat, 1, part_len - #part)
	end
	return part
end

local function fakemultidisorder_part_bounds(pos, data_len, part_n)
	local pos_start = part_n == 1 and 1 or pos[part_n - 1]
	local pos_end = part_n <= #pos and (pos[part_n] - 1) or data_len
	return pos_start, pos_end
end



-- nfqws2 custom : "multidisorder" with interleaved "fake"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- FOOLING AND REPEATS APPLIED ONLY TO FAKES. real parts keep only ip_id and tcp_ts_up, like fakeddisorder
-- arg : pos=<posmarker list> . position marker list. for example : "1,host,midsld+1,-10"
-- arg : fake_blob=<blob> - fake payload source. slices are taken from matching offsets
-- arg : pattern=<blob> - padding pattern for fake slices when fake_blob is shorter. default - zero byte
-- arg : fake_count=N - how many initial original-order segments to fake before real disorder. default - 1
-- arg : fake_all - fake all segments before real disorder

-- arg : nofakeN - skip N-th fake segment in original segment numbering, for example nofake1 or nofake3
-- arg : seqovl=<posmarker> . same semantics as multidisorder: decrease seq number of the second segment in the original order
-- arg : seqovl_pattern=<blob> . override pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload/reasm_data as real payload
-- arg : optional - skip if blob/fake_blob is absent. use zero pattern if seqovl_pattern or pattern blob is absent
-- arg : tls_mod=<list> - optional TLS modifications for fake_blob, same format as in fake()
-- arg : nodrop - do not drop current dissect
function fakemultidisorder(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end

	direction_cutoff_opposite(ctx, desync)

	if not desync.arg.fake_blob then
		error("fakemultidisorder: 'fake_blob' arg required")
	end

	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("fakemultidisorder: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	if desync.arg.optional and not blob_exist(desync, desync.arg.fake_blob) then
		DLOG("fakemultidisorder: fake_blob '"..desync.arg.fake_blob.."' not found. skipped")
		return
	end

	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			if b_debug then DLOG("fakemultidisorder: split pos: "..spos) end

			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("fakemultidisorder: resolved split pos: "..table.concat(zero_based_pos(pos), " ")) end
			delete_pos_1(pos)

			if #pos>0 then
				local seqovl
				if desync.arg.seqovl then
					seqovl = resolve_pos(data, desync.l7payload, desync.arg.seqovl)
					if not seqovl then
						DLOG("fakemultidisorder: seqovl cancelled because could not resolve marker '"..desync.arg.seqovl.."'")
					end
				end

				local fake_data = blob(desync, desync.arg.fake_blob)
				if desync.reasm_data and desync.arg.tls_mod then
					local pl = tls_mod_shim(desync, fake_data, desync.arg.tls_mod, desync.reasm_data)
					if pl then fake_data = pl end
				end

				local fake_pat = "\x00"
				if desync.arg.pattern then
					if desync.arg.optional and not blob_exist(desync, desync.arg.pattern) then
						DLOG("fakemultidisorder: blob '"..desync.arg.pattern.."' not found. using zero pattern")
					else
						fake_pat = blob(desync, desync.arg.pattern)
					end
				end

				local opts_orig = {
					rawsend = rawsend_opts_base(desync),
					reconstruct = {},
					ipfrag = {},
					ipid = desync.arg,
					fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
				}
				local opts_fake = {
					rawsend = rawsend_opts(desync),
					reconstruct = reconstruct_opts(desync),
					ipfrag = {},
					ipid = desync.arg,
					fooling = desync.arg
				}

				local part_count = #pos + 1
				local fake_count = tonumber(desync.arg.fake_count) or 1
				if desync.arg.fake_all then
					fake_count = part_count
				elseif fake_count < 0 then
					fake_count = 0
				elseif fake_count > part_count then
					fake_count = part_count
				end

				for part_n=1,fake_count do
					local pos_start, pos_end = fakemultidisorder_part_bounds(pos, #data, part_n)
					local part_len = pos_end - pos_start + 1
					local fake_part

					if not desync.arg["nofake"..tostring(part_n)] then
						fake_part = z2r_fake_segment_part(fake_data, fake_pat, pos_start, part_len)
						if b_debug then
							DLOG("fakemultidisorder: sending prefake part "..part_n.." "..(pos_start-1).."-"..(pos_end-1).." len="..#fake_part.." : "..hexdump_dlog(fake_part))
						end
						if not rawsend_payload_segmented(desync, fake_part, pos_start-1, opts_fake) then
							return VERDICT_PASS
						end
					end
				end

				for i=#pos,0,-1 do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part_n = i + 1

					local part = string.sub(data, pos_start, pos_end)
					local ovl = 0
					if i==1 and seqovl and seqovl>0 then
						if seqovl>=pos[1] then
							DLOG("fakemultidisorder: seqovl cancelled because seqovl "..(seqovl-1).." is not less than the first split pos "..(pos[1]-1))
						else
							ovl = seqovl - 1
							local pat = "\x00"
							if desync.arg.seqovl_pattern then
								if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
									DLOG("fakemultidisorder: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
								else
									pat = blob(desync, desync.arg.seqovl_pattern)
								end
							end
							part = pattern(pat, 1, ovl) .. part
						end
					end

					if b_debug then
						DLOG("fakemultidisorder: sending real part "..part_n.." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..ovl.." : "..hexdump_dlog(part))
					end
					if not rawsend_payload_segmented(desync, part, pos_start-1-ovl, opts_orig) then
						return VERDICT_PASS
					end
				end

				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("fakemultidisorder: no valid split positions")
			end
		else
			DLOG("fakemultidisorder: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end


-- nfqws2 custom : "multisplit" with interleaved "fake"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- FOOLING AND REPEATS APPLIED ONLY TO FAKES. real parts keep only ip_id and tcp_ts_up, like fakedsplit
-- arg : pos=<posmarker list> . position marker list. for example : "1,host,midsld+1,-10"
-- arg : fake_blob=<blob> - fake payload source. slices are taken from matching offsets
-- arg : pattern=<blob> - padding pattern for fake slices when fake_blob is shorter. default - zero byte
-- arg : nofakeN - skip N-th fake segment, for example nofake1 or nofake3
-- arg : seqovl=N . decrease seq number of the first real segment by N and fill N bytes with pattern (default - all zero)
-- arg : seqovl_pattern=<blob> . override seqovl pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload/reasm_data as real payload
-- arg : optional - skip if blob/fake_blob is absent. use zero pattern if seqovl_pattern or pattern blob is absent
-- arg : tls_mod=<list> - optional TLS modifications for fake_blob, same format as in fake()
-- arg : nodrop - do not drop current dissect
function fakemultisplit(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end

	direction_cutoff_opposite(ctx, desync)

	if not desync.arg.fake_blob then
		error("fakemultisplit: 'fake_blob' arg required")
	end

	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("fakemultisplit: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	if desync.arg.optional and not blob_exist(desync, desync.arg.fake_blob) then
		DLOG("fakemultisplit: fake_blob '"..desync.arg.fake_blob.."' not found. skipped")
		return
	end

	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			if b_debug then DLOG("fakemultisplit: split pos: "..spos) end

			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("fakemultisplit: resolved split pos: "..table.concat(zero_based_pos(pos), " ")) end
			delete_pos_1(pos)

			if #pos>0 then
				local fake_data = blob(desync, desync.arg.fake_blob)
				if desync.reasm_data and desync.arg.tls_mod then
					local pl = tls_mod_shim(desync, fake_data, desync.arg.tls_mod, desync.reasm_data)
					if pl then fake_data = pl end
				end

				local fake_pat = "\x00"
				if desync.arg.pattern then
					if desync.arg.optional and not blob_exist(desync, desync.arg.pattern) then
						DLOG("fakemultisplit: blob '"..desync.arg.pattern.."' not found. using zero pattern")
					else
						fake_pat = blob(desync, desync.arg.pattern)
					end
				end

				local opts_orig = {
					rawsend = rawsend_opts_base(desync),
					reconstruct = {},
					ipfrag = {},
					ipid = desync.arg,
					fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
				}
				local opts_fake = {
					rawsend = rawsend_opts(desync),
					reconstruct = reconstruct_opts(desync),
					ipfrag = {},
					ipid = desync.arg,
					fooling = desync.arg
				}

				for i=0,#pos do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part_len = pos_end - pos_start + 1
					local fake_part = z2r_fake_segment_part(fake_data, fake_pat, pos_start, part_len)

					if not desync.arg["nofake"..tostring(i+1)] then
						if b_debug then
							DLOG("fakemultisplit: sending fake part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#fake_part.." : "..hexdump_dlog(fake_part))
						end
						if not rawsend_payload_segmented(desync, fake_part, pos_start-1, opts_fake) then
							return VERDICT_PASS
						end
					end

					local part = string.sub(data, pos_start, pos_end)
					local seqovl = 0
					if i==0 and desync.arg.seqovl and tonumber(desync.arg.seqovl)>0 then
						seqovl = tonumber(desync.arg.seqovl)
						local pat = "\x00"
						if desync.arg.seqovl_pattern then
							if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
								DLOG("fakemultisplit: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
							else
								pat = blob(desync, desync.arg.seqovl_pattern)
							end
						end
						part = pattern(pat, 1, seqovl) .. part
					end

					if b_debug then
						DLOG("fakemultisplit: sending real part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..seqovl.." : "..hexdump_dlog(part))
					end
					if not rawsend_payload_segmented(desync, part, pos_start-1-seqovl, opts_orig) then
						return VERDICT_PASS
					end
				end

				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("fakemultisplit: no valid split positions")
			end
		else
			DLOG("fakemultisplit: not acting on further replay pieces")
		end

		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end
