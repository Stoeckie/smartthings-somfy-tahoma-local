-- Minimal HTTPS client for the Somfy TaHoma local API (Developer Mode, port 8443, Bearer token).
-- The box uses a certificate from Somfy's own CA, which the hub does not know, so verification is off and the
-- certificate is pinned on first use instead (certpin.lua): the token is never sent to another certificate.
local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local json = require "st.json"
local pin = require "certpin"

local M = {}
M.BASE = "/enduser-mobile-web/1/enduserAPI"
M.PORT = 8443
local TIMEOUT = 15

local function tls_connect(host, port, secret)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(TIMEOUT)
  local ok, cerr = sock:connect(host, port)
  if not ok then
    sock:close()
    return nil, "connect: " .. tostring(cerr)
  end
  local tls, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
  if not tls then
    sock:close()
    return nil, "tls wrap: " .. tostring(werr)
  end
  local hs, herr = tls:dohandshake()
  if not hs then
    tls:close()
    return nil, "tls handshake: " .. tostring(herr)
  end
  local okp, perr = pin.check(tls, host, secret)
  if not okp then tls:close(); return nil, perr end
  return tls
end

local function read_body(sock, headers)
  local parts = {}
  if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
    while true do
      local line, rerr = sock:receive("*l")
      if not line then return nil, "receive chunk size: " .. tostring(rerr) end
      local size = tonumber(line:match("^%s*(%x+)"), 16)
      if not size then return nil, "bad chunk size" end
      if size == 0 then break end
      local data, cerr = sock:receive(size)
      if not data then return nil, "receive chunk: " .. tostring(cerr) end
      parts[#parts + 1] = data
      sock:receive("*l")
    end
  elseif headers["content-length"] then
    local len = tonumber(headers["content-length"]) or 0
    if len > 0 then
      local data, cerr = sock:receive(len)
      if not data then return nil, "receive body: " .. tostring(cerr) end
      parts[#parts + 1] = data
    end
  else
    local data, _, partial = sock:receive("*a")
    parts[#parts + 1] = data or partial or ""
  end
  return table.concat(parts)
end

--- One HTTPS request. Returns status, body or nil, err.
function M.request(method, host, path, token, body, port)
  port = port or M.PORT
  local sock, err = tls_connect(host, port, token)
  if not sock then return nil, err end
  local lines = {
    method .. " " .. M.BASE .. path .. " HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "User-Agent: smartthings-edge-somfy-tahoma-local",
    "Accept: application/json",
    "Connection: close",
    "Authorization: Bearer " .. tostring(token or ""),
  }
  if body then
    lines[#lines + 1] = "Content-Type: application/json"
    lines[#lines + 1] = "Content-Length: " .. #body
  end
  local sent, serr = sock:send(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""))
  if not sent then sock:close(); return nil, "send: " .. tostring(serr) end
  local line, rerr = sock:receive("*l")
  if not line then sock:close(); return nil, "receive status: " .. tostring(rerr) end
  local status = tonumber(line:match("^HTTP/%d%.?%d?%s+(%d+)"))
  if not status then sock:close(); return nil, "bad status line" end
  local headers = {}
  while true do
    line, rerr = sock:receive("*l")
    if not line then sock:close(); return nil, "receive headers: " .. tostring(rerr) end
    if line == "" then break end
    local k, v = line:match("^([^:]+):%s*(.-)%s*$")
    if k then headers[k:lower()] = v end
  end
  local data, berr = read_body(sock, headers)
  sock:close()
  if not data then return nil, berr end
  return status, data
end

--- JSON request; returns decoded table or nil, err, status.
function M.json(method, host, path, token, payload)
  local body = payload and json.encode(payload) or nil
  local status, data = M.request(method, host, path, token, body)
  if not status then return nil, data end
  if status == 401 then return nil, "token rejected (HTTP 401)", status end
  if status < 200 or status >= 300 then return nil, "HTTP " .. status .. " on " .. path, status end
  if data == "" then return {} end
  local ok, obj = pcall(json.decode, data)
  if not ok or type(obj) ~= "table" then return nil, "invalid JSON on " .. path end
  return obj
end

return M
