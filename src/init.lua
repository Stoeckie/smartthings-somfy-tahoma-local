-- SmartThings Edge driver: Somfy TaHoma (Switch, v2 and other boxes with Developer Mode) over the local API.
-- One box device; every shade, screen, awning or shutter on the box becomes a child device.
-- The Developer Mode token is a device setting on the box device and stays on the hub; nothing secret in code.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local api = require "tahoma_api"
local model = require "tahoma_model"

local BUILD = "2026-11-08a"
local FAST_POLL_SECS = 2
local FAST_POLL_FOR = 60

-- Connection status as a capability, so routines can notify when the box is unreachable.
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local drop_cap = capabilities["silvervalley08660.connectionLog"]
local CONN_GRACE = 120
local function emit_conn(dev, v)
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() dev:emit_event(conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local function fmt_secs(s)
  if s < 120 then return string.format("%d s", s) end
  if s < 7200 then return string.format("%d min", s // 60) end
  return string.format("%.1f h", s / 3600)
end
local function set_conn(dev, up, reason)
  if up then
    dev:set_field("conn_down_since", nil)
    if not dev:get_field("drop_seen") then
      -- the app wants a value for every attribute ("not all status information updated yet" otherwise)
      dev:set_field("drop_seen", true)
      local ok, v = pcall(dev.get_latest_state, dev, "main", drop_cap.ID, "lastDrop")
      if ok and v == nil and not dev:get_field("conn_drop") then
        pcall(function() dev:emit_event(drop_cap.lastDrop("No drops yet")) end)
      end
    end
    local d = dev:get_field("conn_drop")
    if type(d) == "table" and d.at then
      dev:set_field("conn_drop", nil, { persist = true })
      local txt = string.format("%s UTC, %s: %s", os.date("!%Y-%m-%d %H:%M:%S", d.at),
        fmt_secs(math.max(0, os.time() - d.at)), tostring(d.reason))
      pcall(function() dev:emit_event(drop_cap.lastDrop(txt:sub(1, 200))) end)
    end
    emit_conn(dev, "online")
    return
  end
  if not dev:get_field("conn_drop") then
    dev:set_field("conn_drop", { at = os.time(), reason = tostring(reason or "unknown"):sub(1, 120) }, { persist = true })
  end
  if dev:get_field("conn_down_since") then return end
  local since = os.time()
  dev:set_field("conn_down_since", since)
  local ok = pcall(function()
    dev.thread:call_with_delay(CONN_GRACE, function()
      if dev:get_field("conn_down_since") == since then emit_conn(dev, "offline") end
    end)
  end)
  if not ok then emit_conn(dev, "offline") end
end

local shade = capabilities.windowShade
local shadeLevel = capabilities.windowShadeLevel
local shadePreset = capabilities.windowShadePreset

local state = {} -- box.id -> { timer, busy, fast_until, devices = { url -> somfy device }, err, last_ok }

local function is_box(d) return d.parent_assigned_child_key == nil end

local function clean(s) return (tostring(s or ""):gsub("%s", "")) end

local function discover_ip()
  local ok, mdns = pcall(require, "st.mdns")
  if not ok then return nil end
  local okd, res = pcall(mdns.discover, "_kizboxdev._tcp", "local")
  for _, f in ipairs((okd and res and res.found) or {}) do
    local addr = (f.host_info or {}).address
    if addr and addr:match("^%d+%.%d+%.%d+%.%d+$") then return addr end
  end
end

local function settings(box)
  local p = box.preferences or {}
  local host = clean(p.ipAddress)
  if host == "" or host == "auto" then host = box:get_field("ip") or "" end
  return host, clean(p.token)
end

local function children(driver, box)
  local out = {}
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == box.id and d.parent_assigned_child_key then out[d.parent_assigned_child_key] = d end
  end
  return out
end

local function profile_for(kind) return kind == "rts" and "tahoma-shade-rts" or "tahoma-shade" end

local function emit_shade(child, sd, kind)
  local invert = (child.preferences or {}).invert == true
  if sd.available == false then child:offline() return end
  child:online()
  local lvl = model.level(sd, kind, invert)
  pcall(function()
    child:emit_event(shade.supportedWindowShadeCommands({ "open", "close", "pause" }, { visibility = { displayed = false } }))
  end)
  if lvl ~= nil then
    pcall(function() child:emit_event(shadeLevel.shadeLevel(lvl)) end)
    local st = model.shade_state(lvl)
    if model.moving(sd) then
      local last = child:get_field("last_level")
      if last and lvl > last then st = "opening" elseif last and lvl < last then st = "closing" end
    end
    pcall(function() child:emit_event(shade.windowShade(st)) end)
    child:set_field("last_level", lvl)
  else
    -- RTS: no position, show the last command
    local last = child:get_field("rts_state") or "unknown"
    pcall(function() child:emit_event(shade.windowShade(last)) end)
  end
end

local poll

-- creating a child takes a moment before it shows up in get_devices(); remember pending creations so a
-- second poll in that window does not create the same shade twice
local CREATE_WAIT = 120

local function ensure_children(driver, box, shades)
  local kids = children(driver, box)
  local st = state[box.id]
  st.creating = st.creating or {}
  for _, s in ipairs(shades) do
    local url = s.dev.deviceURL
    if kids[url] then st.creating[url] = nil end
    if not kids[url] and os.time() - (st.creating[url] or 0) >= CREATE_WAIT then
      st.creating[url] = os.time()
      local label = tostring(s.dev.label or url)
      log.info("[tahoma] creating " .. label .. " (" .. s.kind .. ", " .. tostring(model.ui_class(s.dev)) .. ")")
      driver:try_create_device({ type = "EDGE_CHILD", parent_device_id = box.id, parent_assigned_child_key = url,
        label = label, profile = profile_for(s.kind), manufacturer = "Somfy",
        model = tostring(s.dev.controllableName or model.ui_class(s.dev) or "TaHoma"), vendor_provided_label = label })
    end
  end
  return kids
end

local function poll_once(driver, box, st)
  local host, token = settings(box)
  if token == "" then
    st.err = "no token yet: enter the Developer Mode token in the settings of this device"
    return
  end
  if host == "" then
    host = discover_ip()
    if host then
      box:set_field("ip", host, { persist = true })
      log.info("[tahoma] box found at " .. host)
    else
      st.err = "box not found (set the IP address in the settings)"
      log.warn("[tahoma] " .. st.err)
      set_conn(box, false, st.err); box:offline()
      return
    end
  end
  local devices, err = api.json("GET", host, "/setup/devices", token)
  if not devices then
    st.err = err
    log.warn("[tahoma] " .. tostring(err))
    set_conn(box, false, err); box:offline()
    for _, k in pairs(children(driver, box)) do k:offline() end
    return
  end
  st.err, st.last_ok = nil, os.time()
  box:online(); set_conn(box, true)
  local shades = model.shades(devices)
  if not st.listed then
    st.listed = true
    log.info(string.format("[tahoma] %d device(s) on the box, %d shade(s)", #devices, #shades))
    for _, d in ipairs(devices) do
      log.info(string.format("[tahoma]   %s | %s | %s", tostring(d.label), tostring(model.ui_class(d)), tostring(d.controllableName)))
    end
  end
  st.devices = {}
  local kids = ensure_children(driver, box, shades)
  for _, s in ipairs(shades) do
    st.devices[s.dev.deviceURL] = s
    local child = kids[s.dev.deviceURL]
    if child then emit_shade(child, s.dev, s.kind) end
  end
end

poll = function(driver, box)
  local st = state[box.id]
  if not st or st.busy then return end
  st.busy = true
  local ok, err = pcall(poll_once, driver, box, st)
  st.busy = false
  if not ok then log.error("[tahoma] poll error: " .. tostring(err)) end
end

local function fast_poll(driver, box)
  local st = state[box.id]
  if not st then return end
  local was = st.fast_until and os.time() < st.fast_until
  st.fast_until = os.time() + FAST_POLL_FOR
  if was then return end
  local function tick()
    if not state[box.id] or os.time() >= (st.fast_until or 0) then return end
    poll(driver, box)
    box.thread:call_with_delay(FAST_POLL_SECS, tick)
  end
  box.thread:call_with_delay(FAST_POLL_SECS, tick)
end

local function schedule(driver, box)
  local st = state[box.id]
  if st.timer then box.thread:cancel_timer(st.timer) end
  local interval = tonumber((box.preferences or {}).pollInterval) or 30
  st.timer = box.thread:call_on_schedule(interval, function() poll(driver, box) end, "tahoma-poll")
  box.thread:call_with_delay(2, function() poll(driver, box) end)
end

local function send(driver, child, action, value)
  local box = child:get_parent_device()
  local st = box and state[box.id]
  if not st then return end
  local s = (st.devices or {})[child.parent_assigned_child_key]
  if not s then
    log.warn("[tahoma] " .. child.label .. ": not (yet) known on the box")
    return
  end
  local invert = (child.preferences or {}).invert == true
  local cmds = model.commands(s.dev, s.kind, action, value, invert)
  if not cmds then
    log.warn("[tahoma] " .. child.label .. ": no command for " .. action)
    return
  end
  local host, token = settings(box)
  local res, err = api.json("POST", host, "/exec/apply", token, model.exec_body(s.dev.deviceURL, cmds))
  if not res then
    log.error("[tahoma] " .. child.label .. " " .. action .. ": " .. tostring(err))
    return
  end
  log.info(string.format("[tahoma] %s: %s %s", child.label, cmds[1].name, table.concat(cmds[1].parameters or {}, ",")))
  if s.kind == "rts" then
    local rts = (action == "open" or (action == "level" and (tonumber(value) or 0) >= 50)) and "open"
      or ((action == "close" or action == "level") and "closed") or "partially open"
    child:set_field("rts_state", rts, { persist = true })
    pcall(function() child:emit_event(shade.windowShade(rts)) end)
  end
  fast_poll(driver, box)
end

local function handle_refresh(driver, device)
  local box = is_box(device) and device or device:get_parent_device()
  if box then
    if state[box.id] then state[box.id].listed = false end
    poll(driver, box)
  end
end

local function device_init(driver, device)
  if not is_box(device) then
    pcall(function() device:emit_event(shadePreset.supportedCommands({ "presetPosition" }, { visibility = { displayed = false } })) end)
    return
  end
  state[device.id] = state[device.id] or {}
  schedule(driver, device)
end

local function info_changed(driver, device, _event, args)
  if is_box(device) then
    local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
    if clean(old.ipAddress) ~= clean((device.preferences or {}).ipAddress) then device:set_field("ip", nil, { persist = true }) end
    state[device.id] = state[device.id] or {}
    state[device.id].listed = false
    schedule(driver, device)
  else
    local box = device:get_parent_device()
    if box then poll(driver, box) end
  end
end

local function device_removed(_driver, device)
  local st = state[device.id]
  if st and st.timer then pcall(function() device.thread:cancel_timer(st.timer) end) end
  state[device.id] = nil
end

local function discovery(driver, _opts, _should_continue)
  for _, d in ipairs(driver:get_devices()) do
    if is_box(d) then return end -- one box per hub for now
  end
  local ip = discover_ip()
  log.info("[tahoma] discovery: box " .. tostring(ip or "not found via mDNS, set the IP in the settings"))
  driver:try_create_device({ type = "LAN", device_network_id = "somfy-tahoma-box", label = "Somfy TaHoma",
    profile = "tahoma-box", manufacturer = "Somfy", model = "TaHoma", vendor_provided_label = "Somfy TaHoma" })
end

local driver = Driver("somfy-tahoma-local", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_init, infoChanged = info_changed, removed = device_removed },
  capability_handlers = {
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
    [shade.ID] = {
      [shade.commands.open.NAME] = function(d, dev) send(d, dev, "open") end,
      [shade.commands.close.NAME] = function(d, dev) send(d, dev, "close") end,
      [shade.commands.pause.NAME] = function(d, dev) send(d, dev, "stop") end,
    },
    [shadeLevel.ID] = {
      [shadeLevel.commands.setShadeLevel.NAME] = function(d, dev, cmd) send(d, dev, "level", cmd.args.shadeLevel) end,
    },
    [shadePreset.ID] = {
      [shadePreset.commands.presetPosition.NAME] = function(d, dev) send(d, dev, "my") end,
    },
  },
})

log.info("[tahoma] Somfy TaHoma (local) driver starting, build " .. BUILD)
-- certificate pinning: which box device owns an address
require("certpin").lookup = function(host)
  for _, d in ipairs(driver:get_devices()) do
    if is_box(d) and settings(d) == host then return d end
  end
end

driver:run()
