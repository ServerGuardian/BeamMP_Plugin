-- ServerGuardian client mod for BeamMP, report window: the server sends sgReportOpen (after the player typed
-- /report), this shows an imgui window with a player list, a reason list and a short note, sends the report as
-- sgReportSubmit, and shows the server's sgReportResult. See ../../../README.md for the protocol and for which
-- game source file each imgui call was taken from.
--
-- BeamNG runs this on LuaJIT (Lua 5.1): no goto, no utf8 library, no integer division, no bit operators.
-- Everything the server sends is untrusted text. Nothing here throws, stores anything, or makes a network
-- call, and nothing the server sent (and nothing the player typed) is ever written to the log.

local M = {}
M.dependencies = { "ui_imgui" } -- as the game's own imgui extensions declare it (ui/console.lua)

local EXT_NAME = "serverguardian" -- the BeamMP handler source name, the same as the notice extension
local MOD_VERSION = "0.1.0"
local PROTOCOL_VERSION = 1
local LOG_TAG = "ServerGuardian"

local EVENT_OPEN = "sgReportOpen" -- server -> client
local EVENT_RESULT = "sgReportResult" -- server -> client
local EVENT_SUBMIT = "sgReportSubmit" -- client -> server
local EVENT_READY = "sgReportReady" -- client -> server: this client can show the report window

local DEFAULT_TITLE = "Report a player"
local DEFAULT_SEND = "Send report"
local DEFAULT_CANCEL = "Cancel"

local MAX_PAYLOAD_BYTES = 100000
local MAX_TITLE = 80
local MAX_NOTICE = 1000
local MAX_LABEL = 60
local MAX_BUTTON = 40
local MAX_MESSAGE = 300
local MAX_PLAYERS = 100
local MAX_REASONS = 12
local MAX_ENTRIES_READ = 400 -- raw list entries looked at, however many are sent
local MAX_PLAYER_ID = 2147483647
local DEFAULT_NOTE_MAX = 200
local MAX_NOTE_MAX = 300
local OPEN_INTERVAL = 1 -- seconds between two attempts to open the window
local SUBMIT_TIMEOUT = 15 -- seconds to wait for sgReportResult before Send is enabled again
local MAX_FRAME_SECONDS = 5 -- one frame never advances the clock by more than this

local WINDOW_SUFFIX = "##serverguardianReport" -- the window id: stays the same whatever title the server sends

local state = {
  registered = { [EVENT_OPEN] = false, [EVENT_RESULT] = false },
  -- Per join (reset at a loading-screen fade-out, see resetJoin):
  readySent = false, -- sgReportReady has been sent
  win = nil, -- the open window (a table), or nil
  lastAttempt = nil, -- clock value of the last sgReportOpen that was looked at
  -- Per session:
  clock = 0, -- seconds, advanced by onUpdate
  warned = {},
}

-- Logging: fixed lines only, never anything the server sent or the player typed. ----------------------------------

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

-- imgui reads "##" and "###" inside a label as the start of the widget id and does not draw what follows.
-- Text with those in it would be cut short on screen, so a space is put between the hashes.
local function neutraliseHashes(s)
  while s:find("##", 1, true) do
    s = s:gsub("##", "# #")
  end
  return s
end

-- One line of plain text for a title, a name or a button.
local function cleanLabel(value, maxChars, default)
  local s = trim(neutraliseHashes(cleanText(value, maxChars, false)))
  if s == "" then
    return default
  end
  return s
end

-- Reading the server's messages -----------------------------------------------------------------------------------

-- Decodes a JSON object string with the game's jsonDecode, or returns nil. Only text that looks like a JSON
-- object reaches the decoder, which logs what it could not read.
local function decodeObject(data, context)
  if type(data) ~= "string" or #data == 0 or #data > MAX_PAYLOAD_BYTES then
    return nil
  end
  local body = trim(data)
  if body:sub(1, 1) ~= "{" or body:sub(-1) ~= "}" then
    return nil
  end
  if type(jsonDecode) ~= "function" then
    warnOnce("jsonDecode", "jsonDecode is not available, cannot read server messages")
    return nil
  end
  local ok, obj = pcall(jsonDecode, body, context)
  if not ok or type(obj) ~= "table" then
    return nil
  end
  if type(obj.v) ~= "number" or obj.v ~= PROTOCOL_VERSION then
    return nil
  end
  return obj
end

local function validPlayerId(id)
  return type(id) == "number" and id >= 0 and id <= MAX_PLAYER_ID and math.floor(id) == id
end

local function validReasonId(id)
  return type(id) == "string" and #id >= 1 and #id <= 40 and id:find("^[a-z_]+$") ~= nil
end

-- The sgReportOpen payload as a table (title, notice, noteMax, send, cancel, players, reasons) or nil if it
-- cannot be used. Nothing from the payload is logged.
local function parseOpen(data)
  local obj = decodeObject(data, "ServerGuardian report window")
  if not obj then
    return nil
  end
  local players, seenPlayers = {}, {}
  if type(obj.players) == "table" then
    for i = 1, math.min(#obj.players, MAX_ENTRIES_READ) do
      if #players >= MAX_PLAYERS then
        break
      end
      local entry = obj.players[i]
      if type(entry) == "table" and validPlayerId(entry.id) and not seenPlayers[entry.id] then
        seenPlayers[entry.id] = true
        players[#players + 1] = {
          id = entry.id,
          label = cleanLabel(entry.name, MAX_LABEL, "Player " .. string.format("%d", entry.id)),
        }
      end
    end
  end
  local reasons, seenReasons = {}, {}
  if type(obj.reasons) == "table" then
    for i = 1, math.min(#obj.reasons, MAX_ENTRIES_READ) do
      if #reasons >= MAX_REASONS then
        break
      end
      local entry = obj.reasons[i]
      if type(entry) == "table" and validReasonId(entry.id) and not seenReasons[entry.id] then
        seenReasons[entry.id] = true
        reasons[#reasons + 1] = { id = entry.id, label = cleanLabel(entry.label, MAX_LABEL, entry.id) }
      end
    end
  end
  if #players == 0 or #reasons == 0 then
    return nil
  end
  local noteMax = DEFAULT_NOTE_MAX
  if type(obj.noteMax) == "number" and obj.noteMax == obj.noteMax and obj.noteMax ~= math.huge
    and obj.noteMax ~= -math.huge then
    noteMax = math.floor(obj.noteMax)
    if noteMax < 1 then
      noteMax = 1
    elseif noteMax > MAX_NOTE_MAX then
      noteMax = MAX_NOTE_MAX
    end
  end
  return {
    title = cleanLabel(obj.title, MAX_TITLE, DEFAULT_TITLE),
    notice = trim(cleanText(obj.notice, MAX_NOTICE, true)),
    noteMax = noteMax,
    send = cleanLabel(obj.send, MAX_BUTTON, DEFAULT_SEND),
    cancel = cleanLabel(obj.cancel, MAX_BUTTON, DEFAULT_CANCEL),
    players = players,
    reasons = reasons,
  }
end

-- The sgReportResult payload as { ok, message } or nil.
local function parseResult(data)
  local obj = decodeObject(data, "ServerGuardian report result")
  if not obj or type(obj.ok) ~= "boolean" then
    return nil
  end
  local message = trim(cleanText(obj.message, MAX_MESSAGE, false))
  if message == "" then
    message = obj.ok and "Report sent." or "The report could not be sent."
  end
  return { ok = obj.ok, message = message }
end

-- Talking to the server ---------------------------------------------------------------------------------------------

local JSON_ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- A JSON string literal. Quotes, backslashes and every control character below 0x20 are escaped; anything else
-- (including multi-byte UTF-8, which the note has already been cleaned to be valid) is written as it is.
local function jsonString(s)
  local escaped = s:gsub('[%c\\"]', function(c)
    return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function submitPayload(targetId, reasonId, note)
  return '{"v":' .. PROTOCOL_VERSION .. ',"target":' .. string.format("%d", targetId) .. ',"reason":'
    .. jsonString(reasonId) .. ',"note":' .. jsonString(note) .. "}"
end

local function sendEvent(name, payload)
  if type(TriggerServerEvent) ~= "function" then
    warnOnce("TriggerServerEvent", "TriggerServerEvent is not available, cannot send the report")
    return false
  end
  if not pcall(TriggerServerEvent, name, payload) then
    say("W", "could not send " .. name .. " to the server")
    return false
  end
  return true
end

local function tryRegister(report)
  if type(AddEventHandler) ~= "function" then
    if report then
      warnOnce("AddEventHandler", "AddEventHandler is not available, cannot listen for report events")
    end
    return
  end
  local handlers = { [EVENT_OPEN] = M.onReportOpen, [EVENT_RESULT] = M.onReportResult }
  for _, event in ipairs({ EVENT_OPEN, EVENT_RESULT }) do
    if not state.registered[event] then
      -- The third argument is the handler's source name, as in the notice extension.
      if pcall(AddEventHandler, event, handlers[event], EXT_NAME) then
        state.registered[event] = true
      else
        say("W", "could not register the " .. event .. " handler")
      end
    end
  end
end

-- The window -----------------------------------------------------------------------------------------------------

local function closeWindow()
  state.win = nil
end

-- Every loading-screen fade-out is taken to be a new join: the window is closed and everything about it, the
-- last result and the pending send included, is forgotten. The handler registration is per session and is kept.
local function resetJoin()
  state.win = nil
  state.readySent = false
  state.lastAttempt = nil
end

-- Tells the server this client can show the report window. Sent once per join, and only once both handlers are
-- registered, so the server's sgReportOpen cannot arrive before anything listens for it. If it could not be
-- sent (no TriggerServerEvent yet) it is tried again at the next loading-screen fade-out.
local function sendReady()
  if state.readySent or not (state.registered[EVENT_OPEN] and state.registered[EVENT_RESULT]) then
    return
  end
  if sendEvent(EVENT_READY, '{"v":' .. PROTOCOL_VERSION .. ',"mod":"' .. MOD_VERSION .. '"}') then
    state.readySent = true
  end
end

local function newWindow(parsed)
  return {
    title = parsed.title,
    notice = parsed.notice,
    noteMax = parsed.noteMax,
    send = parsed.send,
    cancel = parsed.cancel,
    players = parsed.players,
    reasons = parsed.reasons,
    windowName = parsed.title .. WINDOW_SUFFIX,
    bufSize = parsed.noteMax * 4 + 1, -- imgui counts bytes; a character is at most 4
    player = nil, -- index into players
    reason = nil, -- index into reasons
    openPtr = nil, -- imgui's open flag (a BoolPtr), made on the first frame
    buf = nil, -- the note's text buffer (an ArrayChar), made on the first frame and again after a success
    pending = false, -- a submit is waiting for its result
    pendingFor = 0,
    message = nil, -- { text, ok } of the last result
    done = false, -- a success was shown: the second button reads "Close"
  }
end

-- The text of the note buffer as a string, cut at the first NUL byte. The game reads these buffers with
-- ffi.string(buffer) (ui/messagesDebugger.lua).
local function readBuffer(buf)
  if buf == nil or type(ffi) ~= "table" or type(ffi.string) ~= "function" then
    return ""
  end
  local ok, s = pcall(ffi.string, buf)
  if not ok or type(s) ~= "string" then
    return ""
  end
  local nul = s:find("\0", 1, true)
  if nul then
    s = s:sub(1, nul - 1)
  end
  return s
end

-- The number of characters (not bytes) in a string: every byte that is not a UTF-8 continuation byte.
local function characterCount(s)
  local _, continuation = s:gsub("[\128-\191]", "")
  return #s - continuation
end

-- Sends the report if the form is complete and nothing is pending. Returns true when it was sent.
local function submit(win)
  if win.pending or not win.player or not win.reason then
    return false
  end
  local target, reason = win.players[win.player], win.reasons[win.reason]
  if not target or not reason then
    return false
  end
  local raw = readBuffer(win.buf)
  local note = trim(cleanText(trim(raw), win.noteMax, true))
  win.message = nil
  if not sendEvent(EVENT_SUBMIT, submitPayload(target.id, reason.id, note)) then
    win.message = { text = "Could not send the report. Please try again.", ok = false }
    return false
  end
  win.pending = true
  win.pendingFor = 0
  return true
end

-- Drawing. Every call below is the game's own imgui binding (lua/common/extensions/ui/imgui_*.lua) used the way
-- the game's own windows use it; see the README for the list and what each was copied from.

local COLOR_OK = { 0.2, 1, 0.4, 1 }
local COLOR_BAD = { 1, 0.4, 0.4, 1 }

-- Text that wraps at the edge of the window. TextUnformatted draws the string as it is (no printf-style
-- formatting), and imgui wraps it at the wrap position set by PushTextWrapPos.
-- Every push below is followed by its pop even if the call in between fails: imgui's stacks must stay balanced.
local function wrappedText(im, text)
  im.PushTextWrapPos(0)
  local ok = pcall(im.TextUnformatted, text)
  im.PopTextWrapPos()
  return ok
end

local function coloredText(im, color, text)
  im.PushStyleColor2(im.Col_Text, im.ImVec4(color[1], color[2], color[3], color[4]))
  local ok = pcall(wrappedText, im, text)
  im.PopStyleColor(im.Int(1))
  return ok
end

-- A button that is greyed out and does nothing when enabled is false. Returns true when it was pressed.
local function drawButton(im, label, enabled)
  if not enabled then
    im.BeginDisabled()
  end
  local ok, pressed = pcall(im.Button, label)
  if not enabled then
    im.EndDisabled()
  end
  return ok and pressed == true
end

-- A combo box of items (each { label }) with the index of the chosen one; returns the new index.
local function drawCombo(im, id, placeholder, items, selected)
  im.SetNextItemWidth(im.GetContentRegionAvailWidth())
  local preview = selected and items[selected] and items[selected].label or placeholder
  if im.BeginCombo(id, preview) then
    local ok = pcall(function()
      for i, item in ipairs(items) do
        if im.Selectable1(item.label .. "##item" .. i, selected == i) then
          selected = i
        end
      end
    end)
    im.EndCombo() -- always paired with a BeginCombo that returned true
    if not ok then
      warnOnce("combo", "could not draw a list in the report window")
    end
  end
  return selected
end

local function drawBody(im, win)
  if win.notice ~= "" then
    wrappedText(im, win.notice)
    im.Spacing()
    im.Separator()
    im.Spacing()
  end

  im.TextUnformatted("Player")
  win.player = drawCombo(im, "##sgPlayer", "Choose a player", win.players, win.player)
  im.Spacing()

  im.TextUnformatted("Reason")
  win.reason = drawCombo(im, "##sgReason", "Choose a reason", win.reasons, win.reason)
  im.Spacing()

  im.TextUnformatted("What happened (optional)")
  im.InputTextMultiline("##sgNote", win.buf, im.ArraySize(win.buf), im.ImVec2(-1, 90))
  local length = characterCount(readBuffer(win.buf))
  if length > win.noteMax then
    coloredText(im, COLOR_BAD, length .. " / " .. win.noteMax .. " characters. Only the first " .. win.noteMax
      .. " are sent.")
  else
    im.TextUnformatted(length .. " / " .. win.noteMax)
  end
  im.Spacing()
  im.Separator()
  im.Spacing()

  if win.pending then
    im.TextUnformatted("Sending...")
  elseif win.message then
    coloredText(im, win.message.ok and COLOR_OK or COLOR_BAD, win.message.text)
  end
  im.Spacing()

  local canSend = not win.pending and win.player ~= nil and win.reason ~= nil
  local sendPressed = drawButton(im, win.send .. "##sgSend", canSend)
  im.SameLine()
  local closePressed = drawButton(im, (win.done and "Close" or win.cancel) .. "##sgCancel", true)

  if sendPressed and canSend then
    submit(win)
  end
  if closePressed then
    win.closeRequested = true
  end
end

-- Draws the window for one frame. Begin is always followed by End, as imgui requires, even if drawing fails.
local function drawWindow(im, win)
  if not win.openPtr then
    win.openPtr = im.BoolPtr(true)
  end
  if not win.buf then
    win.buf = im.ArrayChar(win.bufSize, "")
  end

  pcall(function()
    -- Centered on the main viewport each time the window appears, a modest size that can be resized.
    local viewport = im.GetMainViewport()
    local center = im.ImVec2(viewport.Pos.x + viewport.Size.x / 2, viewport.Pos.y + viewport.Size.y / 2)
    im.SetNextWindowPos(center, im.Cond_Appearing, im.ImVec2(0.5, 0.5))
  end)
  pcall(function()
    im.SetNextWindowSize(im.ImVec2(460, 430), im.Cond_FirstUseEver)
    im.SetNextWindowSizeConstraints(im.ImVec2(360, 300), im.ImVec2(4000, 4000))
  end)

  local flags = (im.WindowFlags_NoCollapse or 0) + (im.WindowFlags_NoSavedSettings or 0)
    + (im.WindowFlags_NoDocking or 0)
  local began, visible = pcall(im.Begin, win.windowName, win.openPtr, flags)
  if not began then
    return false
  end
  if visible then
    if not pcall(drawBody, im, win) then
      warnOnce("draw", "could not draw the report window")
    end
  end
  pcall(im.End)
  return true
end

-- BeamNG and BeamMP entry points (every one is wrapped so that nothing can throw into the game) -----------------

-- BeamMP calls this with the data string of an "sgReportOpen" event from the server.
M.onReportOpen = function(data)
  local ok = pcall(function()
    if state.win then
      return -- already open: ignored
    end
    if type(ui_imgui) ~= "table" then
      warnOnce("ui_imgui", "ui_imgui is not available, cannot show the report window")
      return
    end
    -- At most one attempt per second, valid or not, so a flood of events costs next to nothing.
    if state.lastAttempt and state.clock - state.lastAttempt < OPEN_INTERVAL then
      return
    end
    state.lastAttempt = state.clock
    local parsed = parseOpen(data)
    if not parsed then
      say("W", "ignored a report window request that could not be used")
      return
    end
    state.win = newWindow(parsed)
    say("I", "report window opened")
  end)
  if not ok then
    say("W", "could not process a report window request")
  end
end

-- BeamMP calls this with the data string of an "sgReportResult" event from the server.
M.onReportResult = function(data)
  local ok = pcall(function()
    local win = state.win
    if not win then
      return -- the window was closed: nobody to show it to
    end
    local result = parseResult(data)
    if not result then
      say("W", "ignored a report result that could not be used")
      return
    end
    win.pending = false
    win.pendingFor = 0
    win.message = { text = result.message, ok = result.ok }
    if result.ok then
      win.player = nil
      win.reason = nil
      win.buf = nil -- a new, empty buffer is made on the next frame
      win.done = true
    end
  end)
  if not ok then
    say("W", "could not process a report result")
  end
end

-- The game calls this every frame (extensions.hook('onUpdate', dtReal, dtSim, dtRaw), lua/ge/main.lua).
M.onUpdate = function(dtReal, dtSim, dtRaw)
  pcall(function()
    local dt = dtReal
    if type(dt) ~= "number" or dt ~= dt or dt < 0 then
      dt = 0
    elseif dt > MAX_FRAME_SECONDS then
      dt = MAX_FRAME_SECONDS
    end
    state.clock = state.clock + dt
    local win = state.win
    if not win then
      return
    end
    if win.pending then
      win.pendingFor = win.pendingFor + dt
      if win.pendingFor >= SUBMIT_TIMEOUT then
        win.pending = false
        win.pendingFor = 0
        win.message = { text = "No answer from the server yet. You can try again.", ok = false }
      end
    end
    local im = ui_imgui
    if type(im) ~= "table" then
      return
    end
    local drawn = drawWindow(im, win)
    if not drawn then
      warnOnce("begin", "could not open the report window")
      closeWindow()
    elseif win.closeRequested or (win.openPtr and win.openPtr[0] == false) then
      closeWindow() -- Cancel, Close, or the close button in the title bar
    end
  end)
end

M.onLoadingScreenFadeout = function()
  local ok = pcall(function()
    resetJoin()
    tryRegister(true)
    sendReady()
  end)
  if not ok then
    say("W", "could not run the loading screen hook")
  end
end

-- Leaving the level (the game calls this with the level path, lua/ge/main.lua): the window belongs to the
-- server that was joined, so it goes too.
M.onClientEndMission = function()
  pcall(resetJoin)
end

M.onExtensionLoaded = function()
  local ok = pcall(function()
    tryRegister(false) -- the BeamMP globals may not exist yet; the loading screen hook tries again
    if worldReadyState == 2 then
      M.onLoadingScreenFadeout() -- the world is already ready: this is a join that started before we loaded
    end
  end)
  if not ok then
    say("W", "could not start")
  end
end

return M
