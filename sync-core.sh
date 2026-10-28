#!/bin/sh
# Copies the shared core into each platform's folder. Run after editing shared/sg_core.lua.
# (Each platform loads files from its own folder, so each ships its own copy; a test checks they match.)
set -e
cd "$(dirname "$0")"
for target in beammp/ServerGuardian fivem/serverguardian; do
  cp shared/sg_core.lua "$target/sg_core.lua"
done
