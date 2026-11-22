-- fakemultisplit/fakemultidisorder are based on avatarDD/zapret-gui; see ../THIRD_PARTY_NOTICES.md.
local LOCKED_PATH = "/opt/zator/extra_strats/cache/orchestra/locked.tsv"
local LOCKED_MANUAL_PATH = "/opt/zator/extra_strats/cache/orchestra/locked.manual.tsv"
-- Per-mark lock-файлы: <orchestra>/scopes/mark_N.tsv (3 колонки, без колонки scope).
-- Список активных mark'ов берём из маппинга клиентов — он и так перечисляет
-- все mark'и, чей трафик маркируется firewall'ом.
local LOCKED_DIR = string.match(LOCKED_PATH, "^(.*)/[^/]+$") or "/opt/zator/extra_strats/cache/orchestra"
local SCOPED_DIR = LOCKED_DIR .. "/scopes"
local SCOPED_MAP_PATH = LOCKED_DIR .. "/../client_scope.tsv"
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
local BLOB_OVERRIDE_PATH = LOCKED_DIR .. "/blob_override.tsv"
local BLOB_OVERRIDES = {}
local SNI_OVERRIDE_PATH = LOCKED_DIR .. "/sni_override.tsv"
local SNI_OVERRIDES = {}
-- mode_override.tsv: «profile<TAB>clone|classic» — режим фейков профиля.
local MODE_OVERRIDE_PATH = LOCKED_DIR .. "/mode_override.tsv"
local MODE_OVERRIDES = {}
-- clonesize.tsv: «profile<TAB>байты» — максимальный размер клон-пакета профиля.
local CLONESIZE_PATH = LOCKED_DIR .. "/clonesize.tsv"
local CLONE_SIZES = {}
local ADAPTIVE_RULES_PATH = os.getenv("Z2R_ADAPTIVE_RULES_FILE") or "/tmp/z2r-adaptive/rules.tsv"
local ADAPTIVE_RULES_SNAPSHOT_PATH = (os.getenv("ZATOR_ROOT") or "/opt/zator") .. "/extra_strats/cache/adaptive/rules.tsv"
local ADAPTIVE_BROWSER_TRIALS_PATH = os.getenv("Z2R_ADAPTIVE_BROWSER_TRIALS_FILE") or "/tmp/z2r-adaptive/browser/trials.tsv"
local ADAPTIVE_BROWSER_FLOW_DIR = os.getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR")
  or ((os.getenv("Z2R_ADAPTIVE_DIR") or "/tmp/z2r-adaptive") .. "/browser/flows")
local function adaptive_quic_host_allowed(host)
  return type(host) == "string" and (host == "youtube.com" or host:match("%.youtube%.com$") or
    host == "googlevideo.com" or host:match("%.googlevideo%.com$") or
    host == "youtubei.googleapis.com" or host:match("%.youtubei%.googleapis%.com$"))
end
local ADAPTIVE_MODE_PATH = (os.getenv("ZATOR_ROOT") or "/opt/zator") .. "/extra_strats/cache/adaptive/mode"
local ADAPTIVE_DEFAULT_SCOPE_PATH = (os.getenv("ZATOR_ROOT") or "/opt/zator") .. "/extra_strats/cache/adaptive/apply-default-scope"
local ADAPTIVE_MODE = "OFF"
do
  local f = io.open(ADAPTIVE_MODE_PATH, "r")
  if f then
    local mode = f:read("*l")
    if mode == "OBSERVE" or mode == "TEST_ONLY" or mode == "AUTO" or mode == "AGENT_BETA" then ADAPTIVE_MODE = mode end
    f:close()
  end
end
-- Environment opt-in alone is insufficient: TEST_ONLY must never select a
-- stored rule, even if a stale daemon environment still carries the flag.
local ADAPTIVE_RULES_APPLY = ADAPTIVE_MODE == "AGENT_BETA"
  or (os.getenv("Z2R_ADAPTIVE_RULES_APPLY") == "1" and ADAPTIVE_MODE == "AUTO")
local ADAPTIVE_DEFAULT_SCOPE_APPLY = ADAPTIVE_MODE == "AUTO"
do
  if ADAPTIVE_MODE == "AGENT_BETA" then
    local f = io.open(ADAPTIVE_DEFAULT_SCOPE_PATH, "r")
    if f then ADAPTIVE_DEFAULT_SCOPE_APPLY = f:read("*l") == "1"; f:close() end
  end
end
local ADAPTIVE_EVENTS_PATH = os.getenv("Z2R_ADAPTIVE_EVENTS_FILE") or "/tmp/z2r-adaptive/events.tsv"
local ADAPTIVE_RAMP_TARGETS_PATH = os.getenv("Z2R_ADAPTIVE_RAMP_TARGETS_FILE") or "/tmp/z2r-adaptive/ramp-targets.tsv"
local ADAPTIVE_OBSERVE_ENABLED = ADAPTIVE_MODE == "OBSERVE" or ADAPTIVE_MODE == "TEST_ONLY" or ADAPTIVE_MODE == "AGENT_BETA"
local ADAPTIVE_OBSERVE_EVENTS = {}
local ADAPTIVE_OBSERVE_ORDER = {}
local ADAPTIVE_OBSERVE_COUNT = 0
local ADAPTIVE_RAMP_TARGETS = {}
local ADAPTIVE_RAMP_TARGET_ORDER = {}
local ADAPTIVE_RAMP_TARGET_COUNT = 0
if ADAPTIVE_OBSERVE_ENABLED then
  local f = io.open(ADAPTIVE_EVENTS_PATH, "r")
  if f then
    local count = 0
    for line in f:lines() do
      count = count + 1
      if count > 128 then break end
      local ver, status, host, ip, profile, proto, scope, seen = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)$")
      local valid_kind = proto == "tls" and profile:match("^[1-4]$")
        or proto == "googlevideo-tcp" and profile == "2" and host:match("^[a-z0-9%-]+%.googlevideo%.com$")
        or proto == "quic" and profile == "5" and adaptive_quic_host_allowed(host)
      if ver == "1" and (status == "seen" or status == "needs_verify" or status == "suspected_failure" or status == "active_rule_degraded") and #host <= 253
        and host:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") and valid_kind
        and (scope == "default" or scope:match("^mark:%d+$")) then
        local key = table.concat({host, ip, profile, proto, scope}, "\0")
        if not ADAPTIVE_OBSERVE_EVENTS[key] then
          local event = {key = key, host = host, ip = ip, profile = profile, proto = proto,
            scope = scope, status = status, seen = tonumber(seen) or 0,
            failure_count = (status == "suspected_failure" or status == "active_rule_degraded") and 2 or 0}
          ADAPTIVE_OBSERVE_EVENTS[key] = event
          ADAPTIVE_OBSERVE_ORDER[#ADAPTIVE_OBSERVE_ORDER + 1] = event
          ADAPTIVE_OBSERVE_COUNT = ADAPTIVE_OBSERVE_COUNT + 1
        end
      end
    end
    f:close()
  end
end
local ADAPTIVE_RULES = {}
local ADAPTIVE_RULE_CONFLICTS = {}
local ADAPTIVE_TEST_LINES = nil
local ADAPTIVE_TEST_RUNTIME_STAMP = nil
local ADAPTIVE_BROWSER_TRIALS = {}
local ADAPTIVE_BROWSER_TEST_LINES = nil
local ADAPTIVE_BROWSER_TEST_NOW = nil
local function adaptive_runtime_stat_stamp(path)
  if type(stat) ~= "function" then return nil end
  local info = stat(path)
  if type(info) ~= "table" or info.mtime == nil or info.size == nil then return "0:0" end
  local mtime, size = tonumber(info.mtime), tonumber(info.size)
  if not mtime or not size then return "0:0" end
  return tostring(math.floor(mtime)) .. ":" .. tostring(math.floor(size))
end
local ADAPTIVE_RUNTIME_STAMP
do
  local zapret_root = os.getenv("ZAPRET2_ROOT") or "/opt/zapret2"
  local zator_root = os.getenv("ZATOR_ROOT") or "/opt/zator"
  local paths = {
    zapret_root .. "/config", zapret_root .. "/nfq2/nfqws2",
    zapret_root .. "/lua/zapret-lib.lua", zapret_root .. "/lua/zapret-antidpi.lua",
    zapret_root .. "/lua/zapret-auto.lua",
    LOCKED_DIR .. "/blob_override.tsv", LOCKED_DIR .. "/sni_override.tsv",
    LOCKED_DIR .. "/mode_override.tsv", LOCKED_DIR .. "/clonesize.tsv",
    LOCKED_DIR .. "/custom_strategies.tsv",
    zator_root .. "/lua/client-scope-config.lua",
    zator_root .. "/lua/locked.lua",
    zator_root .. "/lua/rst-guard.lua",
    zator_root .. "/lua/strategy-lock-manager.lua",
    zator_root .. "/lua/combined-detector.lua",
    zator_root .. "/lua/silent-drop-detector.lua",
    zator_root .. "/lua/dns-clone.lua",
    zator_root .. "/lua/fake-adapt.lua",
    zator_root .. "/lua/wssize-ramp.lua",
    zator_root .. "/z2r_lib/adaptive_rules.sh",
    zator_root .. "/z2r_lib/adaptive_media.sh",
    zator_root .. "/z2r_lib/youtube_media.sh",
    zator_root .. "/z2r_lib/supersweep_probe.sh",
    zator_root .. "/tools/adaptive-controller.sh",
  }
  local path_seen = {}
  for _, path in ipairs(paths) do path_seen[path] = true end
  local config = io.open(zapret_root .. "/config", "r")
  if config then
    local in_options = false
    for line in config:lines() do
      if line:match('^NFQWS2_OPT="%s*$') then
        in_options = true
      elseif in_options and line:match('^"%s*$') then
        in_options = false
      elseif in_options then
        for token in line:gmatch("%-%-[^%s]+") do
          local path = token:match("^%-%-blob=[^:]+:@(.+)$") or token:match("^%-%-lua%-init=@(.+)$")
          if path then
            if path:match("^/opt/zator/") then path = zator_root .. path:sub(11)
            elseif path:match("^/opt/zapret2/") then path = zapret_root .. path:sub(13) end
            if not path_seen[path] then paths[#paths + 1] = path; path_seen[path] = true end
          end
        end
      end
    end
    config:close()
  end
  local stamps = {}
  for _, path in ipairs(paths) do
    stamps[#stamps + 1] = adaptive_runtime_stat_stamp(path)
    if not stamps[#stamps] then break end
  end
  if #stamps == #paths then ADAPTIVE_RUNTIME_STAMP = table.concat(stamps, "|") end
end
-- Isolated adaptive probes opt into one connection-level strategy ACK; normal
-- nfqws2 processes pay only the environment check and never touch the filesystem.
local ADAPTIVE_ACK_PATH = os.getenv("Z2R_ADAPTIVE_ACK_PATH")
local ADAPTIVE_ACK_HOST = os.getenv("Z2R_ADAPTIVE_ACK_HOST")
local ADAPTIVE_ACK_PROFILE = os.getenv("Z2R_ADAPTIVE_ACK_PROFILE")
local ADAPTIVE_ACK_STRATEGY = tonumber(os.getenv("Z2R_ADAPTIVE_ACK_STRATEGY"))
local ADAPTIVE_ACK_TEST_ID = os.getenv("Z2R_ADAPTIVE_TEST_ID")
local ADAPTIVE_ACKED = false

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

-- Per-mark файл: строки «profile<TAB>proto<TAB>strategy» без колонки scope.
-- Скоуп подставляется из имени mark'а; валидация — общая через locked_parse_line.
local function load_scoped_file(path, scope)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local s, profile, proto, strategy = locked_parse_line(scope .. "\t" .. line)
    if s then
      CLIENT_SCOPE_SCOPED_LOCK_COUNT = CLIENT_SCOPE_SCOPED_LOCK_COUNT + 1
      store_locked(s, profile, proto, strategy)
    end
  end
  f:close()
end

local function load_scoped_locks()
  local f = io.open(SCOPED_MAP_PATH, "r")
  if not f then return end
  for line in f:lines() do
    local mark = line:match("^mark:(%d+)\t")
    if mark then
      load_scoped_file(SCOPED_DIR .. "/mark_" .. mark .. ".tsv", "mark:" .. mark)
    end
  end
  f:close()
end

-- blob_override.tsv: «profile<TAB>имя» — per-profile TLS блоб.
-- Подменяется только blob=/fake_blob= со значением maxru|fake_default_tls (зеркало sed'ов п.16).
local function blob_override_parse_line(line)
  if type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  if line == "" or string.match(line, "^%s*#") then return nil end
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = trim(field) end
  if #fields ~= 2 then return nil end
  if not string.match(fields[1], "^%d+$") or not string.match(fields[2], "^[%w_]+$") then return nil end
  return fields[1], fields[2]
end

local function load_blob_override_file(path)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local profile, name = blob_override_parse_line(line)
    if profile then BLOB_OVERRIDES[profile] = name end
  end
  f:close()
end

-- sni_override.tsv: «profile<TAB>домен» — per-profile SNI клон-стратегий.
-- Подменяется арг sni_first у стратегии перед исполнением; пусто = из конфига.
local function sni_override_parse_line(line)
  if type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  if line == "" or string.match(line, "^%s*#") then return nil end
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = trim(field) end
  if #fields ~= 2 then return nil end
  if not string.match(fields[1], "^%d+$")
    or not string.match(fields[2], "^[%w%-%.]+$") then return nil end
  return fields[1], string.lower(fields[2])
end

local function load_sni_override_file(path)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local profile, sni = sni_override_parse_line(line)
    if profile then SNI_OVERRIDES[profile] = sni end
  end
  f:close()
end

-- mode_override.tsv: «profile<TAB>clone|classic» — режим фейков профиля.
-- classic (или нет строки) — штатные блобы стратегии из конфига; clone —
-- блоб инстанса строится в рантайме из ClientHello пользователя.
local function mode_override_parse_line(line)
  if type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  if line == "" or string.match(line, "^%s*#") then return nil end
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = trim(field) end
  if #fields ~= 2 then return nil end
  if not string.match(fields[1], "^%d+$") then return nil end
  if fields[2] ~= "clone" and fields[2] ~= "classic" then return nil end
  return fields[1], fields[2]
end

local function load_mode_override_file(path)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local profile, mode = mode_override_parse_line(line)
    if profile then MODE_OVERRIDES[profile] = mode end
  end
  f:close()
end

-- clonesize.tsv: «profile<TAB>байты» — максимальный размер клон-пакета
-- профиля в режиме clone. Нет строки = без пользовательского ограничения
-- (действует верхняя граница ТСПУ 1200 — Z2R_TLS_FAKE_LIMIT_MAX ниже).
local function clone_size_parse_line(line)
  if type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  if line == "" or string.match(line, "^%s*#") then return nil end
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = trim(field) end
  if #fields ~= 2 then return nil end
  if not string.match(fields[1], "^%d+$") then return nil end
  local size = tonumber(fields[2])
  -- нижняя граница: реальный ClientHello меньше ~64 байт не бывает; выше
  -- 1200 ограничивать смысла нет — там всё равно режет ТСПУ
  if not size or size < 64 or size > 1200 or size % 1 ~= 0 then return nil end
  return fields[1], size
end

local function load_clone_size_file(path)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local profile, size = clone_size_parse_line(line)
    if profile then CLONE_SIZES[profile] = size end
  end
  f:close()
end

local function adaptive_rule_parse_line(line, now)
  if type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  local f = {}
  for value in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = trim(value) end
  if #f ~= 11 or f[1] ~= "1" then return nil end
  local host, ip, profile, proto, scope = f[2], f[3], f[4], f[5], f[6]
  local strategy, fingerprint, catalog, runtime_stamp, expires = tonumber(f[7]), f[8], f[9], f[10], tonumber(f[11])
  if #host > 253 or not host:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") or not host:find(".", 1, true) then return nil end
  local labels_ok = true
  for label in host:gmatch("[^%.]+") do
    if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then labels_ok = false; break end
  end
  if not labels_ok or host:find("%.%.") or host:sub(1, 1) == "." or host:sub(-1) == "." then return nil end
  local octets = {}
  for part in (ip .. "."):gmatch("(.-)%." ) do octets[#octets + 1] = part end
  if #octets ~= 4 then return nil end
  for _, octet in ipairs(octets) do
    local n = tonumber(octet)
    if not octet:match("^%d%d?%d?$") or (#octet > 1 and octet:sub(1, 1) == "0") or not n or n > 255 then return nil end
  end
  local a, b, c = tonumber(octets[1]), tonumber(octets[2]), tonumber(octets[3])
  if a == 0 or a == 10 or a == 127 or a >= 224 or
    (a == 100 and b >= 64 and b <= 127) or (a == 169 and b == 254) or
    (a == 172 and b >= 16 and b <= 31) or
    (a == 192 and (b == 168 or (b == 0 and (c == 0 or c == 2)) or (b == 88 and c == 99))) or
    (a == 198 and (b == 18 or b == 19 or (b == 51 and c == 100))) or
    (a == 203 and b == 0 and c == 113) then return nil end
  local valid_rule = proto == "tls" and profile:match("^[1-4]$")
    or proto == "googlevideo-tcp" and profile == "2" and host:match("^[a-z0-9%-]+%.googlevideo%.com$")
    or proto == "quic" and profile == "5" and adaptive_quic_host_allowed(host)
  if not valid_rule then return nil end
  if scope ~= "default" and not scope:match("^mark:%d%d?%d?%d?%d?$") then
    if not scope:match("^mark:%d+$") or #scope > 10 then return nil end
  end
  if not strategy or strategy < 0 or strategy > 999 or strategy % 1 ~= 0 then return nil end
  if not fingerprint:match("^sha256:[0-9a-f]+$") or #fingerprint ~= 71 then return nil end
  if not catalog:match("^sha256:[0-9a-f]+$") or #catalog ~= 71 then return nil end
  if #runtime_stamp > 2048 or not runtime_stamp:match("^[0-9:|]+$") then return nil end
  if not expires or expires % 1 ~= 0 or expires <= now then return nil end
  return {host = host, ip = ip, profile = profile, proto = proto, scope = scope,
    strategy = strategy, fingerprint = fingerprint, catalog = catalog,
    runtime_stamp = runtime_stamp, expires = expires}
end

local function adaptive_rule_key(rule)
  return table.concat({rule.host, rule.ip, rule.profile, rule.proto, rule.scope}, "\0")
end

local function adaptive_browser_trial_parse_line(line, now)
  if ADAPTIVE_MODE ~= "AGENT_BETA" or type(line) ~= "string" then return nil end
  line = line:gsub(string.char(13) .. "$", "")
  local ver, id, generation, client_id, client_ip, scope, host, ip, profile, proto, strategy, fingerprint, created, expires =
    line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
  if not ver then return nil end
  generation, profile, strategy, created, expires = tonumber(generation), tonumber(profile), tonumber(strategy), tonumber(created), tonumber(expires)
  if ver ~= "1" or not id:match("^[0-9a-f]+$") or #id ~= 32 or not generation or generation < 1 or
    not client_id:match("^[0-9a-f]+$") or #client_id ~= 32 or not host:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") or #host > 253 then return nil end
  local function valid_ip(value, public)
    local octets = {}
    for part in (value .. "."):gmatch("(.-)%.") do octets[#octets + 1] = part end
    if #octets ~= 4 then return false end
    local n = {}
    for i, part in ipairs(octets) do
      n[i] = tonumber(part)
      if not part:match("^%d%d?%d?$") or (#part > 1 and part:sub(1, 1) == "0") or not n[i] or n[i] > 255 then return false end
    end
    if public and (n[1] == 0 or n[1] == 10 or n[1] == 127 or n[1] >= 224 or
      (n[1] == 100 and n[2] >= 64 and n[2] <= 127) or (n[1] == 169 and n[2] == 254) or
      (n[1] == 172 and n[2] >= 16 and n[2] <= 31) or (n[1] == 192 and (n[2] == 168 or (n[2] == 0 and (n[3] == 0 or n[3] == 2)) or (n[2] == 88 and n[3] == 99))) or
      (n[1] == 198 and (n[2] == 18 or n[2] == 19 or (n[2] == 51 and n[3] == 100))) or (n[1] == 203 and n[2] == 0 and n[3] == 113)) then return false end
    return true
  end
  local function valid_client_ip(value)
    if not valid_ip(value, false) then return false end
    local a, b = value:match("^(%d+)%.(%d+)%.")
    a, b = tonumber(a), tonumber(b)
    return a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
  end
  if not valid_client_ip(client_ip) or not valid_ip(ip, true) or
    (scope ~= "default" and not scope:match("^mark:[1-9]%d?%d?%d?%d?$")) or
    (profile < 1 or profile > 5 or profile % 1 ~= 0) or
    not ((proto == "tls" and profile <= 4) or (proto == "googlevideo-tcp" and profile == 2 and host:match("^[a-z0-9%-]+%.googlevideo%.com$")) or
      (proto == "quic" and profile == 5 and adaptive_quic_host_allowed(host))) or
    (strategy < 1 or strategy > 999 or strategy % 1 ~= 0) or
    (fingerprint ~= "-" and (not fingerprint:match("^sha256:[0-9a-f]+$") or #fingerprint ~= 71)) or
    not created or not expires or expires <= (now or os.time()) or expires > (now or os.time()) + 90 then return nil end
  if proto == "quic" and not adaptive_quic_host_allowed(host) then return nil end
  if scope == "default" and not ADAPTIVE_DEFAULT_SCOPE_APPLY then return nil end
  return {id=id, generation=generation, client_id=client_id, client_ip=client_ip, scope=scope,
    host=host, ip=ip, profile=tostring(profile), proto=proto, strategy=strategy,
    fingerprint=fingerprint, created=created, expires=expires}
end

local function adaptive_browser_trials_load(lines, now)
  ADAPTIVE_BROWSER_TRIALS = {}
  local conflicts, count = {}, 0
  now = now or os.time()
  for _, line in ipairs(lines or {}) do
    count = count + 1
    if count > 64 then break end
    local trial = adaptive_browser_trial_parse_line(line, now)
    if trial then
      local key = table.concat({trial.host, trial.ip, trial.profile, trial.proto, trial.scope}, "\0")
      if ADAPTIVE_BROWSER_TRIALS[key] then ADAPTIVE_BROWSER_TRIALS[key] = nil; conflicts[key] = true
      elseif not conflicts[key] then ADAPTIVE_BROWSER_TRIALS[key] = trial end
    end
  end
end

local function load_adaptive_browser_trials_file(path)
  local f = io.open(path, "r")
  local lines = {}
  if f then
    for line in f:lines() do
      lines[#lines + 1] = line
      if #lines >= 64 then break end
    end
    f:close()
  end
  adaptive_browser_trials_load(lines)
end

local function adaptive_rules_load(lines, now)
  ADAPTIVE_RULES, ADAPTIVE_RULE_CONFLICTS = {}, {}
  now = now or os.time()
  local count = 0
  for _, line in ipairs(lines) do
    count = count + 1
    if count > 256 then break end
    local rule = adaptive_rule_parse_line(line, now)
    if rule then
      local key = adaptive_rule_key(rule)
      if ADAPTIVE_RULES[key] then
        ADAPTIVE_RULES[key] = nil
        ADAPTIVE_RULE_CONFLICTS[key] = true
      elseif not ADAPTIVE_RULE_CONFLICTS[key] then
        ADAPTIVE_RULES[key] = rule
      end
    end
  end
end

local function load_adaptive_rules_file(path)
  local f = io.open(path, "r")
  if not f then f = io.open(ADAPTIVE_RULES_SNAPSHOT_PATH, "r") end
  local lines = {}
  if f then
    for line in f:lines() do
      lines[#lines + 1] = line
      if #lines >= 256 then break end
    end
    f:close()
  end
  adaptive_rules_load(lines)
end

local function load_locked_tables()
  local now = ADAPTIVE_BROWSER_TEST_NOW or os.time()
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
    adaptive_rules_load(ADAPTIVE_TEST_LINES or {}, now)
  else
    load_locked_file(LOCKED_PATH)
    load_locked_file(LOCKED_MANUAL_PATH)
    load_scoped_locks()
    BLOB_OVERRIDES = {}
    load_blob_override_file(BLOB_OVERRIDE_PATH)
    SNI_OVERRIDES = {}
    load_sni_override_file(SNI_OVERRIDE_PATH)
    MODE_OVERRIDES = {}
    load_mode_override_file(MODE_OVERRIDE_PATH)
    CLONE_SIZES = {}
    load_clone_size_file(CLONESIZE_PATH)
    load_adaptive_rules_file(ADAPTIVE_RULES_PATH)
  end
  if ADAPTIVE_BROWSER_TEST_LINES then adaptive_browser_trials_load(ADAPTIVE_BROWSER_TEST_LINES, now)
  else load_adaptive_browser_trials_file(ADAPTIVE_BROWSER_TRIALS_PATH) end
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
  ADAPTIVE_TEST_LINES = {}
  last_load = 0
  load_locked_tables()
end

function locked_load_adaptive_lines_for_tests(lines, now, runtime_stamp)
  ADAPTIVE_TEST_LINES = lines or {}
  ADAPTIVE_TEST_RUNTIME_STAMP = runtime_stamp
  adaptive_rules_load(lines or {}, now)
end

function locked_load_browser_trials_for_tests(lines, now)
  ADAPTIVE_BROWSER_TEST_LINES = lines or {}
  ADAPTIVE_BROWSER_TEST_NOW = now
  if not ADAPTIVE_TEST_LINES then ADAPTIVE_TEST_LINES = {} end
  last_load = 0
  adaptive_browser_trials_load(ADAPTIVE_BROWSER_TEST_LINES, now)
end

function locked_browser_trial_count_for_tests()
  local count = 0
  for _ in pairs(ADAPTIVE_BROWSER_TRIALS) do count = count + 1 end
  return count
end

function locked_adaptive_runtime_stamp_for_tests()
  return ADAPTIVE_RUNTIME_STAMP
end

function locked_adaptive_strategy_for_tuple(host, ip, profile, proto, scope, now)
  if not host or not ip or not profile then return nil end
  if not ADAPTIVE_TEST_LINES then load_locked_tables() end
  host = string.lower(tostring(host):gsub("%.$", ""))
  ip = tostring(ip)
  profile = tostring(profile)
  proto = string.lower(tostring(proto or "tcp"))
  scope = string.lower(tostring(scope or "default"))
  local key = table.concat({host, ip, profile, proto, scope}, "\0")
  local rule = ADAPTIVE_RULES[key]
  if not rule or ADAPTIVE_RULE_CONFLICTS[key] or rule.expires <= (now or os.time()) then return nil end
  local runtime_stamp = ADAPTIVE_TEST_RUNTIME_STAMP or ADAPTIVE_RUNTIME_STAMP
  if not runtime_stamp or rule.runtime_stamp ~= runtime_stamp then return nil end
  return rule.strategy, rule.fingerprint, rule.catalog, rule.expires
end

function locked_browser_trial_for_tuple(host, ip, profile, proto, scope, now)
  if not host or not ip or not profile then return nil end
  if not ADAPTIVE_TEST_LINES then load_locked_tables() end
  host = string.lower(tostring(host):gsub("%.$", ""))
  ip, profile = tostring(ip), tostring(profile)
  proto, scope = string.lower(tostring(proto or "tcp")), string.lower(tostring(scope or "default"))
  local key = table.concat({host, ip, profile, proto, scope}, "\0")
  local trial = ADAPTIVE_BROWSER_TRIALS[key]
  if not trial or trial.expires <= (now or os.time()) then return nil end
  return trial
end

-- Тестовый загрузчик per-mark файла: чистые таблицы + один файл под своим скоупом.
function locked_load_scoped_file_for_tests(path, scope)
  LOCKED_TEST_LINES = nil
  last_load = os.time() or 0
  LOCKED_TLS, LOCKED_HTTP, LOCKED_UDP = {}, {}, {}
  LOCKED_CONFLICTS, LOCKED_CONFLICTS_TOTAL = {}, 0
  CLIENT_SCOPE_SCOPED_LOCK_COUNT = 0
  load_scoped_file(path, scope)
end

-- Тестовый сеттер per-profile блобов (мимо файла, как locked_load_lines_for_tests).
function locked_load_blob_override_for_tests(lines)
  BLOB_OVERRIDES = {}
  for _, line in ipairs(lines or {}) do
    local profile, name = blob_override_parse_line(line)
    if profile then BLOB_OVERRIDES[profile] = name end
  end
end

-- Тестовый сеттер режима фейков (мимо файла, как blob/sni аналоги).
function locked_load_mode_override_for_tests(lines)
  MODE_OVERRIDES = {}
  for _, line in ipairs(lines or {}) do
    local profile, mode = mode_override_parse_line(line)
    if profile then MODE_OVERRIDES[profile] = mode end
  end
end

-- Тестовый сеттер лимитов клонов (мимо файла, как sibling-аналоги).
function locked_load_clone_size_for_tests(lines)
  CLONE_SIZES = {}
  for _, line in ipairs(lines or {}) do
    local profile, size = clone_size_parse_line(line)
    if profile then CLONE_SIZES[profile] = size end
  end
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

-- Хост прямо из payload текущего пакета: на первом ClientHello/HTTP-запросе
-- соединения имени в conntrack может ещё не быть, а решение по доменному
-- локу принимается именно на этом пакете.
function z2r_hostname_from_payload(payload, l7)
  if l7 == "http_req" then
    return payload:match("\n[Hh][Oo][Ss][Tt]:[%s]*([^%s%c]+)")
  end
  local t = tls_dissect(payload)
  if not (t and t.handshake and t.handshake[1] and t.handshake[1].dis and t.handshake[1].dis.ext) then return nil end
  for _, e in ipairs(t.handshake[1].dis.ext) do
    if e.type == 0 and e.dis and e.dis.list then
      for _, n in ipairs(e.dis.list) do
        if n.name and n.name ~= "" then return tostring(n.name) end
      end
    end
  end
  return nil
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
  local l7 = desync.l7payload
  if l7 == "tls_client_hello" or l7 == "http_req" then
    local payload = desync.reasm_data or (desync.dis and desync.dis.payload) or ""
    if #payload > 8 then
      local ok, name = pcall(z2r_hostname_from_payload, payload, l7)
      if ok and name and name ~= "" then return name end
    end
  end
  return nil
end

-- Клон ClientHello пользователя для режима clone (mode_override.tsv):
-- фингерпринт — от текущего пакета (версия записи, сьюты, GREASE, расширения
-- наследуются сами), все имена SNI заменяются на невинные. Настоящий SNI
-- юзера в фейке не оставляем. Строится только на ClientHello; провал = nil.
local Z2R_CLONE_FIELD = "z2r_mode_clone"
local Z2R_CLONE_SNI_DEFAULT = "www.google.com"

-- Авторское правило (живой ТСПУ 03.10): TLS-фейк больше 1200 байт рубится
-- ТСПУ вместе с потоком. Верхняя граница для ЛЮБОГО TLS-фейка — клон, блоб
-- или конфиг-клон. Не-TLS фейки (QUIC/Discord UDP/STUN) не трогаем.
local Z2R_TLS_FAKE_LIMIT_MAX = 1200
-- Рантайм-поле с порезанным фейк-блобом (по образцу Z2R_CLONE_FIELD).
local Z2R_CAP_FIELD = "z2r_blob_cap"

-- Лимит клона профиля: clonesize.tsv[profile], нет строки = 1200.
local function z2r_clone_limit_for(profile_key)
  -- Явный диагностический режим полного клона; обычные профили ограничены 1200.
  if tonumber(_G.Z2R_CLONE_MAX_SIZE) == 0 then return 0 end
  local v = profile_key and CLONE_SIZES[tostring(profile_key)]
  if type(v) == "number" and v >= 64 and v <= Z2R_TLS_FAKE_LIMIT_MAX then return v end
  return Z2R_TLS_FAKE_LIMIT_MAX
end

-- GREASE-типы расширений: 0x?a?a (0x0a0a..0xfafa, шаг 0x1010 в nibble-арифметике).
local function z2r_is_grease_ext(t)
  return t >= 0x0a0a and t <= 0xfafa and (t - 0x0a0a) % 0x1010 == 0
end

-- Группы согласованного удаления расширений клона (по приоритету из живого
-- эксперимента 03.10). Удаляются ТОЛЬКО группами: пары вида
-- signature_algorithms без supported_groups / pre_shared_key не последним
-- расширением ТСПУ режет. SNI (инжектированный), supported_versions (43),
-- signature_algorithms (13), renegotiation_info (0xff01) не удаляются никогда.
local Z2R_CLONE_CUT_GROUPS = {
  { t = { [0xfe0d] = true } },                            -- ECH: фейку не нужен
  { t = { [51] = true, [10] = true, [11] = true } },      -- key_share + supported_groups + ec_point_formats
  { t = { [21] = true } },                                -- padding
  { grease = true },                                      -- GREASE-расширения
  { t = { [35] = true } },                                -- session_ticket
  { t = { [16] = true } },                                -- ALPN
  { t = { [45] = true, [41] = true, [42] = true } },      -- psk_key_exchange_modes + pre_shared_key + early_data
}

-- Классические (не post-quantum) записи key_share: secp256r1/secp384r1/
-- secp521r1/x25519. PQ-гибриды (X25519MLKEM768 = 0x11EC, X25519Kyber768 =
-- 0x6399 и пр.) все >= 0x0100, кривые — ниже.
local Z2R_KEY_SHARE_CLASSIC = { [0x001d] = true, [0x0017] = true, [0x0018] = true, [0x0019] = true }

-- Post-quantum записи из key_share (~1216 Б за X25519MLKEM768). CH БЕЗ
-- key_share не существует у браузеров — ТСПУ такие режет (эксперимент 03.10:
-- согласованная резка, убравшая key_share целиком, валит большой поток),
-- а key_share из одной x25519 — обычный клиент до pq-эры. Удаляем только
-- PQ-записи, классические остаются: клон pq-CH (~1812Б) превращается в
-- согласованный CH «старого браузера» (~595Б) без снятия расширений.
-- Возвращает сэкономленное (0 = нечего было убирать/нечего оставить).
local function z2r_clone_key_share_drop_pq(tdis)
  local ext = tdis.handshake[1].dis.ext
  for i = 1, #ext do
    local e = ext[i]
    if e and e.type == 51 and e.dis and type(e.dis.list) == "table" and #e.dis.list > 1 then
      local keep, saved = {}, 0
      for _, ks in ipairs(e.dis.list) do
        if ks.group and Z2R_KEY_SHARE_CLASSIC[ks.group] then
          keep[#keep + 1] = { group = ks.group, kex = ks.kex }
        else
          saved = saved + 4 + #(ks.kex or "")
        end
      end
      if saved > 0 and #keep > 0 then
        e.dis.list = keep
        return saved
      end
    end
  end
  return 0
end

-- Согласованная резка ClientHello до <= limit: сначала точечная операция на
-- key_share (PQ-записи — главный источник размера), затем расширения снимаются
-- группами из Z2R_CLONE_CUT_GROUPS, пока оценка размера не войдёт в лимит;
-- затем один tls_reconstruct. Не CH / не влезли минимальным набором — nil
-- (фейк не шлём: отравленный фейк хуже отсутствия, см. эксперимент 03.10).
local function z2r_clone_semantic_cut(clone, limit)
  if type(clone) ~= "string" or #clone <= limit then return nil end
  local ok, tdis = pcall(tls_dissect, clone)
  if not (ok and type(tdis) == "table" and tdis.handshake
      and tdis.handshake[1] and tdis.handshake[1].dis
      and type(tdis.handshake[1].dis.ext) == "table") then
    return nil
  end
  local ext = tdis.handshake[1].dis.ext
  local saved = z2r_clone_key_share_drop_pq(tdis)
  if #clone - saved <= limit then
    local ok2, cut = pcall(tls_reconstruct, tdis)
    if ok2 and type(cut) == "string" and #cut > 0 and #cut <= limit then return cut end
    return nil
  end
  for _, group in ipairs(Z2R_CLONE_CUT_GROUPS) do
    local removed = 0
    for i = #ext, 1, -1 do
      local etype = ext[i] and ext[i].type
      local hit = false
      if etype then
        if group.grease then
          hit = z2r_is_grease_ext(etype)
        elseif group.t then
          hit = group.t[etype] and true or false
        end
      end
      if hit then
        removed = removed + 4 + #tostring(ext[i].data or "")
        table.remove(ext, i)
      end
    end
    if removed > 0 then
      saved = saved + removed
      if #clone - saved <= limit then
        local ok2, cut = pcall(tls_reconstruct, tdis)
        if ok2 and type(cut) == "string" and #cut > 0 and #cut <= limit then return cut end
        return nil
      end
    end
  end
  return nil
end

-- Сырая резка цепочки TLS-рекордов до <= limit: рекорды целиком помещаются,
-- последний режется с починкой длины рекорда (валидность структуры на проводе
-- подтверждена экспериментом 03.10: раздутый нулями рекорд с починкой длины
-- ТСПУ пропускает). Не TLS (первый байт не 20-23, битая длина) — nil.
local function z2r_tls_record_cut(data, limit)
  if type(data) ~= "string" or #data <= limit then return nil end
  local out, off = "", 1
  while #data - off + 1 >= 5 do
    local rtype = string.byte(data, off)
    local rlen = string.byte(data, off + 3) * 256 + string.byte(data, off + 4)
    if rtype < 20 or rtype > 23 or #data - off + 1 < 5 + rlen then return nil end
    if off - 1 + 5 + rlen <= limit then
      out = out .. string.sub(data, off, off + 4 + rlen)
      if off - 1 + 5 + rlen == limit then return out end
      off = off + 5 + rlen
    else
      local space = limit - (off - 1) - 5
      if space < 1 then break end
      -- длину последнего (порезанного) рекорда переписываем на фактическую:
      -- рекорд с хвостом чужих байт невалиден, с честной длиной — валиден
      -- (A/B на проде 03.10: раздутый рекорд с починенной длиной ТСПУ прошёл)
      out = out .. string.char(rtype) .. string.sub(data, off + 1, off + 2)
        .. string.char(math.floor(space / 256)) .. string.char(space % 256)
        .. string.sub(data, off + 5, off + 4 + space)
      return out
    end
  end
  return (#out > 0 and #out <= limit) and out or nil
end

-- Кап TLS-фейка: CH режется согласованно, прочие TLS-рекорды — сырой резкой,
-- не-TLS возвращается как есть (nil = резать не потребовалось/нечем).
local function z2r_tls_fake_cap(data, limit)
  if type(data) ~= "string" or #data <= limit then return nil end
  return z2r_clone_semantic_cut(data, limit) or z2r_tls_record_cut(data, limit)
end

-- Клон — точная копия random/session_id реального CH: в одном потоке ТСПУ
-- видит два CH с одним random и разными SNI (фейк google + настоящий discord)
-- — очевидная подделка. Пересобираем клон со свежим random и session_id той
-- же длины (отпечаток формы сохраняется, значения — нет).
local function z2r_clone_rerandomize(clone)
  local ok, tdis = pcall(tls_dissect, clone)
  if not (ok and type(tdis) == "table" and tdis.handshake
      and tdis.handshake[1] and tdis.handshake[1].dis) then return clone end
  local d = tdis.handshake[1].dis
  d.random = brandom(32)
  d.session_id = brandom(#(d.session_id or ""))
  local ok2, out = pcall(tls_reconstruct, tdis)
  if ok2 and type(out) == "string" and #out > 0 then return out end
  return clone
end

-- FULL -> PARTIAL: кеш принадлежит соединению, а не объекту desync.
-- Лимит участвует в ключе, как SNI; тип отправляющей стратегии его не меняет.
local function z2r_cached_clienthello(desync, options, key, slot, limit, per_key)
  if desync.l7payload ~= "tls_client_hello" then return nil end
  key = key .. "\tmax_size=" .. limit
  if desync.track and not desync.track.lua_state then desync.track.lua_state = {} end
  local state = desync.track and desync.track.lua_state or desync
  -- В одном плане может быть несколько native-производителей с разными
  -- blob/SNI. Их FULL-клоны должны одновременно переживать PARTIAL replay.
  if per_key then
    if type(state[slot]) ~= "table" then state[slot] = {} end
    state = state[slot]
    slot = key
  end
  local cached = state[slot]
  local function complete(payload)
    return type(payload) == "string" and #payload >= 9
      and payload:byte(1) == 22 and payload:byte(6) == 1
      and tls_record_full(payload)
  end
  local payload = desync.reasm_data
  if not complete(payload) then payload = desync.dis and desync.dis.payload end
  local seq = desync.dis and desync.dis.tcp and desync.dis.tcp.th_seq
  local start_seq = type(seq) == "number" and
    (seq - (desync.reasm_offset or 0)) % 4294967296 or nil
  if cached and cached.key ~= key then state[slot] = nil; cached = nil end
  if not complete(payload) then
    if not cached or start_seq == nil or start_seq ~= cached.start_seq
      or type(payload) ~= "string" or #payload < 9
      or payload:byte(1) ~= 22 or payload:byte(6) ~= 1 then return nil end
    if payload ~= cached.source:sub(1, #payload) then state[slot] = nil; return nil end
    DLOG("fake_mode: complete clone reused on partial replay")
    return cached.data
  end
  if cached and cached.source == payload and cached.start_seq == start_seq then return cached.data end
  state[slot] = nil
  local ok, clone = pcall(tls_client_hello_mod, payload, options)
  if not (ok and type(clone) == "string" and #clone > 0) then return nil end
  -- Лимит применяется ко всем клонам независимо от типа стратегии.
  -- Сокращаем структуру TLS, не настоящий пакет; провал резки = штатный fallback.
  if limit > 0 and #clone > limit then
    local cut = z2r_clone_semantic_cut(clone, limit)
    if not cut then
      DLOG("fake_mode: clone "..#clone.."B over limit "..limit.."B, cut failed, keeping config blob profile="..key)
      return nil
    end
    DLOG("fake_mode: clone cut "..#clone.."->"..#cut.."B (limit "..limit.."B) profile="..key)
    clone = cut
  end
  if clone:sub(1, 3) == string.char(22, 3, 1) then
    clone = clone:sub(1, 2) .. string.char(3) .. clone:sub(4)
  end
  clone = z2r_clone_rerandomize(clone)
  state[slot] = { key = key, start_seq = start_seq, source = payload, data = clone }
  return clone
end

local function fake_mode_user_clone(desync, sni, profile_key)
  local name = (sni and sni ~= "") and sni or Z2R_CLONE_SNI_DEFAULT
  return z2r_cached_clienthello(desync, {
    sni_del = true, sni_first = name, sni_snt_new = 0,
  }, tostring(profile_key) .. "\t" .. name, "z2r_full_clone",
    z2r_clone_limit_for(profile_key))
end

-- Native/ECH clone имеет отдельный слот, общий лимит и защиту ретрансляций.
function tls_client_hello_clone(ctx, desync)
  if not desync.dis.tcp then
    if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
    return
  end
  direction_cutoff_opposite(ctx, desync)
  if not direction_check(desync) then return end
  if not desync.arg.blob then error("tls_client_hello_clone: 'blob' arg required") end
  local parts = {}
  for _, field in ipairs({"blob", "sni_snt", "sni_snt_new", "sni_del_ext", "sni_del", "sni_first", "sni_last"}) do
    local value = tostring(desync.arg[field])
    parts[#parts + 1] = field .. "=" .. #value .. ":" .. value
  end
  local profile = desync.z2r_clone_profile_key or desync.profile_n or desync_profile_key(desync)
  local clone = z2r_cached_clienthello(desync, desync.arg,
    table.concat(parts, "|"), "z2r_explicit_full_clone", z2r_clone_limit_for(profile), true)
  desync[desync.arg.blob] = clone
  if not clone and desync.arg.fallback then
    desync[desync.arg.blob] = blob(desync, desync.arg.fallback)
  end
end

-- Какой arg инстанса несёт фейк-блоб: fake() держит фейк в blob=,
-- fakemultisplit/fakemultidisorder — в fake_blob=. У остальных (multisplit,
-- hostfakesplit, tls_client_hello_clone) blob= — реальный payload или имя
-- поля: резать нельзя.
local function z2r_fake_blob_arg(func)
  if func == "fake" then return "blob" end
  if func == "fakemultisplit" or func == "fakemultidisorder" then return "fake_blob" end
  return nil
end

-- Какие значения blob=/fake_blob= подлежат подмене per-profile override'ом
-- (blob_override.tsv). TLS-профили 1/2/3/4/8 — maxru|fake_default_tls (зеркало
-- глобальных sed'ов п.16). QUIC-профиль 5 — именованные UDP-блобы, на которых
-- построены стратегии блока key=5 (литеральный 0x00 — не имя, остаётся как есть).
local Z2R_BLOB_SWAP_TLS = { maxru = true, fake_default_tls = true }
local Z2R_BLOB_SWAP_QUIC = {
  quic_google = true, quic5 = true, discord_fake = true,
  stun_fake = true, discord_udp_1 = true, discord_udp_2 = true,
}
local function z2r_blob_override_swap(profile_key, value)
  if value == nil then return false end
  if tostring(profile_key) == "5" then
    return Z2R_BLOB_SWAP_QUIC[value] == true
  end
  return Z2R_BLOB_SWAP_TLS[value] == true
end

-- Подмена per-profile TLS блоба на исполнении стратегии (blob_override.tsv),
-- режим фейков профиля (mode_override.tsv) и per-profile SNI клон-стратегий
-- (sni_override.tsv). Порядок: режим (clone строит клон CH юзера) -> блоб-
-- override -> sni_first. Меняются только args blob/fake_blob со значением
-- maxru|fake_default_tls (QUIC-профиль 5 — именованные UDP-блобы) и arg
-- sni_first; исходные значения восстанавливаются — план может быть переисполнен
-- (replay/desync_copy). Имя блоба должно быть объявлено в конфиге
-- (--blob=ИМЯ:@...) или быть встроенным, иначе подмены нет.
function blob_override_execute(desync, verdict, instance, profile_key)
  local mode = profile_key and MODE_OVERRIDES[tostring(profile_key)]
  local name = profile_key and BLOB_OVERRIDES[tostring(profile_key)]
  local sni = profile_key and SNI_OVERRIDES[tostring(profile_key)]
  local fake_arg = (instance and instance.arg and z2r_fake_blob_arg(instance.func)) or nil
  local native_clone = instance and instance.func == "tls_client_hello_clone"
  if (not mode and not name and not sni and not fake_arg and not native_clone) or not instance or not instance.arg then
    return plan_instance_execute(desync, verdict, instance)
  end
  if name and not blob_exist(desync, name) then
    DLOG("blob_override: '"..tostring(name).."' not declared, keeping config value profile="..tostring(profile_key))
    name = nil
  end
  -- режим clone: клон CH юзера выигрывает у блоба-override; провал клона
  -- (не CH-пакет, dissect/reconstruct не удался) = штатный путь ниже.
  -- Превышение лимита сокращает клон и на зеркалящих стратегиях.
  local clone_data = mode == "clone"
    and fake_mode_user_clone(desync, sni, profile_key)
    or nil
  local target = clone_data and Z2R_CLONE_FIELD or name
  local saved_clone = desync[Z2R_CLONE_FIELD]
  local saved_cap = desync[Z2R_CAP_FIELD]
  if clone_data then
    desync[Z2R_CLONE_FIELD] = clone_data
  end
  local saved_blob = instance.arg.blob
  local saved_fake_blob = instance.arg.fake_blob
  local swapped = false
  if target and z2r_blob_override_swap(profile_key, saved_blob) then
    instance.arg.blob = target
    swapped = true
  end
  if target and z2r_blob_override_swap(profile_key, saved_fake_blob) then
    instance.arg.fake_blob = target
    swapped = true
  end
  -- Авторское правило: любой TLS-фейк <= 1200. Резолвим итоговое имя блоба
  -- после подмен (клон режима clone уже порезан по лимиту профиля — не трогаем),
  -- порезанное кладём в Z2R_CAP_FIELD и подставляем его имя. Не-TLS фейки
  -- (QUIC/Discord UDP/STUN/rdp) z2r_tls_fake_cap не трогает.
  local cap_arg, cap_saved, cap_old
  if fake_arg then
    local fname = instance.arg[fake_arg]
    if fname and fname ~= Z2R_CLONE_FIELD then
      local okb, bdata = pcall(blob, desync, fname)
      if okb and type(bdata) == "string" then
        local capped = z2r_tls_fake_cap(bdata, Z2R_TLS_FAKE_LIMIT_MAX)
        if capped then
          cap_old = #bdata
          cap_saved = fname
          cap_arg = fake_arg
          desync[Z2R_CAP_FIELD] = capped
          instance.arg[fake_arg] = Z2R_CAP_FIELD
        end
      end
    end
  end
  -- sni_first есть только у клон-стратегий: подмена не задевает остальные
  local saved_sni = instance.arg.sni_first
  local sni_swapped = false
  if sni and saved_sni and saved_sni ~= "" and saved_sni ~= sni then
    instance.arg.sni_first = sni
    sni_swapped = true
  end
  -- profile_n — физический профиль nfqws2; после маршрутизации нужен
  -- логический ключ circular_locked. arg заменяется исполнителем инстанса.
  local saved_profile = desync.z2r_clone_profile_key
  desync.z2r_clone_profile_key = profile_key or saved_profile
  local ok, v = pcall(plan_instance_execute, desync, verdict, instance)
  desync.z2r_clone_profile_key = saved_profile
  if swapped then
    if clone_data then
      DLOG("fake_mode: profile="..tostring(profile_key).." user clone -> "..target)
    else
      DLOG("blob_override: profile="..tostring(profile_key).." blob -> "..name)
    end

  end
  if cap_arg then
    DLOG("blob_cap: profile="..tostring(profile_key).." "..cap_arg.."="..tostring(cap_saved).." "..cap_old.."->"..#desync[Z2R_CAP_FIELD].."B")

  end
  if sni_swapped then
    DLOG("blob_override: profile="..tostring(profile_key).." sni_first -> "..sni)
    instance.arg.sni_first = saved_sni
  end
  -- Сначала снимаем cap, затем подмену alias: иначе cap_saved возвращает
  -- временное имя профиля вместо исходного blob даже без исключения.
  if swapped or cap_arg then
    instance.arg.blob = saved_blob
    instance.arg.fake_blob = saved_fake_blob
  end
  desync[Z2R_CLONE_FIELD] = saved_clone
  desync[Z2R_CAP_FIELD] = saved_cap
  if not ok then error(v, 0) end
  return v
end

function circular_locked_passthrough(ctx, desync)
  -- Без orchestrate: не создаём полный план, но запрещаем нативному циклу
  -- выполнить оставшиеся стратегии. Вложенный план очищаем на месте.
  if ctx then execution_plan_cancel(ctx) end
  if desync.plan then plan_clear(desync) end
  return VERDICT_PASS
end

local function adaptive_probe_ack(host, profile, strategy)
  if ADAPTIVE_ACKED or not ADAPTIVE_ACK_PATH or not ADAPTIVE_ACK_HOST
    or host ~= ADAPTIVE_ACK_HOST or tostring(profile) ~= ADAPTIVE_ACK_PROFILE
    or strategy ~= ADAPTIVE_ACK_STRATEGY or not ADAPTIVE_ACK_TEST_ID
    or not string.match(ADAPTIVE_ACK_TEST_ID, "^[%w_-]+$") then return end
  local f = io.open(ADAPTIVE_ACK_PATH, "w")
  if not f then return end
  f:write(ADAPTIVE_ACK_TEST_ID, "\t", host, "\t", tostring(profile), "\t", tostring(strategy), "\n")
  f:close()
  ADAPTIVE_ACKED = true
end

local function adaptive_observe_ip_valid(ip)
  if type(ip) ~= "string" then return false end
  local octets = {}
  for part in (ip .. "."):gmatch("(.-)%.") do
    local n = tonumber(part)
    if not part:match("^%d%d?%d?$") or (#part > 1 and part:sub(1, 1) == "0") or not n or n > 255 then return false end
    octets[#octets + 1] = n
  end
  if #octets ~= 4 then return false end
  local a, b, c = octets[1], octets[2], octets[3]
  return not (a == 0 or a == 10 or a == 127 or a >= 224 or
    (a == 100 and b >= 64 and b <= 127) or (a == 169 and b == 254) or
    (a == 172 and b >= 16 and b <= 31) or (a == 192 and (b == 168 or (b == 0 and (c == 0 or c == 2)) or (b == 88 and c == 99))) or
    (a == 198 and (b == 18 or b == 19 or (b == 51 and c == 100))) or (a == 203 and b == 0 and c == 113))
end

local function adaptive_ramp_group_id(host)
  host = string.lower(host or ""):gsub("%.$", "")
  if #host > 253 or not host:match("%.googlevideo%.com$") then return nil end
  for label in (host .. "."):gmatch("(.-)%.") do
    if #label < 1 or #label > 63 or (not label:match("^[a-z0-9]$")
      and not label:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$")) then return nil end
  end
  local rr = host:match("^rr[0-9]+%-([a-z0-9][a-z0-9%-]*[a-z0-9])%.googlevideo%.com$")
  if rr then return "gv1:rr:" .. rr end
  local r = host:match("^r[0-9]+(%-%-%-sn%-%w[%w%-]*)%.googlevideo%.com$")
  if r then return "gv1:r:" .. r end
  return "gv1:exact:" .. host
end

local function adaptive_ramp_targets_load()
  if ADAPTIVE_RAMP_TARGET_COUNT > 0 then return end
  local f = io.open(ADAPTIVE_RAMP_TARGETS_PATH, "r")
  if not f then return end
  local count = 0
  for line in f:lines() do
    count = count + 1
    if count > 128 then break end
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    local ver, host, ip, scope, seen, provenance, group, state, dns_expiry, media =
      fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9], fields[10]
    local valid_group = adaptive_ramp_group_id(host or "")
    if #fields == 10 and ver == "1" and valid_group == group and adaptive_observe_ip_valid(ip)
      and (scope == "default" or (scope or ""):match("^mark:%d+$"))
      and (seen or ""):match("^%d+$") and provenance == "tls-observed"
      and (state == "pending" or state == "ramp_default" or state == "ramp_exempt" or state == "conflict" or state == "uncertain")
      and ((dns_expiry or ""):match("^%d+$")) and (media == "unknown" or media == "available" or media == "unavailable") then
      local key = table.concat({host, ip, scope}, "\0")
      if not ADAPTIVE_RAMP_TARGETS[key] and ADAPTIVE_RAMP_TARGET_COUNT < 128 then
        local item = {key=key, host=host, ip=ip, scope=scope, seen=tonumber(seen) or 0,
          provenance=provenance, group=group, state=state, dns_expiry=tonumber(dns_expiry) or 0, media=media}
        ADAPTIVE_RAMP_TARGETS[key] = item
        ADAPTIVE_RAMP_TARGET_ORDER[#ADAPTIVE_RAMP_TARGET_ORDER + 1] = item
        ADAPTIVE_RAMP_TARGET_COUNT = ADAPTIVE_RAMP_TARGET_COUNT + 1
      end
    end
  end
  f:close()
end

local function adaptive_ramp_targets_write()
  local tmp = ADAPTIVE_RAMP_TARGETS_PATH .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local lines = {}
  for i, item in ipairs(ADAPTIVE_RAMP_TARGET_ORDER) do
    lines[i] = table.concat({"1", item.host, item.ip, item.scope, tostring(item.seen), item.provenance,
      item.group, item.state, tostring(item.dns_expiry), item.media}, "\t")
  end
  f:seek("set", 0)
  local ok = f:write(table.concat(lines, "\n"), "\n")
  f:close()
  local renamed = ok and os.rename(tmp, ADAPTIVE_RAMP_TARGETS_PATH)
  -- Windows-based Lua smoke environments do not replace an existing file
  -- with os.rename; router filesystems do, so retain the atomic fast path.
  if not renamed and ok and os.remove(ADAPTIVE_RAMP_TARGETS_PATH) then
    renamed = os.rename(tmp, ADAPTIVE_RAMP_TARGETS_PATH)
  end
  if not renamed then
    os.remove(tmp)
    return false
  end
  return true
end

local function adaptive_ramp_target_seen(host, ip, scope, now, profile)
  if not ADAPTIVE_OBSERVE_ENABLED or tostring(ADAPTIVE_MODE) ~= "AGENT_BETA"
    or tostring(profile or "") ~= "2" then return end
  if not adaptive_ramp_group_id(host) or not adaptive_observe_ip_valid(ip) then return end
  local group = adaptive_ramp_group_id(host)
  if not group then return end
  adaptive_ramp_targets_load()
  scope = tostring(scope or "default")
  if scope ~= "default" then
    local mark = scope:match("^mark:(%d+)$")
    if not mark or #mark > 5 or tonumber(mark) < 1 or tonumber(mark) > 65535 then return end
  end
  local key = table.concat({host, ip, scope}, "\0")
  local item = ADAPTIVE_RAMP_TARGETS[key]
  if item then
    item.seen = now
  else
    item = {key=key, host=host, ip=ip, scope=scope, seen=now, provenance="tls-observed",
      group=group, state="pending", dns_expiry=0, media="unknown"}
    if ADAPTIVE_RAMP_TARGET_COUNT >= 128 then
      local evicted = table.remove(ADAPTIVE_RAMP_TARGET_ORDER, 1)
      if evicted then ADAPTIVE_RAMP_TARGETS[evicted.key] = nil end
    else
      ADAPTIVE_RAMP_TARGET_COUNT = ADAPTIVE_RAMP_TARGET_COUNT + 1
    end
    ADAPTIVE_RAMP_TARGET_ORDER[#ADAPTIVE_RAMP_TARGET_ORDER + 1] = item
    ADAPTIVE_RAMP_TARGETS[key] = item
  end
  -- Ramp is decided at SYN by destination IP. Different observed hostnames
  -- sharing that IP therefore cannot safely receive different Ramp policies.
  for _, candidate in ipairs(ADAPTIVE_RAMP_TARGET_ORDER) do
    if candidate.ip == ip and candidate.scope == scope and now - candidate.seen <= 604800 then
      local conflict = false
      for _, other in ipairs(ADAPTIVE_RAMP_TARGET_ORDER) do
        if other.ip == ip and other.scope == scope and other.host ~= candidate.host
          and now - other.seen <= 604800 then conflict = true; break end
      end
      if conflict then candidate.state = "conflict"
      elseif candidate.state == "conflict" then candidate.state = "pending" end
    end
  end
  return adaptive_ramp_targets_write()
end

local function adaptive_observe_seen(host, ip, profile, proto, scope, track)
  local valid_kind = proto == "tls" and tostring(profile):match("^[1-4]$")
    or proto == "quic" and tostring(profile) == "5" and adaptive_quic_host_allowed(host)
  if not ADAPTIVE_OBSERVE_ENABLED or not host or host == "" or not ip or not valid_kind
    or not track or type(track.lua_state) ~= "table" then return end
  if not host:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") or #host > 253
    or not adaptive_observe_ip_valid(ip) then return end
  scope = tostring(scope or "default")
  if scope ~= "default" and not scope:match("^mark:%d%d?%d?%d?%d?$" ) then return end
  local state = track.lua_state
  local key = table.concat({host, ip, tostring(profile), proto, scope}, "\0")
  if state.adaptive_observe_key == key then return end
  local now = os.time()
  if tostring(profile) == "2" then adaptive_ramp_target_seen(host, ip, scope, now, profile) end
  local old = ADAPTIVE_OBSERVE_EVENTS[key]
  if old then
    state.adaptive_observe_context = {key = key, host = host, ip = ip, profile = tostring(profile),
      proto = proto, scope = scope, adaptive_rule_applied = state.adaptive_rule_applied == true}
    state.adaptive_observe_key = key
    return
  end
  local event = {key = key, host = host, ip = ip, profile = tostring(profile), proto = proto,
    scope = scope, status = "seen", seen = now}
  local f = io.open(ADAPTIVE_EVENTS_PATH, "r+")
  if not f then return end
  local ok
  if ADAPTIVE_OBSERVE_COUNT < 128 then
    f:seek("end")
    ok = f:write("1\tseen\t", host, "\t", ip, "\t", tostring(profile), "\t", proto,
      "\t", scope, "\t", tostring(now), "\n")
  else
    local next_order, lines = {}, {}
    for i = 2, #ADAPTIVE_OBSERVE_ORDER do next_order[#next_order + 1] = ADAPTIVE_OBSERVE_ORDER[i] end
    next_order[#next_order + 1] = event
    for i, item in ipairs(next_order) do
      lines[i] = table.concat({"1", item.status, item.host, item.ip, item.profile,
        item.proto, item.scope, tostring(item.seen)}, "\t")
    end
    for i = #lines + 1, 128 do lines[i] = "" end
    f:seek("set", 0)
    ok = f:write(table.concat(lines, "\n"), "\n")
    if ok then
      -- Rewrite the existing private inode so its owner and mode stay unchanged.
      ADAPTIVE_OBSERVE_EVENTS[ADAPTIVE_OBSERVE_ORDER[1].key] = nil
      ADAPTIVE_OBSERVE_ORDER = next_order
    end
  end
  f:close()
  if not ok then return end
  ADAPTIVE_OBSERVE_EVENTS[key] = event
  if ADAPTIVE_OBSERVE_COUNT < 128 then
    ADAPTIVE_OBSERVE_ORDER[#ADAPTIVE_OBSERVE_ORDER + 1] = event
    ADAPTIVE_OBSERVE_COUNT = ADAPTIVE_OBSERVE_COUNT + 1
  end
  state.adaptive_observe_key = key
  state.adaptive_observe_context = {key = key, host = host, ip = ip, profile = tostring(profile),
    proto = proto, scope = scope, adaptive_rule_applied = state.adaptive_rule_applied == true}
end

local function adaptive_observe_rewrite()
  local f = io.open(ADAPTIVE_EVENTS_PATH, "r+")
  if not f then return false end
  local lines = {}
  for i, event in ipairs(ADAPTIVE_OBSERVE_ORDER) do
    lines[i] = table.concat({"1", event.status, event.host, event.ip, event.profile,
      event.proto, event.scope, tostring(event.seen)}, "\t")
  end
  f:seek("set", 0)
  local ok = f:write(table.concat(lines, "\n"), "\n")
  f:close()
  return ok ~= nil
end

-- A packet-level detector is only a suspicion signal. Require two distinct
-- failed connections for this exact tuple before asking the agent to probe it.
function z2r_adaptive_suspected_failure(desync, crec)
  if not ADAPTIVE_OBSERVE_ENABLED or type(crec) ~= "table" or crec.adaptive_failure_reported
    or type(desync) ~= "table" or type(desync.track) ~= "table"
    or type(desync.track.lua_state) ~= "table" then return end
  crec.adaptive_failure_reported = true
  local context = desync.track.lua_state.adaptive_observe_context
  if type(context) ~= "table" then return end
  local event = ADAPTIVE_OBSERVE_EVENTS[context.key]
  if not event or event.status == "suspected_failure" or event.status == "active_rule_degraded" then return end
  event.failure_count = (event.failure_count or 0) + 1
  if event.failure_count < 2 then return end
  event.status = context.adaptive_rule_applied and "active_rule_degraded" or "suspected_failure"
  event.seen = os.time()
  adaptive_observe_rewrite()
end

function z2r_adaptive_observe_connection(desync, profile, host, scope, require_outgoing)
  if type(desync) ~= "table" or (require_outgoing and desync.outgoing ~= true) or not desync.dis or not desync.dis.tcp
    or tonumber(desync.dis.tcp.th_dport) ~= 443 or not desync.track then return end
  if type(dis_ipdst) ~= "function" or type(ntop) ~= "function" then return end
  local dst = dis_ipdst(desync.dis)
  local ip = dst and ntop(dst) or nil
  if ip and ip ~= "" then adaptive_observe_seen(host, ip, profile, desync_proto(desync), scope, desync.track) end
end

local function adaptive_browser_capture_syn(desync, profile, scope)
  if ADAPTIVE_MODE ~= "AGENT_BETA" or type(desync) ~= "table" or desync.outgoing ~= true
    or type(desync.track) ~= "table" or type(desync.dis) ~= "table" or type(desync.dis.tcp) ~= "table"
    or tonumber(desync.dis.tcp.th_dport) ~= 443 or type(bitand) ~= "function"
    or type(TH_SYN) ~= "number" or type(TH_ACK) ~= "number" then return false, "ineligible" end
  local flags = tonumber(desync.dis.tcp.th_flags) or 0
  if bitand(flags, TH_SYN) == 0 or bitand(flags, TH_ACK) ~= 0 then return false, "not-initial-syn" end
  local state = desync.track.lua_state
  if type(state) ~= "table" then state = {}; desync.track.lua_state = state end
  if state.adaptive_browser_syn then return false, "already-seen" end -- SYN retransmits do not make a new flow.
  if type(dis_ipdst) ~= "function" or type(ntop) ~= "function" then return false, "ip-helpers-missing" end
  local dst = dis_ipdst(desync.dis)
  local ip = dst and ntop(dst) or nil
  if type(ip) ~= "string" or not ip:match("^%d+%.%d+%.%d+%.%d+$") then return false, "invalid-ip" end
  state.adaptive_browser_syn = {ip = ip, profile = tostring(profile), proto = "tcp", scope = tostring(scope or "default"), seen = os.time()}
  return true
end

local function adaptive_browser_mark_flow_ambiguous(path)
  local existing = io.open(path, "r")
  if existing then
    local first = existing:read("*l")
    local second = existing:read("*l")
    existing:close()
    if first == "AMBIGUOUS" and second == nil then return true end
  end
  local f = io.open(path, "w")
  if not f then return false end
  local ok = f:write("AMBIGUOUS\n")
  f:close()
  return ok ~= nil
end

local function adaptive_browser_capture_quic_initial(desync, host, profile, scope)
  if ADAPTIVE_MODE ~= "AGENT_BETA" or tostring(profile) ~= "5" or not adaptive_quic_host_allowed(host)
    or type(desync) ~= "table" or desync.outgoing ~= true or desync.l7payload ~= "quic_initial"
    or type(desync.track) ~= "table" or type(desync.dis) ~= "table" or type(desync.dis.udp) ~= "table"
    or tonumber(desync.dis.udp.th_dport) ~= 443 then return false, "ineligible" end
  local state = desync.track.lua_state
  if type(state) ~= "table" then state = {}; desync.track.lua_state = state end
  if state.adaptive_browser_syn then
    if state.adaptive_browser_syn.proto == "quic" then
      state.adaptive_browser_syn.quic_repeated = true
      local id, generation = state.adaptive_browser_trial_id, state.adaptive_browser_trial_generation
      if not state.adaptive_browser_flow_ambiguous_recorded and type(id) == "string"
        and id:match("^[0-9a-f]+$") and #id == 32 and tonumber(generation) then
        state.adaptive_browser_flow_ambiguous_recorded = adaptive_browser_mark_flow_ambiguous(
          ADAPTIVE_BROWSER_FLOW_DIR .. "/" .. id .. "." .. tostring(generation) .. ".tsv")
      end
    end
    return false, "already-seen"
  end
  if type(dis_ipdst) ~= "function" or type(ntop) ~= "function" then return false, "ip-helpers-missing" end
  local dst = dis_ipdst(desync.dis)
  local ip = dst and ntop(dst) or nil
  if type(ip) ~= "string" or not ip:match("^%d+%.%d+%.%d+%.%d+$") then return false, "invalid-ip" end
  state.adaptive_browser_syn = {ip = ip, profile = "5", proto = "quic", scope = tostring(scope or "default"), seen = os.time()}
  return true
end

local function adaptive_browser_record_flow(desync, trial, host, ip, profile, proto, scope, strategy)
  if ADAPTIVE_MODE ~= "AGENT_BETA" or type(trial) ~= "table" or type(desync) ~= "table"
    or type(desync.track) ~= "table" or type(desync.track.lua_state) ~= "table" then return false end
  local syn = desync.track.lua_state.adaptive_browser_syn
  local now = os.time()
  local expected_syn_proto = proto == "quic" and "quic" or "tcp"
  if type(syn) ~= "table" or syn.ip ~= ip or syn.profile ~= tostring(profile) or syn.proto ~= expected_syn_proto or syn.scope ~= scope
    or (proto == "quic" and syn.quic_repeated)
    or syn.seen < trial.created or syn.seen > now or now > trial.expires
    or trial.host ~= host or trial.ip ~= ip or trial.profile ~= tostring(profile) or trial.proto ~= proto
    or trial.scope ~= scope or trial.strategy ~= strategy or not trial.id:match("^[0-9a-f]+$")
    or #trial.id ~= 32 or not tostring(trial.fingerprint):match("^sha256:[0-9a-f]+$") then return false end
  local path = ADAPTIVE_BROWSER_FLOW_DIR .. "/" .. trial.id .. "." .. tostring(trial.generation) .. ".tsv"
  local existing = io.open(path, "r")
  if existing then
    local first = existing:read("*l")
    local second = existing:read("*l")
    existing:close()
    if first ~= nil then
      if first ~= "AMBIGUOUS" or second ~= nil then adaptive_browser_mark_flow_ambiguous(path) end
      return false
    end
  end
  local ramp_treatment = "not_applicable"
  local ramp_ack_evidence = "not_applicable"
  if proto == "googlevideo-tcp" then
    ramp_treatment = desync.track.lua_state.wssize_ramp_treatment or "unknown"
    if ramp_treatment ~= "applied" and ramp_treatment ~= "bypassed" and ramp_treatment ~= "unchanged"
      and ramp_treatment ~= "no_window_scale" then ramp_treatment = "unknown" end
    if ramp_treatment == "applied" then
      ramp_ack_evidence = desync.track.lua_state.wssize_ramp_late_ack_confirmed and "confirmed" or "pending"
    elseif ramp_treatment == "unknown" then
      ramp_ack_evidence = "unknown"
    end
  end
  local f = io.open(path, "w")
  if not f then return false end
  local ok = f:write(table.concat({"1", trial.id, tostring(trial.generation), trial.client_id, scope,
    host, ip, tostring(profile), proto, tostring(strategy), trial.fingerprint, tostring(syn.seen), tostring(now),
    ramp_treatment, ramp_ack_evidence}, "\t"), "\n")
  f:close()
  return ok ~= nil
end

function locked_browser_capture_syn_for_tests(desync, profile, scope)
  return adaptive_browser_capture_syn(desync, profile, scope)
end

function locked_browser_record_flow_for_tests(desync, trial, host, ip, profile, proto, scope, strategy)
  return adaptive_browser_record_flow(desync, trial, host, ip, profile, proto, scope, strategy)
end

function locked_browser_capture_quic_for_tests(desync, host, profile, scope)
  return adaptive_browser_capture_quic_initial(desync, host, profile, scope)
end

function circular_locked(ctx, desync)
  if desync.arg and desync.arg.payload and not payload_check(desync) then
    return circular_locked_passthrough(ctx, desync)
  end
  local allow_nohost_enabled = desync_allow_nohost(desync)
  if not desync.track and not allow_nohost_enabled then
    -- Соединение началось до старта nfqws2 (SYN не попадал в очередь):
    -- пакет уходит без обработки, штатно после рестарта. Лог не чаще
    -- раза в 10 сек, иначе всплеск засоряет журнал.
    if os.time() - (_Z2R_CONNTRACK_NOTE_TS or 0) >= 10 then
      _Z2R_CONNTRACK_NOTE_TS = os.time()
      DLOG_ERR("circular_locked: conntrack is missing but required (connection started before nfqws2 start, packet passed undesynced - normal after daemon restart)")
    end
    return circular_locked_passthrough(ctx, desync)
  end

  local proto = desync_proto(desync)
  local base_profile = desync_profile_key(desync)
  local scope = desync_client_scope(desync)
  adaptive_browser_capture_syn(desync, base_profile, scope)
  local quic_initial = base_profile == "5" and proto == "udp" and desync.l7payload == "quic_initial"
    and desync.dis and desync.dis.udp and tonumber(desync.dis.udp.th_dport) == 443
  -- Хост извлекается для любого профиля: доменные локи должны срабатывать на
  -- первом пакете соединения независимо от allow_nohost (он управляет только
  -- допуском потоков без хоста).
  local host = desync_hostname(desync)
  if host and host ~= "" then
    host = host:gsub("%.$", "")
    host = string.lower(host)
    if host ~= "" then
      if allow_nohost_enabled then
        DLOG("circular_locked: allow_nohost profile from host "..host)
      else
        DLOG("circular_locked: host "..host.." profile="..tostring(base_profile))
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
  if quic_initial and host and host ~= "" then
    adaptive_browser_capture_quic_initial(desync, host, base_profile, scope)
  end
  if hostlist_has_host(desync.arg and desync.arg.exclude_hostlist, gate_host) then
    DLOG("circular_locked: excluded by hostlist profile="..profile.." host="..tostring(gate_host))
    return circular_locked_passthrough(ctx, desync)
  end
  local exclude_substrings = desync.arg and desync.arg.exclude_substrings
  if exclude_substrings and substring_hostlist_matches_desync(desync, exclude_substrings, gate_host) then
    DLOG("circular_locked: excluded by substring profile="..profile.." host="..tostring(gate_host))
    return circular_locked_passthrough(ctx, desync)
  end
  local include_substrings = desync.arg and desync.arg.include_substrings
  if include_substrings and not substring_hostlist_matches_desync(desync, include_substrings, gate_host) then
    DLOG("circular_locked: no substring match profile="..profile.." host="..tostring(gate_host))
    if ctx then lua_cutoff(ctx) end
    return circular_locked_passthrough(ctx, desync)
  end

  -- Only expose QUIC targets to browser trials after every configured list gate.
  if quic_initial and host and host ~= "" and type(dis_ipdst) == "function" and type(ntop) == "function" and desync.track then
    local dst = dis_ipdst(desync.dis)
    local dst_ip = dst and ntop(dst) or nil
    if dst_ip and dst_ip ~= "" then adaptive_observe_seen(host, dst_ip, base_profile, "quic", scope, desync.track) end
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
      return circular_locked_passthrough(ctx, desync)
    end
  end

  local locked = locked_strategy_for_profile(profile, proto, scope)
  if (not locked) and profile ~= base_profile then
    locked = locked_strategy_for_profile(base_profile, proto, scope)
    if locked then
      DLOG("circular_locked: fallback lock profile="..base_profile.." for host profile="..profile)
    end
  end
  if locked == 0 then
    DLOG("circular_locked: profile disabled by lock 0 profile="..profile)
    if ADAPTIVE_ACK_STRATEGY == 0 then adaptive_probe_ack(host or "", base_profile, 0) end
    return circular_locked_passthrough(ctx, desync)
  end

  local adaptive_strategy
  local adaptive_trial
  local adaptive_proto = proto
  if base_profile == "2" and host and host:match("^[a-z0-9%-]+%.googlevideo%.com$") then
    adaptive_proto = "googlevideo-tcp"
  end
  if quic_initial and host and adaptive_quic_host_allowed(host) then adaptive_proto = "quic" end
  local adaptive_transport_ok = (desync.dis and desync.dis.tcp and tonumber(desync.dis.tcp.th_dport) == 443 and proto == "tls")
    or (quic_initial and adaptive_proto == "quic")
  if ADAPTIVE_RULES_APPLY and (scope ~= "default" or ADAPTIVE_DEFAULT_SCOPE_APPLY)
    and locked == nil and host and host ~= "" and desync.track
    and type(desync.track.lua_state) == "table" and desync.dis and desync.dis.ip and adaptive_transport_ok
    and type(dis_ipdst) == "function" and type(ntop) == "function" then
    local dst = dis_ipdst(desync.dis)
    local dst_ip = dst and ntop(dst) or nil
    if dst_ip and dst_ip ~= "" then
      local tuple_key = table.concat({host, dst_ip, "443", base_profile, adaptive_proto, scope}, "\0")
      local state = desync.track.lua_state
      if state.adaptive_rule_checked and state.adaptive_rule_key == tuple_key then
        adaptive_strategy = state.adaptive_rule_strategy or nil
        adaptive_trial = state.adaptive_browser_trial or nil
      else
        adaptive_trial = locked_browser_trial_for_tuple(host, dst_ip, base_profile, adaptive_proto, scope)
        if adaptive_trial then adaptive_strategy = adaptive_trial.strategy
        else adaptive_strategy = locked_adaptive_strategy_for_tuple(host, dst_ip, base_profile, adaptive_proto, scope) end
        state.adaptive_rule_key = tuple_key
        state.adaptive_rule_strategy = adaptive_strategy or false
        state.adaptive_browser_trial = adaptive_trial or false
        state.adaptive_rule_checked = true
      end
    end
  end

  if locked == nil and host and host ~= "" and desync.track
    and desync.dis and desync.dis.ip and desync.dis.tcp
    and tonumber(desync.dis.tcp.th_dport) == 443 and proto == "tls"
    and type(dis_ipdst) == "function" and type(ntop) == "function" then
    z2r_adaptive_observe_connection(desync, base_profile, host, scope)
  end

  -- DIRECT is a distinct verified adaptive result. It passes this exact flow
  -- through before constructing/executing the numbered strategy plan. Manual
  -- and profile locks have already won above, so DIRECT cannot override them.
  if locked == nil and adaptive_strategy == 0 then
    if desync.track and type(desync.track.lua_state) == "table" and desync.track.lua_state.adaptive_observe_context then
      desync.track.lua_state.adaptive_observe_context.adaptive_rule_applied = true
    end
    DLOG("circular_locked: exact adaptive DIRECT host="..host)
    return circular_locked_passthrough(ctx, desync)
  end

  orchestrate(ctx, desync)
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

  local selected_strategy
  if locked and locked >= 1 and locked <= hrec.ctstrategy then
    selected_strategy = locked
    hrec.nstrategy = locked
    if scope ~= "default" then
      DLOG("circular_locked: locked strategy "..hrec.nstrategy.." scope="..scope.." profile="..profile)
    else
      DLOG("circular_locked: locked strategy "..hrec.nstrategy.." profile="..profile)
    end
  elseif adaptive_strategy and adaptive_strategy >= 1 and adaptive_strategy <= hrec.ctstrategy then
    selected_strategy = adaptive_strategy
    hrec.nstrategy = adaptive_strategy
    DLOG("circular_locked: exact adaptive rule strategy "..selected_strategy.." host="..host)
  else
    hrec.nstrategy = 1
    selected_strategy = 1
    DLOG("circular_locked: start from strategy 1 profile="..profile)
  end

  if desync.track and type(desync.track.lua_state) == "table" and desync.track.lua_state.adaptive_observe_context then
    desync.track.lua_state.adaptive_observe_context.adaptive_rule_applied =
      adaptive_strategy ~= nil and selected_strategy == adaptive_strategy
  end
  if adaptive_trial and desync.track and type(desync.track.lua_state) == "table" and selected_strategy == adaptive_trial.strategy then
    desync.track.lua_state.adaptive_browser_trial_id = adaptive_trial.id
    desync.track.lua_state.adaptive_browser_trial_generation = adaptive_trial.generation
    desync.track.lua_state.adaptive_browser_trial_strategy = adaptive_trial.strategy
    if not desync.track.lua_state.adaptive_browser_flow_recorded then
      desync.track.lua_state.adaptive_browser_flow_recorded = adaptive_browser_record_flow(
        desync, adaptive_trial, host, adaptive_trial.ip, base_profile, adaptive_proto, scope, selected_strategy)
    end
  end

  local verdict = VERDICT_PASS
  DLOG("circular_locked: current strategy "..selected_strategy.." profile="..profile)
  adaptive_probe_ack(host or "", base_profile, selected_strategy)
  while true do
    local instance = plan_instance_pop(desync)
    if not instance then break end
    if instance.arg.strategy and tonumber(instance.arg.strategy) == selected_strategy then
      verdict = blob_override_execute(desync, verdict, instance, base_profile)
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
