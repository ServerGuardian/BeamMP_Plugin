# ServerGuardian client mod for BeamMP

A small BeamNG.drive / BeamMP client mod (game-engine Lua, no UI files, no assets). When a player has joined and the loading screen is gone it shows the ServerGuardian join notice as a popup, and tells the server that it did. The server plugin (`../main.lua`) uses that to know the player has really seen the notice, instead of guessing from a chat line that a still-loading client may never have displayed.

Players without the mod are unaffected: they never send `sgClientReady`, so the server can fall back to the chat notice.

**Status:** unit-tested under a fake BeamNG/BeamMP client environment (Backend `tests/mod-kit/client_mod_test.lua`, also run under LuaJIT, the game's Lua). **Never run inside BeamNG or BeamMP.** See "Not verified in the game" below.

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

The zip has `scripts/serverguardian/modScript.lua` and `lua/ge/extensions/serverguardian.lua` at its root, nothing else. `modScript.lua` loads the extension as `serverguardian` with manual unload, the same way BeamNG's own mods do.

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

## Tests

`Backend/tests/mod-kit/client_mod_test.lua` (run with `lua client_mod_test.lua lua/ge/extensions/serverguardian.lua`, wrapped by `Backend/tests/mods.client-mod.test.ts`) runs the extension under a fake BeamNG and BeamMP client: events and payloads, one-time registration and retry, popup fields, duplicate and malformed notices, clamping, injection set, links, operator lines, missing globals, failing calls and the log never containing notice text.
