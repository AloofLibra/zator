-- Lua contract tests for scoped and legacy orchestra lock rows.
local G = _G

dofile("orchestra/locked.lua")

assert(type(G.locked_parse_line) == "function", "parser must be exported")
assert(type(G.locked_load_lines_for_tests) == "function", "test loader must be exported")

local scope, profile, proto, strategy = G.locked_parse_line("client-a\t3\ttls\t7")
assert(scope == "client-a" and profile == "3" and proto == "tls" and strategy == 7,
  "new scoped TSV row must parse")

scope, profile, proto, strategy = G.locked_parse_line("3\thttp\t4")
assert(scope == "default" and profile == "3" and proto == "http" and strategy == 4,
  "legacy three-column row must use default scope")

scope, profile, proto, strategy = G.locked_parse_line("3\t5")
assert(scope == "default" and profile == "3" and proto == "tls" and strategy == 5,
  "legacy two-column row must mean default TLS")

assert(G.locked_parse_line("client-a\t3\tbogus\t4") == nil, "invalid scoped proto is malformed")
assert(G.locked_parse_line("client-a\t3\ttls\t") == nil, "missing strategy is malformed")
assert(G.locked_parse_line("\t3\ttls\t4") == nil, "missing scope is malformed")
assert(G.locked_parse_line("client-a\t3\ttls\t-1") == nil, "negative strategy is malformed")

G.locked_load_lines_for_tests({
  "client-a\t3\ttls\t7",
  "default\t3\ttls\t8",
  "3\thttp\t4",
  "3\t8",
  "client-a\t4\ttls\t0",
})
assert(G.locked_strategy_for_profile("3", "tls", "client-a") == 7,
  "exact client scope must win")
assert(G.locked_strategy_for_profile("3", "tls", "other-client") == 8,
  "default scope must be fallback")
assert(G.locked_strategy_for_profile("3", "http", "other-client") == 4,
  "legacy protocol-specific lock must be retained")
assert(G.locked_strategy_for_profile("3", "tls", "missing") == 8,
  "automatic fallback must not be represented as a lock")
assert(G.locked_strategy_for_profile("4", "tls", "client-a") == 0,
  "strategy zero must be preserved")

G.locked_load_lines_for_tests({"client-a\t3\ttls\t7", "client-a\t3\ttls\t8"})
assert(G.locked_strategy_for_profile("3", "tls", "client-a") == nil,
  "conflicting duplicate must be rejected, not last-write-wins")
assert(G.locked_conflict_count() == 1, "conflict must be diagnosable")

-- Exercise the real circular_locked selection path: two clients use the same
-- hostname/profile but must select different scoped locks.  The stubs only
-- replace nfqws2's orchestration and plan executor, not the selection logic.
G.CLIENT_SCOPE_ENABLE = 1
G.CLIENT_SCOPE_MARK_MASK = 0xff00
G.CLIENT_SCOPE_MARK_SHIFT = 8
G.CLIENT_SCOPE_MARK_MAX = 255
G.DESYNC_MARK = 0x40000000
G.DESYNC_MARK_POSTNAT = 0x20000000
G.VERDICT_PASS = 0
G.DLOG = function() end
G.orchestrate = function() end
G.automate_host_record = function() return {} end
G.plan_instance_pop = function(desync)
  return table.remove(desync.plan, 1)
end
local selected = {}
G.plan_instance_execute = function(desync, verdict, instance)
  selected[#selected + 1] = tonumber(instance.arg.strategy)
  return verdict
end

G.locked_load_lines_for_tests({
  "mark:1\texample.com\ttls\t2",
  "mark:2\texample.com\ttls\t1",
  "default\texample.com\ttls\t1",
})
local function run_circular(fwmark, hostname, profile)
  local desync = {
    fwmark = fwmark,
    hostname = hostname,
    profile = profile,
    track = { lua_state = {} },
    arg = {},
    plan = {{arg = {strategy = 1}}, {arg = {strategy = 2}}},
  }
  assert(G.circular_locked({}, desync) == 0, "circular selection must preserve pass verdict")
  return table.remove(selected, 1), desync.track.lua_state.client_scope
end
local strategy, scope = run_circular(0x0100, "example.com", "example.com")
assert(strategy == 2 and scope == "mark:1", "first client must use its scoped lock")
strategy, scope = run_circular(0x0200, "example.com", "example.com")
assert(strategy == 1 and scope == "mark:2", "second client must use its scoped lock")

-- Disabled/missing scope remains legacy-compatible and falls back to default.
G.CLIENT_SCOPE_ENABLE = nil
G.locked_load_lines_for_tests({"example.com\ttls\t2"})
strategy, scope = run_circular(nil, "example.com", "example.com")
assert(strategy == 2 and scope == "default", "legacy lock must remain the default-scope behavior")

print("client scope parser ok")
