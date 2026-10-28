-- ServerGuardian for FiveM (server resource).
--
-- When a player connects it shows the ServerGuardian notice, offers the optional hardware check
-- (once per notice version), asks the ServerGuardian API whether the player may join, and refuses
-- the connection with a fixed message if the answer is "block". The server only ever learns pass or
-- block. See docs/mods.md.

local function log(level, message)
  -- Fixed messages only: never a player's name, address, id or token.
  print(string.format("[ServerGuardian] %s: %s", level, message))
end

local apiKey = GetConvar("serverguardian_api_key", "")
local apiBase = GetConvar("serverguardian_api_base", "")

local guard = nil
local pending = {} -- temporary connecting id -> event id of the check
local joins = {} -- permanent player id -> event id, to report the leave

if not apiKey:match("^sg_[%w]+_[%w_%-]+$") then
  log("error", "not started: set serverguardian_api_key in server.cfg to your ServerGuardian key")
elseif not apiBase:match("^https?://[%w%.%-:]+$") then
  log("error", "not started: set serverguardian_api_base in server.cfg (for example https://api.example.com)")
else
  -- PerformHttpRequest has no timeout of its own, so one is added: whichever of the answer and the
  -- timer comes first is used and the other is ignored.
  local function http(method, path, body, callback)
    local settled = false
    local function finish(status, response)
      if settled then
        return
      end
      settled = true
      callback(status, response)
    end
    SetTimeout(Config.timeoutMs, function()
      finish(nil, nil)
    end)
    PerformHttpRequest(apiBase .. path, function(status, response)
      finish(status ~= 0 and status or nil, response)
    end, method, body and json.encode(body) or "", {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. apiKey,
    })
  end

  guard = ServerGuardianCore.new({
    apiBase = apiBase,
    failMode = Config.failMode,
    http = http,
    json = json,
    log = log,
    prefix = "fx",
  })
  guard:refreshConfig(function(ok)
    log("info", ok and "started" or "started with the built-in wording (could not reach the API)")
  end, true)
end

-- Splits "kind:value" identifiers into what the API accepts. FiveM's Steam ids are hexadecimal; the
-- API turns them into the decimal form Steam itself uses, so they can be matched with a Steam sign-in.
local function collectIdentity(src)
  local ip = nil
  local platformIds = {}
  local license = nil
  for _, identifier in ipairs(GetPlayerIdentifiers(src)) do
    local kind, value = identifier:match("^(%w+):(.+)$")
    if kind == "ip" then
      ip = value
    elseif kind == "license" then
      license = value
      platformIds[#platformIds + 1] = { type = "cfx_license", id = value }
    elseif kind == "steam" then
      platformIds[#platformIds + 1] = { type = "steam", id = value }
    end
  end
  if not ip then
    local endpoint = GetPlayerEndpoint(src)
    if type(endpoint) == "string" then
      ip = endpoint:match("^%[?([^%]]+)%]?:%d+$") or endpoint
    end
  end
  return ip, platformIds, license
end

local function collectTokens(src)
  local tokens = {}
  local count = GetNumPlayerTokens(src) or 0
  for index = 0, math.min(count, 8) - 1 do
    local token = GetPlayerToken(src, index)
    if type(token) == "string" and token ~= "" then
      tokens[#tokens + 1] = token
    end
  end
  return tokens
end

-- What a player chose is remembered on this server, against a hash of their license, together with
-- the wording version it was chosen under. A new wording version asks again.
local function consentKey(license)
  return "sg:c:" .. tostring(GetHashKey(license))
end

local function storedChoice(license)
  local value = GetResourceKvpString(consentKey(license))
  if not value then
    return nil
  end
  local version, choice = value:match("^(.-)|(%a+)$")
  if version == guard.wording.noticeVersion and (choice == "granted" or choice == "declined") then
    return choice
  end
  return nil
end

local function promptCard(wording)
  return {
    type = "AdaptiveCard",
    ["$schema"] = "http://adaptivecards.io/schemas/adaptive-card.json",
    version = "1.3",
    body = {
      { type = "TextBlock", text = wording.notice, wrap = true, size = "Small" },
      { type = "TextBlock", text = wording.optInTitle, wrap = true, weight = "Bolder" },
      { type = "TextBlock", text = wording.optInBody, wrap = true },
    },
    actions = {
      { type = "Action.Submit", title = wording.optInYes, data = { choice = "yes" } },
      { type = "Action.Submit", title = wording.optInNo, data = { choice = "no" } },
    },
  }
end

-- Asks the player about the hardware check. There is no default: closing the window or running out
-- of time is "not answered", never a yes.
local function askHardwareChoice(deferrals)
  local answer = nil
  deferrals.presentCard(json.encode(promptCard(guard.wording)), function(data)
    if type(data) == "table" and (data.choice == "yes" or data.choice == "no") then
      answer = data.choice
    end
  end)
  local waited = 0
  while answer == nil and waited < Config.promptTimeoutMs do
    Wait(100)
    waited = waited + 100
  end
  if answer == "yes" then
    return "granted"
  elseif answer == "no" then
    return "declined"
  end
  return nil
end

AddEventHandler("playerConnecting", function(_name, _setKickReason, deferrals)
  local src = source
  deferrals.defer()
  Wait(0)
  if not guard then
    deferrals.done()
    return
  end
  guard:refreshConfig(nil, false)

  local ip, platformIds, license = collectIdentity(src)
  if not ip or #platformIds == 0 then
    -- Nothing stable to check: let them in, and send nothing.
    deferrals.done()
    return
  end

  local consent = nil
  if Config.collectHardware and license then
    consent = storedChoice(license)
    if consent == nil then
      -- The prompt carries the notice, so a player who has not been asked sees both together.
      local answered = askHardwareChoice(deferrals)
      if answered ~= nil then
        SetResourceKvp(consentKey(license), guard.wording.noticeVersion .. "|" .. answered)
        consent = answered
      end
    end
  end
  -- Every player sees the notice on every join, even when they have already chosen.
  deferrals.update(guard.wording.notice)
  Wait(0)

  local input = { ip = ip, platformIds = platformIds }
  if consent == "granted" then
    input.hardware = { consent = "granted", hwids = collectTokens(src) }
  elseif consent == "declined" then
    input.hardware = { consent = "declined" }
  end

  guard:check(input, function(decision)
    pending[src] = decision.eventId
    if decision.action == "deny" then
      deferrals.done(decision.message)
    else
      deferrals.done()
    end
  end)
end)

-- The id a player has while connecting is temporary: playerJoining gives the permanent one.
AddEventHandler("playerJoining", function(temporaryId)
  local eventId = pending[temporaryId]
  pending[temporaryId] = nil
  if eventId then
    joins[source] = eventId
  end
end)

AddEventHandler("playerDropped", function()
  local eventId = joins[source]
  joins[source] = nil
  if guard and eventId then
    guard:leave(eventId)
  end
end)

-- /sgconsent clears the player's stored hardware-check choice, so they are asked again next time.
RegisterCommand("sgconsent", function(src)
  if src == 0 or not guard then
    return
  end
  local _, _, license = collectIdentity(src)
  if license then
    DeleteResourceKvp(consentKey(license))
  end
  local consentUrl = guard.wording.links and guard.wording.links.consent or ""
  TriggerClientEvent("chat:addMessage", src, {
    args = {
      "ServerGuardian",
      "Your hardware check choice was cleared. You will be asked again the next time you join. "
        .. consentUrl,
    },
  })
end, false)
