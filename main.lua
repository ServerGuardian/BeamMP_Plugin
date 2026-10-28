-- ServerGuardian for BeamMP (server plugin).
--
-- On join it shows the ServerGuardian notice in chat, then asks the ServerGuardian API whether the
-- player may stay, and removes them if the answer is "block". The server operator only ever learns
-- pass or block. See docs/mods.md.
--
-- BeamMP's Lua has no HTTP client we can use (Http.CreateConnection only issues a GET and returns
-- nothing), so this plugin calls curl. curl must be installed and on the PATH (or set curlPath).
-- BeamMP exposes no hardware id, so this plugin never sends one.

local PLUGIN_NAME = "ServerGuardian"
local DEFAULT_DIR = "Resources/Server/ServerGuardian"

local guard = nil -- the ServerGuardianCore instance, created in onInit
local settings = nil
local joins = {} -- playerID -> eventId of the join we checked

local function log(level, message)
  -- Fixed messages only: never a player's name, address or id.
  print(string.format("[%s] %s: %s", PLUGIN_NAME, level, message))
end

local function readFile(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

-- An empty environment variable counts as not set.
local function env(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return nil
  end
  return value
end

local function loadSettings()
  local dir = DEFAULT_DIR
  local raw = readFile(dir .. "/config.json")
  if not raw then
    return nil, "config.json not found in " .. dir
  end
  local ok, decoded = pcall(Util.JsonDecode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, "config.json is not valid JSON"
  end
  local key = env("SERVERGUARDIAN_API_KEY") or decoded.apiKey
  local base = env("SERVERGUARDIAN_API_BASE") or decoded.apiBase
  if type(key) ~= "string" or not key:match("^sg_[%w]+_[%w_%-]+$") then
    return nil, "apiKey is missing or not a ServerGuardian key"
  end
  if type(base) ~= "string" or not base:match("^https?://[%w%.%-:]+$") then
    return nil, "apiBase must look like https://api.example.com (no path)"
  end
  local curl = decoded.curlPath or "curl"
  if not curl:match("^[%w%./\\:%-_ ]+$") then
    return nil, "curlPath contains characters that are not allowed"
  end
  local timeout = tonumber(decoded.timeoutSeconds) or 3
  if timeout < 1 then
    timeout = 1
  elseif timeout > 10 then
    timeout = 10
  end
  return {
    dir = dir,
    key = key,
    base = base,
    curl = curl,
    timeout = timeout,
    failMode = decoded.failMode == "closed" and "closed" or "open",
  }
end

local isWindows = package.config:sub(1, 1) == "\\"

-- Runs curl and returns the HTTP status and body, or nil on any failure. Everything placed in the
-- command line is either fixed or generated here: the request body goes through a file so nothing a
-- player controls (such as a name) is ever part of a shell command, and the key goes through a curl
-- config file so it does not show up in the process list.
local function curlRequest(method, path, body, wait)
  local id = string.format("%x%x", os.time(), math.random(0, 0xfffff))
  local work = settings.dir .. "/work"
  local bodyFile = work .. "/req-" .. id .. ".json"
  local outFile = work .. "/res-" .. id .. ".txt"
  local configFile = work .. "/curl.conf"

  local command = {
    '"' .. settings.curl .. '"',
    "-sS",
    "--max-time",
    tostring(settings.timeout),
    "-K",
    '"' .. configFile .. '"',
    "-o",
    '"' .. outFile .. '"',
    "-w",
    '"%{http_code}"',
    "-X",
    method,
  }
  if body then
    local file = io.open(bodyFile, "wb")
    if not file then
      return nil
    end
    file:write(Util.JsonEncode(body))
    file:close()
    command[#command + 1] = "-H"
    command[#command + 1] = '"content-type: application/json"'
    command[#command + 1] = "--data-binary"
    command[#command + 1] = '"@' .. bodyFile .. '"'
  end
  command[#command + 1] = '"' .. settings.base .. path .. '"'
  local line = table.concat(command, " ")

  if not wait then
    -- Do not hold up the server: start it in the background, and have it tidy up its own files.
    if isWindows then
      os.execute('start "" /b cmd /c "' .. line:gsub('"', '""') .. ' & del /q "' .. bodyFile .. '" "' .. outFile .. '"" >NUL 2>&1')
    else
      os.execute("( " .. line .. ' ; rm -f "' .. bodyFile .. '" "' .. outFile .. '" ) >/dev/null 2>&1 &')
    end
    return nil
  end

  local handle = io.popen(line, "r")
  if not handle then
    return nil
  end
  local status = tonumber((handle:read("*a") or ""):match("%d+"))
  handle:close()
  local response = readFile(outFile)
  os.remove(bodyFile)
  os.remove(outFile)
  if not status or status == 0 then
    return nil
  end
  return status, response or ""
end

local function writeCurlConfig()
  FS.CreateDirectory(settings.dir .. "/work")
  local file = io.open(settings.dir .. "/work/curl.conf", "wb")
  if not file then
    return false
  end
  file:write('header = "authorization: Bearer ' .. settings.key .. '"\n')
  file:close()
  return true
end

local function httpForCore(method, path, body, callback)
  -- Leave events are fire-and-forget; everything else waits for the answer (with a time limit).
  local wait = path ~= "/v1/events/player-leave"
  local status, response = curlRequest(method, path, body, wait)
  callback(status, response)
end

function onInit()
  local loaded, problem = loadSettings()
  if not loaded then
    log("error", "not started: " .. problem)
    return
  end
  settings = loaded
  -- All files in a plugin folder share one Lua state, but do not depend on the load order.
  if not ServerGuardianCore then
    local ok = pcall(dofile, settings.dir .. "/sg_core.lua")
    if not ok or not ServerGuardianCore then
      log("error", "not started: sg_core.lua is missing")
      settings = nil
      return
    end
  end
  if not writeCurlConfig() then
    log("error", "not started: cannot write to " .. settings.dir .. "/work")
    settings = nil
    return
  end
  guard = ServerGuardianCore.new({
    apiBase = settings.base,
    failMode = settings.failMode,
    http = httpForCore,
    json = { encode = Util.JsonEncode, decode = Util.JsonDecode },
    log = log,
    prefix = "bm",
  })
  guard:refreshConfig(function(ok)
    log("info", ok and "started" or "started with the built-in wording (could not reach the API)")
  end, true)
end

-- Splits long text for the chat box, on spaces.
local function chunks(text, size)
  local parts = {}
  local line = ""
  for word in text:gmatch("%S+") do
    if #line + #word + 1 > size and line ~= "" then
      parts[#parts + 1] = line
      line = word
    else
      line = (line == "" and word) or (line .. " " .. word)
    end
  end
  if line ~= "" then
    parts[#parts + 1] = line
  end
  return parts
end

-- Shows the notice. Returns false if it could not be delivered (for example the player is not yet
-- fully loaded): we do not send anything about a player who has not been told.
local function showNotice(playerID)
  for _, part in ipairs(chunks(guard.wording.notice, 180)) do
    local sent = false
    for _ = 1, 3 do
      local ok = MP.SendChatMessage(playerID, part)
      if ok then
        sent = true
        break
      end
      MP.Sleep(300)
    end
    if not sent then
      return false
    end
  end
  return true
end

function onPlayerJoin(playerID)
  if not guard then
    return
  end
  guard:refreshConfig(nil, false)
  local identifiers = MP.GetPlayerIdentifiers(playerID)
  if not identifiers then
    return
  end

  -- A guest has no BeamMP account id, so there is nothing stable to check. They are not covered.
  local platformIds = {}
  if type(identifiers.beammp) == "string" and identifiers.beammp ~= "" then
    platformIds[1] = { type = "beammp", id = identifiers.beammp }
  end

  if #platformIds > 0 and not showNotice(playerID) then
    log("warn", "the notice could not be shown, so this player was not checked")
    return
  end

  guard:check({ ip = identifiers.ip, platformIds = platformIds }, function(decision)
    joins[playerID] = decision.eventId
    if decision.action == "deny" then
      MP.DropPlayer(playerID, decision.message)
    end
  end)
end

function onPlayerDisconnect(playerID)
  local eventId = joins[playerID]
  joins[playerID] = nil
  if guard and eventId then
    guard:leave(eventId)
  end
end

MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
