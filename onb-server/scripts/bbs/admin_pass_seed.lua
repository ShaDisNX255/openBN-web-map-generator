local sha = require('scripts/bbs/sha256')

local seed_pass = "INPUT_YOUR_SEED_HERE"
local pass_hash = sha.sha256(seed_pass)

return {
  -- used by the OLD method (Admin Console password prompt)
  pass_hash = pass_hash,

  -- used by the NEW method (auto-admin by secret id)
  admins = {
    -- Put player secrets here (either full secret OR the short secret variant)
    -- "FULL_PLAYER_SECRET_HERE",
  "SECRET_ID",
  }
}