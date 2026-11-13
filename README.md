# ServerGuardian for BeamMP

A BeamMP server plugin that asks ServerGuardian whether a joining player is linked to an account banned elsewhere. The server only learns **pass** or **block**: never why, never who. If ServerGuardian cannot be reached, players are let in (or kept out, if you set `failMode` to `closed`).

**Status:** tested end to end under a fake BeamMP environment (from the Backend repository), **not yet on a real BeamMP server** (decision D17).

## Install

1. Copy `main.lua`, `sg_core.lua` and `config.example.json` into `Resources/Server/ServerGuardian/` on your BeamMP server.
2. Copy `config.example.json` to `config.json` and set the API address and your server's API key (made in the ServerGuardian portal), then check the `settings` block (see Settings below).
3. Restart the server. The plugin needs `curl` on the host.

Players with a BeamMP guest session have no account id, so they cannot be checked or banned; they are let in and nothing is sent. That makes guests a way around any ban. To refuse them, set `AllowGuests = false` under `[General]` in BeamMP's `ServerConfig.toml` (or `BEAMMP_ALLOW_GUESTS=false`): it is BeamMP's own setting, and your choice.

## When a player is shown the notice, and checked

BeamMP raises `onPlayerJoin` when a player *starts* syncing: their game is still loading the map and the other players' cars, and a chat line sent then is not seen (BeamMP has no event for "finished loading"). So the plugin waits: the player is shown the ServerGuardian notice, and only then checked, as soon as **their first car spawns or they first say something** (they are certainly in the game then), or **15 seconds after they joined**, whichever comes first. Nothing is sent about a player before the notice. Change the 15 with `noticeDelaySeconds` in `config.json` (0 to 120; 0 restores the old behaviour of acting at once). A player who leaves before then is simply forgotten.

BeamMP's Lua `MP.SendChatMessage` returns nothing (the success or failure is dropped between BeamMP's C++ and its Lua), so the plugin cannot tell whether a chat line reached a player, and a line sent to a client that is still syncing is silently skipped. The plugin therefore treats "no answer" as sent and relies on the wait above; only a server version that does return `false` makes it report `the notice could not be shown` and skip the check. A BeamMP client mod can show the notice in a popup after the loading screen and confirm it back to the server, which would remove this guesswork.

The price is that a banned player is removed after that wait (up to 15 seconds, or sooner when they spawn a car) instead of at the instant they join. A server that would rather check at once, accepting that the notice may be missed, can set 0.

## What you see when it starts

The plugin prints the ServerGuardian badge, its version and the API address to the server console as soon as it loads, then lines saying whether it reached ServerGuardian a moment later. The badge is drawn in braille dots, which need a console that shows UTF-8; on Windows, or with `"bannerStyle": "ascii"` in `config.json`, a plain-ASCII badge is used instead (`"braille"` forces the dots, `"auto"` is the default):

```
  ⠀⠀⠀⠀⠀⢀⣠⣤⣶⠿⠿⣶⣤⣄⡀⠀⠀⠀⠀⠀
  ⢀⣀⣤⣶⡾⠟⠛⠉⠀⠀⠀⠀⠉⠛⠻⢷⣶⣤⣀⡀
  ⣿⡟⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⢻⣿
  ⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿
  ⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣄⠀⠀⠀⢸⣿   ServerGuardian for BeamMP
  ⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣾⡿⠃⠀⠀⠀⢸⣿   Version 0.9.1
  ⣿⡇⠀⠀⠀⠺⣷⣄⠀⢀⣴⡿⠋⠀⠀⠀⠀⠀⢸⣿   API: https://test.example.com
  ⢻⣇⠀⠀⠀⠀⠘⢿⣷⣿⠋⠀⠀⠀⠀⠀⠀⠀⣸⡟   Connecting in the background...
  ⠈⣿⡆⠀⠀⠀⠀⠀⠉⠁⠀⠀⠀⠀⠀⠀⠀⢰⣿⠁
  ⠀⠘⢿⣆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⡿⠃⠀
  ⠀⠀⠈⠻⣷⣄⠀⠀⠀⠀⠀⠀⠀⠀⣠⣾⠟⠁⠀⠀
  ⠀⠀⠀⠀⠈⠻⣷⣤⡀⠀⠀⢀⣤⣾⠟⠁⠀⠀⠀⠀
  ⠀⠀⠀⠀⠀⠀⠀⠙⠻⣷⣾⠟⠋⠀⠀⠀⠀⠀⠀⠀

[ServerGuardian] info: started
[ServerGuardian] info: CONNECTED: connected, API key accepted
[ServerGuardian] info: fail mode open | game events off | reports off | chat checking off
```

If it cannot connect you get `NOT CONNECTED:` and the reason: **the API key was refused** (check `apiKey` in `config.json`: it may be revoked or belong to another server), **the Data Processing Agreement has not been accepted** or **the plan does not allow this server** (both fixed in the portal), or **no answer from the API** (check `apiBase`, that `curl` is installed and the network), together with what happens to players meanwhile (let in unchecked, or kept out, depending on `failMode`). It keeps trying, and writes one line if the connection is lost or comes back later. A key still set to the example from `config.example.json` stops the plugin from starting, with a line that says so.

**Start-up never holds the server up.** BeamMP waits for a plugin's `onInit` and gives up on one that takes too long (`'onInit' ... failed to execute in time`), so the first requests to ServerGuardian (the settings, the wording and the first heartbeat) run in the background and their answers are collected by the plugin's one-second timer. Only a join check, which must have an answer before the player is let in, is waited for.

## Settings

This server's behaviour is set in **`config.json`, in the `settings` object**, next to the API key. The ServerGuardian portal only **shows** what each server is set to (read-only, with when the plugin last reported it); it cannot change them.

| Setting | Values | Default | What it does |
|---|---|---|---|
| `failMode` | `open` or `closed` | `open` | What happens when ServerGuardian cannot be reached. `open` lets players in; `closed` keeps them out. It applies from here even if ServerGuardian has never been reached. |
| `gameEvents` | `true` or `false` | `false` | Send vehicle spawns, edits and deletes, and run ServerGuardian's movement checks, sending only a flag. See "Game events" below. |
| `reports` | `true` or `false` | `false` | Let players report each other with `/report`. See "Player reports" below. |
| `shareBans` | `true` or `false` | `true` | Use bans recorded on your other ServerGuardian servers here too, and share this server's bans with them. Turn it off for a server that should keep its own list. Bans reported to other server owners are not affected. |
| `youthOriented` | `true` or `false` | `false` | This server or event is for players under 18. Their data is handled more strictly: no hardware check, shorter records, and game events are neither kept nor sent on to webhooks. |
| `chatModeration` | `true` or `false` | `false` | Send chat lines to ServerGuardian to be checked against the rules you set in the portal, and show players the join notice that says so. See "Chat moderation" below. **Off by default.** |

- Use JSON `true` and `false` without quotes.
- **Any setting you leave out keeps the value it already had**, so an older config file never changes a server's youth-oriented protection or anything else.
- A value that is not valid (for example `"yes"` instead of `true`) is ignored, with a line in the log that names the setting but never repeats what was written.
- The plugin tells ServerGuardian its settings when it starts and at every refresh (every ten minutes), so a change applies after a restart or at the next refresh. A server can change its settings at most **10 times an hour**; if that is exceeded the plugin carries on with what the file says and logs that ServerGuardian refused the change.
- Join rules (what blocks a player: your own bans, other owners' bans, account links, minimum standing) are still set in the portal.

## How it works

On join the plugin shows the ServerGuardian notice, sends the player's BeamMP account id and IP address (and, if they agree to the optional hardware check, a hardware token) and removes the player if the answer is "block". Nothing a player controls reaches a shell command, and the key is never logged. When a player leaves, the plugin says so.


**Heartbeat.** About once a minute (and once at start-up) the plugin tells ServerGuardian it is there and how many players are on, so the portal can show the server as online or offline. The count is the only thing sent, it is never logged, and it runs whether or not game events or reports are on. It runs in the background (see "What you see when it starts" above): the server never waits for it, and only one is in flight at a time. A refused key, plan or permission pauses it for ten minutes, too many requests for one.

## Chat moderation

Off unless **`chatModeration`** is `true` in `settings` (the default is off; the portal shows the setting but cannot change it). While it is off the plugin does nothing with chat. While it is on:

- **What is sent:** each chat line a player types (not commands: anything starting with `/` is never queued, and empty lines are not), cut to 500 characters, with the id of that player's join (the reference ServerGuardian already has) and a short label, the player's in-game name with only letters, digits, spaces and `_ . : / -` kept. A line from a player who has no join reference yet is dropped. Lines go to `POST /v1/chat` in groups of up to 50, at most every five seconds. **What is never sent:** an IP address, a platform id, a hardware id, or anything else.
- **What ServerGuardian does with it** is described in the portal: it reads each line in memory, keeps only the lines that break a rule you turned on, and forgets the rest.
- **The plugin never writes chat anywhere.** Not to disk (the request body goes to curl through a pipe, not a temporary file, unlike every other request), not to the console and not to the log, and no error message ever includes it. Lines wait in memory only, at most 500 (the oldest are dropped first, and only a count is logged, at debug level) and for at most a minute, and are never kept for a retry.
- **Chat is never slowed, changed or cancelled.** `onChatMessage` only puts the line in the queue and returns nothing (it returns `1` only for `/report`, as before), so other plugins and the server see no difference. Sending happens from the one-second timer, in the background.
- **Honouring the answer.** If ServerGuardian answers that chat checking is off for this server (`enabled: false`), the plugin queues nothing more until the next settings refresh (every ten minutes) reads the switch as on. Any error (a `429`, a `5xx`, no answer, a `401`, `402`, `403` or `404`, including `chat_moderation_disabled`) backs off (`Retry-After` or a minute for a `429`; 5 seconds then longer, up to a minute, for a server error or no answer; ten minutes for `401`, `402`, `403` and `404`), and the lines that were in that request, and any waiting, are **discarded**: nothing is retried. While backing off, chat is not queued at all.
- **The join notice.** While chat moderation is on, the plugin shows the `noticeChat` wording from ServerGuardian's settings instead of the usual notice (which says chat is not read). If ServerGuardian does not supply `noticeChat`, the usual notice is shown **and no chat is sent**, so players are never told chat is not read while it is.
- **Not verified:** the Windows branch of the pipe (`start /b` with curl reading its standard input) has not been run on Windows. If it does not work no answer arrives and the lines are simply lost. The hook was checked against the BeamMP-Server source (`TServer.cpp`: `onChatMessage(senderID, senderName, message)`, a handler's return of `1` rejects the message); it was **not run on a real BeamMP server**.

## Recording bans and kicks

BeamMP-Server has no ban system of its own (only a console `kick`), so ServerGuardian has nothing to match against unless bans are recorded. The plugin adds three console commands for that. Type them in the server console:

| Command | What it does |
|---|---|
| `sgban <player> [reason]` | Removes the player and records a **permanent** ban. |
| `sgtempban <player> <hours> [reason]` | The same, ending after that many hours (1 to 87,600). |
| `sgunban <ban id>` | Ends a ban early. The id is printed when the ban is recorded. |

A recorded ban applies across all of your servers: the next time that account tries to join one, the join check turns them away. The player is told only the fixed wording with the appeal link, never your reason. **The reason you type is stored and shown to the player in their portal**, so keep it factual and leave out personal details.

- `<player>` is a name, any case. A name that starts with what you typed works if it is unique; if two players match, nothing happens and you are asked to type more.
- A **guest** has no BeamMP account, so a ban cannot be recorded against them. Nothing is done; use the built-in `kick`.
- If ServerGuardian cannot be reached, or the key is refused, the player is still removed but the ban is **not** recorded, and the console says so. The key must be allowed to record actions (most keys are).
- Bans made by other plugins are not seen. Only these commands record bans.

**Recording kicks (off by default).** Set `"recordKicks": true` in `config.json` and the plugin also records the built-in `kick <name> [reason]` as a kick. A kick never blocks anyone; it shows on the player's page and feeds their standing. BeamMP runs the kick first and tells the plugin afterwards, so the plugin matches the name against who was here a moment ago, and records nothing if it cannot tell exactly who was kicked. Names are held in memory only, and never logged or sent.

## Player reports

When **`reports`** is `true` in `settings` (off by default), players can type `/report <player> <category> [what happened]` in chat (a guest has no account, so cannot send or be the subject of one). The report goes to the server's staff through ServerGuardian. Nobody else sees it, and it is never used to score or match anyone.

- The categories are `cheating`, `griefing`, `harassment`, `hate_or_abuse` and `other`. A wrong one is answered with the list.
- The first time a player reports in a session they are shown a notice (reports are kept for a limited time, and are not a chat log) and must type the same command again within two minutes to send it. After that, reports send straight away. Each player can send three reports in ten minutes.
- `<player>` is a connected player's name, any case; a unique start of a name works. A player cannot report themselves, and a player with no account cannot be reported.
- **What is sent:** the category, the optional note the player typed (cut to 200 characters), the account ids of the reporter and of the reported player, and a reference built from the reported player's name (letters and digits only) so staff can recognise it. **What is not sent:** chat, IP addresses, or anything else about either player. Nothing about a report (note, names, ids) is ever logged.
- If ServerGuardian cannot be reached the player is told the report could not be sent. Reports need the key's ingest scope, which every normal key has.

## Game events

When **`gameEvents`** is `true` in `settings` (off by default), the plugin tells ServerGuardian when a player **spawns, edits or deletes a vehicle** and runs two **movement checks** on the server: a speed or a jump the game could not produce, and a change of speed that is not believable. The operator sees them in the portal (on plans that keep history) and can have them sent to a webhook.

- **What is sent:** for a spawn or an edit, the short name of the vehicle (the `jbm` model name in the spawn or edit data, or just `vehicle` if it cannot be read); for a delete, the model the plugin remembered from when that vehicle was spawned or edited (`unknown` if the plugin never saw it, for example a vehicle spawned before the plugin started); for a flag, which check failed (`impossible_move` or `acceleration`) and whether it was `low` or `high`. Both carry the id of the player's join (the reference ServerGuardian already has for them) and a short label, the player's in-game name with only letters, digits, spaces and `_ . : / -` kept. **What is never sent:** a position or any coordinate, chat, an IP address, a platform id, or a hardware id. Nothing about an event (label, item, ids) is ever logged.
- **The numbers come from ServerGuardian.** The speed, jump and acceleration limits, and how often to look, are in the settings the plugin already fetches, so they can be tuned without a new release. They are placeholders until they have been tried on real servers.
- **A flag is a prompt for a person to look.** Nothing is ever kicked, banned or messaged because of one. A given check flags a given player at most once a minute (however many vehicles they have, and deleting a vehicle does not reset that), and a player is held to 20 spawns, 20 edits, 20 deletes and 10 flags a minute, counted separately so spam of one kind cannot hide another, with 400 events a minute for the server.
- While game events are off (the default) the plugin does not sample or send anything at all.
- Checks use `MP.GetPositionRaw` (a table with `pos = {x, y, z}`) once a second for each of a player's vehicles, driven by `MP.CreateEventTimer`; a vehicle reset (`onVehicleReset`) starts that vehicle's track again, so a reset is not a jump. **The first two samples after a spawn or a reset are not used**, and neither is a position that is missing or exactly zero, because the position may not be right yet. The handlers (`onVehicleSpawn`, `onVehicleEdited`, `onVehicleDeleted`) return nothing, so a spawn or an edit is never cancelled by this plugin; another plugin may cancel it afterwards and this one cannot tell, so a cancelled spawn is still reported. Vehicles spawned before the plugin started are not checked until they are respawned.
- **The clock.** The checks time their samples with `MP.CreateTimer()` (a stopwatch with microsecond resolution in BeamMP-Server, `TLuaEngine.cpp`). On a server without it the plugin falls back to `os.time`, whole seconds, in which a stalled plugin thread can make an interval look shorter than it was; the checks then need a speed to be over its limit in two samples in a row (and a change of speed over its limit twice in the same direction) before flagging. A jump in distance does not depend on the clock and is flagged at once.
- **Sent in batches, in the background.** Events are held in memory and sent together in one request (`POST /v1/events/batch`) when 100 are waiting or the oldest has waited five seconds (both numbers come from ServerGuardian's settings, and a once-a-second event timer does the sending). The request runs in the background and its answer is picked up on the next tick, so a slow or unreachable ServerGuardian never holds up the server. If the settings do not mention batching (an older ServerGuardian), each event is sent on its own as before, and edits and deletes are not sent. What is waiting is never written to disk, and the plugin also sends what it has when BeamMP says it is shutting down.
- **Backing off.** On a batch, a `429` holds the waiting events for as long as `Retry-After` says (a minute if it does not) and keeps collecting up to 500 meanwhile; a server error or no answer keeps them and tries again after 5 seconds, then longer, up to a minute. The waiting events are limited to 500 (the oldest are dropped first, and only a count is logged at debug level) and an event that has waited ten minutes is dropped. A `422` drops only the events ServerGuardian named, and logs the names of the fields it did not like, never what was in them. A `401`, `402` or any other `403` (a revoked key, a paused plan, a missing permission) pauses game events for ten minutes and drops what was waiting; a `403` that says game events are off turns them off until the next settings refresh. Sent one by one (no batching), a `429` pauses game events for a minute, and the plugin cannot see the answer, so it relies on its settings refresh **every ten minutes** (an event timer, whether or not anyone joins). A refused settings request turns them off. The settings are asked for again every ten minutes whether or not anyone joins, and game events switch themselves off if the settings cannot be refreshed for three hours. Settings that are not usable (a number that is zero, negative or not a number, a cooldown under a second) leave the movement checks off, and the sample period is held between one and ten seconds.
- **Verified against** the BeamMP-Server source and docs (`onVehicleSpawn`, `onVehicleEdited`, `onVehicleReset`, `onVehicleDeleted`, `onShutdown`, `MP.GetPositionRaw`, `MP.GetPlayerVehicles`, `MP.CreateEventTimer`); **not run on a real BeamMP server.** The table keys of `MP.GetPositionRaw` (`pos`, `vel`, ...) come from the official docs, not from running it.

## Shared core and tests

`sg_core.lua` is shared with the [FiveM resource](https://github.com/ServerGuardian/FiveM_Plugin). **This repository is where it is edited.** After a change, run `./sync-core.sh` (it copies to `../FiveM_Plugin`) and commit there too.

The end-to-end tests run this plugin against the real API, so they live in [Backend](https://github.com/ServerGuardian/Backend) (`tests/mods.beammp.e2e.test.ts`), with the fake BeamMP and FiveM environments. Check this repository out next to Backend as `../BeamMP_Plugin` and run `pnpm test` there. Needs `lua` and `curl`. The game-event checks in the core also have their own tests with made-up positions (`tests/mods.game-core.test.ts`), and the chat part of the core has its own (`tests/mod-kit/chat_core_test.lua`, run by `tests/mods.chat-core.test.ts`). `tests/mod-kit/beammp_chat.e2e.test.mjs` runs `main.lua` under the fake BeamMP with real curl against a small fake API (no database: `node --test tests/mod-kit/beammp_chat.e2e.test.mjs`); it checks what `onChatMessage` returns, that chat never reaches a file or a command line, and what is sent.

The earlier 2025 BeamMP resource is kept on the `legacy-2025` branch.
