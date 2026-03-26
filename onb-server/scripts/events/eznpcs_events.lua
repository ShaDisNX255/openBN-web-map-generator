local ezwarps = require("scripts/ezlibs-scripts/ezwarps/main")


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
