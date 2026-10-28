# ServerGuardian for BeamMP

A BeamMP server plugin that asks ServerGuardian whether a joining player is linked to an account banned elsewhere. The server only learns **pass** or **block**: never why, never who. If ServerGuardian cannot be reached, players are let in (or kept out, if you set the server to fail closed).

**Status:** tested end to end under a fake BeamMP environment (from the Backend repository), **not yet on a real BeamMP server** (decision D17).

## Install

1. Copy `main.lua`, `sg_core.lua` and `config.example.json` into `Resources/Server/ServerGuardian/` on your BeamMP server.
2. Copy `config.example.json` to `config.json` and set the API address and your server's API key (made in the ServerGuardian portal).
3. Restart the server. The plugin needs `curl` on the host.

Players with a BeamMP guest session have no account id, so they cannot be checked or banned; they are let in and nothing is sent. That makes guests a way around any ban. To refuse them, set `AllowGuests = false` under `[General]` in BeamMP's `ServerConfig.toml` (or `BEAMMP_ALLOW_GUESTS=false`): it is BeamMP's own setting, and your choice.

## How it works

On join the plugin shows the ServerGuardian notice, sends the player's BeamMP account id and IP address (and, if they agree to the optional hardware check, a hardware token) and removes the player if the answer is "block". Nothing a player controls reaches a shell command, and the key is never logged. When a player leaves, the plugin says so.

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

## Shared core and tests

`sg_core.lua` is shared with the [FiveM resource](https://github.com/ServerGuardian/FiveM_Plugin). **This repository is where it is edited.** After a change, run `./sync-core.sh` (it copies to `../FiveM_Plugin`) and commit there too.

The end-to-end tests run this plugin against the real API, so they live in [Backend](https://github.com/ServerGuardian/Backend) (`tests/mods.beammp.e2e.test.ts`), with the fake BeamMP and FiveM environments. Check this repository out next to Backend as `../BeamMP_Plugin` and run `pnpm test` there. Needs `lua` and `curl`.

The earlier 2025 BeamMP resource is kept on the `legacy-2025` branch.
