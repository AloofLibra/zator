-- fake payload adapter: keeps shipped default blob header in line with modern clients
local function logf(fmt, a, b, c, d)
  pcall(function()
    local f = io.open("/tmp/fake_adapt.log", "a")
    if f then
      f:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), string.format(fmt, a, b, c, d)))
      f:close()
    end
  end)
end

local function adapt(name, ver)
  local data = _G[name]
  if type(data) ~= "string" or #data < 6 then
    logf("skip %s: not a blob", tostring(name))
    return
  end
  local t = tls_dissect(data)
  if not (t and t.rec and t.rec[1]) then
    logf("skip %s: dissect failed (size=%d)", name, #data)
    return
  end
  local old = t.rec[1].ver
  if old == ver then
    logf("ok %s: already %04x (size=%d)", name, ver, #data)
    return
  end
  t.rec[1].ver = ver
  local r = tls_reconstruct(t)
  if r and #r == #data then
    _G[name] = r
    logf("adapted %s: %04x -> %04x (size=%d)", name, old, ver, #r)
  else
    logf("skip %s: reconstruct failed", name)
  end
end

adapt("fake_default_tls", 0x0303)
