-- A stand-in for the FiveM server runtime, for testing the ServerGuardian resource without a game
-- server. It mimics only what the resource uses (event handlers that run as coroutines, Wait,
-- SetTimeout, deferrals with Adaptive Cards, PerformHttpRequest with a callback, KVP storage,
-- commands, convars) on a virtual clock, so timeouts take no real time.
--
-- Usage: lua fake_fivem.lua <scenario.json>
-- PerformHttpRequest makes a real request with curl, so the resource talks to a real API.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local json_lib = dofile(here .. "/json.lua")
local scenario = json_lib.decode(assert(io.open(arg[1], "rb")):read("*a"))

local out = {}
local function record(entry)
  out[#out + 1] = json_lib.encode(entry)
end

-- Virtual time and tasks ------------------------------------------------------------------
local clock, seq, tasks = 0, 0, {}
local function schedule(delay, fn)
  seq = seq + 1
  tasks[#tasks + 1] = { t = clock + delay, s = seq, fn = fn }
end
local function settle()
  while #tasks > 0 do
    table.sort(tasks, function(a, b)
      if a.t ~= b.t then
        return a.t < b.t
      end
      return a.s < b.s
    end)
    local task = table.remove(tasks, 1)
    clock = task.t
    task.fn()
  end
end
local function spawn(fn, ...)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, wait = coroutine.resume(co, ...)
    if not ok then
      record({ type = "lua_error", message = tostring(wait) })
      return
    end
    if coroutine.status(co) == "suspended" then
      schedule(wait or 0, step)
    end
  end
  step(...)
end

-- Natives ---------------------------------------------------------------------------------
json = json_lib
local players = scenario.players or {}
local convars = scenario.convars or {}
local kvp = scenario.kvp or {}
local handlers = {}
local commands = {}

function Wait(ms)
  coroutine.yield(ms)
end
function SetTimeout(ms, fn)
  schedule(ms, fn)
end
function GetCurrentResourceName()
  return "serverguardian"
end
function GetConvar(name, default)
  local value = convars[name]
  if value == nil then
    return default
  end
  return value
end
function GetHashKey(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + text:byte(i)) % 4294967296
  end
  return h
end
function GetResourceKvpString(key)
  return kvp[key]
end
function SetResourceKvp(key, value)
  kvp[key] = value
end
function DeleteResourceKvp(key)
  kvp[key] = nil
end
function GetPlayerIdentifiers(src)
  local p = players[tostring(src)]
  return p and p.identifiers or {}
end
function GetPlayerEndpoint(src)
  local p = players[tostring(src)]
  return p and p.endpoint
end
function GetNumPlayerTokens(src)
  local p = players[tostring(src)]
  return p and p.tokens and #p.tokens or 0
end
function GetPlayerToken(src, index)
  local p = players[tostring(src)]
  return p and p.tokens and p.tokens[index + 1]
end
function AddEventHandler(name, fn)
  handlers[name] = handlers[name] or {}
  table.insert(handlers[name], fn)
end
function RegisterCommand(name, fn)
  commands[name] = fn
end
function TriggerClientEvent(name, src, payload)
  record({ type = "client_event", event = name, player = src, payload = payload })
end

local http = scenario.http or {}
local requestCounter = 0
function PerformHttpRequest(url, callback, method, data, headers)
  requestCounter = requestCounter + 1
  record({ type = "http", method = method, path = url:gsub("^https?://[^/]+", "") })
  if http.hang then
    return -- never answers
  end
  local dir = assert(scenario.tmpDir, "tmpDir")
  local body = dir .. "/req-" .. requestCounter .. ".json"
  local file = io.open(body, "wb")
  file:write(data or "")
  file:close()
  local cmd = { "curl", "-s", "--max-time", "5", "-o", '"' .. dir .. "/res-" .. requestCounter .. '.txt"', "-w", '"%{http_code}"', "-X", method }
  for k, v in pairs(headers or {}) do
    cmd[#cmd + 1] = "-H"
    cmd[#cmd + 1] = "'" .. k .. ": " .. v .. "'"
  end
  if data and data ~= "" then
    cmd[#cmd + 1] = "--data-binary"
    cmd[#cmd + 1] = '"@' .. body .. '"'
  end
  cmd[#cmd + 1] = "'" .. url .. "'"
  local handle = io.popen(table.concat(cmd, " "), "r")
  local status = tonumber((handle:read("*a") or ""):match("%d+")) or 0
  handle:close()
  local res = io.open(dir .. "/res-" .. requestCounter .. ".txt", "rb")
  local text = res and res:read("*a") or ""
  if res then
    res:close()
  end
  schedule(http.latencyMs or 20, function()
    callback(status, text, {})
  end)
end

-- Load the resource's scripts in manifest order -------------------------------------------
local resource = assert(scenario.resourceDir, "resourceDir")
for _, name in ipairs({ "sg_core.lua", "config.lua", "server.lua" }) do
  dofile(resource .. "/" .. name)
end
settle()

-- Drive the scenario ----------------------------------------------------------------------
local function deferralsFor(src, p)
  local d = {}
  function d.defer()
    record({ type = "defer", player = src })
  end
  function d.update(message)
    record({ type = "update", player = src, message = message })
  end
  function d.presentCard(card, callback)
    record({ type = "card", player = src, card = card })
    if p.cardChoice then
      schedule(2000, function()
        callback({ choice = p.cardChoice }, "{}")
      end)
    end
  end
  function d.done(message)
    record({ type = "done", player = src, message = message })
  end
  return d
end

for _, step in ipairs(scenario.steps or {}) do
  if step.event == "playerConnecting" then
    local p = players[tostring(step.src)]
    for _, fn in ipairs(handlers.playerConnecting or {}) do
      source = step.src
      spawn(fn, p.name or "player", function() end, deferralsFor(step.src, p))
    end
  elseif step.event == "playerJoining" then
    for _, fn in ipairs(handlers.playerJoining or {}) do
      source = step.newId
      spawn(fn, step.src)
    end
  elseif step.event == "playerDropped" then
    for _, fn in ipairs(handlers.playerDropped or {}) do
      source = step.src
      spawn(fn, "left")
    end
  elseif step.event == "command" then
    source = step.src
    commands[step.name](step.src, {}, "")
  end
  settle()
end

record({ type = "kvp", values = kvp })
for _, line in ipairs(out) do
  print(line)
end
