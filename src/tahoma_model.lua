-- Pure logic for Somfy TaHoma devices (no SmartThings or network code, so it can be tested on a pc).
-- SmartThings level: 100 = open (light in), 0 = closed. Somfy ClosureState: 0 = open, 100 = closed.
-- Somfy DeploymentState (awnings, some screens): 0 = retracted, 100 = deployed (sun blocked = "closed").
local M = {}

-- uiClass values that are shades, screens, awnings, shutters and the like
M.SHADE_CLASSES = {
  RollerShutter = true, Awning = true, ExteriorScreen = true, Screen = true, Shutter = true, Curtain = true,
  VenetianBlind = true, ExteriorVenetianBlind = true, Pergola = true, SwingingShutter = true, Window = true,
}

function M.has_cmd(dev, name)
  for _, c in ipairs(((dev or {}).definition or {}).commands or {}) do
    if c.commandName == name then return true end
  end
  return false
end

function M.state(dev, name)
  for _, s in ipairs((dev or {}).states or {}) do
    if s.name == name then return s.value end
  end
end

function M.ui_class(dev)
  return (dev or {}).uiClass or ((dev or {}).definition or {}).uiClass
end

--- "closure", "deployment", "rts" (no position, e.g. Somfy RTS) or nil (not a shade)
function M.kind(dev)
  if not M.SHADE_CLASSES[M.ui_class(dev) or ""] then return nil end
  if M.has_cmd(dev, "setClosure") or M.state(dev, "core:ClosureState") ~= nil then return "closure" end
  if M.has_cmd(dev, "setDeployment") or M.state(dev, "core:DeploymentState") ~= nil then return "deployment" end
  if M.has_cmd(dev, "open") or M.has_cmd(dev, "close") or M.has_cmd(dev, "up") or M.has_cmd(dev, "down") then
    return "rts"
  end
  return nil
end

local function clamp(v) return math.max(0, math.min(100, math.floor(v + 0.5))) end

--- SmartThings level 0..100 (100 = open) or nil when unknown
function M.level(dev, kind, invert)
  local raw
  if kind == "closure" then raw = tonumber(M.state(dev, "core:ClosureState"))
  elseif kind == "deployment" then raw = tonumber(M.state(dev, "core:DeploymentState")) end
  if not raw then return nil end
  local lvl = 100 - raw
  if invert then lvl = 100 - lvl end
  return clamp(lvl)
end

function M.shade_state(level)
  if level == nil then return nil end
  if level >= 99 then return "open" end
  if level <= 1 then return "closed" end
  return "partially open"
end

function M.moving(dev)
  local m = M.state(dev, "core:MovingState")
  return m == true or m == "true"
end

-- no "parameters" key for commands without arguments: an empty Lua table could be encoded as {} instead of []
local function one(name, params)
  if params and #params > 0 then return { { name = name, parameters = params } } end
  return { { name = name } }
end

--- Somfy commands for a SmartThings action: "open", "close", "stop", "my", "level" (value 0..100)
function M.commands(dev, kind, action, value, invert)
  if action == "stop" then
    if M.has_cmd(dev, "stop") then return one("stop") end
    return one("my") -- RTS: "my" stops a moving motor
  end
  if action == "my" then return one("my") end
  local lvl
  if action == "open" then lvl = 100 elseif action == "close" then lvl = 0 else lvl = clamp(tonumber(value) or 0) end
  if invert then lvl = 100 - lvl end
  if kind == "closure" and M.has_cmd(dev, "setClosure") then return one("setClosure", { 100 - lvl }) end
  if kind == "deployment" and M.has_cmd(dev, "setDeployment") then return one("setDeployment", { 100 - lvl }) end
  -- no position command: only fully open or closed
  if lvl >= 50 then
    if M.has_cmd(dev, "open") then return one("open") end
    if M.has_cmd(dev, "up") then return one("up") end
    if M.has_cmd(dev, "undeploy") then return one("undeploy") end
  else
    if M.has_cmd(dev, "close") then return one("close") end
    if M.has_cmd(dev, "down") then return one("down") end
    if M.has_cmd(dev, "deploy") then return one("deploy") end
  end
  return nil
end

--- body for POST /exec/apply
function M.exec_body(device_url, cmds)
  return { label = "SmartThings", actions = { { deviceURL = device_url, commands = cmds } } }
end

--- the shades among the devices of GET /setup/devices
function M.shades(devices)
  local out = {}
  for _, d in ipairs(devices or {}) do
    local k = M.kind(d)
    if k and d.deviceURL then out[#out + 1] = { dev = d, kind = k } end
  end
  return out
end

return M
