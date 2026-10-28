-- A stand-in for the BeamMP server's Lua environment, for testing the ServerGuardian plugin without a
-- game server. It mimics only what the plugin uses (see docs/mods.md for the spike that established
-- these names against BeamMP-Server's source): MP.*, Util.Json*, FS.CreateDirectory, and events.
--
-- Usage: lua fake_beammp.lua <scenario.json>
-- The scenario describes players; the output is a JSON list of what the plugin did, one entry per
-- line, so tests can assert on it.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local json = dofile(here .. "/json.lua")

local scenario = json.decode(assert(io.open(arg[1], "rb")):read("*a"))
local pluginDir = assert(scenario.pluginDir, "pluginDir")

local events = {}
local handlers = {}
local players = scenario.players or {}
local log = {}

local function record(entry)
  log[#log + 1] = json.encode(entry)
end

MP = {
  RegisterEvent = function(name, fn)
    handlers[name] = fn
  end,
  GetPlayerIdentifiers = function(id)
    local p = players[tostring(id)]
    if not p or not p.identifiers then
      return nil
    end
    return p.identifiers
  end,
  SendChatMessage = function(id, message)
    local p = players[tostring(id)]
    if p and p.chatFails and p.chatFails > 0 then
      p.chatFails = p.chatFails - 1
      return false, "not synced"
    end
    record({ type = "chat", player = id, message = message })
    return true
  end,
  DropPlayer = function(id, reason)
    record({ type = "drop", player = id, reason = reason })
    return true
  end,
  Sleep = function() end,
}
-- Record every command the plugin runs, so tests can check what reaches a shell.
local realPopen, realExecute = io.popen, os.execute
io.popen = function(command, mode)
  record({ type = "exec", command = command })
  return realPopen(command, mode)
end
os.execute = function(command)
  record({ type = "exec", command = command })
  return realExecute(command)
end
Util = { JsonEncode = json.encode, JsonDecode = json.decode }
FS = {
  CreateDirectory = function(path)
    os.execute('mkdir -p "' .. path .. '"')
  end,
}

-- BeamMP runs every file in the plugin folder in one state, in no promised order: load main first
-- to prove the plugin does not rely on sg_core.lua being loaded before it.
dofile(pluginDir .. "/main.lua")

if _G.onInit then
  -- BeamMP calls onInit itself, once, after loading the plugin; so do we.
  _G.onInit()
end

for _, step in ipairs(scenario.steps or {}) do
  local fn = _G[step.event]
  if not fn then
    record({ type = "missing_handler", event = step.event })
  else
    fn(table.unpack(step.args or {}))
  end
end

for _, line in ipairs(log) do
  print(line)
end
