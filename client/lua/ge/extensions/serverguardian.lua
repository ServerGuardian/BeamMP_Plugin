-- ServerGuardian client mod for BeamMP: shows the server's ServerGuardian join notice as a popup once the
-- loading screen is gone, and tells the server it did. See ../../../README.md for the protocol.
--
-- BeamNG runs this on LuaJIT (Lua 5.1): no goto, no utf8 library, no integer division, no bit operators.
-- Everything the server sends is untrusted text. Nothing here throws, stores anything, or makes a network
-- call, and nothing the server sent is ever written to the log.

local M = {}

local EXT_NAME = "serverguardian"
local MOD_VERSION = "0.1.0"
local PROTOCOL_VERSION = 1
local LOG_TAG = "ServerGuardian"
local POPUP_ID = "serverguardianNotice"

local EVENT_NOTICE = "sgNotice" -- server -> client
local EVENT_READY = "sgClientReady" -- client -> server
local EVENT_SHOWN = "sgNoticeShown" -- client -> server
local EVENT_CLOSED = "sgNoticeClosed" -- client -> server

local DEFAULT_TITLE = "ServerGuardian"
local DEFAULT_BUTTON = "I understand"

local MAX_PAYLOAD_BYTES = 100000
local MAX_TITLE = 80
local MAX_BUTTON = 40
local MAX_TEXT = 2000
local MAX_EXTRA_LINES = 5
local MAX_EXTRA_LINE = 300
local MAX_VERSION = 100

local state = {
  registered = false, -- AddEventHandler("sgNotice", ...) has been called
  -- Per join (reset at a loading-screen fade-out, see startNewJoin):
  readySent = false, -- sgClientReady has been sent
  worldReady = false, -- the loading screen has faded out
  pending = nil, -- a valid notice that arrived before the loading screen was gone
  shown = false, -- the popup was opened (once per join)
  closedSent = false,
  noticeVersion = "",
  warned = {},
}

-- Logging: fixed lines only, never anything the server sent. -------------------------------------------------

local function say(level, message)
  if type(log) == "function" then
    pcall(log, level, LOG_TAG, message)
  end
end

local function warnOnce(key, message)
  if state.warned[key] then
    return
  end
  state.warned[key] = true
  say("W", message)
end

-- Cleaning text ----------------------------------------------------------------------------------------------

-- The length of the well-formed UTF-8 sequence that starts at byte i of s (a lead byte of 0xC2 or more), or nil.
local function sequenceLength(s, i)
  local b1 = s:byte(i)
  if b1 >= 0xC2 and b1 <= 0xDF then
    local b2 = s:byte(i + 1)
    if b2 and b2 >= 0x80 and b2 <= 0xBF then
      return 2
    end
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    local b2, b3 = s:byte(i + 1, i + 2)
    if b2 and b3 and b3 >= 0x80 and b3 <= 0xBF then
      local lo, hi = 0x80, 0xBF
      if b1 == 0xE0 then
        lo = 0xA0
      elseif b1 == 0xED then
        hi = 0x9F -- no surrogates
      end
      if b2 >= lo and b2 <= hi then
        return 3
      end
    end
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    local b2, b3, b4 = s:byte(i + 1, i + 3)
    if b2 and b3 and b4 and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
      local lo, hi = 0x80, 0xBF
      if b1 == 0xF0 then
        lo = 0x90
      elseif b1 == 0xF4 then
        hi = 0x8F
      end
      if b2 >= lo and b2 <= hi then
        return 4
      end
    end
  end
  return nil
end

-- Multi-byte characters that are dropped: C1 controls, byte order mark, line and paragraph separators,
-- and the bidirectional overrides and isolates that can make text read differently from how it is stored.
local function isDroppedCharacter(ch)
  local n = #ch
  if n == 2 then
    local b1, b2 = ch:byte(1, 2)
    return b1 == 0xC2 and b2 >= 0x80 and b2 <= 0x9F
  elseif n == 3 then
    local b1, b2, b3 = ch:byte(1, 3)
    if b1 == 0xEF and b2 == 0xBB and b3 == 0xBF then
      return true
    end
    if b1 == 0xE2 and b2 == 0x80 and ((b3 >= 0xAA and b3 <= 0xAE) or b3 == 0xA8 or b3 == 0xA9) then
      return true
    end
    if b1 == 0xE2 and b2 == 0x81 and b3 >= 0xA6 and b3 <= 0xA9 then
      return true
    end
  end
  return false
end

-- A clean copy of a string, at most maxChars characters long: well-formed UTF-8 only (a bad byte becomes
-- "?"), no control characters (a tab is a space), and newlines kept only when multiline is true (otherwise a
-- space). Returns "" for anything that is not a string.
local function cleanText(value, maxChars, multiline)
  if type(value) ~= "string" then
    return ""
  end
  value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
  local out, count, i, len = {}, 0, 1, #value
  while i <= len and count < maxChars do
    local b = value:byte(i)
    if b < 0x80 then
      if b == 10 then
        out[#out + 1] = multiline and "\n" or " "
        count = count + 1
      elseif b == 9 then
        out[#out + 1] = " "
        count = count + 1
      elseif b >= 32 and b ~= 127 then
        out[#out + 1] = string.char(b)
        count = count + 1
      end
      i = i + 1
    else
      local n = sequenceLength(value, i)
      if n then
        local ch = value:sub(i, i + n - 1)
        if not isDroppedCharacter(ch) then
          out[#out + 1] = ch
          count = count + 1
        end
        i = i + n
      else
        out[#out + 1] = "?"
        count = count + 1
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

local function trim(s)
  local a = s:find("%S")
  if not a then
    return ""
  end
  local b = #s
  while b > a and s:sub(b, b):find("%s") do
    b = b - 1
  end
  return s:sub(a, b)
end

-- One line of plain text for the popup title or button. Both are rendered as text by the game's popup
-- (Vue text interpolation), so they are not HTML-escaped (that would show "&amp;"), but < and > are removed so
-- that no tag can exist even if a game version rendered them as HTML.
local function cleanLabel(value, maxChars, default)
  local s = trim((cleanText(value, maxChars, false):gsub("[<>]", "")))
  if s == "" then
    return default
  end
  return s
end

-- Building the popup HTML -------------------------------------------------------------------------------------

-- The popup text goes through the game's translate and BBCode/markdown parser and then into v-html, so
-- besides the HTML characters, { } (translation placeholders) and [ ] * (BBCode and markdown, which the
-- game turns into links, images and styled spans) are written as numeric entities too.
local ESCAPES = {
  ["&"] = "&amp;",
  ["<"] = "&lt;",
  [">"] = "&gt;",
  ['"'] = "&quot;",
  ["'"] = "&#39;",
  ["{"] = "&#123;",
  ["}"] = "&#125;",
  ["["] = "&#91;",
  ["]"] = "&#93;",
  ["*"] = "&#42;",
}

local function escapeHtml(s)
  return (s:gsub("[&<>\"'{}%[%]%*]", ESCAPES))
end

-- In the escaped text, an entity that ends a link (the character behind it is not part of the address).
local LINK_STOPS = {
  ["&lt;"] = true,
  ["&gt;"] = true,
  ["&quot;"] = true,
  ["&#39;"] = true,
  ["&#123;"] = true,
  ["&#125;"] = true,
  ["&#91;"] = true,
  ["&#93;"] = true,
}
local UNESCAPE = { ["&amp;"] = "&", ["&#42;"] = "*" }

-- The game turns any whitespace followed by http:// or https:// in the text into its own link control. Text
-- that is not one of our links gets the colon written as an entity, so that cannot happen to it.
local function defang(s)
  return (s:gsub("([Hh][Tt][Tt][Pp][Ss]?):", "%1&#58;"))
end

local function isAlnum(c)
  return c ~= "" and c:find("^[A-Za-z0-9]$") ~= nil
end

local function count(s, ch)
  local _, n = s:gsub(ch, "")
  return n
end

-- Takes the escaped text; returns it with every http:// or https:// address made a link.
local function linkify(escaped)
  local out, pos, len = {}, 1, #escaped
  while pos <= len do
    local s, e = escaped:find("[Hh][Tt][Tt][Pp][Ss]?://", pos)
    if not s then
      break
    end
    local linked = false
    if s == 1 or not isAlnum(escaped:sub(s - 1, s - 1)) then
      local j = e + 1
      while j <= len do
        local c = escaped:sub(j, j)
        if c:find("%s") then
          break
        elseif c == "&" then
          local entity = escaped:match("^&#?%w+;", j)
          if entity == nil or LINK_STOPS[entity] then
            break
          end
          j = j + #entity
        else
          j = j + 1
        end
      end
      local url = escaped:sub(s, j - 1)
      -- A link does not end with sentence punctuation, a closing bracket that has no opener, or an ampersand.
      local trimming = true
      while trimming do
        trimming = false
        if url:sub(-5) == "&amp;" then
          url, trimming = url:sub(1, -6), true
        elseif url:sub(-6) == "&#42;" then
          url, trimming = url:sub(1, -7), true
        else
          local last = url:sub(-1)
          if last:find("^[%.,;:!%?]$") then
            url, trimming = url:sub(1, -2), true
          elseif last == ")" and count(url, "%)") > count(url, "%(") then
            url, trimming = url:sub(1, -2), true
          end
        end
      end
      local scheme, rest = url:match("^(%a+)(://.*)$")
      if scheme and rest:find("^://[A-Za-z0-9]") then
        local raw = url:gsub("&#?%w+;", function(entity)
          return UNESCAPE[entity] or entity
        end)
        raw = raw:gsub("^%a+", string.lower, 1)
        -- Percent-encoded so that nothing in it can end the attribute or add a parameter to the proxy address.
        local encoded = raw:gsub("[^A-Za-z0-9%%%-%._~:/%?=@]", function(c)
          return string.format("%%%02X", c:byte())
        end)
        out[#out + 1] = defang(escaped:sub(pos, s - 1))
        -- class before href: the game rewrites a link that starts <a href=" into a control that does nothing here.
        out[#out + 1] = '<a class="sg-link" href="http-external://www.beamng.com/proxy.php?link='
          .. encoded .. '">' .. url .. "</a>"
        pos = s + #url
        linked = true
      end
    end
    if not linked then
      out[#out + 1] = defang(escaped:sub(pos, e))
      pos = e + 1
    end
  end
  if pos <= len then
    out[#out + 1] = defang(escaped:sub(pos))
  end
  return table.concat(out)
end

-- The escaped text as paragraphs: a blank line ends one, a single newline is a line break inside it.
local function paragraphs(escaped, convert)
  local html, lines = {}, {}
  local function flush()
    if #lines > 0 then
      html[#html + 1] = "<p>" .. table.concat(lines, "<br>") .. "</p>"
      lines = {}
    end
  end
  for line in (escaped .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("^%s*$") then
      flush()
    else
      lines[#lines + 1] = convert(trim(line))
    end
  end
  flush()
  return table.concat(html)
end

local STYLE = "<style>"
  .. ".sg-notice{line-height:1.45;overflow-wrap:anywhere;word-break:break-word}"
  .. ".sg-notice p{margin:0 0 .8em}"
  .. ".sg-notice a.sg-link{color:#f60;text-decoration:underline}"
  .. ".sg-notice .sg-extra{margin-top:1em;padding-top:.8em;border-top:1px solid rgba(255,255,255,.3)}"
  .. "</style>"

local function buildHtml(notice)
  local parts = { STYLE, '<div class="sg-notice">', paragraphs(escapeHtml(notice.text), linkify) }
  if #notice.extra > 0 then
    parts[#parts + 1] = '<div class="sg-extra">'
    for _, line in ipairs(notice.extra) do
      parts[#parts + 1] = "<p>" .. defang(escapeHtml(line)) .. "</p>"
    end
    parts[#parts + 1] = "</div>"
  end
  parts[#parts + 1] = "</div>"
  return table.concat(parts)
end

-- Reading the server's notice ------------------------------------------------------------------------------------

-- The notice as a table (title, button, text, extra, version) or nil if the payload cannot be used. Nothing
-- from the payload is logged.
local function parseNotice(data)
  if type(data) ~= "string" or #data == 0 or #data > MAX_PAYLOAD_BYTES then
    return nil
  end
  local body = trim(data)
  -- Only text that looks like a JSON object reaches the game's decoder, which logs what it could not read.
  if body:sub(1, 1) ~= "{" or body:sub(-1) ~= "}" then
    return nil
  end
  if type(jsonDecode) ~= "function" then
    warnOnce("jsonDecode", "jsonDecode is not available, cannot read the notice")
    return nil
  end
  local ok, obj = pcall(jsonDecode, body, "ServerGuardian notice")
  if not ok or type(obj) ~= "table" then
    return nil
  end
  if type(obj.v) ~= "number" or obj.v ~= PROTOCOL_VERSION then
    return nil
  end
  local text = trim(cleanText(obj.text, MAX_TEXT, true))
  if text == "" then
    return nil
  end
  local extra = {}
  if type(obj.extra) == "table" then
    local last = #obj.extra
    if last > 50 then
      last = 50
    end
    for i = 1, last do
      if #extra >= MAX_EXTRA_LINES then
        break
      end
      local line = trim(cleanText(obj.extra[i], MAX_EXTRA_LINE, false))
      if line ~= "" then
        extra[#extra + 1] = line
      end
    end
  end
  return {
    title = cleanLabel(obj.title, MAX_TITLE, DEFAULT_TITLE),
    button = cleanLabel(obj.button, MAX_BUTTON, DEFAULT_BUTTON),
    text = text,
    extra = extra,
    version = trim(cleanText(obj.noticeVersion, MAX_VERSION, false)),
  }
end

-- Talking to the server ---------------------------------------------------------------------------------------------

local function jsonString(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

local function noticePayload(version)
  return '{"v":' .. PROTOCOL_VERSION .. ',"noticeVersion":' .. jsonString(version) .. "}"
end

local function sendEvent(name, payload)
  if type(TriggerServerEvent) ~= "function" then
    warnOnce("TriggerServerEvent", "TriggerServerEvent is not available, cannot tell the server")
    return false
  end
  if not pcall(TriggerServerEvent, name, payload) then
    say("W", "could not send " .. name .. " to the server")
    return false
  end
  return true
end

local function tryRegister(report)
  if state.registered then
    return true
  end
  if type(AddEventHandler) ~= "function" then
    if report then
      warnOnce("AddEventHandler", "AddEventHandler is not available, cannot listen for the notice")
    end
    return false
  end
  -- The third argument is the handler's source name (BeamMP defaults to the calling file); a second
  -- registration under the same name would replace this one instead of adding another.
  if not pcall(AddEventHandler, EVENT_NOTICE, M.onNotice, EXT_NAME) then
    say("W", "could not register the " .. EVENT_NOTICE .. " handler")
    return false
  end
  state.registered = true
  return true
end

-- Every loading-screen fade-out is taken to be a new join (the mod stays loaded when the player leaves one
-- server and joins another). The state of the previous join is wiped, so this join sends sgClientReady and
-- may show one notice, unless that would throw away something still in flight:
--   - a notice that is held (pending) is this join's notice, waiting for this very fade-out;
--   - a popup that is open and not yet confirmed closed may belong to the join that is still running (a
--     fade-out also happens for reasons other than a join), so it is left alone. A player who leaves a server
--     without pressing the button therefore gets no ready event or popup on the next server until they have.
-- `registered` and the warn-once flags are per session and are kept. Since the state only changes here, a
-- server can never get a second popup out of one fade-out.
local function startNewJoin()
  if state.pending or (state.shown and not state.closedSent) then
    return
  end
  state.readySent = false
  state.shown = false
  state.closedSent = false
  state.noticeVersion = ""
end

local function sendReady()
  if state.readySent then
    return
  end
  if sendEvent(EVENT_READY, '{"v":' .. PROTOCOL_VERSION .. ',"mod":"' .. MOD_VERSION .. '"}') then
    state.readySent = true
  end
end

local function showNotice(notice)
  if type(guihooks) ~= "table" or type(guihooks.trigger) ~= "function" then
    warnOnce("guihooks", "guihooks is not available, cannot show the notice")
    return false
  end
  local built, html = pcall(buildHtml, notice)
  if not built then
    say("W", "could not build the notice")
    return false
  end
  local opened = pcall(guihooks.trigger, "OpenTutorialPopup", {
    popups = {
      {
        type = "info",
        id = POPUP_ID,
        title = notice.title,
        buttonLabel = notice.button,
        text = html,
        flavour = "onlyOk",
        isPopup = true,
      },
    },
  })
  if not opened then
    say("W", "could not open the notice popup")
    return false
  end
  state.shown = true
  state.pending = nil
  state.noticeVersion = notice.version
  say("I", "notice shown")
  sendEvent(EVENT_SHOWN, noticePayload(notice.version))
  return true
end

-- BeamNG and BeamMP entry points (every one is wrapped so that nothing can throw into the game) -----------------

-- BeamMP calls this with the data string of an "sgNotice" event from the server.
M.onNotice = function(data)
  local ok = pcall(function()
    if state.shown or state.pending then
      say("I", "ignored a second notice")
      return
    end
    local notice = parseNotice(data)
    if not notice then
      say("W", "ignored a notice that could not be used")
      return
    end
    if not (state.worldReady and showNotice(notice)) then
      state.pending = notice -- shown at the next loading screen fade-out, if it could not be shown now
    end
  end)
  if not ok then
    say("W", "could not process a notice")
  end
end

M.onLoadingScreenFadeout = function()
  local ok = pcall(function()
    startNewJoin()
    state.worldReady = true
    tryRegister(true) -- before the ready event, so the server's answer cannot be missed
    sendReady()
    if state.pending and not state.shown then
      showNotice(state.pending)
    end
  end)
  if not ok then
    say("W", "could not run the loading screen hook")
  end
end

M.onExtensionLoaded = function()
  local ok = pcall(function()
    tryRegister(false) -- the BeamMP globals may not exist yet; the loading screen hook tries again
    if worldReadyState == 2 then
      M.onLoadingScreenFadeout()
    end
  end)
  if not ok then
    say("W", "could not start")
  end
end

-- The game's tutorial popup calls extensions.hook("onIntroPopupCareerClosed", <popup id>) when its button is
-- pressed (ui/ui-vue/src/modules/career/components/tutorial/TutorialPopupDialog.vue, finalizeClose).
M.onIntroPopupCareerClosed = function(id)
  pcall(function()
    if id ~= POPUP_ID or not state.shown or state.closedSent then
      return
    end
    state.closedSent = true
    sendEvent(EVENT_CLOSED, noticePayload(state.noticeVersion))
  end)
end

return M
