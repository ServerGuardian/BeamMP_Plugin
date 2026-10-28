# ServerGuardian for Paper

**Status: written but not yet compiled or run.** This machine has no JDK, so unlike the BeamMP and
FiveM mods (which are tested end to end, see `docs/mods.md` in the Internal repository, and the Backend repository's mod tests) this plugin has not been built. Build and
test it on a Paper server before relying on it.

## Build

```bash
cd minecraft
gradle build        # needs JDK 21; the jar is in build/libs/
```

If the Paper API version in `build.gradle.kts` does not resolve, set it to the version you run.

## Install

Copy the jar into the server's `plugins/` folder, start the server once, edit
`plugins/ServerGuardian/config.yml` (API key and address), and restart.

## How it works

1. A player joins. The ServerGuardian notice is shown in chat.
2. Off the main thread the plugin sends the player's Minecraft UUID and IP address to ServerGuardian
   (`POST /v1/join-check`) and waits up to `timeout-ms`.
3. On `block`, the player is removed with a fixed message that links to the appeal page and never says
   why. On `pass` nothing happens. On any failure `fail-mode` applies.

A Minecraft server cannot read a hardware id, so none is collected and there is no opt-in prompt.
