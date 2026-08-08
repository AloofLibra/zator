-- Strategy Lock Manager - centralized locked/blocked strategy management
-- Single source of truth for hostname normalization
--
-- Usage: require("strategy-lock-manager") in mega_circular.lua
-- All other modules should use slm_* functions for hostname operations

-- ==================== GLOBAL TABLES ====================
-- These tables are the single source of truth for strategy state

-- Strategies that WORK for a hostname (LOCK)
-- Key: normalized hostname, Value: strategy number
SLM_LOCKED = SLM_LOCKED or {}

-- Strategies that DON'T WORK for a hostname (BLOCK)
-- Key: normalized hostname, Value: table of blocked strategy numbers
SLM_BLOCKED = SLM_BLOCKED or {}

-- Strategies currently being tested (in-flight)
-- Key: normalized hostname, Value: {strategy=N, start_time=T}
SLM_TESTING = SLM_TESTING or {}

-- Auto-locked strategies (persisted to disk, auto-learned only)
SLM_AUTO_LOCKED = SLM_AUTO_LOCKED or {}
-- Рабочий файл часто меняется, поэтому держим его в tmpfs. Копия в /opt
-- нужна только для восстановления после перезапуска и обновляется с паузой,
-- чтобы не изнашивать flash-накопитель роутера частыми мелкими записями.
local SLM_AUTO_LOCKED_PATH = "/tmp/auto_locked.tsv"
local SLM_AUTO_LOCKED_BACKUP_PATH = "/opt/zapret2/extra_strats/cache/orchestra/auto_locked.tsv"
local SLM_AUTO_LOCKED_BACKUP_INTERVAL = 1800
local SLM_AUTO_LOCKED_LAST_BACKUP = 0

-- ==================== SEPARATE SUBDOMAINS ====================
-- Domains that should NOT be grouped by NLD (need separate strategies)
-- These are subdomains that behave differently from their parent domain

local SEPARATE_SUBDOMAINS = {
    ["updates.discord.com"] = true,      -- Discord/app updates
    ["clients.google.com"] = true,       -- Google clients API
    ["update.googleapis.com"] = true,    -- Google update API
    ["dl.google.com"] = true,            -- Downloads
    ["redirector.googlevideo.com"] = true, -- Different from regular googlevideo.com
}

-- ==================== NORMALIZATION FUNCTIONS ====================
-- ЕДИНСТВЕННОЕ место для hostname:lower() - все остальные модули должны использовать это

--- Check if hostname should be kept as full subdomain (not NLD-cut)
--- @param hostname string The hostname to check
--- @return boolean True if hostname should NOT be cut to NLD
function slm_should_keep_full_hostname(hostname)
    if not hostname then return false end
    local key = slm_normalize_hostkey(hostname)
    if not key then return false end
    return SEPARATE_SUBDOMAINS[key] == true
end

--- Normalize hostname to consistent key format
--- This is THE ONLY place where hostname:lower() should be called
--- @param hostname string The hostname to normalize
--- @return string|nil Normalized hostname or nil if invalid
function slm_normalize_hostkey(hostname)
    if not hostname then return nil end
    if type(hostname) ~= "string" then return nil end
    if hostname == "" then return nil end

    -- Single point of lowercase conversion
    local normalized = hostname:lower()

    -- Remove trailing dots (DNS root)
    normalized = normalized:gsub("%.+$", "")

    -- Remove leading dots (malformed)
    normalized = normalized:gsub("^%.+", "")

    -- Skip if empty after cleanup
    if normalized == "" then return nil end

    return normalized
end

--- Add a hostname to SEPARATE_SUBDOMAINS dynamically
--- @param hostname string The hostname to add
function slm_add_separate_subdomain(hostname)
    if not hostname then return end
    local key = slm_normalize_hostkey(hostname)
    if key then
        SEPARATE_SUBDOMAINS[key] = true
    end
end

-- ==================== TO BE CONTINUED ====================
-- Next parts will add:
-- - slm_lock_strategy(hostname, strategy)
-- - slm_block_strategy(hostname, strategy)
-- - slm_get_locked(hostname)
-- - slm_get_blocked(hostname)
-- - slm_clear_testing(hostname)
-- - Persistence functions for learned-strategies.lua integration

-- ==================== BLOCKED СТРАТЕГИИ ====================
-- BLOCKED_STRATEGIES заполняется из learned-strategies.lua (генерируется Python)
-- Two-level structure: BLOCKED_STRATEGIES[askey][hostname] = {strat1, strat2, ...}
-- For backward compatibility, also supports flat: BLOCKED_STRATEGIES[hostname] = {strat1, ...}

--- Check if strategy is blocked for hostname
--- ВАЖНО: нормализует hostname через slm_normalize_hostkey()
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostname string The hostname to check
--- @param strategy number The strategy number to check
--- @return boolean True if strategy is blocked for this hostname
function slm_is_blocked(askey, hostname, strategy)
    if not BLOCKED_STRATEGIES then return false end
    if not hostname or not strategy then return false end

    -- Нормализуем askey
    askey = askey or "default"

    local key = slm_normalize_hostkey(hostname)
    if not key then return false end

    -- Check two-level structure first: BLOCKED_STRATEGIES[askey][hostname]
    local as_blocked = BLOCKED_STRATEGIES[askey]
    if as_blocked and type(as_blocked) == "table" then
        -- Check exact match
        local blocked = as_blocked[key]
        if blocked and type(blocked) == "table" then
            for _, s in ipairs(blocked) do
                if s == strategy then return true end
            end
        end

        -- Check subdomain matching
        for domain, strategies in pairs(as_blocked) do
            if type(strategies) == "table" then
                if key == domain or key:sub(-#domain - 1) == "." .. domain then
                    for _, s in ipairs(strategies) do
                        if s == strategy then return true end
                    end
                end
            end
        end
    end

    -- Backward compatibility: check flat structure BLOCKED_STRATEGIES[hostname]
    local blocked = BLOCKED_STRATEGIES[key]
    if blocked and type(blocked) == "table" then
        -- Check if it's an array of numbers (old format) vs nested table (new format)
        if #blocked > 0 and type(blocked[1]) == "number" then
            for _, s in ipairs(blocked) do
                if s == strategy then return true end
            end
        end
    end

    -- Backward compatibility: subdomain matching for flat structure
    for domain, strategies in pairs(BLOCKED_STRATEGIES) do
        -- Skip askey tables (they are tables of tables)
        if type(strategies) == "table" and #strategies > 0 and type(strategies[1]) == "number" then
            if key == domain or key:sub(-#domain - 1) == "." .. domain then
                for _, s in ipairs(strategies) do
                    if s == strategy then return true end
                end
            end
        end
    end

    return false
end

-- ==================== SKIP PASS (стратегия 1 запрещена) ====================
-- Домены и IP где pass не работает (заблокированные сервисы)
-- Скопировано из strategy-stats.lua для централизации

-- Домены где стратегия pass (1) не работает
local SLM_SKIP_PASS_DOMAINS = {
    -- Discord (TLS for discord.com, UDP for voice servers)
    ["discord.com"] = true,
    ["discordapp.com"] = true,
    ["discord.gg"] = true,
    ["discord.media"] = true,
    ["discordapp.net"] = true,
    -- YouTube / Google Video
    ["youtube.com"] = true,
    ["googlevideo.com"] = true,
    ["ytimg.com"] = true,
    ["yt3.ggpht.com"] = true,
    ["youtu.be"] = true,
    -- Google (часто блокируется)
    ["google.com"] = true,
    ["googleapis.com"] = true,
    ["gstatic.com"] = true,
    -- Twitch
    ["twitch.tv"] = true,
    ["twitchcdn.net"] = true,
    -- Twitter/X
    ["twitter.com"] = true,
    ["x.com"] = true,
    ["twimg.com"] = true,
    -- Instagram
    ["instagram.com"] = true,
    ["cdninstagram.com"] = true,
    ["igcdn.com"] = true,
    ["ig.me"] = true,
    -- Facebook / Meta
    ["facebook.com"] = true,
    ["fbcdn.net"] = true,
    ["fb.com"] = true,
    ["fb.me"] = true,
    ["messenger.com"] = true,
    ["meta.com"] = true,
    -- Telegram
    ["telegram.org"] = true,
    ["t.me"] = true,
    -- Spotify
    ["spotify.com"] = true,
    ["spotifycdn.com"] = true,
    ["scdn.co"] = true,
    -- Roblox
    ["roblox.com"] = true,
    ["rbxcdn.com"] = true,
    ["robloxcdn.com"] = true,
    ["rbx.com"] = true,
    -- Torrents / Rutracker
    ["rutracker.org"] = true,
    ["rutracker.net"] = true,
    ["rutracker.cc"] = true,
    ["rutor.info"] = true,
    ["rutor.is"] = true,
    ["nnmclub.to"] = true,
    ["nnm-club.me"] = true,
    ["kinozal.tv"] = true,
    ["kinozal.me"] = true,
    ["thepiratebay.org"] = true,
    ["1337x.to"] = true,
    ["rarbg.to"] = true,
    -- Amazon
    ["amazon.com"] = true,
    ["amazon.co.uk"] = true,
    ["amazon.de"] = true,
    ["amazonaws.com"] = true,
    ["amazonvideo.com"] = true,
    ["primevideo.com"] = true,
    ["amazon-adsystem.com"] = true,
    -- Cloudflare
    ["cloudflare.com"] = true,
    ["cloudflare-dns.com"] = true,
    ["cloudflareinsights.com"] = true,
    ["cloudflareclient.com"] = true,
    ["one.one"] = true,
    ["1.1.1.1"] = true,
}

-- IP ranges that should NEVER use strategy 1 (pass)
-- Loaded from ipset files in lists/ folder
-- Format: {start_ip_num, end_ip_num} for CIDR ranges
local SLM_SKIP_PASS_IP_RANGES = {}
local slm_skip_pass_ips_loaded = false

-- Convert IP string to number for range comparison
local function slm_ip_to_number(ip)
    if not ip then return nil end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or not b or not c or not d then return nil end
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return a * 16777216 + b * 65536 + c * 256 + d
end

-- Parse CIDR notation (e.g., "34.0.48.0/24") into start and end IP numbers
local function slm_parse_cidr(cidr)
    local ip, mask = cidr:match("^([%d%.]+)/(%d+)$")
    if not ip or not mask then
        -- Single IP without mask
        local ip_num = slm_ip_to_number(cidr)
        if ip_num then
            return ip_num, ip_num
        end
        return nil, nil
    end

    local ip_num = slm_ip_to_number(ip)
    if not ip_num then return nil, nil end

    mask = tonumber(mask)
    if not mask or mask < 0 or mask > 32 then return nil, nil end

    -- Calculate range
    local host_bits = 32 - mask
    local range_size = 2 ^ host_bits
    local start_ip = ip_num
    local end_ip = ip_num + range_size - 1

    return start_ip, end_ip
end

-- Load IP ranges from ipset files
local function slm_load_skip_pass_ips()
    if slm_skip_pass_ips_loaded then return end
    slm_skip_pass_ips_loaded = true

    -- List of ipset files to load (relative to zapret folder)
    local ipset_files = {
        "lists/ipset-discord.txt",
        "lists/ipset-youtube.txt",
        "lists/ipset-telegram.txt",
        "lists/ipset-cloudflare.txt",
        "lists/ipset-cloudflare1.txt",
        "lists/ipset-roblox.txt",
        "lists/ipset-rutracker.txt",
        "lists/ipset-amazon.txt",
        "lists/ipset-whatsapp.txt",
        "lists/russia-discord-ipset.txt",
    }

    local total_ranges = 0

    for _, filename in ipairs(ipset_files) do
        local file = io.open(filename, "r")
        if file then
            for line in file:lines() do
                -- Skip empty lines and comments
                line = line:match("^%s*(.-)%s*$")  -- trim
                if line and #line > 0 and not line:match("^#") then
                    local start_ip, end_ip = slm_parse_cidr(line)
                    if start_ip and end_ip then
                        table.insert(SLM_SKIP_PASS_IP_RANGES, {start_ip, end_ip})
                        total_ranges = total_ranges + 1
                    end
                end
            end
            file:close()
        end
    end

    if total_ranges > 0 and DLOG then
        DLOG("strategy-lock-manager: loaded " .. total_ranges .. " IP ranges for SKIP_PASS")
    end
end

-- Check if IP is in skip_pass ranges (internal)
local function slm_ip_in_skip_pass_ranges(ip)
    if not ip then return false end

    -- Load ranges on first call
    slm_load_skip_pass_ips()

    local ip_num = slm_ip_to_number(ip)
    if not ip_num then return false end

    for _, range in ipairs(SLM_SKIP_PASS_IP_RANGES) do
        if ip_num >= range[1] and ip_num <= range[2] then
            return true
        end
    end

    return false
end

-- Helper: check if string is an IP address (not a hostname)
local function slm_is_ip_address(str)
    if not str then return false end
    return str:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

--- Check if hostname/IP should skip strategy 1 (pass)
--- Checks domains, subdomains, and IP ranges from ipset files
--- @param hostname string The hostname or IP to check
--- @return boolean True if strategy 1 (pass) should be skipped
function slm_should_skip_pass(hostname)
    if not hostname then return false end

    -- Normalize hostname
    local key = slm_normalize_hostkey(hostname)
    if not key then return false end

    -- For IP addresses: check against ipset ranges
    if slm_is_ip_address(key) then
        return slm_ip_in_skip_pass_ranges(key)
    end

    -- Check exact domain match
    if SLM_SKIP_PASS_DOMAINS[key] then
        return true
    end

    -- Check if it's a subdomain of a skip_pass domain
    -- e.g., "cdn.discord.com" should match "discord.com"
    for domain, _ in pairs(SLM_SKIP_PASS_DOMAINS) do
        -- Check if hostname ends with .domain or equals domain
        if key == domain or key:sub(-#domain - 1) == "." .. domain then
            return true
        end
    end

    return false
end

--- Public function to check if IP is in skip_pass ranges
--- @param ip string IP address to check
--- @return boolean True if IP should skip pass strategy
function slm_ip_in_skip_pass(ip)
    return slm_ip_in_skip_pass_ranges(ip)
end

-- ==================== LOCKED СТРАТЕГИИ (Quality Tracker) ====================
-- Отслеживает успешность стратегий и лочит лучшую
-- Логика адаптирована из combined-detector.lua

-- Global table for strategy quality scores (per askey, per host key)
-- Two-level structure: SLM_QUALITY[askey][hostkey] = quality record
-- askey: "tls", "http", "quic", "discord", "wireguard", "mtproto", "dns", "stun", or "default"
SLM_QUALITY = SLM_QUALITY or {}

-- Приватная функция: получить/создать запись качества для хоста
-- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
-- @param hostkey string Нормализованный ключ хоста
-- @return table Quality record
local function slm_get_quality_record(askey, hostkey)
    askey = askey or "default"

    if not SLM_QUALITY[askey] then
        SLM_QUALITY[askey] = {}
    end

    if not SLM_QUALITY[askey][hostkey] then
        SLM_QUALITY[askey][hostkey] = {
            strategy_successes = {},  -- strategy_id -> success count
            strategy_tests = {},      -- strategy_id -> total test count
            total_tests = 0,
            locked_strategy = nil,
            lock_reason = nil,
            is_user_lock = false      -- true if user manually locked this strategy
        }
    end
    return SLM_QUALITY[askey][hostkey]
end

-- Serializes the whole SLM_AUTO_LOCKED table to `path`. Returns true on
-- success, false if the file couldn't be opened for writing.
local function slm_write_auto_locked_to(path)
    local f = io.open(path, "w")
    if not f then return false end
    for askey, hosts in pairs(SLM_AUTO_LOCKED) do
        if type(hosts) == "table" then
            for host, strat in pairs(hosts) do
                if type(strat) == "number" then
                    f:write(askey, "\t", host, "\t", tostring(strat), "\n")
                end
            end
        end
    end
    f:close()
    return true
end

-- Atomically replaces `path`, so readers never see a partially written TSV.
local function slm_write_auto_locked_atomic(path)
    local tmp_path = path .. ".tmp"
    if slm_write_auto_locked_to(tmp_path) and os.rename(tmp_path, path) then
        return true
    end
    os.remove(tmp_path)
    return false
end

-- The active state is updated on every change in /tmp. The persistent copy is
-- refreshed at most once per interval (the first change after startup is
-- backed up immediately). If /tmp is unexpectedly unavailable, save directly
-- to the persistent copy so the new state is not lost completely.
local function slm_save_auto_locked()
    local active_saved = slm_write_auto_locked_atomic(SLM_AUTO_LOCKED_PATH)
    if not active_saved and DLOG then
        DLOG("slm_quality: failed to write active auto locks to " .. SLM_AUTO_LOCKED_PATH)
    end

    local now = os.time()
    local backup_due = SLM_AUTO_LOCKED_LAST_BACKUP == 0 or
        now < SLM_AUTO_LOCKED_LAST_BACKUP or
        now - SLM_AUTO_LOCKED_LAST_BACKUP >= SLM_AUTO_LOCKED_BACKUP_INTERVAL

    if not active_saved or backup_due then
        if slm_write_auto_locked_atomic(SLM_AUTO_LOCKED_BACKUP_PATH) then
            SLM_AUTO_LOCKED_LAST_BACKUP = now
        elseif DLOG then
            DLOG("slm_quality: failed to back up auto locks to " .. SLM_AUTO_LOCKED_BACKUP_PATH)
        end
    end
end

local function slm_set_auto_locked(askey, hostkey, strategy_id)
    if not askey or not hostkey or not strategy_id then return end
    if not SLM_AUTO_LOCKED[askey] then
        SLM_AUTO_LOCKED[askey] = {}
    end
    if SLM_AUTO_LOCKED[askey][hostkey] == strategy_id then return end
    SLM_AUTO_LOCKED[askey][hostkey] = strategy_id
    slm_save_auto_locked()
end

local function slm_clear_auto_locked(askey, hostkey)
    if not askey or not hostkey then return end
    local hosts = SLM_AUTO_LOCKED[askey]
    if hosts and hosts[hostkey] then
        hosts[hostkey] = nil
        slm_save_auto_locked()
    end
end

--- Commits an automatic lock and persists it in auto_locked.tsv.
--- Unlike slm_set_locked, this never creates a user/manual lock.
function slm_commit_auto_lock(askey, hostkey, strategy_id, reason)
    if not hostkey or not strategy_id then return false end
    askey = askey or "default"

    local key = slm_normalize_hostkey(hostkey)
    if not key or slm_is_blocked(askey, key, strategy_id) then return false end

    local qrec = slm_get_quality_record(askey, key)
    if qrec.is_user_lock then return false end

    qrec.locked_strategy = strategy_id
    qrec.lock_reason = reason or "auto"
    qrec.is_user_lock = false
    slm_set_auto_locked(askey, key, strategy_id)
    if DLOG then
        DLOG("slm_commit_auto_lock: [" .. askey .. "] " .. key .. " -> strat=" .. strategy_id ..
             " reason=" .. qrec.lock_reason)
    end
    return true
end

--- Записать результат теста стратегии
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @param strategy_id number ID стратегии
--- @param success boolean Успех или провал
function slm_record_result(askey, hostkey, strategy_id, success)
    if not hostkey or not strategy_id then return end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return end

    local qrec = slm_get_quality_record(askey, key)

    -- Initialize counters for this strategy
    if not qrec.strategy_successes[strategy_id] then
        qrec.strategy_successes[strategy_id] = 0
        qrec.strategy_tests[strategy_id] = 0
    end

    qrec.strategy_tests[strategy_id] = qrec.strategy_tests[strategy_id] + 1
    qrec.total_tests = qrec.total_tests + 1

    if success then
        qrec.strategy_successes[strategy_id] = qrec.strategy_successes[strategy_id] + 1
        if DLOG then
            DLOG("slm_quality: [" .. askey .. "] " .. key .. " strat=" .. strategy_id ..
                 " SUCCESS " .. qrec.strategy_successes[strategy_id] .. "/" .. qrec.strategy_tests[strategy_id])
        end
    else
        if DLOG then
            DLOG("slm_quality: [" .. askey .. "] " .. key .. " strat=" .. strategy_id ..
                 " FAIL " .. qrec.strategy_successes[strategy_id] .. "/" .. qrec.strategy_tests[strategy_id])
        end
    end
end

--- Найти лучшую стратегию по успешности
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @param skip_strategy number|nil ID стратегии для пропуска (например, 1 для pass)
--- @return number|nil best_id Лучшая стратегия или nil
--- @return number successes Количество успехов
--- @return number tests Количество тестов
function slm_get_best(askey, hostkey, skip_strategy)
    if not hostkey then return nil, 0, 0 end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return nil, 0, 0 end

    local as_table = SLM_QUALITY[askey]
    if not as_table then return nil, 0, 0 end

    local qrec = as_table[key]
    if not qrec then return nil, 0, 0 end

    local best_id = nil
    local best_successes = 0
    local best_tests = 0

    -- Collect and sort strategy ids first so iteration order (and therefore
    -- any tie-break between equally-good strategies) is deterministic.
    -- Plain pairs() order over a Lua table is unspecified and can vary
    -- between runs/reloads even for identical data, which previously made
    -- "best strategy" picks non-reproducible on ties.
    local strat_ids = {}
    for strat_id in pairs(qrec.strategy_successes) do
        strat_ids[#strat_ids + 1] = strat_id
    end
    table.sort(strat_ids)

    for _, strat_id in ipairs(strat_ids) do
        local successes = qrec.strategy_successes[strat_id]
        -- Skip strategy (e.g., 1 = pass - it's not a real bypass strategy)
        if skip_strategy and strat_id == skip_strategy then
            if DLOG then
                DLOG("slm_get_best: skipping strategy " .. strat_id .. " (pass)")
            end
        -- Skip blocked strategies using slm_is_blocked
        elseif slm_is_blocked(askey, key, strat_id) then
            if DLOG then
                DLOG("slm_get_best: skipping strategy " .. strat_id .. " (blocked for [" .. askey .. "] " .. key .. ")")
            end
        else
            local tests = qrec.strategy_tests[strat_id] or 0
            -- Prefer strategy with more successes
            -- If equal successes, prefer one with higher success RATE
            if successes > best_successes or
               (successes == best_successes and tests > 0 and best_tests > 0 and
                successes/tests > best_successes/best_tests) then
                best_id = strat_id
                best_successes = successes
                best_tests = tests
            end
        end
    end

    return best_id, best_successes, best_tests
end

--- Проверить нужно ли лочить стратегию
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @param desync_arg table|nil Параметры: lock_successes, lock_tests, lock_rate, skip_strategy
--- @return boolean should_lock Нужно ли лочить
--- @return number|nil strategy_id ID стратегии для лока
function slm_should_lock(askey, hostkey, desync_arg)
    if not hostkey then return false, nil end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return false, nil end

    local as_table = SLM_QUALITY[askey]
    if not as_table then return false, nil end

    local qrec = as_table[key]
    if not qrec then return false, nil end

    -- Already locked? Check if still valid (not blocked)
    if qrec.locked_strategy then
        -- If locked strategy is now blocked, unlock and find new one
        if slm_is_blocked(askey, key, qrec.locked_strategy) then
            if DLOG then
                DLOG("slm_quality: UNLOCK [" .. askey .. "] " .. key .. " strat=" .. qrec.locked_strategy .. " (now blocked)")
            end
            qrec.locked_strategy = nil
            qrec.lock_reason = nil
            -- Continue to find new best strategy below
        else
            return true, qrec.locked_strategy
        end
    end

    local min_successes = tonumber(desync_arg and desync_arg.lock_successes) or 3
    local min_tests = tonumber(desync_arg and desync_arg.lock_tests) or 5
    local min_rate = tonumber(desync_arg and desync_arg.lock_rate) or 0.6
    local skip_strategy = tonumber(desync_arg and desync_arg.skip_strategy)

    -- Not enough tests yet
    if qrec.total_tests < min_tests then
        return false, nil
    end

    -- Find best strategy (excluding skip_strategy and blocked strategies)
    local best_id, best_successes, best_tests = slm_get_best(askey, hostkey, skip_strategy)

    if not best_id then
        return false, nil
    end

    -- Check if best strategy meets lock criteria
    local success_rate = best_tests > 0 and (best_successes / best_tests) or 0

    -- Require the WINNING strategy itself to have at least min_tests
    -- attempts, not just the host's total_tests summed across every
    -- strategy that was ever tried. Otherwise, with several strategies
    -- rotating, total_tests can reach the threshold while the strategy
    -- that happens to be "best" so far only has 1-2 tests of its own -
    -- locking onto it prematurely based on a short lucky streak instead of
    -- a statistically meaningful sample.
    if best_tests < min_tests then
        return false, nil
    end

    if best_successes >= min_successes and success_rate >= min_rate then
        local reason = string.format("successes=%d tests=%d rate=%.0f%%",
                                     best_successes, best_tests, success_rate * 100)
        if desync_arg and desync_arg.validator then
            return true, best_id
        end
        if slm_commit_auto_lock(askey, key, best_id, reason) then
            return true, best_id
        end
    end

    return false, nil
end

--- Получить залоченную стратегию для хоста
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @return number|nil strategy_id Залоченная стратегия или nil
function slm_get_locked(askey, hostkey)
    if not hostkey then return nil end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return nil end

    local as_table = SLM_QUALITY[askey]
    if not as_table then return nil end

    local qrec = as_table[key]
    if qrec and qrec.locked_strategy then
        return qrec.locked_strategy
    end
    return nil
end

--- Проверить, является ли лок пользовательским (защищён от auto-unlock)
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @return boolean True если это user lock
function slm_is_user_lock(askey, hostkey)
    if not hostkey then return false end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return false end

    local as_table = SLM_QUALITY[askey]
    if not as_table then return false end

    local qrec = as_table[key]
    return qrec and qrec.is_user_lock == true
end

--- Установить лок на стратегию вручную
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @param strategy_id number ID стратегии
--- @param reason string|nil Причина лока
--- @return boolean Успех установки лока
function slm_set_locked(askey, hostkey, strategy_id, reason)
    if not hostkey or not strategy_id then return false end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return false end

    -- Проверка что стратегия не заблокирована
    if slm_is_blocked(askey, key, strategy_id) then
        if DLOG then
            DLOG("slm_set_locked: REJECTED [" .. askey .. "] " .. key .. " strat=" .. strategy_id .. " (blocked)")
        end
        return false
    end

    local qrec = slm_get_quality_record(askey, key)
    qrec.locked_strategy = strategy_id
    qrec.lock_reason = reason or "manual"

    if DLOG then
        DLOG("slm_set_locked: [" .. askey .. "] " .. key .. " -> strat=" .. strategy_id .. " reason=" .. (reason or "manual"))
    end
    return true
end

--- Сбросить качество для хоста (для переобучения)
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
function slm_reset(askey, hostkey)
    if not hostkey then return end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return end

    local as_table = SLM_QUALITY[askey]
    if not as_table then return end

    local qrec = as_table[key]
    if not qrec then return end

    if not qrec.is_user_lock then
        slm_clear_auto_locked(askey, key)
    end

    as_table[key] = nil
    if DLOG then
        DLOG("slm_quality: RESET [" .. askey .. "] " .. key)
    end
end

--- Получить статистику по стратегиям для логов
--- @param askey string Ключ autostate (tls, http, quic, etc.) - optional, defaults to "default"
--- @param hostkey string Имя хоста (будет нормализовано)
--- @return string Статистика в виде строки
function slm_get_stats(askey, hostkey)
    if not hostkey then return "no host" end

    -- Нормализуем askey
    askey = askey or "default"

    -- Нормализуем hostkey
    local key = slm_normalize_hostkey(hostkey)
    if not key then return "invalid host" end

    local as_table = SLM_QUALITY[askey]
    if not as_table then return "no data" end

    local qrec = as_table[key]
    if not qrec then return "no data" end

    local parts = {}
    for strat_id, successes in pairs(qrec.strategy_successes) do
        local tests = qrec.strategy_tests[strat_id] or 0
        local rate = tests > 0 and math.floor(successes / tests * 100) or 0
        table.insert(parts, string.format("#%d:%d/%d(%d%%)", strat_id, successes, tests, rate))
    end

    if #parts == 0 then return "empty" end

    table.sort(parts)
    local result = table.concat(parts, " ")

    if qrec.locked_strategy then
        result = result .. " [LOCK=#" .. qrec.locked_strategy .. "]"
    end

    return result
end

-- ==================== PRELOAD (вызывается из Python) ====================
-- Эти функции вызываются из learned-strategies.lua (генерируется Python)

--- Предзагрузка залоченной стратегии
--- @param askey string Ключ протокола (tls, http, quic, discord, wireguard, mtproto, dns, stun)
--- @param hostname string Имя хоста
--- @param strategy number Номер стратегии
--- @param is_user_lock boolean|nil True если это пользовательский лок (защищён от auto-unlock)
--- @return boolean Успех загрузки
function slm_preload_locked(askey, hostname, strategy, is_user_lock)
    -- Default askey to "tls" for backward compatibility
    if not askey or askey == "" then askey = "tls" end
    if not hostname then return false end
    if not strategy then return false end

    -- Нормализуем hostname
    local key = slm_normalize_hostkey(hostname)
    if not key then return false end

    -- Проверяем что стратегия не заблокирована
    if slm_is_blocked(askey, key, strategy) then
        if DLOG then
            DLOG("slm_preload_locked: SKIP [" .. askey .. "] " .. key .. " strat=" .. strategy .. " (blocked)")
        end
        return false
    end

    -- Создаём запись качества и устанавливаем лок
    -- Передаём askey для правильного размещения в SLM_QUALITY[askey][hostkey]
    local qrec = slm_get_quality_record(askey, key)
    qrec.locked_strategy = strategy
    qrec.is_user_lock = is_user_lock or false

    -- Формируем lock_reason в зависимости от типа лока
    if is_user_lock then
        qrec.lock_reason = "user"
    else
        qrec.lock_reason = "preload"
    end

    if DLOG then
        local lock_type = is_user_lock and "USER" or "preload"
        DLOG("slm_preload_locked: [" .. askey .. "] " .. key .. " -> strat=" .. strategy .. " lock=" .. lock_type)
    end

    return true
end

local function slm_load_auto_locked()
    if SLM_AUTO_LOCKED._loaded then return end
    SLM_AUTO_LOCKED._loaded = true

    -- Normally reuse the current /tmp state (it may already have been created
    -- by another nfqws2 process). After reboot /tmp is empty, so restore from
    -- the persistent backup and immediately recreate the active file.
    local source_path = SLM_AUTO_LOCKED_PATH
    local f = io.open(source_path, "r")
    local restored_from_backup = false
    if not f then
        source_path = SLM_AUTO_LOCKED_BACKUP_PATH
        f = io.open(source_path, "r")
        restored_from_backup = f ~= nil
    end
    if not f then return end
    for line in f:lines() do
        if line and line ~= "" then
            local askey, host, strat = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
            if askey and host and strat then
                local n = tonumber(strat)
                if n then
                    local key = slm_normalize_hostkey(host)
                    if key then
                        if not SLM_AUTO_LOCKED[askey] then
                            SLM_AUTO_LOCKED[askey] = {}
                        end
                        SLM_AUTO_LOCKED[askey][key] = n
                        slm_preload_locked(askey, key, n, false)
                    end
                end
            end
        end
    end
    f:close()

    if restored_from_backup and not slm_write_auto_locked_atomic(SLM_AUTO_LOCKED_PATH) and DLOG then
        DLOG("slm_quality: failed to restore active auto locks to " .. SLM_AUTO_LOCKED_PATH)
    end
end

--- Предзагрузка заблокированных стратегий для хоста
--- Создает two-level структуру: BLOCKED_STRATEGIES[askey][hostname] = {strat1, strat2, ...}
--- @param askey string Ключ протокола (tls, http, quic, discord, wireguard, mtproto, dns, stun)
--- @param hostname string Имя хоста
--- @param strategies table Массив номеров заблокированных стратегий {1, 2, 3, ...}
--- @return boolean Успех загрузки
function slm_preload_blocked(askey, hostname, strategies)
    -- Default askey to "default" for backward compatibility
    if not askey or askey == "" then askey = "default" end
    if not hostname then return false end
    if not strategies then return false end
    if type(strategies) ~= "table" then return false end

    -- Нормализуем hostname
    local key = slm_normalize_hostkey(hostname)
    if not key then return false end

    -- Инициализируем BLOCKED_STRATEGIES если не существует
    if not BLOCKED_STRATEGIES then
        BLOCKED_STRATEGIES = {}
    end

    -- Инициализируем askey уровень если не существует
    if not BLOCKED_STRATEGIES[askey] then
        BLOCKED_STRATEGIES[askey] = {}
    end

    -- Инициализируем массив для хоста или добавляем к существующему
    if not BLOCKED_STRATEGIES[askey][key] then
        BLOCKED_STRATEGIES[askey][key] = {}
    end

    -- Добавляем стратегии (избегая дубликатов)
    local existing = {}
    for _, s in ipairs(BLOCKED_STRATEGIES[askey][key]) do
        existing[s] = true
    end

    local added = 0
    for _, strat in ipairs(strategies) do
        if type(strat) == "number" and not existing[strat] then
            table.insert(BLOCKED_STRATEGIES[askey][key], strat)
            existing[strat] = true
            added = added + 1
        end
    end

    if DLOG then
        DLOG("slm_preload_blocked: [" .. askey .. "] " .. key .. " added " .. added .. " strategies")
    end

    return true
end

--- Загрузка таблицы BLOCKED_STRATEGIES (DEPRECATED - для обратной совместимости)
--- Использует flat структуру BLOCKED_STRATEGIES[hostname] = {strat1, strat2, ...}
--- ВНИМАНИЕ: Эта функция устарела, используйте slm_preload_blocked(askey, hostname, strategies)
--- @param blocked_table table Таблица { ["hostname"] = {strat1, strat2, ...}, ... }
--- @return number Количество загруженных записей
function slm_preload_blocked_flat(blocked_table)
    if not blocked_table then return 0 end
    if type(blocked_table) ~= "table" then return 0 end

    local count = 0

    for hostname, strategies in pairs(blocked_table) do
        if type(strategies) == "table" then
            -- Нормализуем hostname
            local key = slm_normalize_hostkey(hostname)
            if key then
                -- Инициализируем BLOCKED_STRATEGIES если не существует
                if not BLOCKED_STRATEGIES then
                    BLOCKED_STRATEGIES = {}
                end

                -- Копируем массив стратегий
                BLOCKED_STRATEGIES[key] = {}
                for _, strat in ipairs(strategies) do
                    if type(strat) == "number" then
                        table.insert(BLOCKED_STRATEGIES[key], strat)
                    end
                end

                count = count + 1
            end
        end
    end

    if DLOG then
        DLOG("slm_preload_blocked_flat: loaded " .. count .. " hosts (DEPRECATED)")
    end

    return count
end

--- Предзагрузка истории успехов/неудач
--- @param askey string Ключ протокола (tls, http, quic, discord, wireguard, mtproto, dns, stun)
--- @param hostname string Имя хоста
--- @param strategy number Номер стратегии
--- @param successes number Количество успехов
--- @param failures number Количество неудач
--- @return boolean Успех загрузки
function slm_preload_history(askey, hostname, strategy, successes, failures)
    -- Default askey to "tls" for backward compatibility
    if not askey or askey == "" then askey = "tls" end
    if not hostname then return false end
    if not strategy then return false end

    successes = tonumber(successes) or 0
    failures = tonumber(failures) or 0

    -- Нормализуем hostname
    local key = slm_normalize_hostkey(hostname)
    if not key then return false end

    -- Создаём запись качества
    -- Передаём askey для правильного размещения в SLM_QUALITY[askey][hostkey]
    local qrec = slm_get_quality_record(askey, key)

    -- Устанавливаем счётчики
    qrec.strategy_successes[strategy] = successes
    qrec.strategy_tests[strategy] = successes + failures
    qrec.total_tests = (qrec.total_tests or 0) + successes + failures

    if DLOG then
        DLOG("slm_preload_history: [" .. askey .. "] " .. key .. " strat=" .. strategy ..
             " successes=" .. successes .. " failures=" .. failures)
    end

    return true
end

-- Load auto-learned locks from disk on startup.
slm_load_auto_locked()
