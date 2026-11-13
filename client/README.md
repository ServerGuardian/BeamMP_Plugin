# ServerGuardian client mod for BeamMP

A small BeamNG.drive / BeamMP client mod (game-engine Lua, no UI files, no assets). When a player has joined and the loading screen is gone it shows the ServerGuardian join notice as a popup, and tells the server that it did. The server plugin (`../main.lua`) uses that to know the player has really seen the notice, instead of guessing from a chat line that a still-loading client may never have displayed.

Players without the mod are unaffected: they never send `sgClientReady`, so the server can fall back to the chat notice.

The mod has a second extension, the **report window** (`serverguardianReport.lua`, see "Report window" below): a player types `/report` in chat, the server sends `sgReportOpen`, and the client shows an in-game window to pick a player, a reason and write a short note, then sends `sgReportSubmit`.

**Status:** unit-tested under a fake BeamNG/BeamMP client environment (Backend `tests/mod-kit/client_mod_test.lua` for the notice, `tests/mod-kit/client_report_test.lua` for the report window, both also run under LuaJIT, the game's Lua). **Never run inside BeamNG or BeamMP.** See "Not verified in the game" and "Report window: not verified in the game" below.

## What it does, and does not do

- Sends one event to the server when the loading screen is gone, listens for one event from the server, shows one popup, confirms it.
- Shows at most one notice per join. Later notices in the same join are ignored. A join is a loading-screen fade-out (see "Joins").
- Does not store anything, make any network call, or write anything the server sent to the game log (only fixed lines such as `notice shown`).
- Never throws into the game: every entry point and every game or BeamMP call is guarded, and a missing global is logged once and skipped.

## Protocol

Three events from the client, one from the server. All data is a JSON string. `v` is the protocol version (currently `1`); a notice with any other `v` is ignored.

| Event | Direction | Data |
|---|---|---|
| `sgClientReady` | client to server | `{"v":1,"mod":"0.1.0"}` |
| `sgNotice` | server to client | `{"v":1,"title":"ServerGuardian","text":"...","button":"I understand","extra":["...","..."],"noticeVersion":"notice-v1"}` |
| `sgNoticeShown` | client to server | `{"v":1,"noticeVersion":"<as received, or empty>"}` |
| `sgNoticeClosed` | client to server (optional) | `{"v":1,"noticeVersion":"<as received, or empty>"}` |

`sgClientReady` is sent once per join, when the loading screen has faded out (or when the extension loads into a world that is already ready). If `TriggerServerEvent` did not exist yet it is sent at the next loading-screen event instead.

`sgNotice` fields (anything else in the object is ignored):

| Field | Rule |
|---|---|
| `v` | must be the number `1` |
| `text` | required string, plain text, at most 2000 characters. A blank line starts a new paragraph, a single newline is a line break, `http://` and `https://` addresses become links |
| `title` | string, at most 80 characters, default `ServerGuardian` |
| `button` | string, at most 40 characters, default `I understand` |
| `extra` | optional list of strings, at most 5 used, each at most 300 characters. Shown as plain paragraphs below the notice, visually separated. Never turned into links |
| `noticeVersion` | optional string, at most 100 characters, sent back unchanged in the two confirmations |

Anything malformed (not JSON, not an object, wrong `v`, no usable `text`) is ignored and does not use up the one notice. Lengths are counted in characters and clamped; control characters, invalid UTF-8 and bidirectional override characters are removed.

`sgNoticeShown` is sent immediately after the popup has been opened. A notice that arrives before the loading screen is gone is held and shown right after it (the ready event goes first). If the popup cannot be opened (no `guihooks`), no confirmation is sent and the notice is shown at the next chance.

`sgNoticeClosed` is sent when the player presses the popup's button, once. It is not sent when the popup is replaced or closed by something else (see below), so treat it as "definitely closed", never as required.

## Joins

The mod stays loaded for the whole game session (`manual` unload), so a player can leave one server and join another without it reloading. Every `onLoadingScreenFadeout` is therefore treated as the start of a new join:

- At each fade-out the state of the previous join (ready sent, notice shown, held notice, close reported, version) is wiped before anything is sent, so each join sends `sgClientReady` once and can show one notice. The event handler registration is per session and is kept.
- The state is **not** wiped when it would throw away something in flight: a held notice (it is this fade-out's notice, waiting for it), or a popup that is open and not yet reported closed (the fade-out may not be a new join). In that case no new ready event is sent and no second popup is allowed. A player who leaves a server without pressing the popup's button therefore gets no ready event or popup on the next server until they have pressed it.
- A hostile or buggy server cannot get more than one popup out of one fade-out: the "shown" flag only resets at a fade-out, and only once the previous popup was reported closed (or none was shown).
- A notice that arrives between joins (after the previous join's notice was shown or closed, before the next fade-out) is treated as part of the previous join and ignored; it is not held. A server that answers before its own loading screen is gone must therefore send its notice after `sgClientReady`, which the mod sends at that fade-out. If the previous join never showed a notice, a notice arriving between joins is shown at once.
- A late `onIntroPopupCareerClosed` for the previous join's popup, after the next fade-out, is ignored.

## What the server must do

1. Register a handler for `sgClientReady` (`MP.RegisterEvent("sgClientReady", ...)`; BeamMP calls it with the player id and the data string). A client-to-server event is dropped by BeamMP only if its name is on the server's excluded list (`onPlayerJoin`, `onChatMessage` and similar); the three names the client sends are not.
2. In that handler, send the notice: `MP.TriggerClientEvent(playerID, "sgNotice", Util.JsonEncode({...}))`. The data must be a string, and BeamMP refuses the call (returns false) unless the player is syncing or synced, which is always true after the player has loaded.
3. Treat `sgNoticeShown` (and optionally `sgNoticeClosed`) as the confirmation that the player has seen the notice. Both are sent by the player's game, so a modified client can send them without showing anything; they say "the notice was displayed", not more.
4. Keep the chat-line fallback for players who never send `sgClientReady`.
5. Do not send the notice before `sgClientReady`; the mod's handler may not be registered yet.

## Install (server owner)

1. Build the zip (below) or take `ServerGuardianClient.zip` from a release.
2. Put it in the BeamMP server's `Resources/Client/` folder. Players download it automatically when they join; nothing to install by hand.
3. Restart the server so it serves the new mod, and use a plugin version that speaks this protocol.

The zip has `scripts/serverguardian/modScript.lua`, `lua/ge/extensions/serverguardian.lua` and `lua/ge/extensions/serverguardianReport.lua` at its root, nothing else. `modScript.lua` loads both extensions (`serverguardianReport` and `serverguardian`) with manual unload, the same way BeamNG's own mods do.

## Build the zip

```
./build.sh                 # writes ServerGuardianClient.zip next to this file
./build.sh /some/where.zip # or somewhere else
```

It uses `zip` when installed and python3's `zipfile` otherwise. `ServerGuardianClient.zip` is in `.gitignore`: do not commit it.

## How the popup is built, and why

The notice is shown with `guihooks.trigger('OpenTutorialPopup', ...)` with id `serverguardianNotice`, flavour `onlyOk`. Every string from the server is untrusted. Read in the game's own UI source (`TutorialPopupDialog.vue`, `bbcode*.js`) rather than assumed:

- The popup text is run through the game's translate and BBCode/markdown parser and then put into the page as HTML. So besides `& < > " '`, the characters `{ } [ ] *` are written as numeric entities: otherwise the game would turn `[url=...]`, `[img]...`, `[COLOR=...]`, `*x*` or `[x](http://...)` into links, remote images and styled spans. Text is escaped first, then addresses are made into links, then the paragraphs are cut.
- A link is `<a class="sg-link" href="http-external://www.beamng.com/proxy.php?link=<address>">`. `class` must come before `href`: the game rewrites any `<a href="...">` into a control that does nothing inside this popup. The address is percent-encoded (nothing outside `A-Za-z0-9 % - . _ ~ : / ? = @` survives), so it cannot end the attribute or add a parameter to the proxy address. Only `http://` and `https://` are linked; a link ends at whitespace, a quote, a bracket or a tag character, and trailing `. , ; : ! ?`, an unmatched `)`, and `&` are not part of it.
- Any other text that looks like `http://...` gets its colon written as an entity, because the game links any whitespace followed by `http://` by itself.
- The title and the button are rendered by the game as plain text (Vue text interpolation), so they are not HTML-escaped (that would display `&amp;`); `<` and `>` are removed instead so that no tag can exist in either.
- The only markup the mod writes: a fixed `<style>` block, `div`, `p`, `br` and the link above. The test suite checks every one of those properties for an injection set, and the output was also run through the game's real `bbcode.parse` (copied from the game folder): it leaves the generated html unchanged.

## Not verified in the game

Nothing here has run inside BeamNG or BeamMP. Specifically:

**Taken from the reference mod (`mozaQualifying`, a mod known to work) and read in the installed game's files:** the `OpenTutorialPopup` payload shape (`popups = {{type, id, title, buttonLabel, text, flavour = "onlyOk", isPopup = true}}`), `M.onLoadingScreenFadeout` and the `worldReadyState == 2` check in `M.onExtensionLoaded`, `guihooks.trigger`, `setExtensionUnloadMode` plus `extensions.load` in `modScript.lua`, and the `http-external://www.beamng.com/proxy.php?link=` link form. Still unverified: that these behave the same on the game version players use; that the `<style>` block applies; that `http-external://` links open the browser when clicked (only the reference mod's use of them is known).

**From BeamMP's client Lua (read in a local checkout of the BeamMP client, `MPGameNetwork.lua`) and the server source, but not run:** `AddEventHandler(event, func, sourceName)` (the handler is called as `func(dataString)` inside a pcall; the third argument is passed so the handler has a fixed source name), `TriggerServerEvent(name, data)` (sent as an `E:` packet that the server turns into `TriggerEvent(name, playerID, data)`), and `MP.TriggerClientEvent` on the server. Unverified: that those globals exist when the extension loads (the mod retries at the loading screen); that a handler registered at that point receives the first `sgNotice`; the BeamMP version players run.

**From the installed game's Lua, read but not run:** `jsonDecode` (`lua/common/utils.lua`; on bad JSON it logs an error that may include part of the input, which is why anything that does not look like a JSON object never reaches it), `log(level, tag, message)`, and the `onIntroPopupCareerClosed` hook that `sgNoticeClosed` depends on (the popup's button calls `extensions.hook("onIntroPopupCareerClosed", id)`, as `finalizeClose` in `TutorialPopupDialog.vue` shows). Not used: `jsonEncode` (the confirmations are built by hand).

**Things only a real session can answer:**

- that the popup appears, looks right (readable paragraphs, the operator block, link colour), and that the button reads as set;
- that the popup is not covered or closed by another mod's popup: the game closes any open tutorial popup when another `OpenTutorialPopup` arrives, so a second popup mod firing at the same loading screen replaces this one (then `sgNoticeShown` was sent but `sgNoticeClosed` never will be);
- that a very large notice fits in one BeamMP event packet (the mod accepts up to 100000 bytes of JSON and shows at most 2000 characters of text; BeamMP's packet size limits were not looked up or measured);
- that `onLoadingScreenFadeout` fires at every server join in a session that stays loaded. The per-join design (below) depends on it. If it fires more than once for one join, the server gets a second ready event once the first popup was closed; if it does not fire for a second join, that join gets neither a ready event nor a popup;
- that `sgNoticeClosed` arrives when the player presses the button, and on Enter or a controller button;
- the Lua 5.1 syntax was checked by running the tests under LuaJIT, but not inside the game's own Lua build.

## Report window

`lua/ge/extensions/serverguardianReport.lua`, loaded by `modScript.lua` as `serverguardianReport` (manual unload, depends on the game's `ui_imgui`). It is independent of the notice extension; both use the handler source name `serverguardian`.

### Protocol

All data are JSON strings, `v` is `1`. Handlers are registered with `AddEventHandler(name, fn, "serverguardian")`, sends are `TriggerServerEvent(name, jsonString)`.

| Event | Direction | Data |
|---|---|---|
| `sgReportReady` | client to server | `{"v":1,"mod":"0.1.0"}` |
| `sgReportOpen` | server to client | `{"v":1,"title":"Report a player","players":[{"id":3,"name":"Bob"}],"reasons":[{"id":"cheating","label":"Cheating"}],"notice":"...","noteMax":200,"send":"Send report","cancel":"Cancel"}` |
| `sgReportSubmit` | client to server | `{"v":1,"target":3,"reason":"cheating","note":"..."}` |
| `sgReportResult` | server to client | `{"v":1,"ok":true,"message":"..."}` |

**`sgReportReady`** says only "this client can show the report window" (the mod version is the only other content). It is sent once per join, at each `onLoadingScreenFadeout` after both handlers are registered, and also when the extension loads into a world that is already ready (`worldReadyState == 2`). It is not sent while the handlers are not registered (no `AddEventHandler`, or registration failed), and if `TriggerServerEvent` was missing or threw it is retried at the next fade-out. The server should only send `sgReportOpen` to a client that has sent it.

**`sgReportOpen`** is untrusted in every field. Ignored (nothing shown, nothing sent) when `v` is not the number `1`, the payload is not a JSON object, over 100000 bytes, or there is no usable player or no usable reason. Otherwise:

| Field | Rule |
|---|---|
| `title` | string, at most 80 characters, default `Report a player` |
| `players` | list, at most 100 used. Entry: `id` must be a number that is a whole number from 0 to 2147483647 (anything else drops the entry, as does a repeated `id`); `name` at most 60 characters, default `Player <id>` |
| `reasons` | list, at most 12 used. Entry: `id` must be a string matching `^[a-z_]{1,40}$` (else the entry is dropped, as is a repeated id); `label` at most 60 characters, default the id |
| `notice` | string, at most 1000 characters, plain text, blank lines and newlines kept, shown wrapped at the top of the window; none shown if empty |
| `noteMax` | number, rounded down and clamped to 1..300, default 200 (also for anything that is not a finite number) |
| `send`, `cancel` | strings, at most 40 characters, defaults `Send report` and `Cancel` |

Every string has control characters, invalid UTF-8, C1 controls, line and paragraph separators and bidirectional overrides removed (a tab or newline in a one-line field becomes a space); `##` is changed to `# #` in text used as an imgui label (imgui reads `##` as an id separator and would cut the text there). Lengths count characters. Opening while the window is open is ignored; a window the player closed can be opened again by a new `sgReportOpen`. At most one `sgReportOpen` is looked at per second (valid or not; measured by summing the frame time given to `onUpdate`), so a flood costs next to nothing.

**`sgReportSubmit`** is sent when the player presses Send. `target` is the chosen player's `id` as an integer, `reason` the chosen reason `id`, `note` what the player typed: trimmed, cut at the first NUL byte of the buffer, cleaned as above (newlines kept, a tab becomes a space, other control characters removed), then cut to `noteMax` characters (characters, not bytes), then trimmed again. The JSON is built by hand: `"`, `\`, newline, tab, carriage return and any other character below 0x20 are escaped, everything else (UTF-8 included) is written as it is. Send is greyed out and ignored until a player and a reason are chosen, and while a submit is waiting for its result (up to 15 seconds, then it is enabled again and the window says there was no answer; a result that arrives later is still shown). If `TriggerServerEvent` is missing or throws, the window says so and Send is enabled again. A note longer than `noteMax` is allowed in the field (imgui cannot cap by characters); the counter turns red and says that only the first `noteMax` characters are sent.

**`sgReportResult`** is ignored unless the window is open and `v` is `1` and `ok` is a boolean. `message` is cleaned to one line of at most 300 characters (a fixed English default if empty). The window shows it, green for `ok = true` and red for `false`, and stops waiting. `ok = false` keeps the window as it is so the player can try again. `ok = true` clears the chosen player, reason and note, keeps the window open so the message can be read, and turns the second button into `Close`.

### Window

A normal imgui window (title bar with the close button, no collapse, no saved settings, no docking), centred on the main viewport each time it appears, 460 by 430 at first, resizable (minimum 360 by 300). From the top: the notice, a `Player` combo box, a `Reason` combo box, `What happened (optional)` with a multi-line field of about `noteMax` characters and a `0 / 200` counter, the message of the last result, then the Send and Cancel buttons (labels from the server; `Close` after a success). The window is closed by the title-bar button, Cancel/Close, a new join (`onLoadingScreenFadeout`, everything forgotten: window, pending send, message, choices) and leaving the level (`onClientEndMission`). The window is drawn from `M.onUpdate`; `Begin` is always followed by `End`, and every push, disabled block and combo is closed even if a call fails. The note the player types is only ever in the `sgReportSubmit` payload: it is not logged, stored, or sent anywhere else. Nothing the server sent is ever logged; the log only has fixed lines (`report window opened`, `ignored a report result that could not be used`, ...).

### Where each imgui call was taken from

Read in the locally installed game (Steam: `.../steamapps/common/BeamNG.drive/lua`; the Wine prefix under `~/Wine/beamng-prefix` has only the user folder, not the game). The bindings are `common/extensions/ui/imgui_luaintf.lua` and `imgui_custom_luaintf.lua`, reached through the global `ui_imgui` (a startup extension, `ge/main.lua`; `imgui.lua` loads `imgui_api.lua`). The game version was not determined.

| What | Call | Binding defined in | Used the same way in |
|---|---|---|---|
| `im = ui_imgui`, `M.dependencies = {"ui_imgui"}` | | `extensions/ui/imgui.lua` | `ge/extensions/ui/console.lua`, `ui/messagesDebugger.lua` |
| drawn each frame | `M.onUpdate(dtReal, dtSim, dtRaw)` | `extensions.hook('onUpdate', ...)` in `ge/main.lua` | `ui/messagesDebugger.lua` |
| window with open flag | `im.Begin(name, im.BoolPtr(true), flags)`, `im.End()` (End also when Begin returned false), `im.BoolPtr` | `imgui_luaintf.lua`, `imgui_custom_luaintf.lua` | `ui/messagesDebugger.lua`, `flowgraph/nodes/ui/imgui/imDialogue.lua` |
| flags | `im.WindowFlags_NoCollapse`, `_NoSavedSettings`, `_NoDocking` added with `+` | `imgui_luaintf.lua` (enum block) | `ui/console.lua`, `core/metrics.lua` |
| size and position | `im.SetNextWindowSize(v, im.Cond_FirstUseEver)`, `im.SetNextWindowSizeConstraints(min, max)`, `im.SetNextWindowPos(pos, cond, pivot)` (the pivot argument is in the binding's signature; no game file was found that uses it), `im.GetMainViewport()` with `.Pos` and `.Size`, `im.ImVec2` | `imgui_luaintf.lua`, `imgui_custom_luaintf.lua` | `ui/messagesDebugger.lua`, `core/metrics.lua`, `util/screenshotCreator/nodeOutpaint.lua` |
| combo box | `im.BeginCombo(label, preview)`, `im.Selectable1(label, selected)`, `im.EndCombo()` (End only when Begin returned true), `im.SetNextItemWidth(im.GetContentRegionAvailWidth())` | `imgui_luaintf.lua`, `imgui_custom_luaintf.lua` | `career/modules/debug/vehOfferDebug.lua`, `ui/apps/minimap/minimap.lua`, `career/modules/debug/cargoContainerDebug.lua` |
| note field | `im.ArrayChar(size, "")`, `im.ArraySize(buf)`, `im.InputTextMultiline("##id", buf, im.ArraySize(buf), im.ImVec2(-1, 90))`, read with `ffi.string(buf)` | `imgui_custom_luaintf.lua`, `imgui_luaintf.lua` | `ui/messagesDebugger.lua` (the same four calls) |
| buttons | `im.Button(label)`, `im.SameLine()`, `im.BeginDisabled()` / `im.EndDisabled()` | `imgui_luaintf.lua` | `ui/messagesDebugger.lua`, `career/modules/marketplace.lua` (BeginDisabled) |
| text | `im.TextUnformatted(text)` inside `im.PushTextWrapPos(0)` / `im.PopTextWrapPos()`, `im.Spacing()`, `im.Separator()` | `imgui_luaintf.lua` | `ui/messagesDebugger.lua` (TextUnformatted, Separator), `flowgraph/nodes/ui/imgui/elemental/imText.lua` (PushTextWrapPos plus TextWrapped, with arbitrary text) |
| colour | `im.PushStyleColor2(im.Col_Text, im.ImVec4(r,g,b,a))`, `im.PopStyleColor(im.Int(1))`, `im.ImVec4`, `im.Int` | `imgui_luaintf.lua`, `imgui_custom_luaintf.lua` | `career/modules/debug/dealershipFilterDebug.lua` |

`TextWrapped` (the brief's choice) was not used: the game's own wrapper formats its argument and then passes it on, and whether the engine side treats `%` in it as a format string was not checked, so `TextUnformatted` (which never formats) is used with `PushTextWrapPos(0)` instead. `jsonEncode` is not used (the payload is built by hand). A test (`client_report_test.lua`, "every imgui call in the extension...") scans the extension for every `im.<name>` and fails if it is not in the list of calls read in the game above.

### Report window: not verified in the game

Nothing here has run inside BeamNG or BeamMP. Everything below is unverified:

- that the window appears, is readable, and that the combo boxes, the note field, the buttons and the title-bar close button work with the mouse and keyboard in a real session;
- how a player gets the mouse pointer while driving (the game's usual way for its imgui windows), whether typing into the note field is kept away from the car controls and key bindings while the field has focus, and that the window does not hold the mouse or the keyboard after it is closed. Nothing special is done: it is a plain imgui window, like the game's own;
- that `ffi.string(buffer)` on a buffer from `im.ArrayChar` stops at the first NUL (the game's own windows use it that way; the mod also cuts at the first NUL itself), and that `ArrayChar(size, "")` gives an empty field;
- that `TextUnformatted` wraps at `PushTextWrapPos(0)` in the game's imgui (it does in upstream Dear ImGui; `TextWrapped` is the fallback);
- that `SetNextWindowPos` with the pivot argument centres the window, and what `GetMainViewport().Pos` and `.Size` are with multiple monitors or the game's imgui viewports enabled;
- that the window keeps its place when the player hides the game's UI (`ui_visibility`), and that a window stays usable on top of the game's own pause or menu screens;
- that `onUpdate` is called for a manually loaded BeamMP client extension every frame, also while a loading screen or menu is up, and that `onClientEndMission` fires when the player leaves a BeamMP server (the hook name is in `ge/main.lua`);
- that `onLoadingScreenFadeout` fires at every server join in a session that stays loaded (the same assumption as the notice); if it does not, `sgReportReady` is not sent for later joins and the server will not open the window;
- BeamMP's handling of the events: that `sgReportOpen` and `sgReportResult` reach the handlers registered with the source name `serverguardian` next to the notice extension's `sgNotice` handler, and the size limits of one event packet;
- the 15-second timeout and the one-per-second limit use the sum of the frame times passed to `onUpdate`, not a wall clock, so they run slower when the game's frame time is clamped or the game is paused;
- the Lua 5.1 syntax was checked by running the tests under LuaJIT, but not inside the game's own Lua build.

## Tests

`Backend/tests/mod-kit/client_mod_test.lua` (run with `lua client_mod_test.lua lua/ge/extensions/serverguardian.lua`, wrapped by `Backend/tests/mods.client-mod.test.ts`) runs the extension under a fake BeamNG and BeamMP client: events and payloads, one-time registration and retry, popup fields, duplicate and malformed notices, clamping, injection set, links, operator lines, missing globals, failing calls and the log never containing notice text.

`Backend/tests/mod-kit/client_report_test.lua` (run with `lua client_report_test.lua lua/ge/extensions/serverguardianReport.lua`, wrapped by `Backend/tests/mods.client-report.test.ts`) runs the report extension under the same kind of fake game plus a scripted fake `ui_imgui` (what the player does in each frame is set per frame: pick a player or reason, type a note, press Send or Cancel, press the title-bar button): registration and the `sgReportReady` event (once per join, not before the handlers, retried), the window and what it shows, Send disabled until both choices, the exact `sgReportSubmit` payload and its escaping and character limit, results (failure keeps the window, success clears the form), one submit at a time and the 15-second timeout, floods of `sgReportOpen` and malformed, oversized and hostile payloads, per-join reset, missing and failing globals, balanced imgui stacks, the log containing only fixed lines, and that every imgui call used was read in the game's source.
