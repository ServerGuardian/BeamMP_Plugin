# ServerGuardian for BeamMP

A BeamMP server plugin that asks ServerGuardian whether a joining player is linked to an account banned elsewhere. The server only learns **pass** or **block**: never why, never who. If ServerGuardian cannot be reached, players are let in (or kept out, if you set the server to fail closed).

**Status:** tested end to end under a fake BeamMP environment (from the Backend repository), **not yet on a real BeamMP server** (decision D17).

## Install

1. Copy `main.lua`, `sg_core.lua` and `config.example.json` into `Resources/Server/ServerGuardian/` on your BeamMP server.
2. Copy `config.example.json` to `config.json` and set the API address and your server's API key (made in the ServerGuardian portal).
3. Restart the server. The plugin needs `curl` on the host.

Players with a BeamMP guest session have no account id, so they cannot be checked; they are let in and nothing is sent.

## How it works

On join the plugin shows the ServerGuardian notice, sends the player's BeamMP account id and IP address (and, if they agree to the optional hardware check, a hardware token) and removes the player if the answer is "block". Nothing a player controls reaches a shell command, and the key is never logged. When a player leaves, the plugin says so.

## Shared core and tests

`sg_core.lua` is shared with the [FiveM resource](https://github.com/ServerGuardian/FiveM_Plugin). **This repository is where it is edited.** After a change, run `./sync-core.sh` (it copies to `../FiveM_Plugin`) and commit there too.

The end-to-end tests run this plugin against the real API, so they live in [Backend](https://github.com/ServerGuardian/Backend) (`tests/mods.beammp.e2e.test.ts`), with the fake BeamMP and FiveM environments. Check this repository out next to Backend as `../BeamMP_Plugin` and run `pnpm test` there. Needs `lua` and `curl`.

The earlier 2025 BeamMP resource is kept on the `legacy-2025` branch.
