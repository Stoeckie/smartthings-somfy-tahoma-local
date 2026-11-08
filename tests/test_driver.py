"""Driver flow with mocked SmartThings and a fake TaHoma API: children, levels, commands."""
import json
from run_lua import runtime

HARNESS = r'''
-- events shaped like the hub's ({ capability = { ID }, attribute = { NAME }, value = { value } }), plus path/arg
local function capmock(path, segs)
  segs = segs or { "cap" }
  return setmetatable({}, {
    __index = function(t, k)
      if k == "NAME" then return segs[#segs] end
      local s = {}
      for i, x in ipairs(segs) do s[i] = x end
      s[#s + 1] = k
      local v = capmock(path .. "." .. k, s); rawset(t, k, v); return v end,
    __call = function(_, a, b)
      local val = a
      if type(val) ~= "table" then val = { value = segs[4] or a } end
      return { path = path, arg = a, capability = { ID = segs[2] }, attribute = { NAME = segs[3] }, value = val,
               visibility = b and b.visibility } end })
end
local caps = capmock("cap")
for _, id in ipairs({ "windowShade", "windowShadeLevel", "windowShadePreset", "refresh" }) do caps[id].ID = id end
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; return { run = function() end, get_devices = function() return DEVICES end } end
LOGS = {}
package.loaded["log"] = { info = function(m) LOGS[#LOGS + 1] = m end, warn = function(m) LOGS[#LOGS + 1] = "W " .. m end,
                          error = function(m) LOGS[#LOGS + 1] = "E " .. m end, debug = function() end }
package.loaded["cosock.socket"] = {}; package.loaded["cosock.ssl"] = {}
CALLS = {}
package.loaded["tahoma_api"] = { json = function(method, host, path, token, payload)
  CALLS[#CALLS + 1] = { method = method, host = host, path = path, token = token, payload = payload }
  if path == "/setup/devices" then return SOMFY end
  return { execId = "x" } end }
DEVICES = {}
local function mkdev(o)
  o.fields = {}; o.events = {}; o.status = "online"
  o.thread = { call_on_schedule = function() return 1 end, call_with_delay = function() end, cancel_timer = function() end }
  function o:get_field(k) return self.fields[k] end
  function o:set_field(k, v) self.fields[k] = v end
  function o:emit_event(e) self.events[e.path] = e.arg; self.n = (self.n or 0) + 1; if e.state_change then self.forced = (self.forced or 0) + 1 end end
  function o:online() self.status = "online" end
  function o:offline() self.status = "offline" end
  function o:get_parent_device() for _, d in ipairs(DEVICES) do if d.id == self.parent_device_id then return d end end end
  DEVICES[#DEVICES + 1] = o
  return o
end
MKDEV = mkdev
'''

SOMFY = [
    {"deviceURL": "io://1111-2222-3333/101", "label": "Landing", "uiClass": "ExteriorScreen", "available": True,
     "definition": {"uiClass": "ExteriorScreen", "commands": [{"commandName": c} for c in ["open", "close", "stop", "my", "setClosure"]]},
     "states": [{"name": "core:ClosureState", "value": 100}]},
    {"deviceURL": "io://1111-2222-3333/102", "label": "Kitchen", "uiClass": "Awning", "available": True,
     "definition": {"uiClass": "Awning", "commands": [{"commandName": c} for c in ["deploy", "undeploy", "stop", "my", "setDeployment"]]},
     "states": [{"name": "core:DeploymentState", "value": 0}]},
    {"deviceURL": "internal://1111-2222-3333/pod/0", "label": "Box", "uiClass": "Pod", "available": True,
     "definition": {"uiClass": "Pod", "commands": []}, "states": []},
]

def setup():
    lua = runtime()
    lua.execute(HARNESS.encode())
    j = lua.execute(b'return require("st.json")')
    lua.globals().SOMFY = j.decode(json.dumps(SOMFY).encode())
    lua.execute(b'require("init")')
    lua.execute(b'''BOX = MKDEV({ id = "box", label = "Somfy TaHoma", preferences = { token = " abc123 ", ipAddress = "192.168.1.50", pollInterval = 30 } })
      DRIVER.lifecycle_handlers.init(DRIVER_OBJ, BOX)
      function DRIVER_OBJ_TRY(o) local d = MKDEV({ id = o.parent_assigned_child_key, label = o.label, profile = o.profile,
        parent_device_id = o.parent_device_id, parent_assigned_child_key = o.parent_assigned_child_key, preferences = {} }) end''')
    return lua, j

def test_flow():
    lua, j = setup()
    lua.execute(b'''DRIVER_OBJ = { get_devices = function() return DEVICES end, try_create_device = function(_, o) DRIVER_OBJ_TRY(o) end }
      DRIVER.capability_handlers.refresh.refresh(DRIVER_OBJ, BOX)''')
    g = lua.globals()
    assert g.CALLS[1].path == b"/setup/devices" and g.CALLS[1].token == b"abc123" and g.CALLS[1].host == b"192.168.1.50"
    names = sorted(lua.eval('(function() local t = {} for _, d in ipairs(DEVICES) do t[#t+1] = d.label end return table.concat(t, ",") end)()').decode().split(","))
    assert names == ["Kitchen", "Landing", "Somfy TaHoma"]
    # a shade whose creation is still pending is not created again
    lua.execute(b'''local n = #DEVICES
      for i = #DEVICES, 1, -1 do if DEVICES[i].label == "Kitchen" then table.remove(DEVICES, i) end end
      DRIVER.capability_handlers.refresh.refresh(DRIVER_OBJ, BOX)
      COUNT_AFTER = #DEVICES''')
    assert g.COUNT_AFTER == 2
    lua.execute(b'DRIVER_OBJ_TRY({ label = "Kitchen", parent_device_id = "box", parent_assigned_child_key = "io://1111-2222-3333/102" })')
    # second poll emits the states on the children
    lua.execute(b'DRIVER.capability_handlers.refresh.refresh(DRIVER_OBJ, BOX)')
    assert len(lua.eval('DEVICES')) == 3
    over = lua.eval('(function() for _, d in ipairs(DEVICES) do if d.label == "Landing" then return d end end end)()')
    keuken = lua.eval('(function() for _, d in ipairs(DEVICES) do if d.label == "Kitchen" then return d end end end)()')
    assert over.events[b"cap.windowShadeLevel.shadeLevel"] == 0 and over.events[b"cap.windowShade.windowShade"] == b"closed"
    assert keuken.events[b"cap.windowShadeLevel.shadeLevel"] == 100 and keuken.events[b"cap.windowShade.windowShade"] == b"open"
    # only changed values go to the hub: another poll with the same states emits nothing; the first emits carried
    # state_change so the cloud catches up after a driver start
    n0, forced = over.n, over.forced
    assert forced == n0 and n0 >= 3
    lua.execute(b'DRIVER.capability_handlers.refresh.refresh(DRIVER_OBJ, BOX)')
    assert over.n == n0
    # a position the shade already has is not sent (the app re-sends the shown value when a slider is opened)
    calls0 = len(g.CALLS)
    lua.globals().OVER = over
    lua.execute(b'DRIVER.capability_handlers.windowShadeLevel.setShadeLevel(DRIVER_OBJ, OVER, { args = { shadeLevel = 0 } })')
    lua.execute(b'DRIVER.capability_handlers.windowShade.close(DRIVER_OBJ, OVER, {})')
    assert len(g.CALLS) == calls0
    # commands
    lua.globals().OVER = over
    lua.execute(b'DRIVER.capability_handlers.windowShadeLevel.setShadeLevel(DRIVER_OBJ, OVER, { args = { shadeLevel = 40 } })')
    last = g.CALLS[len(g.CALLS)]
    out = json.loads(j.encode(last.payload))
    assert last.method == b"POST" and last.path == b"/exec/apply"
    assert out["actions"][0] == {"deviceURL": "io://1111-2222-3333/101", "commands": [{"name": "setClosure", "parameters": [60]}]}
    lua.execute(b'DRIVER.capability_handlers.windowShadePreset.presetPosition(DRIVER_OBJ, OVER, {})')
    out = json.loads(j.encode(g.CALLS[len(g.CALLS)].payload))
    assert out["actions"][0]["commands"] == [{"name": "my"}]

def test_no_token():
    lua, j = setup()
    lua.execute(b'''BOX.preferences.token = ""
      DRIVER_OBJ = { get_devices = function() return DEVICES end, try_create_device = function(_, o) DRIVER_OBJ_TRY(o) end }
      DRIVER.capability_handlers.refresh.refresh(DRIVER_OBJ, BOX)''')
    assert len(lua.globals().CALLS) == 0
