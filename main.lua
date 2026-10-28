-- ServerGuardian for BeamMP (server plugin).
--
-- On join it shows the ServerGuardian notice in chat, then asks the ServerGuardian API whether the
-- player may stay, and removes them if the answer is "block". The server operator only ever learns
-- pass or block. See docs/mods.md.
--
-- BeamMP-Server has no ban system of its own (only a console `kick`), so for ServerGuardian to learn
-- about bans this plugin provides console commands that record them: sgban, sgtempban and sgunban.
-- It can also record the built-in `kick` (off by default: recordKicks in config.json).
--
-- When the server owner turns reports on in the ServerGuardian portal, players can type
-- `/report <player> <category> [what happened]` in chat. It is sent to the server's staff through
-- ServerGuardian and never shown to other players.
--
-- BeamMP's Lua has no HTTP client we can use (Http.CreateConnection only issues a GET and returns
-- nothing), so this plugin calls curl. curl must be installed and on the PATH (or set curlPath).
-- BeamMP exposes no hardware id, so this plugin never sends one.

local PLUGIN_NAME = "ServerGuardian"
local DEFAULT_DIR = "Resources/Server/ServerGuardian"

local guard = nil -- the ServerGuardianCore instance, created in onInit
local settings = nil
local joins = {} -- playerID -> eventId of the join we checked
-- Only when recordKicks is on: who is here and who left in the last few seconds, so a console `kick`
-- typed after the player is gone can still be matched. Names are held in memory only. They are never
-- logged or sent anywhere.
local present = {} -- playerID -> { name = lowercased name, beammp = account id }
local recent = {} -- { name, beammp, left = os.time() }
local RECENT_SECONDS = 15

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
    recordKicks = decoded.recordKicks == true,
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

  if settings.recordKicks and #platformIds > 0 then
    local names = MP.GetPlayers()
    local name = type(names) == "table" and names[playerID]
    if type(name) == "string" and name ~= "" then
      present[playerID] = { name = name:lower(), beammp = identifiers.beammp }
    end
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
  if guard then
    -- Forgotten, so an id BeamMP gives to someone new starts with no history.
    local key = tostring(playerID)
    guard.reportPending[key] = nil
    guard.reportConfirmed[key] = nil
    guard.reportSent[key] = nil
  end
  if present[playerID] then
    recent[#recent + 1] = { name = present[playerID].name, beammp = present[playerID].beammp, left = os.time() }
    present[playerID] = nil
  end
  if guard and eventId then
    guard:leave(eventId)
  end
end

-- ---------------------------------------------------------------------------------------------------
-- Console commands. BeamMP calls onConsoleInput with the full text of anything typed in the server
-- console that it does not handle itself, and for its own commands (such as `kick`) after they have
-- run. Returning a string prints it; returning nothing leaves the command to others.
-- ---------------------------------------------------------------------------------------------------

local MAX_HOURS = 24 * 365 * 10

-- Who is connected and matches what was typed. An exact name (any case) wins; otherwise a name that
-- starts with it, which must be unique. Returns the matches, each { id (or nil), beammp (or nil) }.
local function findPlayers(typed, includeRecent)
  typed = typed:lower()
  local exact, prefix = {}, {}
  local function consider(name, entry)
    local lowered = name:lower()
    if lowered == typed then
      exact[#exact + 1] = entry
    elseif lowered:sub(1, #typed) == typed then
      prefix[#prefix + 1] = entry
    end
  end
  local names = MP.GetPlayers()
  if type(names) == "table" then
    for id, name in pairs(names) do
      if type(name) == "string" then
        local identifiers = MP.GetPlayerIdentifiers(id)
        local account = identifiers and identifiers.beammp
        consider(name, {
          id = tonumber(id),
          name = name,
          beammp = (type(account) == "string" and account ~= "") and account or nil,
        })
      end
    end
  end
  if includeRecent then
    local now = os.time()
    for i = #recent, 1, -1 do
      if now - recent[i].left > RECENT_SECONDS then
        table.remove(recent, i)
      else
        consider(recent[i].name, { beammp = recent[i].beammp })
      end
    end
  end
  if #exact > 0 then
    return exact
  end
  return prefix
end

-- Finds the one player a command is about, or the sentence to print instead.
local function onePlayer(typed, includeRecent)
  if typed == "" then
    return nil, "Say which player: the command needs a player name."
  end
  local found = findPlayers(typed, includeRecent)
  if #found == 0 then
    return nil, "No connected player matches that name."
  elseif #found > 1 then
    return nil, "More than one player matches that name. Type more of it."
  end
  return found[1]
end

local REFUSED = "The key was refused. Make a key that is allowed to record actions, in the ServerGuardian portal."

local function describeFailure(result)
  if result.reason == "unreachable" then
    return "ServerGuardian could not be reached."
  elseif result.reason == "refused" then
    return REFUSED
  end
  return "ServerGuardian did not accept it."
end

local function banPlayer(typed, hours, reason)
  local player, problem = onePlayer(typed, false)
  if not player then
    return problem
  end
  if not player.beammp then
    -- Nothing stable to record a ban against, so nothing is done: use the built-in kick for a guest.
    return "That player is a guest and has no BeamMP account, so a ban cannot be recorded. Nothing was done."
  end
  local outcome
  guard:recordAction({
    type = "ban",
    reason = reason or "Banned by the server console",
    durationHours = hours,
    platformIds = { { type = "beammp", id = player.beammp } },
  }, function(result)
    outcome = result
  end)
  -- The operator asked for this player to go, so they go whether or not ServerGuardian was reached.
  MP.DropPlayer(player.id, guard.wording.blocked)
  if outcome and outcome.ok then
    return "Player removed and the ban recorded in ServerGuardian. To end it early: sgunban " .. outcome.actionId
  end
  return "Player removed, but the ban was NOT recorded. " .. describeFailure(outcome or {}) .. " They can rejoin."
end

local function handleBan(rest, temporary)
  local typed, remainder = rest:match("^(%S+)%s*(.-)$")
  if not typed then
    return temporary and "Usage: sgtempban <player> <hours> [reason]" or "Usage: sgban <player> [reason]"
  end
  local hours = nil
  if temporary then
    local count, reason = remainder:match("^(%d+)%s*(.-)$")
    hours = count and tonumber(count)
    if not hours or hours < 1 or hours > MAX_HOURS then
      return "Usage: sgtempban <player> <hours> [reason]  (hours: a whole number from 1 to " .. MAX_HOURS .. ")"
    end
    remainder = reason
  end
  return banPlayer(typed, hours, remainder ~= "" and remainder or nil)
end

local function handleUnban(rest)
  local id = rest:match("^(%S+)$")
  if not id then
    return "Usage: sgunban <ban id>  (the id printed when the ban was recorded)"
  end
  local outcome
  guard:liftAction(id, function(result)
    outcome = result
  end)
  outcome = outcome or {}
  if outcome.ok then
    return "The ban was ended."
  elseif outcome.reason == "bad_input" then
    return "That is not a ban id."
  elseif outcome.reason == "not_found" then
    return "No active ban or mute with that id belongs to this server owner."
  end
  return describeFailure(outcome)
end

-- Records the built-in `kick` after it has run (recordKicks). We only know the name that was typed, so
-- if it does not pick out exactly one player we say nothing rather than guess.
local function observeKick(rest)
  local typed, reason = rest:match("^(%S+)%s*(.-)$")
  if not typed then
    return
  end
  local found = findPlayers(typed, true)
  if #found ~= 1 or not found[1].beammp then
    log("info", "a kick was typed but it could not be matched to one player with an account, so it was not recorded")
    return
  end
  guard:recordAction({
    type = "kick",
    reason = reason ~= "" and reason or "Kicked by the server console",
    platformIds = { { type = "beammp", id = found[1].beammp } },
  }, function(result)
    if not result.ok then
      log("warn", "could not record a kick")
    end
  end)
end

function onConsoleInput(input)
  if not guard or type(input) ~= "string" then
    return nil
  end
  local word, rest = input:match("^%s*(%S+)%s*(.-)%s*$")
  if not word then
    return nil
  end
  word = word:lower()
  if word == "sgban" then
    return handleBan(rest, false)
  elseif word == "sgtempban" then
    return handleBan(rest, true)
  elseif word == "sgunban" then
    return handleUnban(rest)
  elseif word == "kick" and settings.recordKicks then
    observeKick(rest)
  end
  return nil
end

-- ---------------------------------------------------------------------------------------------------
-- /report. BeamMP passes every chat message to onChatMessage; returning 1 keeps a message from being
-- shown to anyone, which is what we want for a report. The rules (the notice, the confirmation, the
-- player's own limit) are in sg_core.lua; this only says who is who and how to talk to the player.
-- ---------------------------------------------------------------------------------------------------

local function say(playerID, text)
  for _, part in ipairs(chunks(text, 180)) do
    MP.SendChatMessage(playerID, part)
  end
end

local function handleReport(playerID, rest)
  local identifiers = MP.GetPlayerIdentifiers(playerID)
  local account = identifiers and identifiers.beammp
  local reporterIds = nil
  if type(account) == "string" and account ~= "" then
    reporterIds = { { type = "beammp", id = account } }
  end
  local typed, category, note = rest:match("^(%S+)%s*(%S*)%s*(.-)$")
  guard:refreshConfig(nil, false)
  guard:reportCommand({
    key = tostring(playerID),
    reporterIds = reporterIds,
    typed = typed,
    category = category ~= "" and category or nil,
    note = note ~= "" and note or nil,
    resolve = function(name)
      local found = findPlayers(name, false)
      if #found == 0 then
        return nil, "not_found"
      elseif #found > 1 then
        return nil, "ambiguous"
      end
      local target = found[1]
      if target.id == tonumber(playerID) or (target.beammp and target.beammp == account) then
        return nil, "self"
      elseif not target.beammp then
        return nil, "guest"
      end
      return { ids = { { type = "beammp", id = target.beammp } }, label = target.name }
    end,
  }, function(text)
    say(playerID, text)
  end)
end

function onChatMessage(playerID, _playerName, message)
  if not guard or type(message) ~= "string" then
    return nil
  end
  local word, rest = message:match("^%s*/(%S+)%s*(.-)%s*$")
  if not word or word:lower() ~= "report" then
    return nil
  end
  handleReport(playerID, rest)
  return 1
end

MP.RegisterEvent("onChatMessage", "onChatMessage")
MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
MP.RegisterEvent("onConsoleInput", "onConsoleInput")
