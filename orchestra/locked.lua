local LOCKED_PATH = "/opt/zapret2/extra_strats/cache/orchestra/locked.tsv"
local LOCKED_MANUAL_PATH = "/opt/zapret2/extra_strats/cache/orchestra/locked.manual.tsv"
local last_load = 0
local cache_ttl = 2
local LOCKED_TLS = {}
local LOCKED_HTTP = {}
local LOCKED_UDP = {}
local EXCLUDE_HOSTLISTS = {}

local function load_locked_file(path)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    if line ~= "" and not string.match(line, "^%s*#") then
      local p1, p2, p3 = string.match(line, "^([^\t]+)\t([^\t]+)\t([^\t]+)$")
      if p1 then
        local profile = string.lower(p1)
        local proto = string.lower(p2)
        local strat = tonumber(p3)
        if strat then
          if proto == "http" then LOCKED_HTTP[profile] = strat
          elseif proto == "udp" then LOCKED_UDP[profile] = strat
          else LOCKED_TLS[profile] = strat end
        end
      else
        local p, s = string.match(line, "^([^\t]+)\t([^\t]+)$")
        if p and s then
          local strat = tonumber(s)
          if strat then LOCKED_TLS[string.lower(p)] = strat end
        end
      end
    end
  end
  f:close()
end

local function load_locked_tables()
  local now = os.time()
  if now and (now - last_load) < cache_ttl then return end
  last_load = now or 0
  LOCKED_TLS = {}
  LOCKED_HTTP = {}
  LOCKED_UDP = {}

  load_locked_file(LOCKED_PATH)
  load_locked_file(LOCKED_MANUAL_PATH)
end

function locked_strategy_for_profile(profile, proto)
  if not profile then return nil end
  profile = string.lower(tostring(profile))
  proto = string.lower(tostring(proto or "tls"))
  load_locked_tables()
  if proto == "http" then return LOCKED_HTTP[profile] end
  if proto == "udp" then return LOCKED_UDP[profile] end
  return LOCKED_TLS[profile]
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

local function hostlist_has_host(path, host)
  if not path or path == "" or not host or host == "" then return false end
  host = string.lower(tostring(host):gsub("%.+$", ""))
  local hosts = load_exclude_hostlist(path)
  while host and host ~= "" do
    if hosts[host] then return true end
    host = string.match(host, "^[^.]+%.(.+)$")
  end
  return false
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

local function desync_allow_nohost(desync)
  local allow_nohost = desync.arg and desync.arg.allow_nohost
  return allow_nohost == "1" or allow_nohost == 1 or allow_nohost == true
end

local function desync_hostname(desync)
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

  local proto = desync_proto(desync)
  local base_profile = desync_profile_key(desync)
  local profile = base_profile
  local host
  if allow_nohost_enabled then
    host = desync_hostname(desync)
    if host and host ~= "" then
      host = host:gsub("%.$", "")
      host = string.lower(host)
      if host ~= "" then
        profile = host
        DLOG("circular_locked: allow_nohost profile from host "..profile)
      end
    end
  end
  if hostlist_has_host(desync.arg and desync.arg.exclude_hostlist, host) then
    DLOG("circular_locked: excluded by hostlist profile="..profile.." host="..host)
    return VERDICT_PASS
  end

  local locked = locked_strategy_for_profile(profile, proto)
  if (not locked) and profile ~= base_profile then
    locked = locked_strategy_for_profile(base_profile, proto)
    if locked then
      DLOG("circular_locked: fallback lock profile="..base_profile.." for host profile="..profile)
    end
  end
  if locked and locked >= 1 and locked <= hrec.ctstrategy then
    hrec.nstrategy = locked
    DLOG("circular_locked: locked strategy "..hrec.nstrategy.." profile="..profile)
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
