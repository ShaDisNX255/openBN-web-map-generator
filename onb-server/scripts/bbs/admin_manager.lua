-- Admin management for BBS boards
-- Stores admin player secrets in scripts/bbs/admin_list.json
-- Provides functions to check/grant admin status and manage the admin key item

local json = require("scripts/bbs/json")
local sha = require('scripts/bbs/sha256')
-- admin_pass_seed.lua can return either:
--   (A) a string password hash (legacy)
--   (B) a table { pass_hash = "...", admins = { ... } } (hybrid)
local seed_cfg
do
    local ok, v = pcall(require, 'scripts/bbs/admin_pass_seed')
    if ok then seed_cfg = v else seed_cfg = nil end
end

local admin_pass_hash
local seeded_admin_secrets = {}

if type(seed_cfg) == "table" then
    admin_pass_hash = seed_cfg.pass_hash
    seeded_admin_secrets = seed_cfg.admins or {}
else
    admin_pass_hash = seed_cfg -- legacy string hash
    seeded_admin_secrets = {}
end

local BBS_ADMINS = "scripts/bbs/admin_list.json"
local AdminKeyID = "ADMIN_KEY"
local perm_card_details = {
    name = "Admin Key",
    description = "Gives Admin level access to BBS boards.",
    type = "keyitem"
}

-- Match either full secret or the "short" secret variant (secret:sub(2, 32))
local function secret_matches_entry(player_secret, entry)
    if type(player_secret) ~= "string" or type(entry) ~= "string" then
        return false
    end

    if entry == player_secret then
        return true
    end

    local short = player_secret:sub(2, 32)
    if entry == short then
        return true
    end

    return false
end

local function is_seeded_secret(player_secret)
    for _, entry in ipairs(seeded_admin_secrets) do
        if secret_matches_entry(player_secret, entry) then
            return true
        end
    end
    return false
end

local admin_secrets = {}      -- in‑memory list of admin secrets
local saving = false
local pending_save = false


function async(p)
    local co = coroutine.create(p)
    return Async.promisify(co)
end

function await(v) return Async.await(v) end

-- Ensure the admin key item exists (idempotent)
local function ensure_admin_item()
    Net.create_item(AdminKeyID, perm_card_details)
end

-- Load admin list from file
local function load_admin_list()
    Async.read_file(BBS_ADMINS).and_then(function(value)
        if value and value ~= "" then
            local ok, data = pcall(json.decode, value)
            if ok and type(data) == "table" then
                admin_secrets = data
            else
                print("Failed to decode admin list")
            end
        end
    end)
end

-- Save admin list to file (with pretty print)
local function save_admin_list()
    if saving then
        pending_save = true
        return
    end
    saving = true
    Async.write_file(BBS_ADMINS, json.encode(admin_secrets, true)).and_then(function()
        saving = false
        if pending_save then
            pending_save = false
            save_admin_list()
        end
    end)
end

local function add_admin(player_id)
    local secret = Net.get_player_secret(player_id)
    if not secret then return false end

    -- If they're in the seeded list, don't bother writing them to admin_list.json
    if is_seeded_secret(secret) then
        return true
    end

    -- Avoid duplicates
    for _, s in ipairs(admin_secrets) do
        if secret_matches_entry(secret, s) then
            return true
        end
    end

    table.insert(admin_secrets, secret)
    save_admin_list()
    return true
end

local function is_admin(player_id)
    local secret = Net.get_player_secret(player_id)
    if not secret then return false end

    local admin = false

    -- New method: seeded secrets
    if is_seeded_secret(secret) then
        admin = true
    else
        -- Old method: stored secrets in admin_list.json
        for _, s in ipairs(admin_secrets) do
            if secret_matches_entry(secret, s) then
                admin = true
                break
            end
        end
    end

    -- Auto-grant the Admin Key item whenever we confirm admin status
    if admin and not Net.player_has_item(player_id, AdminKeyID) then
        Net.give_player_item(player_id, AdminKeyID)
    end

    return admin
end

-- Called when a player connects: give admin key if they are in the list
local function on_player_connect(player_id)
    is_admin(player_id) -- will auto-grant Admin Key if admin (seeded or listed)
end

-- Verify password attempt; if correct, add to admin list and give item
local function check_password_and_grant(player_id, password_attempt)
    if sha.sha256(password_attempt) == admin_pass_hash then
        add_admin(player_id)
        if not Net.player_has_item(player_id, AdminKeyID) then
            Net.give_player_item(player_id, AdminKeyID)
        end
        return true
    end
    return false
end

-- Initialise: create item and load existing admins
ensure_admin_item()
load_admin_list()

return {
    on_player_connect = on_player_connect,
    check_password_and_grant = check_password_and_grant,
    is_admin = is_admin,
    add_admin = add_admin,
}
