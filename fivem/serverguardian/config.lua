-- ServerGuardian settings that are not secret. The API key and address go in server.cfg:
--
--   set serverguardian_api_base "https://api.serverguardian.example"
--   set serverguardian_api_key  "sg_xxxxxxxx_your-key-here"
--
-- (Use `set`, not `setr`: a replicated convar would be sent to every player.)

Config = {
  -- What to do when ServerGuardian cannot be reached: "open" lets players in, "closed" keeps them
  -- out. Once the API has been reached, the setting chosen in your ServerGuardian dashboard wins.
  failMode = "open",

  -- How long to wait for an answer before applying failMode.
  timeoutMs = 3000,

  -- Offer players the optional hardware check, and send the hardware tokens FiveM supplies for those
  -- who agree. Set to false to match on IP and account ids only (no prompt is shown).
  collectHardware = true,

  -- How long a player has to answer the hardware prompt before it counts as "not answered".
  promptTimeoutMs = 90000,
}
