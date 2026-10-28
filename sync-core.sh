#!/bin/sh
# sg_core.lua is shared with the FiveM resource. It is edited here (this repository is the source of
# truth) and copied to ../FiveM_Plugin. A test in the Backend repository checks the two copies match.
set -e
cd "$(dirname "$0")"
cp sg_core.lua ../FiveM_Plugin/sg_core.lua
echo "Copied sg_core.lua to ../FiveM_Plugin. Commit it there too."
