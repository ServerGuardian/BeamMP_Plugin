fx_version "cerulean"
game "common"
lua54 "yes"

name "serverguardian"
author "BeamMP Ltd"
description "ServerGuardian: checks joining players against accounts banned elsewhere. The server only learns pass or block."
version "0.1.0"

server_scripts {
  "sg_core.lua",
  "config.lua",
  "server.lua",
}
