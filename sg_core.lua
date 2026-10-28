-- ServerGuardian mod core. Platform-independent: the BeamMP plugin and the FiveM resource each ship
-- an identical copy of this file (mods/sync-core.sh copies it; a test checks they match).
--
-- Written for Lua 5.3 (BeamMP) and 5.4 (FiveM). It makes no platform calls itself: the platform file
-- passes in an HTTP function, a JSON codec and a logger.
--
-- Privacy rules this file enforces (docs/mods.md):
--   * it never logs an IP address, player id, hardware id or name, only fixed messages and counts;
--   * it sends nothing but the fields of the join-check and action contracts, and sends no hardware id
--     unless the player explicitly said yes;
--   * a blocked player is told only the fixed wording from the API, never why.

ServerGuardianCore = ServerGuardianCore or {}
local M = ServerGuardianCore

M.VERSION = "0.2.0"

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

local PLATFORM_ID_TYPES = { beammp = true, cfx_license = true, minecraft_uuid = true, steam = true }
local MAX_PLATFORM_IDS = 8
local ACTION_TYPES = { ban = true, kick = true, warn = true, mute = true }
local MAX_REASON_BYTES = 500 -- the API's limit is 500 characters, and a character is at least a byte
local MAX_DURATION_HOURS = 24 * 365 * 10
local MAX_HARDWARE_TOKENS = 8
local CONFIG_REFRESH_SECONDS = 3600

local Guard = {}
Guard.__index = Guard

--- Creates a guard.
-- opts.apiBase       API address without a trailing slash
-- opts.failMode      "open" (default) or "closed": what to do when we cannot be reached
-- opts.http          function(method, path, bodyTable_or_nil, callback) ; callback(status, bodyString)
--                    status is nil when the request failed or timed out
-- opts.json          { encode = fn, decode = fn }
-- opts.log           function(level, message) ; messages never contain player data
-- opts.now           function() -> seconds (default os.time)
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
        self.configFetchedAt = now
        ok = true
      end
    end
    if not ok then
      self.log("warn", "could not load ServerGuardian settings, using the built-in wording")
    end
    if callback then
      callback(ok)
    end
  end)
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

--- Tidies text an operator typed into a reason: no control characters, one space between words, no
-- more than the API accepts (cut on a character boundary so the JSON stays valid UTF-8). Returns nil
-- when nothing is left.
local function cleanReason(text)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if text == "" then
    return nil
  end
  if #text > MAX_REASON_BYTES then
    local cut = MAX_REASON_BYTES
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

return M
