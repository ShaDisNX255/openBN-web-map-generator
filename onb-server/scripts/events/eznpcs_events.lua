local ezwarps = require("scripts/ezlibs-scripts/ezwarps/main")
local eznpcs = require('scripts/ezlibs-scripts/eznpcs/eznpcs')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezencounters = require('scripts/ezlibs-scripts/ezencounters/main')
local eztriggers = require("scripts/ezlibs-scripts/eztriggers")

local TAG_MEM_AREA_ID = "default"
local TAG_MEM_KEY = "website_tags_v1"
local TAG_BBS_COLOR = { r = 120, g = 210, b = 255 }

local TAG_TRAP_VIRUS_COST = 300
local TAG_TRAP_BOSS_COST = 1500

local TAG_DOMAIN_LABEL_OVERRIDES = {
    capcom = "Capcom",
    github = "GitHub",
    microsoft = "Microsoft",
    nintendo = "Nintendo",
    reddit = "Reddit",
    wikipedia = "Wikipedia",
    xbox = "Xbox",
    youtube = "YouTube",
}

local TAG_DOMAIN_ALIASES = {
    ["capcom"] = "capcom.com",
    ["capcom.com"] = "capcom.com",
    ["capcomusa"] = "capcom.com",
    ["capcomusa.com"] = "capcom.com",
}

local COMMON_SECOND_LEVEL_TLDS = {
    ac = true, co = true, com = true, edu = true, gov = true, net = true, org = true,
}

local RETURN_INDEX_AREA_ID = "default"
-- fill these in with your actual default-page spawn spot
local RETURN_INDEX_X = 1
local RETURN_INDEX_Y = 1
local RETURN_INDEX_Z = 0
local RETURN_INDEX_DIRECTION = "Down"

local return_index_prompt_open = {}

local function can_open_return_prompt(player_id)
    if return_index_prompt_open[player_id] then
        return false
    end

    return true
end

local website_navigator_warp_locks = {}

local function setup_website_navigator_warps()
  local areas = Net.list_areas()

  for _, area_id in next, areas do
    local objects = Net.list_objects(area_id)

    for _, object_id in next, objects do
      local object = Net.get_object_by_id(area_id, object_id)

      if object and object.type == "Website Navigator Warp" then
        local radius = tonumber(object.custom_properties["Activation Radius"] or 1) or 1
        local diameter = radius * 2

        local emitter = eztriggers.add_radius_trigger(area_id, object, diameter, diameter, 0, 0)

        if emitter then
          emitter:on("entered", function(event)
            local player_id = event.player_id

            if website_navigator_warp_locks[player_id] then
              return
            end

            website_navigator_warp_locks[player_id] = true

            async(function()
              ezwarps.handle_player_request(player_id, "return_to_index")
              await(Async.sleep(0.5))
              website_navigator_warp_locks[player_id] = nil
            end)
          end)
        end
      end
    end
  end
end

setup_website_navigator_warps()

local function open_return_prompt(player_id)
    if not can_open_return_prompt(player_id) then
        return
    end

    local mug = Net.get_player_mugshot(player_id)
    return_index_prompt_open[player_id] = true

    async(function()
        local res = await(Async.question_player(
            player_id,
            "Do you want to return to the index?",
            mug.texture_path,
            mug.animation_path
        ))

        return_index_prompt_open[player_id] = nil

        print("[return_to_index] response for", tostring(player_id), "=", tostring(res))

        -- question_player uses 1 for Yes / first branch, 0 for No / second branch
        if tonumber(res) == 1 then
            print("[return_to_index] YES selected for", tostring(player_id))

            local ezwarps = require("scripts/ezlibs-scripts/ezwarps/main")
            ezwarps.handle_player_request(player_id, "return_to_index")
        else
            print("[return_to_index] NO selected for", tostring(player_id))
        end
    end)
end

local function _safe_name(pid)
    local ok, name = pcall(Net.get_player_name, pid)
    if ok and name and name ~= "" then
        return tostring(name)
    end
    return tostring(pid)
end

local function _safe_secret(pid)
    if helpers and helpers.get_safe_player_secret then
        local ok, secret = pcall(helpers.get_safe_player_secret, pid)
        if ok and secret and secret ~= "" then
            return tostring(secret)
        end
    end
    return tostring(pid)
end

local function _title_words(value)
    local cleaned = tostring(value or ""):gsub("[-_]+", " ")
    return (cleaned:gsub("(%a)([%w']*)", function(a, b)
        return string.upper(a) .. string.lower(b)
    end))
end

local function _registrable_host(host)
    local parts = {}
    for part in tostring(host or ""):lower():gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end

    if #parts <= 2 then
        return table.concat(parts, ".")
    end

    local tld = parts[#parts]
    local sld = parts[#parts - 1]
    if #tld == 2 and COMMON_SECOND_LEVEL_TLDS[sld] and #parts >= 3 then
        return table.concat({ parts[#parts - 2], sld, tld }, ".")
    end

    return table.concat({ sld, tld }, ".")
end

local function _normalize_tag_domain(domain, label)
    local raw_domain = tostring(domain or ""):lower()
    local normalized = TAG_DOMAIN_ALIASES[raw_domain] or raw_domain

    if normalized == "capcom.com" then
        return "capcom.com", "Capcom"
    end

    return domain, label
end

local function _domain_info_for_area(area_id)
    local ok_domain, tag_domain = pcall(Net.get_area_custom_property, area_id, "Tag Domain")
    local ok_label, tag_label = pcall(Net.get_area_custom_property, area_id, "Tag Domain Label")
    local ok_url, raw_url = pcall(Net.get_area_custom_property, area_id, "URL")

    local domain = (ok_domain and tag_domain and tostring(tag_domain) ~= "" and tostring(tag_domain)) or nil
    local label = (ok_label and tag_label and tostring(tag_label) ~= "" and tostring(tag_label)) or nil
    local raw = (ok_url and raw_url and tostring(raw_url)) or ""

    if not domain or domain == "" then
        local host = raw:match("^https?://([^/%?#:]+)") or raw:match("^([^/%?#:]+)")
        if host and host ~= "" then
            domain = _registrable_host(host)
        else
            domain = tostring(area_id)
        end
    end

    if not label or label == "" then
        local base = tostring(domain):match("^([^.]+)") or tostring(domain)
        label = TAG_DOMAIN_LABEL_OVERRIDES[base] or _title_words(base)
    end
    domain, label = _normalize_tag_domain(domain, label)
    return domain, label, raw
end

local function _current_tag_generation_id()
    local ok, generation_id = pcall(Net.get_area_custom_property, TAG_MEM_AREA_ID, "Generation Date")
    if ok and generation_id ~= nil then
        return tostring(generation_id)
    end
    return "no_generation_date"
end

local _archive_tag_history

local function _rebuild_domains_from_pages(store)
    local rebuilt = {}

    for _, page in pairs(store.pages or {}) do
        local owner_key = page.owner_key
        if owner_key and owner_key ~= "" then
            local domain_key = tostring(page.domain_key or "")
            local domain_label = tostring(page.domain_label or domain_key)

            local bucket = rebuilt[domain_key]
            if not bucket then
                bucket = {
                    label = domain_label,
                    owners = {},
                }
                rebuilt[domain_key] = bucket
            end

            bucket.label = domain_label

            local row = bucket.owners[owner_key]
            if not row then
                row = {
                    name = page.owner_name or "Unknown",
                    count = 0,
                }
                bucket.owners[owner_key] = row
            end

            row.name = page.owner_name or row.name or "Unknown"
            row.count = (tonumber(row.count or 0) or 0) + 1
        end
    end

    store.domains = rebuilt
end

local function _merge_season_wins(dst, src)
    dst = dst or {}
    for owner_key, row in pairs(src or {}) do
        local existing = dst[owner_key]
        if not existing then
            dst[owner_key] = {
                name = row.name or "Unknown",
                wins = tonumber(row.wins or 0) or 0,
            }
        else
            existing.name = row.name or existing.name or "Unknown"
            existing.wins = (tonumber(existing.wins or 0) or 0) + (tonumber(row.wins or 0) or 0)
        end
    end
    return dst
end

local function _pick_better_record(a, b)
    if not a then return b end
    if not b then return a end

    local ac = tonumber(a.count or 0) or 0
    local bc = tonumber(b.count or 0) or 0
    if bc > ac then
        return b
    end
    return a
end

local function _pick_newer_last_winner(a, b)
    if not a then return b end
    if not b then return a end

    local at = tonumber(a.at or 0) or 0
    local bt = tonumber(b.at or 0) or 0
    if bt > at then
        return b
    end
    return a
end

local function _migrate_tag_domain_aliases(store)
    local changed = false

    for _, page in pairs(store.pages or {}) do
        local old_key = tostring(page.domain_key or "")
        local old_label = tostring(page.domain_label or "")
        local new_key, new_label = _normalize_tag_domain(old_key, old_label)

        if new_key ~= old_key or new_label ~= old_label then
            page.domain_key = new_key
            page.domain_label = new_label
            changed = true
        end
    end

    if changed then
        _rebuild_domains_from_pages(store)
    end

    local history_domains = (((store or {}).history or {}).domains)
    if history_domains then
        local src = history_domains["capcomusa.com"] or history_domains["capcomusa"]
        if src then
            local dst = history_domains["capcom.com"]
            if not dst then
                dst = {
                    label = "Capcom",
                    season_wins = {},
                    last_winner = nil,
                    record_holder = nil,
                }
                history_domains["capcom.com"] = dst
            end

            dst.label = "Capcom"
            dst.season_wins = _merge_season_wins(dst.season_wins, src.season_wins)
            dst.last_winner = _pick_newer_last_winner(dst.last_winner, src.last_winner)
            dst.record_holder = _pick_better_record(dst.record_holder, src.record_holder)

            history_domains["capcomusa.com"] = nil
            history_domains["capcomusa"] = nil
            changed = true
        end
    end

    return changed
end

local function _get_tag_store()
    local mem = ezmemory.get_area_memory(TAG_MEM_AREA_ID) or {}
    mem[TAG_MEM_KEY] = mem[TAG_MEM_KEY] or {}

    local store = mem[TAG_MEM_KEY]
    store.pages = store.pages or {}
    store.domains = store.domains or {}
    store.history = store.history or { domains = {} }

    local migrated = _migrate_tag_domain_aliases(store)
    local generation_id = _current_tag_generation_id()

    if store.generation_id ~= generation_id then
        if store.generation_id ~= nil and _archive_tag_history then
            _archive_tag_history(store)
        end

        mem[TAG_MEM_KEY] = {
            generation_id = generation_id,
            pages = {},
            domains = {},
            history = store.history or { domains = {} },
        }
        store = mem[TAG_MEM_KEY]
        ezmemory.save_area_memory(TAG_MEM_AREA_ID)
    end

    if migrated then
        ezmemory.save_area_memory(TAG_MEM_AREA_ID)
    end

    return mem, store
end

local function _ensure_owner_row(domain_bucket, owner_key)
    domain_bucket.owners = domain_bucket.owners or {}
    local row = domain_bucket.owners[owner_key]
    if not row then
        row = { name = "Unknown", count = 0 }
        domain_bucket.owners[owner_key] = row
    end
    return row
end

local function _decrement_owner(domain_bucket, owner_key)
    if not domain_bucket or not domain_bucket.owners or not owner_key then
        return
    end

    local row = domain_bucket.owners[owner_key]
    if not row then
        return
    end

    row.count = math.max(0, (tonumber(row.count or 0) or 0) - 1)
    if row.count <= 0 then
        domain_bucket.owners[owner_key] = nil
    end
end

local function _short_name(value, limit)
    local text = tostring(value or "Unknown")
    if #text > limit then
        return text:sub(1, limit)
    end
    return text
end

local function _collect_domain_rows(store)
    local rows = {}

    for domain_key, domain_bucket in pairs(store.domains or {}) do
        local owner_rows = {}
        local total = 0

        for owner_key, owner in pairs(domain_bucket.owners or {}) do
            local count = tonumber(owner.count or 0) or 0
            if count > 0 then
                total = total + count
                owner_rows[#owner_rows + 1] = {
                    key = owner_key,
                    name = owner.name or "Unknown",
                    count = count,
                }
            end
        end

        if total > 0 then
            table.sort(owner_rows, function(a, b)
                if a.count ~= b.count then
                    return a.count > b.count
                end
                return tostring(a.name) < tostring(b.name)
            end)

            rows[#rows + 1] = {
                key = domain_key,
                label = domain_bucket.label or domain_key,
                total = total,
                owners = owner_rows,
            }
        end
    end

    table.sort(rows, function(a, b)
        if a.total ~= b.total then
            return a.total > b.total
        end
        return tostring(a.label) < tostring(b.label)
    end)

    return rows
end

local function _pick_random_domain_winner(owner_rows)
    if not owner_rows or #owner_rows == 0 then
        return nil
    end

    local top_count = tonumber(owner_rows[1].count or 0) or 0
    if top_count <= 0 then
        return nil
    end

    local tied = {}
    for _, row in ipairs(owner_rows) do
        local count = tonumber(row.count or 0) or 0
        if count == top_count then
            tied[#tied + 1] = row
        else
            break
        end
    end

    if #tied == 0 then
        return nil
    end

    return tied[math.random(1, #tied)]
end

local function _get_most_wins_row(season_wins)
    local rows = {}

    for owner_key, row in pairs(season_wins or {}) do
        local wins = tonumber(row.wins or 0) or 0
        if wins > 0 then
            rows[#rows + 1] = {
                key = owner_key,
                name = row.name or "Unknown",
                wins = wins,
            }
        end
    end

    if #rows == 0 then
        return nil
    end

    table.sort(rows, function(a, b)
        if a.wins ~= b.wins then
            return a.wins > b.wins
        end
        return tostring(a.name) < tostring(b.name)
    end)

    return rows[1]
end

_archive_tag_history = function(store)
    if not store then
        return
    end

    store.history = store.history or { domains = {} }
    store.history.domains = store.history.domains or {}

    local domain_rows = _collect_domain_rows(store)
    local now = os.time()

    for _, domain in ipairs(domain_rows) do
        local winner = _pick_random_domain_winner(domain.owners)

        if winner then
            local history_domain = store.history.domains[domain.key]
            if not history_domain then
                history_domain = {
                    label = domain.label,
                    season_wins = {},
                    last_winner = nil,
                    record_holder = nil,
                }
                store.history.domains[domain.key] = history_domain
            end

            history_domain.label = domain.label
            history_domain.season_wins = history_domain.season_wins or {}

            history_domain.last_winner = {
                key = winner.key,
                name = winner.name,
                count = tonumber(winner.count or 0) or 0,
                generation_id = tostring(store.generation_id or ""),
                at = now,
            }

            local win_row = history_domain.season_wins[winner.key]
            if not win_row then
                win_row = { name = winner.name, wins = 0 }
                history_domain.season_wins[winner.key] = win_row
            end

            win_row.name = winner.name
            win_row.wins = (tonumber(win_row.wins or 0) or 0) + 1

            local winner_count = tonumber(winner.count or 0) or 0
            local current_record = tonumber(history_domain.record_holder and history_domain.record_holder.count or 0) or 0

            if (not history_domain.record_holder) or winner_count > current_record then
                history_domain.record_holder = {
                    key = winner.key,
                    name = winner.name,
                    count = winner_count,
                    generation_id = tostring(store.generation_id or ""),
                    at = now,
                }
            end
        end
    end
end

local function _collect_history_rows(store)
    local rows = {}
    local history_domains = (((store or {}).history or {}).domains) or {}

    for domain_key, history_domain in pairs(history_domains) do
        local most_wins = _get_most_wins_row(history_domain.season_wins)
        local last_winner = history_domain.last_winner
        local record_holder = history_domain.record_holder

        if last_winner or most_wins or record_holder then
            rows[#rows + 1] = {
                key = domain_key,
                label = history_domain.label or domain_key,
                last_winner = last_winner,
                most_wins = most_wins,
                record_holder = record_holder,
            }
        end
    end

    table.sort(rows, function(a, b)
        return tostring(a.label) < tostring(b.label)
    end)

    return rows
end

local function _open_website_tag_board(pid)
    local _, store = _get_tag_store()
    local posts = {}
    local domain_rows = _collect_domain_rows(store)
    local history_rows = _collect_history_rows(store)

    posts[#posts + 1] = {
        id = "__tagbbs:current:header",
        read = true,
        title = "== Current Season ==",
        author = "",
    }

    if #domain_rows == 0 then
        posts[#posts + 1] = {
            id = "__tagbbs:current:none",
            read = true,
            title = "(No tags yet this season)",
            author = "",
        }
    else
        for _, domain in ipairs(domain_rows) do
            posts[#posts + 1] = {
                id = "__tagbbs:domain:" .. tostring(domain.key),
                read = true,
                title = string.format("-- %s --", domain.label),
                author = "",
            }

            for _, row in ipairs(domain.owners) do
                posts[#posts + 1] = {
                    id = string.format("__tagbbs:row:%s:%s", tostring(domain.key), tostring(row.key)),
                    read = true,
                    title = string.format("%s: %d", _short_name(row.name, 18), row.count),
                    author = "",
                }
            end
        end
    end

    posts[#posts + 1] = {
        id = "__tagbbs:history:header",
        read = true,
        title = "== History ==",
        author = "",
    }

    if #history_rows == 0 then
        posts[#posts + 1] = {
            id = "__tagbbs:history:none",
            read = true,
            title = "(No completed seasons yet)",
            author = "",
        }
    else
        for _, domain in ipairs(history_rows) do
            posts[#posts + 1] = {
                id = "__tagbbs:history:domain:" .. tostring(domain.key),
                read = true,
                title = string.format("-- %s --", domain.label),
                author = "",
            }

            local last_line = "Last: (None)"
            if domain.last_winner then
                last_line = string.format(
                    "Last: %s (%d)",
                    _short_name(domain.last_winner.name, 14),
                    tonumber(domain.last_winner.count or 0) or 0
                )
            end

            local wins_line = "Wins: (None)"
            if domain.most_wins then
                wins_line = string.format(
                    "Wins: %s (%d)",
                    _short_name(domain.most_wins.name, 14),
                    tonumber(domain.most_wins.wins or 0) or 0
                )
            end

            local record_line = "Record: (None)"
            if domain.record_holder then
                record_line = string.format(
                    "Record: %s (%d)",
                    _short_name(domain.record_holder.name, 12),
                    tonumber(domain.record_holder.count or 0) or 0
                )
            end

            posts[#posts + 1] = {
                id = "__tagbbs:history:last:" .. tostring(domain.key),
                read = true,
                title = last_line,
                author = "",
            }

            posts[#posts + 1] = {
                id = "__tagbbs:history:wins:" .. tostring(domain.key),
                read = true,
                title = wins_line,
                author = "",
            }

            posts[#posts + 1] = {
                id = "__tagbbs:history:record:" .. tostring(domain.key),
                read = true,
                title = record_line,
                author = "",
            }
        end
    end

    posts[#posts + 1] = {
        id = "__tagbbs:close",
        read = true,
        title = "Close",
        author = "",
    }

    Net.open_board(pid, "Web Tags", TAG_BBS_COLOR, posts)
end

local function _trap_label(trap_type)
    if trap_type == "boss" then
        return "Boss Trap"
    end
    return "Virus Trap"
end

local function _trap_cost(trap_type)
    if trap_type == "boss" then
        return TAG_TRAP_BOSS_COST
    end
    return TAG_TRAP_VIRUS_COST
end

local function _player_won_trap_battle(stats)
    if not stats then
        return false
    end

    local reason = tonumber(stats.reason or 0) or 0
    local hp = tonumber(stats.health or stats.player_hp or stats.hp or 0) or 0

    if reason == 1 then
        return true
    end
    if reason == 2 or reason == 3 or reason == 4 then
        return false
    end

    if stats.ran or stats.fled or stats.escape then
        return false
    end

    return hp > 0
end

local function _offer_trap_setup(pid, page_state)
    return async(function()
        if not page_state or not page_state.owner_key then
            return
        end

        local mug = Net.get_player_mugshot(pid)
        local prompt = "Do you want to set a trap on this tag?"

        if page_state.trap and page_state.trap.kind then
            prompt = "This tag already has a " .. _trap_label(page_state.trap.kind) .. ". Replace it?"
        end

        local wants_trap = await(Async.question_player(
            pid,
            prompt,
            mug.texture_path,
            mug.animation_path
        ))

        if tonumber(wants_trap) ~= 1 then
            return
        end

        local pick = await(Async.quiz_player(
            pid,
            "Virus Trap",
            "Boss Trap",
            "Cancel",
            mug.texture_path,
            mug.animation_path
        ))

        local trap_type = nil
        if tonumber(pick) == 0 then
            trap_type = "virus"
        elseif tonumber(pick) == 1 then
            trap_type = "boss"
        else
            return
        end

        local cost = _trap_cost(trap_type)
        if not ezmemory.spend_player_money(pid, cost) then
            await(Async.message_player(pid, string.format(
                "You need %d monies to set a %s.",
                cost,
                _trap_label(trap_type)
            )))
            return
        end

        page_state.trap = {
            kind = trap_type,
            armed_by_key = page_state.owner_key,
            armed_by_name = page_state.owner_name,
            cost = cost,
            armed_at = os.time(),
        }

        ezmemory.save_area_memory(TAG_MEM_AREA_ID)

        await(Async.message_player(pid, string.format(
            "%s armed for %d monies.",
            _trap_label(trap_type),
            cost
        )))
    end)
end

local function _challenge_existing_trap(pid, area_id, previous_page_state)
    return async(function()
        if not previous_page_state or not previous_page_state.trap or not previous_page_state.trap.kind then
            return true
        end

        local trap_type = previous_page_state.trap.kind
        local owner_name = previous_page_state.owner_name or "Someone"

        await(Async.message_player(pid, string.format(
            "%s's tag is protected by a %s. Beat it to overwrite this tag.",
            owner_name,
            _trap_label(trap_type)
        )))

        local stats = await(ezencounters.begin_tag_trap(pid, area_id, trap_type))
        if not _player_won_trap_battle(stats) then
            await(Async.message_player(pid, "The trap held. The tag stays put."))
            return false
        end

        await(Async.message_player(pid, "You broke the trap!"))
        return true
    end)
end

local function _website_tag_action(npc, pid, dialogue, relay_object)
    return async(function()
        local area_id = Net.get_player_area(pid)
        if not area_id or area_id == TAG_MEM_AREA_ID then
            await(Async.message_player(pid, "Net Square pages do not get tagged."))
            return nil
        end

        local _, store = _get_tag_store()
        store.pages = store.pages or {}
        store.domains = store.domains or {}

        local owner_key = _safe_secret(pid)
        local owner_name = _safe_name(pid)
        local domain_key, domain_label, raw_url = _domain_info_for_area(area_id)
        local page_key = tostring(area_id)

        local previous = store.pages[page_key]

        if previous and previous.owner_key == owner_key then
            local domain_bucket = store.domains[domain_key]
            local current_count = 0
            if domain_bucket and domain_bucket.owners and domain_bucket.owners[owner_key] then
                current_count = tonumber(domain_bucket.owners[owner_key].count or 0) or 0
            end

            local trap_line = "No trap is set."
            if previous.trap and previous.trap.kind then
                trap_line = "Current trap: " .. _trap_label(previous.trap.kind) .. "."
            end

            await(Async.message_player(pid, string.format(
                "You already tagged this page for %s. You currently hold %d %s page%s. %s",
                domain_label,
                current_count,
                domain_label,
                current_count == 1 and "" or "s",
                trap_line
            )))

            await(_offer_trap_setup(pid, previous))
            return nil
        end

        if previous and previous.owner_key ~= owner_key then
            local cleared = await(_challenge_existing_trap(pid, area_id, previous))
            if not cleared then
                return nil
            end
        end

        local replaced_name = nil
        if previous then
            local previous_domain_bucket = store.domains[previous.domain_key]
            _decrement_owner(previous_domain_bucket, previous.owner_key)
            if previous.owner_key ~= owner_key then
                replaced_name = previous.owner_name
            end
        end

        local domain_bucket = store.domains[domain_key]
        if not domain_bucket then
            domain_bucket = {
                label = domain_label,
                owners = {},
            }
            store.domains[domain_key] = domain_bucket
        end
        domain_bucket.label = domain_label

        local owner_row = _ensure_owner_row(domain_bucket, owner_key)
        owner_row.name = owner_name
        owner_row.count = (tonumber(owner_row.count or 0) or 0) + 1

        store.pages[page_key] = {
            area_id = tostring(area_id),
            url = raw_url,
            domain_key = domain_key,
            domain_label = domain_label,
            owner_key = owner_key,
            owner_name = owner_name,
            tagged_at = os.time(),
            trap = nil,
        }

        ezmemory.save_area_memory(TAG_MEM_AREA_ID)

        local current_count = tonumber(owner_row.count or 0) or 0
        local message
        if replaced_name and replaced_name ~= "" then
            message = string.format(
                "Nice! You tagged this page for %s. You replaced %s's tag. You now hold %d %s page%s.",
                domain_label,
                replaced_name,
                current_count,
                domain_label,
                current_count == 1 and "" or "s"
            )
        else
            message = string.format(
                "Nice! You tagged this page for %s. You now hold %d %s page%s.",
                domain_label,
                current_count,
                domain_label,
                current_count == 1 and "" or "s"
            )
        end

        await(Async.message_player(pid, message))
        await(_offer_trap_setup(pid, store.pages[page_key]))
        return nil
    end)
end

local function _website_tag_bbs_action(npc, pid, dialogue, relay_object)
    return async(function()
        _open_website_tag_board(pid)
        return nil
    end)
end

-- Same legacy bridge pattern LMenu uses:
-- button 0 => A
-- button 1 => LS
local function emit_legacy_button_press(player_id, button)
    if not player_id then return end

    if button == 0 then
        Net:emit("button_press", { player_id = player_id, button = "A" })
    elseif button == 1 then
        Net:emit("button_press", { player_id = player_id, button = "LS" })
    end
end

Net:on("tile_interaction", function(event)
    if not event then return end
    emit_legacy_button_press(event.player_id, event.button)
end)

Net:on("button_press", function(event)
    local pid = event.player_id
    local btn = event.button
    if not pid or not btn then return end

    if btn == "LS" then
        open_return_prompt(pid)
    end
end)

Net:on("player_disconnect", function(event)
    if not event or not event.player_id then return end
    return_index_prompt_open[event.player_id] = nil
end)

Net:on("player_area_transfer", function(event)
    if not event or not event.player_id then return end
    return_index_prompt_open[event.player_id] = nil
end)

if not _G.__WEBSITE_TAG_BBS_WIRED then
    _G.__WEBSITE_TAG_BBS_WIRED = true
    Net:on("post_selection", function(event)
        if tostring(event.post_id or "") == "__tagbbs:close" then
            pcall(Net.close_bbs, event.player_id)
        end
    end)
end

eznpcs.add_event({
    name = "website_tag",
    action = _website_tag_action,
})

eznpcs.add_event({
    name = "website_tag_bbs",
    action = _website_tag_bbs_action,
})
