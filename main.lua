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
-- When the server owner turns game events on in the portal, the plugin also tells ServerGuardian when
-- a player spawns, edits or deletes a vehicle (its model name), and runs a few movement checks on the
-- server (a speed or a jump the game could not produce) and sends only a flag when one fails. Events
-- are held for a few seconds and sent together. Positions never leave the server. A flag is a prompt
-- for a person to look: nothing is ever kicked or banned because of it.
--
-- When the server owner turns chat moderation on (the `chatModeration` setting in config.json, off by
-- default), the plugin also hands each chat line (not commands) to ServerGuardian, in groups, from a
-- queue in memory. It never blocks, changes or cancels chat, never writes chat to disk, the console or
-- the log, and shows the join notice that says chat is checked instead of the usual one.
--
-- BeamMP's Lua has no HTTP client we can use (Http.CreateConnection only issues a GET and returns
-- nothing), so this plugin calls curl. curl must be installed and on the PATH (or set curlPath).
-- BeamMP exposes no hardware id, so this plugin never sends one.

local PLUGIN_NAME = "ServerGuardian"
local DEFAULT_DIR = "Resources/Server/ServerGuardian"

local guard = nil -- the ServerGuardianCore instance, created in onInit
local settings = nil
local joins = {} -- playerID -> eventId of the join we checked
-- playerID -> { readyAt, ip, platformIds }: a player who has joined and has not yet been shown the notice or
-- checked, because their game is probably still loading (see loadSettings, noticeDelaySeconds).
local waiting = {}
local releasePlayer, releaseWaiting -- defined below, used by timers and handlers that come before them
local clientReady = {} -- playerID -> true once their client mod has said it finished loading (see sgClientReady)
local lastReportOpen = {} -- playerID -> when their /report window was last opened (see openReportWindow)
local reportReady = {} -- playerID -> true once their client mod has said it can show the /report window
-- playerID -> { [vehicleID] = model name }, for the movement checks and so a delete (which carries no
-- data) can say what was deleted. Memory only, and forgotten when the player leaves.
local vehicles = {}
local SAMPLE_EVENT = "sgGameSample"
local FLUSH_EVENT = "sgGameFlush" -- about once a second: sends the waiting game events, collects answers
local REFRESH_EVENT = "sgConfigRefresh"
local HEARTBEAT_EVENT = "sgHeartbeat"
local REFRESH_MS = 10 * 60 * 1000 -- how often the settings are asked for again, so a server nobody joins still hears
local SKIP_AFTER_SPAWN = 2 -- positions right after a spawn or a reset may not be right yet
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

local function fileExists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

-- One line of operator text for the popup: control characters become spaces, ends trimmed, cut to `max`.
-- nil when it is not text or ends up empty. (The client mod escapes it again: this is only tidiness.)
local function cleanLine(value, max)
  if type(value) ~= "string" then
    return nil
  end
  local line = value:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then
    return nil
  end
  return line:sub(1, max)
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
  if key:find("paste-your-key-here", 1, true) then
    return nil, "apiKey is still the example from config.example.json: paste the key made in the ServerGuardian portal"
  end
  if type(base) ~= "string" or not base:match("^https?://[%w%.%-:]+$") then
    return nil, "apiBase must look like https://api.example.com (no path)"
  end
  local curl = decoded.curlPath or "curl"
  if not curl:match("^[%w%./\\:%-_ ]+$") then
    return nil, "curlPath contains characters that are not allowed"
  end
  -- How long after a player joins their notice is shown and they are checked, unless they spawn a car or
  -- say something first. BeamMP raises onPlayerJoin when the player STARTS syncing: their game is still
  -- loading, and a chat line sent then is not seen. There is no event for "finished loading".
  local noticeDelay = tonumber(decoded.noticeDelaySeconds) or 15
  if noticeDelay < 0 then
    noticeDelay = 0
  elseif noticeDelay > 120 then
    noticeDelay = 120
  end
  -- The notice as a popup in the game, from the ServerGuardian client mod (client/ in this repository), which
  -- the server owner puts in Resources/Client. On by default; it only takes effect when the mod's zip is there.
  local popup = type(decoded.popup) == "table" and decoded.popup or {}
  local popupExtra = {}
  if type(popup.extra) == "table" then
    for _, line in ipairs(popup.extra) do
      local clean = cleanLine(line, 300)
      if clean and #popupExtra < 5 then
        popupExtra[#popupExtra + 1] = clean
      end
    end
  end
  local clientModFile = type(decoded.clientModFile) == "string" and decoded.clientModFile:match("^[%w%._%-]+%.zip$")
    or "ServerGuardianClient.zip"
  -- How long to wait for the client mod to say it has loaded, and then for the popup to be shown, before the
  -- notice goes in chat instead.
  local popupFallback = tonumber(decoded.popupFallbackSeconds) or 45
  if popupFallback < 10 then
    popupFallback = 10
  elseif popupFallback > 300 then
    popupFallback = 300
  end
  -- The /report window (client mod, see client/): on by default when reports are on and the mod is installed.
  local reportWindow = type(decoded.reportWindow) == "table" and decoded.reportWindow or {}
  local reportReasons = {}
  if type(reportWindow.reasons) == "table" then
    for _, reason in ipairs(reportWindow.reasons) do
      local id = type(reason) == "string" and reason or (type(reason) == "table" and reason.id) or nil
      if type(id) == "string" and id:match("^[a-z_]+$") and #id <= 40 and #reportReasons < 12 then
        reportReasons[#reportReasons + 1] = { id = id, label = type(reason) == "table" and cleanLine(reason.label, 60) or nil }
      end
    end
  end
  local bannerStyle = decoded.bannerStyle
  if bannerStyle ~= "braille" and bannerStyle ~= "ascii" then
    bannerStyle = "auto"
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
    noticeDelay = noticeDelay,
    clientPopup = decoded.clientPopup ~= false,
    clientModFile = clientModFile,
    popupFallback = popupFallback,
    popupTitle = cleanLine(popup.title, 80) or "ServerGuardian",
    popupButton = cleanLine(popup.button, 40) or "I understand",
    popupExtra = popupExtra,
    reportWindow = reportWindow.enabled ~= false,
    reportTitle = cleanLine(reportWindow.title, 80) or "Report a player",
    reportReasons = reportReasons,
    bannerStyle = bannerStyle,
    -- The old top-level failMode only matters until the API has answered, as before; the "settings"
    -- block below is what sets the server's behaviour now.
    failMode = decoded.failMode == "closed" and "closed" or "open",
    -- The server's settings (fail mode, game events, reports, shared bans, youth-oriented). The core
    -- checks them and sends the ones that are set.
    rawSettings = type(decoded.settings) == "table" and decoded.settings or nil,
    recordKicks = decoded.recordKicks == true,
  }
end

local isWindows = package.config:sub(1, 1) == "\\"

-- Builds the curl command line for one request. Everything placed in it is either fixed or generated
-- here: the request body goes through a file so nothing a player controls (such as a name) is ever
-- part of a shell command, and the key goes through a curl config file so it does not show up in the
-- process list. Returns the line and the names of the files it uses, or nil if the body cannot be
-- written. `headers` makes curl keep the answer's headers in a file too. With `stdin` the body is NOT
-- written to a file: curl is told to read it from its standard input (see curlStartChat), which is how
-- chat is sent, because chat must never be written to disk, even for a moment.
local function curlCommand(method, path, body, headers, stdin)
  local id = string.format("%x%x", os.time(), math.random(0, 0xfffff))
  local work = settings.dir .. "/work"
  local files = {
    body = work .. "/req-" .. id .. ".json",
    out = work .. "/res-" .. id .. ".txt",
    headers = work .. "/hdr-" .. id .. ".txt",
    status = work .. "/sta-" .. id .. ".txt",
  }
  local configFile = work .. "/curl.conf"

  local command = {
    '"' .. settings.curl .. '"',
    "-sS",
    "--max-time",
    tostring(settings.timeout),
    "-K",
    '"' .. configFile .. '"',
    "-o",
    '"' .. files.out .. '"',
    "-w",
    '"%{http_code}"',
    "-X",
    method,
  }
  if headers then
    command[#command + 1] = "-D"
    command[#command + 1] = '"' .. files.headers .. '"'
  end
  if body and stdin then
    command[#command + 1] = "-H"
    command[#command + 1] = '"content-type: application/json"'
    command[#command + 1] = "--data-binary"
    command[#command + 1] = '"@-"'
  elseif body then
    local file = io.open(files.body, "wb")
    if not file then
      return nil
    end
    file:write(Util.JsonEncode(body))
    file:close()
    command[#command + 1] = "-H"
    command[#command + 1] = '"content-type: application/json"'
    command[#command + 1] = "--data-binary"
    command[#command + 1] = '"@' .. files.body .. '"'
  end
  command[#command + 1] = '"' .. settings.base .. path .. '"'
  return table.concat(command, " "), files
end

-- Runs curl and returns the HTTP status and body, or nil on any failure.
local function curlRequest(method, path, body, wait)
  local line, files = curlCommand(method, path, body, false)
  if not line then
    return nil
  end
  local bodyFile, outFile = files.body, files.out

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

-- Requests started in the background whose answer has not been collected yet (see curlStart).
local pendingAnswers = {}

-- Starts a request in the background and, when its answer is in, calls callback(status, body, headers)
-- from pollAnswers (the plugin's one-second timer), never from here. The server is not held up: this is
-- how a batch of game events is sent, and its answer is still seen, so a 429, a refusal or a failure
-- can be acted on. The background shell leaves the status last (written to a temporary name and then
-- renamed, so it appears whole), and the files are tidied up when the answer is collected.
local function curlStart(method, path, body, callback)
  local line, files = curlCommand(method, path, body, true)
  if not line then
    callback(nil)
    return
  end
  local status = files.status
  if isWindows then
    os.execute(
      'start "" /b cmd /c "' .. line:gsub('"', '""') .. ' > ""' .. status .. '.tmp"" 2>NUL & move /y ""' .. status
        .. '.tmp"" ""' .. status .. '"" >NUL & del /q ""' .. files.body .. '"" >NUL" >NUL 2>&1'
    )
  else
    os.execute(
      "( " .. line .. ' > "' .. status .. '.tmp" 2>/dev/null ; mv -f "' .. status .. '.tmp" "' .. status .. '" ; rm -f "'
        .. files.body .. '" ) >/dev/null 2>&1 &'
    )
  end
  -- The request gives up by itself after settings.timeout; this waits a little longer than that.
  pendingAnswers[#pendingAnswers + 1] = { files = files, callback = callback, giveUpAt = os.time() + settings.timeout + 10 }
end

-- Starts a request whose body goes to curl through a pipe, so it is never written to disk: used for chat
-- only. Like curlStart it returns at once and the answer is collected by pollAnswers. On Linux and macOS a
-- shell keeps the read end of the pipe (descriptor 3) and `cat` copies it to curl in the background; `cat`
-- always reads to the end, so writing here can never hit a closed pipe (which would raise SIGPIPE) even if
-- curl cannot start. The command line holds no chat: the text only travels through the pipe. On Windows
-- the same is done with `start /b` and curl reading its standard input: NOT verified on Windows (BeamMP
-- Windows servers have not been tried); if it does not work, no answer ever arrives and the lines are
-- simply lost, which is the safe way for it to fail.
local function curlStartChat(method, path, body, callback)
  local line, files = curlCommand(method, path, body, true, true)
  if not line then
    callback(nil)
    return
  end
  local encoded = nil
  if body then
    local ok, text = pcall(Util.JsonEncode, body)
    encoded = ok and type(text) == "string" and text or nil
  end
  if not encoded then
    callback(nil)
    return
  end
  local status = files.status
  local command
  if isWindows then
    command = 'start "" /b cmd /c "' .. line:gsub('"', '""') .. ' > ""' .. status .. '.tmp"" 2>NUL & move /y ""' .. status
      .. '.tmp"" ""' .. status .. '"" >NUL" >NUL 2>&1'
  else
    command = "exec 3<&0; ( cat <&3 | " .. line .. ' > "' .. status .. '.tmp" 2>/dev/null ; mv -f "' .. status .. '.tmp" "'
      .. status .. '" ) >/dev/null 2>&1 &'
  end
  local handle = io.popen(command, "w")
  if not handle then
    callback(nil)
    return
  end
  handle:write(encoded)
  handle:close()
  pendingAnswers[#pendingAnswers + 1] = { files = files, callback = callback, giveUpAt = os.time() + settings.timeout + 10 }
end

-- The headers curl kept, as a table of lowercase names (only the last answer's, if there were several).
local function readHeaders(path)
  local headers = {}
  for line in (readFile(path) or ""):gmatch("[^\r\n]+") do
    local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return headers
end

-- Collects the answers that have arrived, and gives up on those that never will (the callback then gets
-- nil, as for any failure). Called every second by the flush timer, so an answer is seen within a second.
local function pollAnswers()
  local index = 1
  while index <= #pendingAnswers do
    local pending = pendingAnswers[index]
    local text = readFile(pending.files.status)
    if text or os.time() >= pending.giveUpAt then
      table.remove(pendingAnswers, index)
      local status = tonumber((text or ""):match("%d+"))
      local response = readFile(pending.files.out)
      local headers = readHeaders(pending.files.headers)
      for _, file in pairs(pending.files) do
        os.remove(file)
      end
      os.remove(pending.files.status .. ".tmp")
      if not status or status == 0 then
        pending.callback(nil)
      else
        pending.callback(status, response or "", headers)
      end
    else
      index = index + 1
    end
  end
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

local shuttingDown = false

local function httpForCore(method, path, body, callback)
  -- Leave events and single game events are fire-and-forget; a batch of game events is run in the
  -- background and its answer collected a moment later (see curlStart); everything else waits for the
  -- answer (with a time limit). A game event can come every second for every player, and waiting for
  -- each one would hold up the whole server. A single event (a server that does not batch) is counted
  -- as sent: the plugin cannot see the answer, and relies on its own limits and the settings refresh
  -- every ten minutes (which says if the operator has switched game events off, or the key no longer
  -- works). A batch is seen: a 429, a refusal or a failure is acted on, by the core.
  if path == "/v1/chat" then
    -- Chat is only ever sent in the background through a pipe (never a file), and not at all while the
    -- server stops: nothing is left to see the answer, and chat is not kept for later.
    if shuttingDown then
      callback(nil)
      return
    end
    curlStartChat(method, path, body, callback)
    return
  end
  if path == "/v1/events/batch" and not shuttingDown then
    curlStart(method, path, body, callback)
    return
  end
  if
    (path == "/v1/mod/settings" or path == "/v1/mod/config" or path == "/v1/mod/heartbeat") and not shuttingDown
  then
    -- Start-up, the settings and the heartbeat run in the background too: BeamMP waits for onInit (and for each
    -- timer event) and gives up on a plugin that takes too long, and a first request over the internet can be
    -- slow. The answer is collected a moment later by pollAnswers, so nothing here holds up the server.
    curlStart(method, path, body, callback)
    return
  end
  if path == "/v1/events/game" or path == "/v1/events/batch" then
    -- (A batch sent as the server stops is not waited for: nothing is left to see the answer.)
    curlRequest(method, path, body, false)
    callback(202, "")
    return
  end
  local wait = path ~= "/v1/events/player-leave"
  local status, response = curlRequest(method, path, body, wait)
  callback(status, response)
end

-- The badge (the ServerGuardian shield with its check mark) in braille dots, and a plain-ASCII copy for consoles
-- that cannot show them (a Windows console, by default). bannerStyle in config.json chooses: "auto", "braille", "ascii".
local SHIELD_BRAILLE = {
  "⠀⠀⠀⠀⠀⢀⣠⣤⣶⠿⠿⣶⣤⣄⡀⠀⠀⠀⠀⠀",
  "⢀⣀⣤⣶⡾⠟⠛⠉⠀⠀⠀⠀⠉⠛⠻⢷⣶⣤⣀⡀",
  "⣿⡟⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⢻⣿",
  "⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿",
  "⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣄⠀⠀⠀⢸⣿",
  "⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣾⡿⠃⠀⠀⠀⢸⣿",
  "⣿⡇⠀⠀⠀⠺⣷⣄⠀⢀⣴⡿⠋⠀⠀⠀⠀⠀⢸⣿",
  "⢻⣇⠀⠀⠀⠀⠘⢿⣷⣿⠋⠀⠀⠀⠀⠀⠀⠀⣸⡟",
  "⠈⣿⡆⠀⠀⠀⠀⠀⠉⠁⠀⠀⠀⠀⠀⠀⠀⢰⣿⠁",
  "⠀⠘⢿⣆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⡿⠃⠀",
  "⠀⠀⠈⠻⣷⣄⠀⠀⠀⠀⠀⠀⠀⠀⣠⣾⠟⠁⠀⠀",
  "⠀⠀⠀⠀⠈⠻⣷⣤⡀⠀⠀⢀⣤⣾⠟⠁⠀⠀⠀⠀",
  "⠀⠀⠀⠀⠀⠀⠀⠙⠻⣷⣾⠟⠋⠀⠀⠀⠀⠀⠀⠀",
}
local SHIELD_ASCII = {
  "             _.-.-._",
  "         _.-''     ''-._",
  "     _.-''             ''-._",
  " _.-''                     ''-._",
  "|                     /         |",
  "|                    /          |",
  "|           \\       /           |",
  "|            \\     /            |",
  "|             \\   /             |",
  " \\             \\ /             /",
  "  \\             V             /",
  "   '.                       .'",
  "     '-._               _.-'",
  "         '-.__     __.-'",
}

local function printStartBanner()
  local text = {
    [5] = "ServerGuardian for BeamMP",
    [6] = "Version " .. tostring(ServerGuardianCore.VERSION),
    [7] = "API: " .. settings.base,
    [8] = "Connecting in the background...",
  }
  local style = settings.bannerStyle
  if style == "auto" then
    style = isWindows and "ascii" or "braille"
  end
  local art = style == "ascii" and SHIELD_ASCII or SHIELD_BRAILLE
  -- Every braille row is the same number of characters, so the text lines up without any padding maths on
  -- multi-byte text; the ASCII rows are padded to the widest.
  local width = style == "ascii" and 34 or 0
  print("")
  for index, row in ipairs(art) do
    local line = "  " .. row
    if text[index] then
      line = line .. (style == "ascii" and string.rep(" ", width - #row) or "") .. "   " .. text[index]
    end
    print(line)
  end
  print("")
end

local function yesNo(value)
  return value and "on" or "off"
end

-- Said once, when the first answer (or failure) from the API is in: the result of the start-up connection.
local function printConnectionResult()
  local state, detail = guard:connectionStatus()
  if state == "connected" then
    local summary = guard:summary()
    log("info", "CONNECTED: " .. detail)
    log(
      "info",
      string.format(
        "fail mode %s | game events %s | reports %s | chat checking %s",
        tostring(summary.failMode),
        yesNo(summary.gameEvents),
        yesNo(summary.reports),
        yesNo(summary.chatModeration)
      )
    )
  else
    log(
      "warn",
      "NOT CONNECTED: "
        .. tostring(detail or "no answer yet")
        .. ". Until this works, players are "
        .. (guard.failMode == "closed" and "kept out (failMode is closed)" or "let in unchecked (failMode is open)")
        .. ". It will keep trying."
    )
  end
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
  -- The movement checks need a clock finer than a second. MP.CreateTimer() is a stopwatch with
  -- microsecond resolution (BeamMP-Server, TLuaEngine.cpp), so use it when there is one.
  local clock = nil
  if type(MP.CreateTimer) == "function" then
    local made, stopwatch = pcall(MP.CreateTimer)
    if made and type(stopwatch) == "table" and type(stopwatch.GetCurrent) == "function" then
      clock = function()
        return stopwatch:GetCurrent()
      end
    end
  end
  guard = ServerGuardianCore.new({
    apiBase = settings.base,
    failMode = settings.failMode,
    settings = settings.rawSettings,
    http = httpForCore,
    json = { encode = Util.JsonEncode, decode = Util.JsonDecode },
    log = log,
    prefix = "bm",
    clock = clock,
  })
  -- Game events are off until ServerGuardian says otherwise. The sampling timer exists only while
  -- they are on, and is moved or removed whenever a settings refresh changes that.
  guard.onGameConfig = function(enabled, checks)
    MP.CancelEventTimer(SAMPLE_EVENT)
    if enabled and checks then
      MP.CreateEventTimer(SAMPLE_EVENT, math.max(250, math.floor(checks.sampleSeconds * 1000)))
    end
  end
  -- The settings are asked for again every ten minutes whether or not anyone joins, so a server
  -- with nobody on it still learns that game events were switched off (or on).
  MP.CreateEventTimer(REFRESH_EVENT, REFRESH_MS)
  -- Once a second the waiting game events are sent if they have waited long enough (the core decides),
  -- and the answers to the batches already sent are collected. Nothing happens while game events are
  -- off or nothing is waiting.
  MP.CreateEventTimer(FLUSH_EVENT, ServerGuardianCore.GAME_TICK_SECONDS * 1000)
  -- About once a minute the plugin says it is there, with how many players are on, so the portal can
  -- show the server online or offline. It runs whether or not game events or reports are on.
  MP.CreateEventTimer(HEARTBEAT_EVENT, ServerGuardianCore.HEARTBEAT_SECONDS * 1000)
  settings.clientModFound = fileExists("Resources/Client/" .. settings.clientModFile)
  settings.popupActive = settings.clientPopup and settings.clientModFound
  printStartBanner()
  if settings.popupActive then
    log("info", "client mod found (" .. settings.clientModFile .. "): the notice is shown as a popup in the game")
  elseif settings.clientPopup then
    log(
      "info",
      "client mod not found: the notice is sent in chat. Put "
        .. settings.clientModFile
        .. " in Resources/Client to show it as a popup in the game instead"
    )
  else
    log("info", "the popup is off (clientPopup in config.json): the notice is sent in chat")
  end
  if settings.clientModFound and settings.reportWindow then
    log("info", "/report opens a report window for players with the client mod (reportWindow in config.json)")
  end
  -- Asked for in the background (see httpForCore): onInit returns now, and this runs a moment later from the
  -- one-second timer, with the answers in.
  guard:refreshConfig(function(ok)
    log("info", ok and "started" or "started with the built-in wording (could not reach the API)")
    sgHeartbeat()
    printConnectionResult()
  end, true)
end

-- How many players are connected: only the number is used, and it is never logged.
local function playerCount()
  local ok, names = pcall(MP.GetPlayers)
  if not ok or type(names) ~= "table" then
    return nil
  end
  local count = 0
  for _ in pairs(names) do
    count = count + 1
  end
  return count
end

function sgHeartbeat()
  if guard then
    guard:heartbeat(playerCount())
  end
end

function sgGameFlush()
  if guard then
    releaseWaiting()
    pollAnswers()
    guard:tick()
  end
end

-- BeamMP-Server tells plugins when it is stopping: send what is waiting, once, without waiting for the
-- answer. (A server version that does not send it just never calls this.)
function onShutdown()
  if guard then
    shuttingDown = true
    guard:flushGameEvents()
  end
end

function sgConfigRefresh()
  if guard then
    guard:refreshConfig(nil, true)
  end
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
  for _, part in ipairs(chunks(guard:noticeText(), 180)) do
    local sent = false
    for _ = 1, 3 do
      -- BeamMP-Server's Lua MP.SendChatMessage returns NOTHING (its C++ underneath returns success or failure,
      -- but the Lua binding drops it), so "no value" means "sent as far as anyone can tell". Only an explicit
      -- false, from a server version that does return one, is a failure.
      local ok = MP.SendChatMessage(playerID, part)
      if ok ~= false then
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

-- Sends the notice to the player's client mod, to be shown as a popup (see the client/ folder). Only for a player
-- who is waiting, whose client mod has said it finished loading, on a server that has the mod's zip. A failed
-- send (BeamMP says the player has not joined yet) is tried again on the next tick.
local function offerPopup(playerID)
  local player = waiting[playerID]
  if not (player and guard and settings.popupActive) or player.popupSent then
    return
  end
  local payload = Util.JsonEncode({
    v = 1,
    title = settings.popupTitle,
    text = guard:noticeText(),
    button = settings.popupButton,
    extra = settings.popupExtra,
    noticeVersion = guard.wording and guard.wording.noticeVersion or "",
  })
  -- Marked as sent BEFORE the call: the client's confirmation can come back before this function returns, and
  -- it is only accepted for a player whose popup has been sent. Undone if BeamMP says it did not go.
  player.popupSent = true
  local previousReadyAt = player.readyAt
  local called, sent = pcall(MP.TriggerClientEvent, playerID, "sgNotice", payload)
  if called and sent ~= false then
    -- Now wait for the player's client to say it showed it; if it never does, the chat notice takes over. (If the
    -- confirmation already came, the player has been released and there is nothing left to set.)
    if waiting[playerID] == player then
      player.readyAt = os.time() + settings.popupFallback
    end
  else
    player.popupSent = false
    player.readyAt = previousReadyAt
  end
end

-- Shows the notice and runs the join check for a player who has been waiting. `mode` says why:
--   "popup"  the client mod has shown the notice (nothing to send in chat);
--   "timer"  the wait is over (noticeDelaySeconds, or popupFallbackSeconds when the client mod is in use);
--   nil      their first car spawned or they spoke, so they are certainly in the game (chat notice).
-- When the client mod is in use, only "popup" and "timer" release a player: a spawn or a chat line does not,
-- because the popup is how they are told. Nothing is sent about a player before the notice.
function releasePlayer(playerID, mode)
  local player = waiting[playerID]
  if not player or not guard then
    return
  end
  if settings.popupActive and mode ~= "popup" and mode ~= "timer" then
    return
  end
  waiting[playerID] = nil
  if mode ~= "popup" and not showNotice(playerID) then
    log("warn", "the notice could not be shown, so this player was not checked")
    return
  end
  guard:check({ ip = player.ip, platformIds = player.platformIds }, function(decision)
    joins[playerID] = decision.eventId
    -- One fixed line per checked player (never who): the operator sees that the check ran and what came of it.
    if decision.result == "pass" then
      log("info", "a player was checked: allowed")
    elseif decision.result == "block" then
      log("info", "a player was checked: removed")
    end
    if decision.action == "deny" then
      MP.DropPlayer(playerID, decision.message)
    end
  end)
end

-- Called every second: releases the players whose delay is up.
function releaseWaiting()
  local now = os.time()
  for playerID, player in pairs(waiting) do
    if now >= player.readyAt then
      releasePlayer(playerID, "timer")
    elseif clientReady[playerID] and not player.popupSent then
      offerPopup(playerID) -- the first attempt did not go through
    end
  end
end

-- The client mod tells the server its game has finished loading (BeamNG's loading screen has gone). This is the
-- moment the notice can be shown: it is offered as a popup, and the player is checked once it has been shown.
function sgClientReady(playerID)
  if not guard or not settings.clientModFound then
    return
  end
  clientReady[playerID] = true
  offerPopup(playerID) -- (does nothing unless the popup is in use and the player is waiting)
end

-- The client mod says the popup has been shown. That is the notice delivered, so the check can run.
function sgNoticeShown(playerID)
  local player = waiting[playerID]
  if player and player.popupSent then
    releasePlayer(playerID, "popup")
  end
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

  if #platformIds == 0 then
    -- Said out loud, because the portal counts this player as online (BeamMP lists guests) but has nothing
    -- else about them: nothing is sent, so there is no join, no check and no statistic.
    log(
      "info",
      "a guest joined: guests have no account id, so they cannot be checked and nothing is sent about them"
        .. " (to refuse guests, set AllowGuests = false in BeamMP's ServerConfig.toml)"
    )
  end

  if #platformIds == 0 then
    -- Nothing to wait for: there is nothing to check. (The core records it as skipped.)
    guard:check({ ip = identifiers.ip, platformIds = platformIds }, function(decision)
      joins[playerID] = decision.eventId
    end)
    return
  end
  -- With the client mod in use the wait is for it (popupFallbackSeconds, at least noticeDelaySeconds): a
  -- player without it, or whose mod never answers, gets the notice in chat after that.
  local wait = settings.noticeDelay
  if settings.popupActive then
    wait = math.max(wait, settings.popupFallback)
  end
  waiting[playerID] = { readyAt = os.time() + wait, ip = identifiers.ip, platformIds = platformIds }
  if clientReady[playerID] then
    offerPopup(playerID) -- their client mod was ready before BeamMP told us they joined
  elseif settings.noticeDelay == 0 and not settings.popupActive then
    releasePlayer(playerID, "timer")
  end
end

function onPlayerDisconnect(playerID)
  waiting[playerID] = nil
  clientReady[playerID] = nil
  reportReady[playerID] = nil
  lastReportOpen[playerID] = nil
  local eventId = joins[playerID]
  joins[playerID] = nil
  if guard then
    for vehicleID in pairs(vehicles[playerID] or {}) do
      guard.tracker:forget(playerID .. ":" .. vehicleID)
    end
    -- Their limits and flag cooldowns go with them, so an id BeamMP gives to someone new is clean.
    guard:forgetGamePlayer(playerID)
    -- Forgotten, so an id BeamMP gives to someone new starts with no history.
    local key = tostring(playerID)
    guard.reportPending[key] = nil
    guard.reportConfirmed[key] = nil
    guard.reportSent[key] = nil
  end
  vehicles[playerID] = nil
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

-- ---- The /report window (client mod) --------------------------------------------------------------------------
-- `/report` with nothing after it opens a window on the player's screen: the server sends the list of players and
-- the reasons (sgReportOpen), the window sends the choice back (sgReportSubmit) and the server answers
-- (sgReportResult). The report itself then goes through exactly the same code as the typed command, with its
-- limits. A player whose game has no client mod still has the typed command.
local REPORT_REASON_ORDER = { "cheating", "griefing", "harassment", "hate_or_abuse", "other" }
local REPORT_NOTE_MAX = 200
local REPORT_OPEN_COOLDOWN = 2 -- seconds between windows for one player

-- The first `max` characters of `text` (never half of a multi-byte one).
local function firstChars(text, max)
  if type(utf8) ~= "table" then
    return text:sub(1, max) -- a Lua without the utf8 library: cut by bytes
  end
  local length = utf8.len(text)
  if not length then
    return (text:gsub("[\128-\255]", ""))
  end
  if length <= max then
    return text
  end
  return text:sub(1, utf8.offset(text, max + 1) - 1)
end

local function reportWindowUsable(playerID)
  return guard ~= nil
    and guard.reportsEnabled == true
    and settings.reportWindow
    and settings.clientModFound
    and clientReady[playerID] == true
    and reportReady[playerID] == true
end

-- The client mod says its game can show the /report window. Without this (an older mod, or none) /report stays
-- the typed command: the plugin never opens a window a player's game cannot show.
function sgReportReady(playerID)
  if guard and settings.clientModFound then
    reportReady[playerID] = true
  end
end

-- Who can be reported from this player's window: everyone connected with a BeamMP account, except themselves.
local function reportablePlayers(playerID)
  local identifiers = MP.GetPlayerIdentifiers(playerID)
  local own = identifiers and identifiers.beammp
  local list = {}
  local names = MP.GetPlayers()
  if type(names) == "table" then
    for id, name in pairs(names) do
      local number = tonumber(id)
      if number and number ~= tonumber(playerID) and type(name) == "string" and #list < 100 then
        local theirs = MP.GetPlayerIdentifiers(number)
        local account = theirs and theirs.beammp
        if type(account) == "string" and account ~= "" and account ~= own then
          list[#list + 1] = { id = number, name = firstChars(cleanLine(name, 120) or "?", 60), account = account }
        end
      end
    end
  end
  table.sort(list, function(a, b)
    local left, right = a.name:lower(), b.name:lower()
    if left == right then
      return a.id < b.id
    end
    return left < right
  end)
  return list
end

-- The reasons offered: the server owner's own list when they set one, else every category the API knows, in a
-- fixed order. Only categories the API accepts can be offered; the owner may only rename them.
local function reportReasonList()
  local categories = guard.reportWording.categories
  local list = {}
  local function add(id, label)
    if categories[id] then
      list[#list + 1] = { id = id, label = firstChars(cleanLine(label or categories[id], 60) or id, 60) }
    end
  end
  if #settings.reportReasons > 0 then
    for _, reason in ipairs(settings.reportReasons) do
      add(reason.id, reason.label)
    end
  else
    local seen = {}
    for _, id in ipairs(REPORT_REASON_ORDER) do
      seen[id] = true
      add(id)
    end
    local extra = {}
    for id in pairs(categories) do
      if not seen[id] and type(id) == "string" and id:match("^[a-z_]+$") then
        extra[#extra + 1] = id
      end
    end
    table.sort(extra)
    for _, id in ipairs(extra) do
      add(id)
    end
  end
  return list
end

local function reportResult(playerID, ok, message)
  pcall(MP.TriggerClientEvent, playerID, "sgReportResult", Util.JsonEncode({ v = 1, ok = ok, message = firstChars(message, 300) }))
end

local function openReportWindow(playerID)
  local now = os.time()
  if lastReportOpen[playerID] and now - lastReportOpen[playerID] < REPORT_OPEN_COOLDOWN then
    return
  end
  lastReportOpen[playerID] = now
  guard:refreshConfig(nil, false)
  local players = reportablePlayers(playerID)
  local reasons = reportReasonList()
  if #players == 0 then
    say(playerID, "There is nobody else here who can be reported.")
    return
  end
  if #reasons == 0 then
    say(playerID, "Reports are not set up on this server.")
    return
  end
  local shown = {}
  for index, player in ipairs(players) do
    shown[index] = { id = player.id, name = player.name }
  end
  pcall(MP.TriggerClientEvent, playerID, "sgReportOpen", Util.JsonEncode({
    v = 1,
    title = settings.reportTitle,
    players = shown,
    reasons = reasons,
    notice = firstChars(guard.reportWording.notice, 1000),
    noteMax = REPORT_NOTE_MAX,
    send = "Send report",
    cancel = "Cancel",
  }))
end

-- The window sends the player's choice. Checked as if a stranger sent it (a modified game can send anything),
-- then handed to the same report code as the typed command. The window showed the report notice, so pressing
-- Send is the confirmation the typed command asks for.
function sgReportSubmit(playerID, data)
  if not reportWindowUsable(playerID) then
    return
  end
  local decoded, request = pcall(Util.JsonDecode, data)
  if not decoded or type(request) ~= "table" or request.v ~= 1 then
    return
  end
  -- A player id is a whole NUMBER in the request (not text that looks like one). Whether BeamMP's JSON decoder gives
  -- 1 or 1.0 is not something to depend on, so any whole number is taken.
  local target = request.target
  local reason = request.reason
  if
    type(target) ~= "number"
    or target ~= math.floor(target)
    or target < 0
    or target > 100000
    or type(reason) ~= "string"
    or #reason > 40
    or (request.note ~= nil and type(request.note) ~= "string")
  then
    reportResult(playerID, false, "That report could not be read. Please try again.")
    return
  end
  if #settings.reportReasons > 0 then
    local offered = false
    for _, allowed in ipairs(settings.reportReasons) do
      offered = offered or allowed.id == reason
    end
    if not offered then
      reportResult(playerID, false, "That reason is not offered on this server.")
      return
    end
  end
  target = math.floor(target)
  local note = firstChars(cleanLine(request.note or "", 4 * REPORT_NOTE_MAX) or "", REPORT_NOTE_MAX)
  local chosen
  for _, player in ipairs(reportablePlayers(playerID)) do
    if player.id == target then
      chosen = player
    end
  end
  local identifiers = MP.GetPlayerIdentifiers(playerID)
  local account = identifiers and identifiers.beammp
  if not chosen then
    reportResult(playerID, false, "That player is not here any more, or cannot be reported.")
    return
  end
  guard:refreshConfig(nil, false)
  local key = tostring(playerID)
  guard.reportConfirmed[key] = true
  guard:reportCommand({
    key = key,
    reporterIds = (type(account) == "string" and account ~= "") and { { type = "beammp", id = account } } or nil,
    typed = chosen.name,
    category = reason,
    note = note ~= "" and note or nil,
    resolve = function()
      return { ids = { { type = "beammp", id = chosen.account } }, label = chosen.name }
    end,
  }, function(text)
    reportResult(playerID, text == guard.reportWording.thanks, text)
  end)
end

local function handleReport(playerID, rest)
  if rest == "" and reportWindowUsable(playerID) then
    openReportWindow(playerID)
    return
  end
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

-- Hands a chat line to the chat check, if it is on: the line only goes into a queue in memory (the core
-- sends it later, from the timer), so this takes no time. Guarded, so nothing it does can reach chat. An
-- error is not logged: its text could hold the line.
local function queueChat(playerID, playerName, message)
  local ok = pcall(function()
    guard:chatLine(joins[playerID], playerName, message)
  end)
  if not ok then
    log("warn", "a chat line could not be handed to the chat check")
  end
end

-- BeamMP-Server (TServer.cpp) calls every plugin's onChatMessage(senderID, senderName, message) and
-- waits for them; a handler that returns 1 stops the message being shown to anyone. This one returns 1
-- only for /report. For everything else it returns nothing, so other plugins and the server see no
-- change: chat is never cancelled, altered or delayed by the chat check.
function onChatMessage(playerID, playerName, message)
  if not guard or type(message) ~= "string" then
    return nil
  end
  releasePlayer(playerID) -- they are talking, so they are in the game and can be shown the notice now
  local word, rest = message:match("^%s*/(%S+)%s*(.-)%s*$")
  if word and word:lower() == "report" then
    handleReport(playerID, rest)
    return 1
  end
  if guard:chatOn() then
    queueChat(playerID, playerName, message)
  end
  return nil
end

-- ---------------------------------------------------------------------------------------------------
-- Game events. None of these handlers returns anything: returning 1 from onVehicleSpawn would cancel
-- the spawn, and we never interfere with the game.
-- ---------------------------------------------------------------------------------------------------

-- The model of a spawned vehicle. BeamMP gives onVehicleSpawn a string "roles:name:PID-VID:{json}",
-- and the JSON has the model under "jbm" (the server itself looks for "jbm" to find the unicycle). If it
-- cannot be read, the item is just "vehicle". Only the part after the first "{" is searched, so a
-- player's name cannot be mistaken for it.
local function parsedModel(data)
  if type(data) ~= "string" then
    return nil
  end
  local json = data:match("({.*)")
  local model = json and json:match('"jbm"%s*:%s*"([^"]*)"')
  return model ~= "" and model or nil
end

local function vehicleModel(data)
  return parsedModel(data) or "vehicle"
end

local function playerName(playerID)
  local names = MP.GetPlayers()
  return type(names) == "table" and names[playerID] or nil
end

-- onVehicleSpawn is also run by other plugins, one of which may cancel the spawn afterwards; this
-- plugin cannot tell, so a cancelled spawn is still reported (and tracked until the vehicle is deleted).
function onVehicleSpawn(playerID, vehicleID, data)
  releasePlayer(playerID) -- a car has spawned: they are in the game, so they can be shown the notice now
  vehicles[playerID] = vehicles[playerID] or {}
  vehicles[playerID][vehicleID] = vehicleModel(data)
  if guard then
    guard.tracker:start(playerID .. ":" .. vehicleID, SKIP_AFTER_SPAWN)
  end
  if guard and guard.gameEnabled and joins[playerID] then
    guard:spawn(tostring(playerID), joins[playerID], playerName(playerID), vehicleModel(data))
  end
end

-- A reset moves the vehicle (that is what it is for), so the track starts again, after a couple of
-- samples that may still hold the old position.
function onVehicleReset(playerID, vehicleID)
  if guard then
    guard.tracker:reset(playerID .. ":" .. vehicleID, SKIP_AFTER_SPAWN)
  end
end

-- A player changed a vehicle (parts, paint). BeamMP gives onVehicleEdited the same kind of data string as
-- a spawn, so the model comes from the same parser; if it cannot be read, the model remembered from the
-- spawn is used. An edit of a vehicle we never saw spawn (the plugin started after it) is remembered too.
-- Returning nothing leaves the edit to go ahead: returning 1 would cancel it.
function onVehicleEdited(playerID, vehicleID, data)
  vehicles[playerID] = vehicles[playerID] or {}
  local model = parsedModel(data) or vehicles[playerID][vehicleID] or "vehicle"
  vehicles[playerID][vehicleID] = model
  if guard and guard.gameEnabled and joins[playerID] then
    guard:edit(tostring(playerID), joins[playerID], playerName(playerID), model)
  end
end

-- A vehicle was deleted. The handler is given no data, so what it was comes from what was remembered
-- when it was spawned or edited ("unknown" if the plugin never saw either).
function onVehicleDeleted(playerID, vehicleID)
  local model = vehicles[playerID] and vehicles[playerID][vehicleID]
  if vehicles[playerID] then
    vehicles[playerID][vehicleID] = nil
  end
  if guard then
    guard.tracker:forget(playerID .. ":" .. vehicleID)
  end
  if guard and guard.gameEnabled and joins[playerID] then
    guard:remove(tostring(playerID), joins[playerID], playerName(playerID), type(model) == "string" and model or "unknown")
  end
end

-- Called by the timer while game events are on. MP.GetPositionRaw(pid, vid) returns a table with
-- pos = {x, y, z} (and vel, rot, ...) and an error string, which is empty on success.
function sgGameSample()
  if not guard or not guard.gameEnabled then
    return
  end
  local names = MP.GetPlayers()
  for playerID, list in pairs(vehicles) do
    local joinEventId = joins[playerID]
    if joinEventId then
      for vehicleID in pairs(list) do
        local position, problem = MP.GetPositionRaw(playerID, vehicleID)
        local at = type(position) == "table" and type(position.pos) == "table" and position.pos or nil
        -- A position of nothing, or of exactly zero, is a vehicle that has no position yet.
        local usable = at
          and type(at[1]) == "number" and type(at[2]) == "number" and type(at[3]) == "number"
          and not (at[1] == 0 and at[2] == 0 and at[3] == 0)
        if usable and (problem == nil or problem == "") then
          guard:samplePosition(
            tostring(playerID),
            playerID .. ":" .. vehicleID,
            joinEventId,
            type(names) == "table" and names[playerID] or nil,
            at[1],
            at[2],
            at[3]
          )
        end
      end
    end
  end
end

MP.RegisterEvent("onChatMessage", "onChatMessage")
MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
MP.RegisterEvent("onVehicleReset", "onVehicleReset")
MP.RegisterEvent("onVehicleEdited", "onVehicleEdited")
MP.RegisterEvent("onVehicleDeleted", "onVehicleDeleted")
MP.RegisterEvent("onShutdown", "onShutdown")
MP.RegisterEvent(FLUSH_EVENT, "sgGameFlush")
MP.RegisterEvent(SAMPLE_EVENT, "sgGameSample")
MP.RegisterEvent(REFRESH_EVENT, "sgConfigRefresh")
MP.RegisterEvent(HEARTBEAT_EVENT, "sgHeartbeat")
MP.RegisterEvent("sgClientReady", "sgClientReady")
MP.RegisterEvent("sgNoticeShown", "sgNoticeShown")
MP.RegisterEvent("sgReportSubmit", "sgReportSubmit")
MP.RegisterEvent("sgReportReady", "sgReportReady")
MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
MP.RegisterEvent("onConsoleInput", "onConsoleInput")
