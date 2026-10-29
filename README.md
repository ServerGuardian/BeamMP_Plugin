# ServerGuardian for BeamMP

A BeamMP server plugin that asks ServerGuardian whether a joining player is linked to an account banned elsewhere. The server only learns **pass** or **block**: never why, never who. If ServerGuardian cannot be reached, players are let in (or kept out, if you set `failMode` to `closed`).

**Status:** tested end to end under a fake BeamMP environment (from the Backend repository), **not yet on a real BeamMP server** (decision D17).

## Install

1. Copy `main.lua`, `sg_core.lua` and `config.example.json` into `Resources/Server/ServerGuardian/` on your BeamMP server.
2. Copy `config.example.json` to `config.json` and set the API address and your server's API key (made in the ServerGuardian portal), then check the `settings` block (see Settings below).
3. Restart the server. The plugin needs `curl` on the host.

Players with a BeamMP guest session have no account id, so they cannot be checked or banned; they are let in and nothing is sent. That makes guests a way around any ban. To refuse them, set `AllowGuests = false` under `[General]` in BeamMP's `ServerConfig.toml` (or `BEAMMP_ALLOW_GUESTS=false`): it is BeamMP's own setting, and your choice.

## Settings

This server's behaviour is set in **`config.json`, in the `settings` object**, next to the API key. The ServerGuardian portal only **shows** what each server is set to (read-only, with when the plugin last reported it); it cannot change them.

| Setting | Values | Default | What it does |
|---|---|---|---|
| `failMode` | `open` or `closed` | `open` | What happens when ServerGuardian cannot be reached. `open` lets players in; `closed` keeps them out. It applies from here even if ServerGuardian has never been reached. |
| `gameEvents` | `true` or `false` | `false` | Send spawns (where the game allows) and run ServerGuardian's movement checks, sending only a flag. See "Game events" below. |
| `reports` | `true` or `false` | `false` | Let players report each other with `/report`. See "Player reports" below. |
| `shareBans` | `true` or `false` | `true` | Use bans recorded on your other ServerGuardian servers here too, and share this server's bans with them. Turn it off for a server that should keep its own list. Bans reported to other server owners are not affected. |
| `youthOriented` | `true` or `false` | `false` | This server or event is for players under 18. Their data is handled more strictly: no hardware check, shorter records, and game events are neither kept nor sent on to webhooks. |

- Use JSON `true` and `false` without quotes.
- **Any setting you leave out keeps the value it already had**, so an older config file never changes a server's youth-oriented protection or anything else.
- A value that is not valid (for example `"yes"` instead of `true`) is ignored, with a line in the log that names the setting but never repeats what was written.
- The plugin tells ServerGuardian its settings when it starts and at every refresh (every ten minutes), so a change applies after a restart or at the next refresh. A server can change its settings at most **10 times an hour**; if that is exceeded the plugin carries on with what the file says and logs that ServerGuardian refused the change.
- Join rules (what blocks a player: your own bans, other owners' bans, account links, minimum standing) are still set in the portal.

## How it works

On join the plugin shows the ServerGuardian notice, sends the player's BeamMP account id and IP address (and, if they agree to the optional hardware check, a hardware token) and removes the player if the answer is "block". Nothing a player controls reaches a shell command, and the key is never logged. When a player leaves, the plugin says so.


**Heartbeat.** About once a minute (and once at start-up) the plugin tells ServerGuardian it is there and how many players are on, so the portal can show the server as online or offline. The count is the only thing sent, it is never logged, and it runs whether or not game events or reports are on. BeamMP waits for the answer (with the usual time limit), at most one at a time. A refused key, plan or permission pauses it for ten minutes, too many requests for one.

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

When **`gameEvents`** is `true` in `settings` (off by default), the plugin tells ServerGuardian when a player **spawns a vehicle** and runs two **movement checks** on the server: a speed or a jump the game could not produce, and a change of speed that is not believable. The operator sees them in the portal (on plans that keep history) and can have them sent to a webhook.

- **What is sent:** for a spawn, the short name of what was spawned (the `jbm` model name in the spawn data, or just `vehicle` if it cannot be read); for a flag, which check failed (`impossible_move` or `acceleration`) and whether it was `low` or `high`. Both carry the id of the player's join (the reference ServerGuardian already has for them) and a short label, the player's in-game name with only letters, digits, spaces and `_ . : / -` kept. **What is never sent:** a position or any coordinate, chat, an IP address, a platform id, or a hardware id. Nothing about an event (label, item, ids) is ever logged.
- **The numbers come from ServerGuardian.** The speed, jump and acceleration limits, and how often to look, are in the settings the plugin already fetches, so they can be tuned without a new release. They are placeholders until they have been tried on real servers.
- **A flag is a prompt for a person to look.** Nothing is ever kicked, banned or messaged because of one. A given check flags a given player at most once a minute (however many vehicles they have, and deleting a vehicle does not reset that), and a player is held to 20 spawns and 10 flags a minute, counted separately, with 400 events a minute for the server.
- While game events are off (the default) the plugin does not sample or send anything at all.
- Checks use `MP.GetPositionRaw` (a table with `pos = {x, y, z}`) once a second for each of a player's vehicles, driven by `MP.CreateEventTimer`; a vehicle reset (`onVehicleReset`) starts that vehicle's track again, so a reset is not a jump. **The first two samples after a spawn or a reset are not used**, and neither is a position that is missing or exactly zero, because the position may not be right yet. The handlers return nothing, so a spawn is never cancelled by this plugin; another plugin may cancel it afterwards and this one cannot tell, so a cancelled spawn is still reported. Vehicles spawned before the plugin started are not checked until they are respawned.
- **The clock.** The checks time their samples with `MP.CreateTimer()` (a stopwatch with microsecond resolution in BeamMP-Server, `TLuaEngine.cpp`). On a server without it the plugin falls back to `os.time`, whole seconds, in which a stalled plugin thread can make an interval look shorter than it was; the checks then need a speed to be over its limit in two samples in a row (and a change of speed over its limit twice in the same direction) before flagging. A jump in distance does not depend on the clock and is flagged at once.
- Game events are sent in the background (like leave events), so a slow or unreachable ServerGuardian never holds up the server. The plugin therefore cannot see the answer to an event; it relies on its own limits and on a settings refresh **every ten minutes** (an event timer, whether or not anyone joins), which says if the operator has switched game events off or the key no longer works. A server with nobody on it stops sending within ten minutes of being switched off.
- **Backing off.** A `429` pauses game events for a minute. A `401`, `402` or any `403` (a revoked key, a paused plan, a missing permission) pauses them for ten, and a refused settings request turns them off. The settings are asked for again every ten minutes whether or not anyone joins, and game events switch themselves off if the settings cannot be refreshed for three hours. Settings that are not usable (a number that is zero, negative or not a number, a cooldown under a second) leave the movement checks off, and the sample period is held between one and ten seconds.
- **Verified against** the BeamMP-Server source and docs (`onVehicleSpawn`, `onVehicleReset`, `onVehicleDeleted`, `MP.GetPositionRaw`, `MP.GetPlayerVehicles`, `MP.CreateEventTimer`); **not run on a real BeamMP server.** The table keys of `MP.GetPositionRaw` (`pos`, `vel`, ...) come from the official docs, not from running it.

## Shared core and tests

`sg_core.lua` is shared with the [FiveM resource](https://github.com/ServerGuardian/FiveM_Plugin). **This repository is where it is edited.** After a change, run `./sync-core.sh` (it copies to `../FiveM_Plugin`) and commit there too.

The end-to-end tests run this plugin against the real API, so they live in [Backend](https://github.com/ServerGuardian/Backend) (`tests/mods.beammp.e2e.test.ts`), with the fake BeamMP and FiveM environments. Check this repository out next to Backend as `../BeamMP_Plugin` and run `pnpm test` there. Needs `lua` and `curl`. The game-event checks in the core also have their own tests with made-up positions (`tests/mods.game-core.test.ts`).

The earlier 2025 BeamMP resource is kept on the `legacy-2025` branch.
