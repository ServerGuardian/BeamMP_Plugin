-- ServerGuardian mod core. Platform-independent: the BeamMP plugin and the FiveM resource each ship
-- an identical copy of this file (mods/sync-core.sh copies it; a test checks they match).
--
-- Written for Lua 5.3 (BeamMP) and 5.4 (FiveM). It makes no platform calls itself: the platform file
-- passes in an HTTP function, a JSON codec and a logger.
--
-- Privacy rules this file enforces (docs/mods.md):
--   * it never logs an IP address, player id, hardware id or name, only fixed messages and counts;
--   * it sends nothing but the fields of the join-check, action and report contracts, and sends no
--     hardware id unless the player explicitly said yes;
--   * a player report carries a category, an optional short note the player typed, and the platform ids
--     of the two players: never chat, a name (beyond the operator's own reference), or an address;
--   * a game event (a spawn, an edit or a remove of a vehicle, or a movement flag) carries the id of
--     the player's join, a short label, and either an item name or the kind of check: never a position,
--     a coordinate, chat, an address or a platform id. The movement checks run here, on the game
--     server, and send only a flag. Events are held for a few seconds and sent in groups; a group is
--     only a list of those same events;
--   * the server's settings (fail mode, game events, reports, shared bans, youth-oriented) are set in the
--     platform's config file; they are sent to the API as five yes/no or open/closed values and nothing
--     else, and only those the file actually sets (a missing one is never sent, so an older config
--     file cannot reset what the server had);
--   * the heartbeat (about once a minute, so the portal can show the server online or offline) carries
--     one whole number, how many players are on, and nothing else;
--   * a blocked player is told only the fixed wording from the API, never why.

ServerGuardianCore = ServerGuardianCore or {}
local M = ServerGuardianCore

M.VERSION = "0.8.0"

-- Used until the API has been reached once, and whenever it cannot be. Kept short on purpose: the
-- authoritative wording comes from GET /v1/mod/config so operators cannot change it.
M.DEFAULT_WORDING = {
  noticeVersion = "notice-v1",
  notice = "This server uses ServerGuardian. We check your connection details against accounts "
    .. "banned elsewhere. The server only learns pass or block. Please leave if you do not want this.",
  optInTitle = "Optional: help us stop banned players returning",
  optInBody = "We can also check a scrambled code of your computer's hardware. We never keep the raw code.",
  optInYes = "Yes, include my hardware check",
  optInNo = "No, use my IP and game ID only",
  blocked = "You cannot join this server right now.",
  links = {},
}

-- What the report command says, until the API has been reached (the API's wording replaces the first
-- four). The rest is local: it says what went wrong with the command itself.
M.DEFAULT_REPORT_WORDING = {
  notice = "Your report goes to this server's staff through ServerGuardian, and is kept for a limited "
    .. "time. It is not a chat log: do not copy chat or personal details into it.",
  thanks = "Thank you. Your report has been sent to this server's staff.",
  tooMany = "You have sent several reports recently. Please try again later.",
  categories = {
    cheating = "Cheating",
    griefing = "Griefing",
    harassment = "Harassment",
    hate_or_abuse = "Hate or abuse",
    other = "Something else",
  },
}
local REPORT_TEXT = {
  off = "Reports are not enabled on this server.",
  usage = "Usage: /report <player> <category> [what happened]",
  confirm = "To send this report, type the same command again within 2 minutes.",
  notFound = "No connected player matches that name.",
  ambiguous = "More than one player matches that name. Type more of it.",
  self = "You cannot report yourself.",
  guest = "That player cannot be reported (no account).",
  noAccount = "Reports need a signed-in account, so a guest cannot send one.",
  failed = "Your report could not be sent. Please try again later.",
}
M.REPORT_TEXT = REPORT_TEXT

local PLATFORM_ID_TYPES = { beammp = true, cfx_license = true, minecraft_uuid = true, steam = true }
local MAX_PLATFORM_IDS = 8
local ACTION_TYPES = { ban = true, kick = true, warn = true, mute = true }
local MAX_REASON_BYTES = 500 -- the API's limit is 500 characters, and a character is at least a byte
local MAX_DURATION_HOURS = 24 * 365 * 10
local MAX_HARDWARE_TOKENS = 8
local CONFIG_REFRESH_SECONDS = 3600
local MAX_NOTE_BYTES = 200 -- the API's limit is 200 characters, and a character is at least a byte
local REPORT_CONFIRM_SECONDS = 120
local REPORTS_PER_WINDOW = 3 -- a player's own limit, so they are not told "too many" by the API
local REPORT_WINDOW_SECONDS = 600

-- Game events (decision D41, group 2). The API's own limit is 600 events a minute per key, so a
-- player is held to far less, and the whole server to a little under that.
local GAME_SPAWNS_PER_PLAYER_WINDOW = 20 -- every kind has a limit of its own, so spam of one cannot starve another
local GAME_EDITS_PER_PLAYER_WINDOW = 20
local GAME_REMOVES_PER_PLAYER_WINDOW = 20
local GAME_FLAGS_PER_PLAYER_WINDOW = 10
local GAME_PLAYER_LIMITS = {
  spawn = GAME_SPAWNS_PER_PLAYER_WINDOW,
  edit = GAME_EDITS_PER_PLAYER_WINDOW,
  remove = GAME_REMOVES_PER_PLAYER_WINDOW,
  flag = GAME_FLAGS_PER_PLAYER_WINDOW,
}
-- Edits and removes are only sent to a server that lists them in its `gameEvents.events`: an older
-- server's strict schema would refuse them. Spawns and flags have always been accepted.
local GAME_ALWAYS_KINDS = { spawn = true, flag = true }
local GAME_OPTIONAL_KINDS = { edit = true, remove = true }
local GAME_EVENT_WINDOW_SECONDS = 60
local GAME_EVENTS_PER_SERVER_WINDOW = 400
local GAME_BACKOFF_SECONDS = 60 -- after a 429
local GAME_REFUSED_BACKOFF_SECONDS = 600 -- after a 401, 402 or 403: the key or the account is not usable
-- Batching (decision D43). The API says how many events may go in one request and how long to hold
-- them (`gameEvents.batch`); these are the bounds the mod keeps whatever it says. The platform calls
-- Guard:tick() about every GAME_TICK_SECONDS, from a timer of its own like the heartbeat's.
M.GAME_TICK_SECONDS = 1
local MAX_BATCH_EVENTS = 100 -- the API's own limit for one request
local MIN_FLUSH_SECONDS = 1 -- the tick is about once a second, so nothing finer means anything
local MAX_FLUSH_SECONDS = 60
local GAME_QUEUE_CAP = 500 -- events held at most (while the API is slow, down or says wait); the oldest go first
local GAME_QUEUE_MAX_AGE_SECONDS = 600 -- an event this old is dropped, not sent: it would show with the wrong time
local GAME_RETRY_FIRST_SECONDS = 5 -- after a 5xx or no answer; doubles each time up to the next
local GAME_RETRY_MAX_SECONDS = 60
local GAME_HOLD_MAX_SECONDS = 600 -- the longest a Retry-After is believed
local GAME_REJECT_LOG_SECONDS = 60 -- a rejection is logged once in this long, so a mismatch cannot fill the log
-- The heartbeat is sent about once a minute by the platform's timer. Never twice within 55 seconds
-- (whole-second clocks wobble by one), and a refusal pauses it like the other calls.
M.HEARTBEAT_SECONDS = 60
local HEARTBEAT_MIN_SECONDS = 55
local HEARTBEAT_BACKOFF_SECONDS = 60
local HEARTBEAT_REFUSED_BACKOFF_SECONDS = 600
local MAX_HEARTBEAT_PLAYERS = 100000
local GAME_CONFIG_MAX_AGE_SECONDS = 10800 -- game events switch themselves off if settings cannot be refreshed for this long
local MIN_SAMPLE_SECONDS = 1
local MAX_SAMPLE_SECONDS = 10
local MAX_LABEL = 32
local MAX_ITEM = 40
local GAP_FACTOR = 3 -- a gap longer than this many sample periods starts the track again
local HIGH_RATIO = 1.5 -- a value this many times over its threshold is "high", not "low"

local Guard = {}
Guard.__index = Guard

-- Text for a game event: the schema allows letters, digits, space and _ . : / - only, and refuses
-- anything that looks like an address or a long hexadecimal code. Only ASCII letters and digits are
-- kept, so a name with other characters loses them rather than being refused. Returns nil if nothing
-- usable is left.
local function looksLikeIdentifier(text)
  if text:find(string.rep("%x", 32)) then
    return true
  end
  if text:match("^%d+%.%d+%.%d+%.%d+$") then
    return true
  end
  if text:find(":", 1, true) and text:match("^[%x:%.]+$") then
    return true -- an IPv6 address
  end
  return false
end

local function gameText(text, maxBytes)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("[^%w _%.:/%-]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if text == "" or looksLikeIdentifier(text) then
    return nil
  end
  return text:sub(1, maxBytes):match("^(.-)%s*$")
end
M.gameText = gameText

--- Position tracking for the movement checks. Pure: it is given times and positions and answers with
-- flags, so it is the same on every platform and can be tested with made-up numbers. It never keeps
-- more than the last position, the last speed and when each check last flagged, for each key.
local Tracker = {}
Tracker.__index = Tracker

function M.newTracker()
  -- `cooldowns` is kept per owner (the player), not per track, so a player with several vehicles is
  -- still flagged once for each check in a cooldown, and deleting a vehicle does not clear it.
  return setmetatable({ tracks = {}, cooldowns = {} }, Tracker)
end

--- Forget what is known about this key, so the next sample is a fresh start (a respawn, a teleport
-- command, a change of world, a vehicle reset). `skip` samples after it are ignored as well, for a
-- platform whose position is not yet right straight after.
function Tracker:reset(key, skip)
  local track = self.tracks[key]
  if not track and skip then
    track = {}
    self.tracks[key] = track
  end
  if track then
    track.last = nil
    track.speed = nil
    track.over = nil
    track.skip = skip
  end
end

--- A new track whose first `skip` samples are ignored (a vehicle that has just spawned).
function Tracker:start(key, skip)
  self.tracks[key] = { skip = skip }
end

--- Forget the key altogether (the vehicle has gone). A cooldown already started is kept.
function Tracker:forget(key)
  self.tracks[key] = nil
end

--- Forget an owner's cooldowns (the player has left).
function Tracker:forgetOwner(owner)
  self.cooldowns[owner] = nil
end

--- Takes one sample. `checks` is what the API serves (sampleSeconds, impossibleMove.maxSpeed and
-- .teleportDistance, acceleration.maxAcceleration, flagCooldownSeconds). Returns a list of flags,
-- each { check = "impossible_move" | "acceleration", severity = "low" | "high" }, usually empty.
-- The first sample, a gap longer than three sample periods, and the sample after a reset only set
-- the starting point. `owner` (default: the key) is who the cooldown belongs to. With `coarse` set
-- (the clock only counts whole seconds, so a stalled plugin thread can make a time difference look
-- shorter than it was), a speed or a change of speed is flagged only when the sample before it was
-- over the line too; a jump in distance does not depend on the clock and is flagged at once.
function Tracker:sample(key, t, x, y, z, checks, owner, coarse)
  local track = self.tracks[key]
  if not track then
    track = {}
    self.tracks[key] = track
  end
  if track.skip and track.skip > 0 then
    track.skip = track.skip - 1
    return {}
  end
  owner = owner or key
  local cooldowns = self.cooldowns[owner]
  if not cooldowns then
    cooldowns = {}
    self.cooldowns[owner] = cooldowns
  end
  local last = track.last
  track.last = { t = t, x = x, y = y, z = z }
  if not last then
    track.speed = nil
    track.over = nil
    return {}
  end
  local dt = t - last.t
  if dt <= 0 then
    track.last = last -- a sample out of order: keep the earlier one
    return {}
  end
  if dt > GAP_FACTOR * checks.sampleSeconds then
    track.speed = nil
    track.over = nil
    return {}
  end
  local dx, dy, dz = x - last.x, y - last.y, z - last.z
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local speed = distance / dt
  local previousSpeed = track.speed
  track.speed = speed
  local previousOver = track.over or {}
  local over = {}
  track.over = over

  local flags = {}
  local function consider(check, ratio, confirmed)
    if ratio <= 1 then
      return false
    end
    local lastFlag = cooldowns[check]
    if lastFlag and t - lastFlag < checks.flagCooldownSeconds then
      return true -- over the line, but flagged a moment ago
    end
    cooldowns[check] = t
    flags[#flags + 1] = { check = check, severity = ratio > HIGH_RATIO and "high" or "low" }
    return true
  end

  local speedRatio = speed / checks.impossibleMove.maxSpeed
  local distanceRatio = distance / checks.impossibleMove.teleportDistance
  if coarse and speedRatio > 1 then
    over.speed = true
    if not previousOver.speed then
      speedRatio = 0 -- the first one over the line only counts if the next is over too
    end
  end
  if consider("impossible_move", math.max(speedRatio, distanceRatio)) then
    -- A jump is not a change of speed: do not also flag it, or the sample after it.
    track.speed = nil
    return flags
  end
  if previousSpeed then
    local ratio = math.abs(speed - previousSpeed) / dt / checks.acceleration.maxAcceleration
    if coarse and ratio > 1 then
      -- Speeding up and then slowing down again is one spike, not two: it counts only when the
      -- change of speed is over the line twice in the same direction.
      local direction = speed > previousSpeed and 1 or -1
      over.acceleration = direction
      if previousOver.acceleration ~= direction then
        ratio = 0
      end
    end
    consider("acceleration", ratio)
  end
  return flags
end


-- The settings a server's config file may hold (decision D41 follow-up). The portal shows them but
-- cannot change them.
local SETTING_NAMES = { "failMode", "gameEvents", "reports", "shareBans", "youthOriented" }
local KNOWN_SETTING = {}
for _, name in ipairs(SETTING_NAMES) do
  KNOWN_SETTING[name] = true
end

--- Keeps the settings that are present and valid: failMode must be "open" or "closed", the others true
-- or false. Anything else is ignored as if it were not set, with a fixed line that names the setting
-- but never repeats what was written. A name this plugin does not know is reported without echoing it.
function M.cleanSettings(raw, log)
  local clean = {}
  log = log or function() end
  if type(raw) ~= "table" then
    return clean
  end
  for _, name in ipairs(SETTING_NAMES) do
    local value = raw[name]
    if value ~= nil then
      local valid
      if name == "failMode" then
        valid = value == "open" or value == "closed"
      else
        valid = type(value) == "boolean"
      end
      if valid then
        clean[name] = value
      else
        log("warn", "the setting " .. name .. " is not valid, so it is not used")
      end
    end
  end
  for name in pairs(raw) do
    if type(name) == "string" and not KNOWN_SETTING[name] then
      log("warn", "the settings hold a name this plugin does not know (check the spelling)")
      break
    end
  end
  return clean
end

--- Creates a guard.
-- opts.apiBase       API address without a trailing slash
-- opts.failMode      "open" (default) or "closed": what to do until the API has answered, and the
--                    answer the portal used to give; opts.settings.failMode, when set, always wins
-- opts.settings      the config file's settings: { failMode, gameEvents, reports, shareBans,
--                    youthOriented }, each optional; invalid ones are ignored (see cleanSettings)
-- opts.http          function(method, path, bodyTable_or_nil, callback) ; callback(status, bodyString)
--                    status is nil when the request failed or timed out
-- opts.json          { encode = fn, decode = fn }
-- opts.log           function(level, message) ; messages never contain player data
-- opts.now           function() -> seconds (default os.time)
-- opts.clock         function() -> seconds, finer than a second if the platform has such a clock (the
--                    movement checks use it). Without one the checks use opts.now and are more careful.
-- opts.random        function() -> integer 0..65535 (default math.random)
-- opts.prefix        short id prefix for event ids, e.g. "bm" or "fx"
function M.new(opts)
  assert(type(opts) == "table", "options required")
  assert(type(opts.http) == "function", "opts.http required")
  assert(opts.json and opts.json.encode and opts.json.decode, "opts.json required")
  local self = setmetatable({}, Guard)
  self.http = opts.http
  self.json = opts.json
  self.log = opts.log or function() end
  self.now = opts.now or os.time
  self.random = opts.random or function()
    return math.random(0, 65535)
  end
  self.prefix = opts.prefix or "sg"
  self.localSettings = M.cleanSettings(opts.settings, opts.log)
  -- The config file's fail mode is used from the start, whether or not the API has ever been reached.
  self.failMode = self.localSettings.failMode or (opts.failMode == "closed" and "closed" or "open")
  self.settingsSending = false
  self.wording = M.DEFAULT_WORDING
  self.reportWording = M.DEFAULT_REPORT_WORDING
  self.reportsEnabled = false -- on only when the config file or the API says so; absent means off
  self.reportPending = {} -- player key -> { fingerprint, at }: a report waiting for its confirmation
  self.reportConfirmed = {} -- player key -> true once they have seen the notice and confirmed
  self.reportSent = {} -- player key -> list of times a report was sent, for the player's own limit
  self.clock = opts.clock or self.now -- seconds, and finer than a second where the platform allows
  self.coarseClock = opts.clock == nil -- the movement checks only have whole seconds
  self.gameEnabled = false -- on only when the config file or the API says so; absent means off
  self.gameChecks = nil
  self.gameBackoffUntil = 0
  self.heartbeatInFlight = false
  self.heartbeatBackoffUntil = 0
  self.heartbeatLastAt = nil
  -- kind ("spawn", "edit", "remove" or "flag") -> player key -> list of times one was sent
  self.gameSent = { spawn = {}, edit = {}, remove = {}, flag = {} }
  self.gameServerSent = {} -- times of every game event sent, for the whole server
  self.gameBatch = nil -- { maxEvents, flushSeconds } while the API serves batching; nil means one request per event
  self.gameKinds = nil -- the kinds the API lists in `gameEvents.events`, as a set (nil when it lists none)
  self.gameQueue = {} -- events waiting to be sent, oldest first: { body = the event, at = self.clock() }
  self.gameBatchInFlight = false
  self.gameHoldUntil = 0 -- self.clock() time before which no batch is sent (a 429, or waiting to retry)
  self.gameRetryFails = 0 -- failures in a row, for the retry delay
  self.gameDropped = 0 -- events dropped since the last debug line about it
  self.gameRejectLoggedAt = nil
  self.tracker = M.newTracker()
  self.onGameConfig = nil -- set by the platform: called when game events are switched on or off
  self.configFetchedAt = nil
  self.counter = 0
  self.stats = { checks = 0, passes = 0, blocks = 0, errors = 0, skipped = 0 }
  return self
end

--- Tells the API the server is there, with how many players are on (a whole number, or nothing).
-- Called by the platform's timer about every minute, and once at start-up. Only one is ever in
-- flight, none is sent within 55 seconds of the last, and a refusal pauses it: ten minutes for a
-- revoked key, a paused plan or a missing permission (401, 402, any 403), one minute for 429. Any other
-- failure is simply tried again at the next tick. Works whether or not game events or reports are on.
-- Nothing but the count is sent, and it is never logged. callback (optional) receives true on success.
function Guard:heartbeat(players, callback)
  local function done(ok)
    if callback then
      callback(ok)
    end
  end
  local now = self.clock() -- a steady clock, not wall time, so it only ever measures gaps
  if self.heartbeatInFlight or now < self.heartbeatBackoffUntil then
    return done(false)
  end
  if self.heartbeatLastAt and now - self.heartbeatLastAt < HEARTBEAT_MIN_SECONDS then
    return done(false)
  end
  local body = {}
  if
    type(players) == "number"
    and players >= 0
    and players <= MAX_HEARTBEAT_PLAYERS
    and players == math.floor(players)
  then
    body.players = math.floor(players)
  end
  self.heartbeatInFlight = true
  self.heartbeatLastAt = now
  self.http("POST", "/v1/mod/heartbeat", body, function(status)
    self.heartbeatInFlight = false
    if status == 204 then
      return done(true)
    end
    -- Only the status is logged.
    self.log("debug", "could not send the heartbeat (status " .. tostring(status) .. ")")
    if status == 429 then
      self.heartbeatBackoffUntil = self.clock() + HEARTBEAT_BACKOFF_SECONDS
    elseif status == 401 or status == 402 or status == 403 then
      self.heartbeatBackoffUntil = self.clock() + HEARTBEAT_REFUSED_BACKOFF_SECONDS
    end
    done(false)
  end)
end

--- A new id for one join. Unique enough for idempotency: time, a counter and a random part.
function Guard:newEventId()
  self.counter = self.counter + 1
  return string.format(
    "%s-%x-%x-%04x",
    self.prefix,
    self.now(),
    self.counter,
    self.random() % 65536
  )
end

--- Loads the player-facing wording and the server's fail mode. Safe to call often: it only asks the
-- API when the last answer is an hour old. On any failure the previous wording stays.
function Guard:refreshConfig(callback, force)
  local now = self.now()
  if not force and self.configFetchedAt and now - self.configFetchedAt < CONFIG_REFRESH_SECONDS then
    if callback then
      callback(true)
    end
    return
  end
  -- First tell the API what the config file says (only what it sets), then ask for the wording.
  self:_sendSettings(function()
    self:_fetchConfig(now, callback)
  end)
end

--- Sends the settings the config file sets to PUT /v1/mod/settings, then calls `done`. Sends nothing
-- when the file sets none. Quiet on every failure: the local values are used either way.
function Guard:_sendSettings(done)
  local body = {}
  local any = false
  for _, name in ipairs(SETTING_NAMES) do
    if self.localSettings[name] ~= nil then
      body[name] = self.localSettings[name]
      any = true
    end
  end
  if not any or self.settingsSending then
    return done()
  end
  self.settingsSending = true
  self.http("PUT", "/v1/mod/settings", body, function(status)
    self.settingsSending = false
    if status ~= 200 then
      if status == 429 then
        self.log("warn", "ServerGuardian refused the settings (too many changes in an hour), using the config file")
      else
        self.log("warn", "could not send the settings to ServerGuardian, using the config file")
      end
    end
    done()
  end)
end

function Guard:_fetchConfig(now, callback)
  self.http("GET", "/v1/mod/config", nil, function(status, body)
    local ok = false
    if status == 200 and type(body) == "string" then
      local decoded = self:_decode(body)
      local en = decoded and decoded.text and decoded.text.en
      if en and type(en.notice) == "string" and type(en.blocked) == "string" then
        self.wording = {
          noticeVersion = type(decoded.noticeVersion) == "string" and decoded.noticeVersion
            or M.DEFAULT_WORDING.noticeVersion,
          notice = en.notice,
          optInTitle = en.optInTitle or M.DEFAULT_WORDING.optInTitle,
          optInBody = en.optInBody or M.DEFAULT_WORDING.optInBody,
          optInYes = en.optInYes or M.DEFAULT_WORDING.optInYes,
          optInNo = en.optInNo or M.DEFAULT_WORDING.optInNo,
          blocked = en.blocked,
          links = type(decoded.links) == "table" and decoded.links or {},
        }
        -- The config file wins; the API's answer is for servers whose file does not set it.
        if
          self.localSettings.failMode == nil
          and (decoded.failMode == "open" or decoded.failMode == "closed")
        then
          self.failMode = decoded.failMode
        end
        if self.localSettings.reports ~= nil then
          self.reportsEnabled = self.localSettings.reports
        else
          self.reportsEnabled = type(decoded.reports) == "table" and decoded.reports.enabled == true
        end
        local defaults = M.DEFAULT_REPORT_WORDING
        local categories = type(en.reportCategories) == "table" and en.reportCategories or nil
        self.reportWording = {
          notice = type(en.reportNotice) == "string" and en.reportNotice or defaults.notice,
          thanks = type(en.reportThanks) == "string" and en.reportThanks or defaults.thanks,
          tooMany = type(en.reportTooMany) == "string" and en.reportTooMany or defaults.tooMany,
          categories = categories or defaults.categories,
        }
        local gameSettings = decoded.gameEvents
        if self.localSettings.gameEvents ~= nil then
          -- The file decides whether they are on; the limits for the checks, and how to batch, still come from the API.
          local served = type(decoded.gameEvents) == "table" and decoded.gameEvents or {}
          gameSettings = {
            enabled = self.localSettings.gameEvents,
            checks = served.checks,
            batch = served.batch,
            events = served.events,
          }
        end
        self:_setGameConfig(gameSettings)
        self.configFetchedAt = now
        ok = true
      end
    end
    if not ok then
      self.log("warn", "could not load ServerGuardian settings, using the built-in wording")
      -- A refusal (the key was revoked, the plan paused it, the account is not allowed) means game
      -- events are off. A failure to get an answer at all keeps what we had, which times out below.
      if status == 401 or status == 402 or status == 403 then
        self:_applyGameConfig(false, nil)
      end
    end
    if callback then
      callback(ok)
    end
  end)
end

--- True if every number is finite and above zero.
local function positive(value)
  return type(value) == "number" and value == value and value > 0 and value < math.huge
end

--- How to batch, from `gameEvents.batch`: { maxEvents, flushSeconds }, held to what this file can do.
-- nil when the API does not say (an older server) or says something unusable: events then go one by one.
local function readBatch(value)
  if type(value) ~= "table" or not positive(value.maxEvents) or not positive(value.flushSeconds) then
    return nil
  end
  return {
    maxEvents = math.min(MAX_BATCH_EVENTS, math.max(1, math.floor(value.maxEvents))),
    flushSeconds = math.min(MAX_FLUSH_SECONDS, math.max(MIN_FLUSH_SECONDS, value.flushSeconds)),
  }
end

--- The kinds of event the API lists in `gameEvents.events`, as a set of the ones this file knows.
local function readKinds(value)
  if type(value) ~= "table" then
    return nil
  end
  local kinds = {}
  for _, kind in ipairs(value) do
    if GAME_PLAYER_LIMITS[kind] then
      kinds[kind] = true
    end
  end
  return kinds
end

--- Reads the `gameEvents` part of the settings: off unless it says `enabled: true` with the numbers the
-- checks need. Anything missing or odd means off. Tells the platform when it changes.
function Guard:_setGameConfig(settings)
  if type(settings) ~= "table" or settings.enabled ~= true then
    self:_applyGameConfig(false, nil)
    return
  end
  -- On, but the numbers the checks need must all be sane. If they are not, the checks stay off
  -- (spawns can still go) rather than running with zeros.
  local checks = nil
  local c = type(settings.checks) == "table" and settings.checks or nil
  local move = c and type(c.impossibleMove) == "table" and c.impossibleMove or nil
  local accel = c and type(c.acceleration) == "table" and c.acceleration or nil
  if
    c and move and accel
    and positive(c.sampleSeconds)
    and positive(c.flagCooldownSeconds) and c.flagCooldownSeconds >= 1
    and positive(move.maxSpeed)
    and positive(move.teleportDistance)
    and positive(accel.maxAcceleration)
  then
    checks = {
      sampleSeconds = math.min(MAX_SAMPLE_SECONDS, math.max(MIN_SAMPLE_SECONDS, c.sampleSeconds)),
      flagCooldownSeconds = c.flagCooldownSeconds,
      impossibleMove = { maxSpeed = move.maxSpeed, teleportDistance = move.teleportDistance },
      acceleration = { maxAcceleration = accel.maxAcceleration },
    }
  elseif settings.checks ~= nil then
    self.log("warn", "the movement-check settings from ServerGuardian were not usable, so the checks are off")
  end
  self:_applyGameConfig(true, checks, readBatch(settings.batch), readKinds(settings.events))
end

function Guard:_applyGameConfig(enabled, checks, batch, kinds)
  local oldChecks = self.gameChecks
  local changed = enabled ~= self.gameEnabled
    or (oldChecks == nil) ~= (checks == nil)
    or (oldChecks ~= nil and checks ~= nil and oldChecks.sampleSeconds ~= checks.sampleSeconds)
  self.gameEnabled = enabled
  self.gameChecks = checks
  self.gameBatch = enabled and batch or nil
  self.gameKinds = enabled and kinds or nil
  if not checks then
    self.tracker = M.newTracker() -- nothing is kept while the checks are off
  end
  if not enabled then
    self.gameSent = { spawn = {}, edit = {}, remove = {}, flag = {} }
    self.gameServerSent = {}
  end
  if not self.gameBatch then
    -- Off, or an API that does not batch: nothing is held. (Waiting events are not sent anywhere
    -- else: an API that does not batch may not have the route.)
    self.gameQueue = {}
  end
  if changed and self.onGameConfig then
    self.onGameConfig(enabled, checks)
  end
end

function Guard:_decode(body)
  local ok, decoded = pcall(self.json.decode, body)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

--- True when the list is one to eight well-formed platform ids.
local function validPlatformIds(list)
  if type(list) ~= "table" or #list < 1 or #list > MAX_PLATFORM_IDS then
    return false
  end
  for _, platformId in ipairs(list) do
    if
      type(platformId) ~= "table"
      or not PLATFORM_ID_TYPES[platformId.type]
      or type(platformId.id) ~= "string"
      or platformId.id == ""
      or #platformId.id > 128
    then
      return false
    end
  end
  return true
end

--- Checks the input has what the contract needs. Returns nil and a short reason if not.
local function validate(input)
  if type(input) ~= "table" then
    return nil, "no_input"
  end
  if type(input.ip) ~= "string" or input.ip == "" or #input.ip > 64 then
    return nil, "no_ip"
  end
  if type(input.platformIds) ~= "table" or #input.platformIds < 1 then
    return nil, "no_platform_id"
  end
  if not validPlatformIds(input.platformIds) then
    return nil, "bad_platform_id"
  end
  return true
end

--- Builds the body of a join check. The hardware id is only included after an explicit yes.
function Guard:buildEvent(input, eventId)
  local event = {
    eventId = eventId,
    ip = input.ip,
    platformIds = {},
  }
  for _, platformId in ipairs(input.platformIds) do
    event.platformIds[#event.platformIds + 1] = { type = platformId.type, id = platformId.id }
  end
  -- Hardware: nothing is sent unless the player said yes. A yes may come with one token (hwid) or
  -- several (hwids); a no is reported so it can be recorded as a withdrawal if they said yes before.
  local hardware = input.hardware
  if type(hardware) == "table" and hardware.consent == "granted" then
    event.hardwareConsent = "granted"
    event.consentNoticeVersion = self.wording.noticeVersion
    if type(hardware.hwid) == "string" and hardware.hwid ~= "" then
      event.hwid = hardware.hwid
    elseif type(hardware.hwids) == "table" and #hardware.hwids > 0 then
      event.hwids = {}
      for i, token in ipairs(hardware.hwids) do
        if i > MAX_HARDWARE_TOKENS then
          break
        end
        if type(token) == "string" and token ~= "" and #token <= 512 then
          event.hwids[#event.hwids + 1] = token
        end
      end
      if #event.hwids == 0 then
        event.hwids = nil
      end
    end
  elseif type(hardware) == "table" and hardware.consent == "declined" then
    event.hardwareConsent = "declined"
  end
  if input.operatorMinorHint == true then
    event.operatorMinorHint = true
  end
  return event
end

--- Asks whether a joining player may stay.
-- input: { ip, platformIds = {{type,id},...}, hardware = {consent, hwid}, operatorMinorHint }
-- callback receives { action = "allow" | "deny", result = "pass" | "block" | "error" | "skipped",
--                     eventId = string|nil, message = string|nil }
-- A player is only denied on an explicit "block" from the API, or on a failure when failMode is
-- "closed" (not when a plan or rate limit of ours refused the call: 402 and 429 always let them in). Nothing here distinguishes why: the player is only ever told the fixed wording.
function Guard:check(input, callback)
  local valid, reason = validate(input)
  if not valid then
    -- Cannot identify the player: nothing is sent, and they are let through (e.g. a BeamMP guest).
    self.stats.skipped = self.stats.skipped + 1
    self.log("debug", "join check skipped: " .. reason)
    callback({ action = "allow", result = "skipped" })
    return
  end

  local eventId = self:newEventId()
  local body = self:buildEvent(input, eventId)
  self.stats.checks = self.stats.checks + 1
  self.http("POST", "/v1/join-check", body, function(status, responseBody)
    if status == 200 and type(responseBody) == "string" then
      local decoded = self:_decode(responseBody)
      if decoded and decoded.result == "block" then
        self.stats.blocks = self.stats.blocks + 1
        callback({ action = "deny", result = "block", eventId = eventId, message = self.wording.blocked })
        return
      end
      if decoded and decoded.result == "pass" then
        self.stats.passes = self.stats.passes + 1
        callback({ action = "allow", result = "pass", eventId = eventId })
        return
      end
    end
    -- A limit of ours, not an outage: the plan's monthly allowance is used up (429) or the server is
    -- over its plan (402). Players are let in whatever the fail mode, so that someone else's
    -- billing never locks a server's own players out. The operator is told by email and in the portal.
    if status == 429 or status == 402 then
      self.stats.errors = self.stats.errors + 1
      self.log("warn", "join check not done: plan or rate limit (status " .. tostring(status) .. "), letting the player in")
      callback({ action = "allow", result = "error", eventId = eventId })
      return
    end
    -- Unreachable, refused (401/403), or an answer we do not understand.
    self.stats.errors = self.stats.errors + 1
    self.log("warn", "join check failed (status " .. tostring(status) .. "), failing " .. self.failMode)
    if self.failMode == "closed" then
      callback({ action = "deny", result = "error", eventId = eventId, message = self.wording.blocked })
    else
      callback({ action = "allow", result = "error", eventId = eventId })
    end
  end)
end

--- Tells us a player left. Best effort: nothing depends on it.
function Guard:leave(eventId)
  if type(eventId) ~= "string" or eventId == "" then
    return
  end
  self.http("POST", "/v1/events/player-leave", { eventId = eventId }, function() end)
end

--- Tidies text a person typed (a ban reason, a report note): no control characters, one space between words, no
-- more than the API accepts (cut on a character boundary so the JSON stays valid UTF-8). Returns nil
-- when nothing is left.
local function cleanText(text, maxBytes)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if text == "" then
    return nil
  end
  if #text > maxBytes then
    local cut = maxBytes
    while cut > 0 do
      local nextByte = text:byte(cut + 1)
      if nextByte and nextByte >= 0x80 and nextByte < 0xC0 then
        cut = cut - 1
      else
        break
      end
    end
    text = text:sub(1, cut)
  end
  return text
end

local function cleanReason(text)
  return cleanText(text, MAX_REASON_BYTES)
end

--- Records something the server's operator did to a player: a ban, kick, warning or mute. Only a ban
-- (or a mute) may have a duration; without one a ban is permanent. The reason is operator-written text,
-- so it is the one free-text field this file sends; it is cleaned and limited first.
-- input: { type = "ban"|"kick"|"warn"|"mute", reason, durationHours (optional), platformIds = {...} }
-- callback receives { ok = true, actionId = string } or { ok = false, reason = "bad_input" |
--   "unreachable" | "refused" | "rejected", status = number|nil }. "refused" means the key may not
--   record actions (401 or 403).
function Guard:recordAction(input, callback)
  local function fail(reason, status)
    callback({ ok = false, reason = reason, status = status })
  end
  if type(input) ~= "table" or not ACTION_TYPES[input.type] then
    return fail("bad_input")
  end
  local reason = cleanReason(input.reason)
  if not reason or not validPlatformIds(input.platformIds) then
    return fail("bad_input")
  end
  local hours = input.durationHours
  if hours ~= nil then
    if
      (input.type ~= "ban" and input.type ~= "mute")
      or math.type(hours) ~= "integer"
      or hours < 1
      or hours > MAX_DURATION_HOURS
    then
      return fail("bad_input")
    end
  end
  local body = { eventId = self:newEventId(), type = input.type, reason = reason, platformIds = {} }
  for _, platformId in ipairs(input.platformIds) do
    body.platformIds[#body.platformIds + 1] = { type = platformId.type, id = platformId.id }
  end
  body.durationHours = hours
  self.http("POST", "/v1/actions", body, function(status, responseBody)
    if status == 201 and type(responseBody) == "string" then
      local decoded = self:_decode(responseBody)
      if decoded and type(decoded.id) == "string" and decoded.id:match("^[%x%-]+$") then
        callback({ ok = true, actionId = decoded.id })
        return
      end
    end
    self.log("warn", "could not record an action (status " .. tostring(status) .. ")")
    if status == nil then
      return fail("unreachable")
    elseif status == 401 or status == 403 then
      return fail("refused", status)
    end
    return fail("rejected", status)
  end)
end

--- Ends a ban or mute early, using the id recordAction returned. The id goes into the request address,
-- so only the exact shape the API issues is accepted.
-- callback receives { ok = true } or { ok = false, reason = "bad_input" | "unreachable" | "refused" |
--   "not_found" | "rejected", status = number|nil }.
function Guard:liftAction(actionId, callback)
  if type(actionId) ~= "string" or #actionId ~= 36 or not actionId:match("^[%x%-]+$") then
    callback({ ok = false, reason = "bad_input" })
    return
  end
  self.http("POST", "/v1/actions/" .. actionId .. "/lift", nil, function(status)
    if status == 204 then
      callback({ ok = true })
    elseif status == nil then
      callback({ ok = false, reason = "unreachable" })
    elseif status == 401 or status == 403 then
      callback({ ok = false, reason = "refused", status = status })
    elseif status == 404 then
      callback({ ok = false, reason = "not_found", status = status })
    else
      callback({ ok = false, reason = "rejected", status = status })
    end
  end)
end

--- The id of a report, which the operator sees as its reference. It carries the reported player's name
-- (letters and digits only, shortened) so staff can recognise it, and nothing about the reporter.
function Guard:_reportEventId(label)
  self.counter = self.counter + 1
  local name = type(label) == "string" and label:gsub("[^A-Za-z0-9]", ""):sub(1, 24) or ""
  if name == "" then
    name = "player"
  end
  return string.format("rep-%s-%x-%x", name, self.now(), self.counter)
end

--- Sends one report. Checks the input first; nothing is sent if it is not valid.
-- input: { category, note (optional), reporterIds = {{type,id},...}, reportedIds = {...}, label }
--   (label is the reported player's name, used only to make the reference recognisable)
-- callback receives { ok = true } or { ok = false, reason = "bad_input" | "disabled" | "too_many" |
--   "unreachable" | "refused" | "rejected", status = number|nil }.
function Guard:report(input, callback)
  local function fail(reason, status)
    callback({ ok = false, reason = reason, status = status })
  end
  if type(input) ~= "table" or not self.reportWording.categories[input.category] then
    return fail("bad_input")
  end
  if not validPlatformIds(input.reporterIds) or not validPlatformIds(input.reportedIds) then
    return fail("bad_input")
  end
  local body = {
    eventId = self:_reportEventId(input.label),
    category = input.category,
    note = cleanText(input.note, MAX_NOTE_BYTES),
    reporterPlatformIds = {},
    reportedPlatformIds = {},
  }
  for _, platformId in ipairs(input.reporterIds) do
    body.reporterPlatformIds[#body.reporterPlatformIds + 1] = { type = platformId.type, id = platformId.id }
  end
  for _, platformId in ipairs(input.reportedIds) do
    body.reportedPlatformIds[#body.reportedPlatformIds + 1] = { type = platformId.type, id = platformId.id }
  end
  self.http("POST", "/v1/reports", body, function(status, responseBody)
    if status == 202 then
      callback({ ok = true })
      return
    end
    -- Only the status is logged: never the note, a name or an id.
    self.log("warn", "could not send a report (status " .. tostring(status) .. ")")
    if status == nil then
      return fail("unreachable")
    elseif status == 429 then
      return fail("too_many", status)
    elseif status == 403 then
      local decoded = type(responseBody) == "string" and self:_decode(responseBody) or nil
      if decoded and decoded.error == "reports_disabled" then
        self.reportsEnabled = false
        return fail("disabled", status)
      end
      return fail("refused", status)
    elseif status == 401 then
      return fail("refused", status)
    end
    return fail("rejected", status)
  end)
end

--- The whole /report command, the same on every platform. The platform file passes what it knows and
-- a function to say things to the player; this file decides what to say and when to send.
--   input.key         a string that is the same for one player for the whole session
--   input.reporterIds the reporter's platform ids (nil when they have none, for example a guest)
--   input.typed       what they typed for the player (a name), or nil
--   input.category    what they typed for the category, or nil
--   input.note        the rest of what they typed, or nil
--   input.resolve     function(typed) -> player, or nil and one of "not_found", "ambiguous", "self",
--                     "guest"; a player is { ids = {{type,id},...}, label = name }
--   reply             function(text): says something to the reporter
function Guard:reportCommand(input, reply)
  local text = self.reportWording
  if not self.reportsEnabled then
    return reply(REPORT_TEXT.off)
  end
  if type(input.typed) ~= "string" or input.typed == "" or type(input.category) ~= "string" then
    return reply(REPORT_TEXT.usage .. " " .. self:_categoryList())
  end
  local category = input.category:lower()
  if not text.categories[category] then
    return reply("Choose a category: " .. self:_categoryList())
  end
  if not validPlatformIds(input.reporterIds) then
    return reply(REPORT_TEXT.noAccount)
  end
  local player, problem = input.resolve(input.typed)
  if not player then
    return reply(REPORT_TEXT[problem == "not_found" and "notFound" or problem] or REPORT_TEXT.notFound)
  end

  local now = self.now()
  local key = input.key
  -- The first report a player sends in a session is shown the notice, and sent only when they type the
  -- same command again. After that they have seen it, and a report is sent straight away.
  if not self.reportConfirmed[key] then
    local fingerprint = player.label .. "|" .. category .. "|" .. tostring(input.note)
    local pending = self.reportPending[key]
    if not pending or pending.fingerprint ~= fingerprint or now - pending.at > REPORT_CONFIRM_SECONDS then
      self.reportPending[key] = { fingerprint = fingerprint, at = now }
      return reply(text.notice .. " " .. REPORT_TEXT.confirm)
    end
    self.reportPending[key] = nil
    self.reportConfirmed[key] = true
  end

  local sent = {}
  for _, at in ipairs(self.reportSent[key] or {}) do
    if now - at < REPORT_WINDOW_SECONDS then
      sent[#sent + 1] = at
    end
  end
  self.reportSent[key] = sent
  if #sent >= REPORTS_PER_WINDOW then
    return reply(text.tooMany)
  end
  sent[#sent + 1] = now

  self:report({
    category = category,
    note = input.note,
    reporterIds = input.reporterIds,
    reportedIds = player.ids,
    label = player.label,
  }, function(result)
    if result.ok then
      reply(text.thanks)
    elseif result.reason == "too_many" then
      reply(text.tooMany)
    elseif result.reason == "disabled" then
      reply(REPORT_TEXT.off)
    else
      reply(REPORT_TEXT.failed)
    end
  end)
end

--- "cheating (Cheating), griefing (Griefing), ..." in a steady order, for telling a player what to type.
function Guard:_categoryList()
  local ids = {}
  for id in pairs(self.reportWording.categories) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do
    parts[#parts + 1] = id .. " (" .. tostring(self.reportWording.categories[id]) .. ")"
  end
  return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------------------------------
-- Game events (decision D41, group 2; D43): spawns, edits and removes, and flags from the movement checks.
-- ---------------------------------------------------------------------------------------------------

--- The id of a game event. Opaque, and unique for this server.
function Guard:_gameEventId()
  self.counter = self.counter + 1
  return string.format("ev-%s-%x-%x", self.prefix, self.now(), self.counter)
end

--- True when this player may have another event of this kind ("spawn", "edit", "remove" or "flag")
-- sent now, counting it if so. Keeps the server well inside the API's own limit, and one busy player
-- from using it all; each kind is counted separately so spam of one does not hide another.
function Guard:_gameAllowance(playerKey, kind)
  local now = self.now()
  local function recent(list)
    local kept = {}
    for _, at in ipairs(list) do
      if now - at < GAME_EVENT_WINDOW_SECONDS then
        kept[#kept + 1] = at
      end
    end
    return kept
  end
  local sent = self.gameSent[kind]
  local limit = GAME_PLAYER_LIMITS[kind]
  local mine = recent(sent[playerKey] or {})
  local all = recent(self.gameServerSent)
  sent[playerKey] = mine
  self.gameServerSent = all
  if #mine >= limit or #all >= GAME_EVENTS_PER_SERVER_WINDOW then
    return false
  end
  mine[#mine + 1] = now
  all[#all + 1] = now
  return true
end

--- Forgets everything kept about a player (they left): their limits and their flag cooldowns. Events
-- of theirs that are already waiting to be sent still go: they carry the join's reference, not the player.
function Guard:forgetGamePlayer(playerKey)
  playerKey = tostring(playerKey)
  for _, sent in pairs(self.gameSent) do
    sent[playerKey] = nil
  end
  self.tracker:forgetOwner(playerKey)
end

--- True while game events may be sent: on, not backed off, and the settings are not stale.
function Guard:_gameActive()
  if not self.gameEnabled then
    return false
  end
  local now = self.now()
  if now < self.gameBackoffUntil then
    return false
  end
  if self.configFetchedAt and now - self.configFetchedAt > GAME_CONFIG_MAX_AGE_SECONDS then
    return false -- we have not been able to confirm the operator still wants them
  end
  return true
end

--- A header from the platform's answer, whatever the case it came in. Platforms that cannot give
-- headers pass none.
local function headerOf(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == name then
      return value
    end
  end
  return nil
end

--- Sends one game event. `body` has the type's own fields; the id, the join reference and the label
-- are added here. Nothing is sent while game events are off or backed off, for a player with no join
-- reference, or past the limits. Quiet on every failure: nothing depends on it. When the API serves
-- batching the event is held and sent with others (see Guard:tick); otherwise it is sent at once.
-- input: { playerKey, joinEventId, label (optional), type = "spawn" | "edit" | "remove" | "flag",
--          item | check + severity }
-- callback (optional) receives true when the event was accepted: by the API, or, when it is batched,
-- for sending (what happens to it after that is not reported back).
function Guard:gameEvent(input, callback)
  local function done(ok)
    if callback then
      callback(ok)
    end
  end
  if not self:_gameActive() then
    return done(false)
  end
  if type(input) ~= "table" or type(input.joinEventId) ~= "string" or input.joinEventId == "" then
    return done(false)
  end
  local kind = input.type
  if not GAME_PLAYER_LIMITS[kind] then
    return done(false)
  end
  if GAME_OPTIONAL_KINDS[kind] and not (self.gameKinds and self.gameKinds[kind]) then
    return done(false) -- this API has not said it takes edits and removes
  end
  local body = {
    eventId = self:_gameEventId(),
    joinEventId = input.joinEventId,
    type = kind,
    label = gameText(input.label, MAX_LABEL),
  }
  if kind == "flag" then
    body.check = input.check
    body.severity = input.severity
  else
    body.item = gameText(input.item, MAX_ITEM) or "vehicle"
  end
  if not self:_gameAllowance(tostring(input.playerKey), kind) then
    return done(false)
  end
  if self.gameBatch then
    self:_queueGameEvent(body)
    return done(true)
  end
  self.http("POST", "/v1/events/game", body, function(status, responseBody)
    if status == 202 then
      return done(true)
    end
    -- Only the status is logged: never an item, a label or an id.
    self.log("debug", "could not send a game event (status " .. tostring(status) .. ")")
    if status == 429 then
      self.gameBackoffUntil = self.now() + GAME_BACKOFF_SECONDS
    elseif status == 401 or status == 402 or status == 403 then
      -- The key or the account is not usable (revoked, plan paused, no permission): stop for a while.
      self.gameBackoffUntil = self.now() + GAME_REFUSED_BACKOFF_SECONDS
      local decoded = status == 403 and type(responseBody) == "string" and self:_decode(responseBody) or nil
      if decoded and decoded.error == "game_events_disabled" then
        -- The operator switched them off: off until the next settings refresh says otherwise.
        self.gameBackoffUntil = 0
        self:_applyGameConfig(false, nil)
      end
    end
    done(false)
  end)
end

-- ---------------------------------------------------------------------------------------------------
-- Batching (decision D43). Events wait here, in memory only, until there are `maxEvents` of them or the
-- oldest has waited `flushSeconds`, and then go in one POST /v1/events/batch. The queue is bounded, and
-- nothing in this part ever blocks the game or raises an error into it.
-- ---------------------------------------------------------------------------------------------------

--- Logs how many events were dropped (the queue was full, or they had waited too long) since the last
-- time, from the tick, so at most once a second. A count only, and only at debug level.
function Guard:_reportDrops()
  if self.gameDropped > 0 then
    self.log("debug", "dropped " .. self.gameDropped .. " waiting game events (the queue was full or they were too old)")
    self.gameDropped = 0
  end
end

--- Keeps the queue within its cap by dropping the oldest events.
function Guard:_trimQueue()
  local over = #self.gameQueue - GAME_QUEUE_CAP
  if over > 0 then
    self.gameQueue = table.move(self.gameQueue, over + 1, #self.gameQueue, 1, {})
    self.gameDropped = self.gameDropped + over
  end
end

--- Drops events that have waited so long that sending them would date them wrongly (the API stamps an
-- event with the time it arrives).
function Guard:_dropStale()
  local queue = self.gameQueue
  local now = self.clock()
  local stale = 0
  while queue[stale + 1] and now - queue[stale + 1].at > GAME_QUEUE_MAX_AGE_SECONDS do
    stale = stale + 1
  end
  if stale > 0 then
    self.gameQueue = table.move(queue, stale + 1, #queue, 1, {})
    self.gameDropped = self.gameDropped + stale
  end
end

function Guard:_queueGameEvent(body)
  self:_dropStale() -- so a full batch means a full batch of events worth sending
  self.gameQueue[#self.gameQueue + 1] = { body = body, at = self.clock() }
  self:_trimQueue()
  if #self.gameQueue >= self.gameBatch.maxEvents then
    self:_flushGame()
  end
end

--- Puts events that were not delivered back at the front, in order, and trims.
function Guard:_requeue(entries)
  if #entries == 0 then
    return
  end
  local merged = table.move(entries, 1, #entries, 1, {})
  self.gameQueue = table.move(self.gameQueue, 1, #self.gameQueue, #merged + 1, merged)
  self:_trimQueue()
end

--- Waits before the next batch: for a 429, as long as the API said (Retry-After), else a minute; for a
-- 5xx or no answer, a few seconds and then longer, up to a minute.
function Guard:_holdGame(seconds)
  self.gameHoldUntil = self.clock() + seconds
end

--- What the API refused, as field names only (never a value). The names are cut to plain identifiers.
local function rejectedFields(rejected)
  local names, seen = {}, {}
  if type(rejected) == "table" then
    for _, entry in ipairs(rejected) do
      for _, field in ipairs(type(entry) == "table" and type(entry.fields) == "table" and entry.fields or {}) do
        local name = type(field) == "string" and field:match("^[%w_%.]+") or nil
        if name and not seen[name] and #names < 8 then
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
  end
  return names
end

--- Sends up to `maxEvents` of the waiting events in one request, if one is not already on its way and
-- the API has not asked us to wait. Called when the queue is full, by the tick when the oldest event
-- has waited long enough, and when the platform is shutting down.
function Guard:_flushGame()
  local batch = self.gameBatch
  if not batch or self.gameBatchInFlight or #self.gameQueue == 0 then
    return
  end
  if not self:_gameActive() then
    self.gameQueue = {} -- off, backed off or stale: what is waiting is not sent later
    return
  end
  if self.clock() < self.gameHoldUntil then
    return
  end
  self:_dropStale()
  local count = math.min(#self.gameQueue, batch.maxEvents)
  if count == 0 then
    return
  end
  local taken = table.move(self.gameQueue, 1, count, 1, {})
  self.gameQueue = table.move(self.gameQueue, count + 1, #self.gameQueue, 1, {})
  local events = {}
  for i, entry in ipairs(taken) do
    events[i] = entry.body
  end
  self.gameBatchInFlight = true
  local ok = pcall(self.http, "POST", "/v1/events/batch", { events = events }, function(status, responseBody, headers)
    self.gameBatchInFlight = false
    self:_batchAnswered(taken, status, responseBody, headers)
  end)
  if not ok then
    -- The platform could not even start the request: keep the events and try again later.
    self.gameBatchInFlight = false
    self:_requeue(taken)
    self:_holdGame(GAME_RETRY_FIRST_SECONDS)
  end
end

--- What to do with a batch once the API has answered (or not). `taken` is what was sent.
function Guard:_batchAnswered(taken, status, responseBody, headers)
  if status == 202 then
    self.gameRetryFails = 0
    local decoded = type(responseBody) == "string" and responseBody ~= "" and self:_decode(responseBody) or nil
    local fields = decoded and rejectedFields(decoded.rejected) or {}
    if #fields > 0 then
      self:_logRejected(fields)
    end
    -- Whatever was rejected is dropped: it would be refused again. If a full batch has built up while
    -- this one was on its way, it goes now.
    local batch = self.gameBatch
    if batch and #self.gameQueue >= batch.maxEvents then
      self:_flushGame()
    end
    return
  end
  -- Only the status is logged: never an item, a label or an id.
  self.log("debug", "could not send game events (status " .. tostring(status) .. ")")
  if status == 429 then
    self:_requeue(taken)
    local wait = tonumber(headerOf(headers, "retry-after"))
    if not positive(wait) then
      wait = GAME_BACKOFF_SECONDS
    end
    self:_holdGame(math.min(GAME_HOLD_MAX_SECONDS, wait))
  elseif status == 422 then
    local decoded = type(responseBody) == "string" and self:_decode(responseBody) or nil
    local rejected = decoded and type(decoded.rejected) == "table" and decoded.rejected or {}
    local refused = {}
    for _, entry in ipairs(rejected) do
      if type(entry) == "table" and type(entry.index) == "number" then
        refused[entry.index + 1] = true -- the API counts from zero
      end
    end
    local fields = rejectedFields(rejected)
    self:_logRejected(fields)
    -- Drop only what the API named. If it named none of them (or all), they are all dropped: sending
    -- them again would be refused again.
    local kept = {}
    for i, entry in ipairs(taken) do
      if not refused[i] then
        kept[#kept + 1] = entry
      end
    end
    if #kept < #taken and #kept > 0 then
      self:_requeue(kept)
    end
  elseif status == 401 or status == 402 or status == 403 then
    -- The key or the account is not usable: stop for a while, and what is waiting is not sent later.
    self.gameBackoffUntil = self.now() + GAME_REFUSED_BACKOFF_SECONDS
    self.gameQueue = {}
    local decoded = status == 403 and type(responseBody) == "string" and self:_decode(responseBody) or nil
    if decoded and decoded.error == "game_events_disabled" then
      -- The operator switched them off: off until the next settings refresh says otherwise.
      self.gameBackoffUntil = 0
      self:_applyGameConfig(false, nil)
    end
  elseif status == nil or status >= 500 then
    -- No answer, or the API is struggling: keep them and try again, a little longer each time.
    self:_requeue(taken)
    local wait = math.min(GAME_RETRY_MAX_SECONDS, GAME_RETRY_FIRST_SECONDS * 2 ^ self.gameRetryFails)
    self.gameRetryFails = self.gameRetryFails + 1
    self:_holdGame(wait)
  end
  -- Any other answer (a 400, 404, 413 ...) is not going to change by trying again: dropped, as a
  -- single event would be.
end

--- Logs that the API refused some events, with the names of the fields (never what was in them), once in
-- a while.
function Guard:_logRejected(fields)
  local now = self.clock()
  if self.gameRejectLoggedAt and now - self.gameRejectLoggedAt < GAME_REJECT_LOG_SECONDS then
    return
  end
  self.gameRejectLoggedAt = now
  self.log("warn", "ServerGuardian refused some game events (fields: " .. (#fields > 0 and table.concat(fields, ", ") or "unknown") .. ")")
end

--- Called by the platform's timer about every second (GAME_TICK_SECONDS): sends what is waiting once
-- the oldest event has waited `flushSeconds`, or the queue holds a full batch. Does nothing when game
-- events are off, not batched, or nothing is waiting.
function Guard:tick()
  self:_dropStale()
  self:_reportDrops()
  local batch = self.gameBatch
  local oldest = self.gameQueue[1]
  if not batch or not oldest then
    return
  end
  if #self.gameQueue >= batch.maxEvents or self.clock() - oldest.at >= batch.flushSeconds then
    self:_flushGame()
  end
end

--- Sends what is waiting now (up to one batch), whatever its age: for when the platform is stopping.
-- Best effort, and the answer is not waited for.
function Guard:flushGameEvents()
  self:_flushGame()
end

--- A player spawned something (`item` is its short name). Sent only if game events are on.
function Guard:spawn(playerKey, joinEventId, label, item)
  self:gameEvent({
    playerKey = playerKey,
    joinEventId = joinEventId,
    label = label,
    type = "spawn",
    item = item,
  })
end

--- A player changed something they had spawned (a vehicle's parts or paint). Sent only if game events
-- are on, and only to an API that lists "edit" among the kinds it takes.
function Guard:edit(playerKey, joinEventId, label, item)
  self:gameEvent({
    playerKey = playerKey,
    joinEventId = joinEventId,
    label = label,
    type = "edit",
    item = item,
  })
end

--- A player's vehicle or item is gone (they deleted it). Same conditions as Guard:edit, for "remove".
function Guard:remove(playerKey, joinEventId, label, item)
  self:gameEvent({
    playerKey = playerKey,
    joinEventId = joinEventId,
    label = label,
    type = "remove",
    item = item,
  })
end

--- Takes a position sample for a player or a vehicle and sends a flag for anything the checks do not
-- believe. `key` tells one track from another. The position is used here and goes no further.
function Guard:samplePosition(playerKey, key, joinEventId, label, x, y, z)
  if not self.gameChecks or not self:_gameActive() then
    return
  end
  if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
    return
  end
  local flags =
    self.tracker:sample(key, self.clock(), x, y, z, self.gameChecks, tostring(playerKey), self.coarseClock)
  for _, flag in ipairs(flags) do
    self:gameEvent({
      playerKey = playerKey,
      joinEventId = joinEventId,
      label = label,
      type = "flag",
      check = flag.check,
      severity = flag.severity,
    })
  end
end

return M
