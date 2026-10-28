# ServerGuardian game-server mods

The mods that put ServerGuardian's join check into game servers. Each one sends a pass-or-block question to the ServerGuardian API when a player joins and lets the player in if the API cannot be reached (unless the owner chose otherwise).

| Folder | Platform | State |
|---|---|---|
| `beammp/ServerGuardian` | BeamMP server plugin (Lua) | Tested end to end under a fake BeamMP, not yet on a real server (D17) |
| `fivem/serverguardian` | FiveM resource (Lua) | Tested end to end under a fake FiveM runtime, not yet on a real server (D18) |
| `minecraft` | Paper plugin (Java) | Written, **not compiled or run** (needs JDK 21) |
| `shared/sg_core.lua` | The shared Lua core | Source of truth for the two Lua mods |
| `test-kit` | Fake BeamMP and FiveM environments, and a JSON helper | Used by the tests |

After editing `shared/sg_core.lua`, run `./sync-core.sh` (each platform loads files from its own folder, so each ships a copy).

**Where the tests are.** The mod tests run these mods under Lua against the real API, so they live in the Backend repository (`tests/mods.*.test.ts`). Check this repository out next to Backend (`../BeamMP_Resource`) or set `MODS_DIR`, and run `pnpm test` there. Needs `lua` and `curl`.

**Why FiveM and Minecraft are here.** The organisation had no repositories for them. This one was the closest existing home. Moving them to their own repositories later is a copy of a folder; update `MODS_DIR` or the layout in Backend's `tests/mods-helpers.ts` if you do.

The earlier 2025 BeamMP resource is still on `main`.
