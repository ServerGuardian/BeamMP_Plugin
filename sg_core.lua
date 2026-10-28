-- ServerGuardian mod core. Platform-independent: the BeamMP plugin and the FiveM resource each ship
-- an identical copy of this file (mods/sync-core.sh copies it; a test checks they match).
--
-- Written for Lua 5.3 (BeamMP) and 5.4 (FiveM). It makes no platform calls itself: the platform file
-- passes in an HTTP function, a JSON codec and a logger.
--
-- Privacy rules this file enforces (docs/mods.md):
--   * it never logs an IP address, player id, hardware id or name, only fixed messages and counts;
--   * it sends nothing but the fields of the join-check contract, and sends no hardware id unless the
--     player explicitly said yes;
--   * a blocked player is told only the fixed wording from the API, never why.

ServerGuardianCore = ServerGuardianCore or {}
local M = ServerGuardianCore

M.VERSION = "0.1.0"

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

--- Checks the input has what the contract needs. Returns nil and a short reason if not.
local function validate(input)
  if type(input) ~= "table" then
    return nil, "no_input"
  end
  if type(input.ip) ~= "string" or input.ip == "" or #input.ip > 64 then
    return nil, "no_ip"
  end
  if type(input.platformIds) ~= "table" or #input.platformIds < 1 or #input.platformIds > MAX_PLATFORM_IDS then
    return nil, "no_platform_id"
  end
  for _, platformId in ipairs(input.platformIds) do
    if
      type(platformId) ~= "table"
      or not PLATFORM_ID_TYPES[platformId.type]
      or type(platformId.id) ~= "string"
      or platformId.id == ""
      or #platformId.id > 128
    then
      return nil, "bad_platform_id"
    end
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

return M
