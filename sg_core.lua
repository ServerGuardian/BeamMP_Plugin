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
--   * a game event (a spawn, or a movement flag) carries the id of the player's join, a short label,
--     and either an item name or the kind of check: never a position, a coordinate, chat, an address
--     or a platform id. The movement checks run here, on the game server, and send only a flag;
--   * a blocked player is told only the fixed wording from the API, never why.

ServerGuardianCore = ServerGuardianCore or {}
local M = ServerGuardianCore

M.VERSION = "0.5.0"

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
local GAME_SPAWNS_PER_PLAYER_WINDOW = 20 -- spawns and flags have a limit each, so spam of one cannot starve the other
local GAME_FLAGS_PER_PLAYER_WINDOW = 10
local GAME_EVENT_WINDOW_SECONDS = 60
local GAME_EVENTS_PER_SERVER_WINDOW = 400
local GAME_BACKOFF_SECONDS = 60 -- after a 429
local GAME_REFUSED_BACKOFF_SECONDS = 600 -- after a 401, 402 or 403: the key or the account is not usable
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


--- Creates a guard.
-- opts.apiBase       API address without a trailing slash
-- opts.failMode      "open" (default) or "closed": what to do when we cannot be reached
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
  self.failMode = opts.failMode == "closed" and "closed" or "open"
  self.wording = M.DEFAULT_WORDING
  self.reportWording = M.DEFAULT_REPORT_WORDING
  self.reportsEnabled = false -- the operator turns reports on in the portal; absent means off
  self.reportPending = {} -- player key -> { fingerprint, at }: a report waiting for its confirmation
  self.reportConfirmed = {} -- player key -> true once they have seen the notice and confirmed
  self.reportSent = {} -- player key -> list of times a report was sent, for the player's own limit
  self.clock = opts.clock or self.now -- seconds, and finer than a second where the platform allows
  self.coarseClock = opts.clock == nil -- the movement checks only have whole seconds
  self.gameEnabled = false -- the operator turns game events on in the portal; absent means off
  self.gameChecks = nil
  self.gameBackoffUntil = 0
  self.gameSpawnSent = {} -- player key -> list of times a spawn was sent
  self.gameFlagSent = {} -- player key -> list of times a flag was sent
  self.gameServerSent = {} -- times of every game event sent, for the whole server
  self.tracker = M.newTracker()
  self.onGameConfig = nil -- set by the platform: called when game events are switched on or off
  self.configFetchedAt = nil
  self.counter = 0
  self.stats = { checks = 0, passes = 0, blocks = 0, errors = 0, skipped = 0 }
  return self
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
        if decoded.failMode == "open" or decoded.failMode == "closed" then
          self.failMode = decoded.failMode
        end
        self.reportsEnabled = type(decoded.reports) == "table" and decoded.reports.enabled == true
        local defaults = M.DEFAULT_REPORT_WORDING
        local categories = type(en.reportCategories) == "table" and en.reportCategories or nil
        self.reportWording = {
          notice = type(en.reportNotice) == "string" and en.reportNotice or defaults.notice,
          thanks = type(en.reportThanks) == "string" and en.reportThanks or defaults.thanks,
          tooMany = type(en.reportTooMany) == "string" and en.reportTooMany or defaults.tooMany,
          categories = categories or defaults.categories,
        }
        self:_setGameConfig(decoded.gameEvents)
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
  self:_applyGameConfig(true, checks)
end

function Guard:_applyGameConfig(enabled, checks)
  local oldChecks = self.gameChecks
  local changed = enabled ~= self.gameEnabled
    or (oldChecks == nil) ~= (checks == nil)
    or (oldChecks ~= nil and checks ~= nil and oldChecks.sampleSeconds ~= checks.sampleSeconds)
  self.gameEnabled = enabled
  self.gameChecks = checks
  if not checks then
    self.tracker = M.newTracker() -- nothing is kept while the checks are off
  end
  if not enabled then
    self.gameSpawnSent = {}
    self.gameFlagSent = {}
    self.gameServerSent = {}
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
-- Game events (decision D41, group 2): spawns, and flags from the movement checks.
-- ---------------------------------------------------------------------------------------------------

--- The id of a game event. Opaque, and unique for this server.
function Guard:_gameEventId()
  self.counter = self.counter + 1
  return string.format("ev-%s-%x-%x", self.prefix, self.now(), self.counter)
end

--- True when this player may have another event of this kind ("spawn" or "flag") sent now, counting
-- it if so. Keeps the server well inside the API's own limit, and one busy player from using it all;
-- spawns and flags are counted separately so spam of one does not hide the other.
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
  local sent = kind == "flag" and self.gameFlagSent or self.gameSpawnSent
  local limit = kind == "flag" and GAME_FLAGS_PER_PLAYER_WINDOW or GAME_SPAWNS_PER_PLAYER_WINDOW
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

--- Forgets everything kept about a player (they left): their limits and their flag cooldowns.
function Guard:forgetGamePlayer(playerKey)
  playerKey = tostring(playerKey)
  self.gameSpawnSent[playerKey] = nil
  self.gameFlagSent[playerKey] = nil
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

--- Sends one game event. `body` has the type's own fields; the id, the join reference and the label
-- are added here. Nothing is sent while game events are off or backed off, for a player with no join
-- reference, or past the limits. Quiet on every failure: nothing depends on it.
-- input: { playerKey, joinEventId, label (optional), type = "spawn" | "flag", item | check + severity }
-- callback (optional) receives true when the API accepted it.
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
  local body = {
    eventId = self:_gameEventId(),
    joinEventId = input.joinEventId,
    type = input.type,
    label = gameText(input.label, MAX_LABEL),
  }
  if input.type == "spawn" then
    body.item = gameText(input.item, MAX_ITEM) or "vehicle"
  elseif input.type == "flag" then
    body.check = input.check
    body.severity = input.severity
  else
    return done(false)
  end
  if not self:_gameAllowance(tostring(input.playerKey), input.type) then
    return done(false)
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
