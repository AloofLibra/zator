-- Scoped auto-learning regression tests. Run with fengari or Lua 5.1.
local G = _G
G.DLOG = function() end
G.DLOG_ERR = function() end
G.SLM_QUALITY = {}
G.SLM_AUTO_LOCKED = {}
G.BLOCKED_STRATEGIES = {}
G.io = { open = function(_, mode)
  if mode == "r" then return nil end
  return { write = function() end, close = function() end }
end }
G.os = { time = os.time, rename = function() return true end, remove = function() end }
dofile("lua/strategy-lock-manager.lua")

local function assert_eq(actual, expected, message)
  assert(actual == expected, message .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
end

-- Same hostname/profile, independent scope counters and locks.
for _ = 1, 3 do G.slm_record_result("tls", "Example.COM.", 1, true, "mark:101") end
for _ = 1, 3 do G.slm_record_result("tls", "example.com", 2, true, "mark:102") end
for _ = 1, 3 do G.slm_record_result("tls", "example.com", 3, true) end
local ok, strat = G.slm_should_lock("tls", "example.com", {lock_successes=3, lock_tests=3, lock_rate=1}, "mark:101")
assert(ok and strat == 1, "mark:101 should learn strategy 1")
ok, strat = G.slm_should_lock("tls", "example.com", {lock_successes=3, lock_tests=3, lock_rate=1}, "mark:102")
assert(ok and strat == 2, "mark:102 should learn strategy 2")
ok, strat = G.slm_should_lock("tls", "example.com", {lock_successes=3, lock_tests=3, lock_rate=1})
assert(ok and strat == 3, "default should learn strategy 3")
assert_eq(G.slm_get_locked("tls", "example.com", "mark:101"), 1, "scope 101 lock")
assert_eq(G.slm_get_locked("tls", "example.com", "mark:102"), 2, "scope 102 lock")
assert_eq(G.slm_get_locked("tls", "example.com"), 3, "default lock")

-- A success in mark:101 must not alter mark:102/default statistics.
local before_102 = G.slm_get_stats("tls", "example.com", "mark:102")
local before_default = G.slm_get_stats("tls", "example.com")
G.slm_record_result("tls", "example.com", 1, true, "mark:101")
assert_eq(G.slm_get_stats("tls", "example.com", "mark:102"), before_102, "mark:102 stats isolation")
assert_eq(G.slm_get_stats("tls", "example.com"), before_default, "default stats isolation")

-- Scoped blocked state must not block the default scope.
G.slm_preload_blocked("tls", "example.com", {2}, "mark:101")
assert(G.slm_is_blocked("tls", "example.com", 2, "mark:101"), "scoped blocked strategy")
assert(not G.slm_is_blocked("tls", "example.com", 2), "scoped block leaked into default")

-- Manual scoped locks are user locks and survive auto-lock attempts.
assert(G.slm_set_locked("tls", "manual.example", 7, "manual", "mark:101"))
assert(G.slm_is_user_lock("tls", "manual.example", "mark:101"))
for _ = 1, 4 do G.slm_record_result("tls", "manual.example", 1, true, "mark:101") end
assert(not G.slm_commit_auto_lock("tls", "manual.example", 1, "auto", "mark:101"), "auto must not replace manual scoped lock")
assert_eq(G.slm_get_locked("tls", "manual.example", "mark:101"), 7, "manual scoped lock preserved")

print("client scope learning ok")
