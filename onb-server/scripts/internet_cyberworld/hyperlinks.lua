local json = require('scripts/ezlibs-scripts/json')

local player_last_warp_info = {}
local area_warps_active = {}
local link_to_tmx = {}
local existing_areas = Net.list_areas()
for index, value in ipairs(existing_areas) do
    print("existing area", index, value)
end

math.randomseed(os.time())

local websites_being_generated = {}
local manual_priority_queue = {}
local foreground_generation_queue = {}
local background_generation_queue = {}
local queued_links = {}
local link_waiters = {}
local link_retry_after = {}
local player_current_area = {}
local active_area_counts = {}

local max_generated_at_time = 3
local max_queued_links = 300
local retry_delay_seconds = 5
local queue_full_retry_delay_seconds = 15

local lib = {}

function normalize_link(link)
    if not link then
        return nil
    end

    link = link:gsub("#.*$", "")

    local protocol, host, rest = link:match("^(https?://)([^/]+)(.*)$")
    if protocol and host then
        host = host:lower()
        host = host:gsub(":80$", "")
        host = host:gsub(":443$", "")
        return protocol .. host .. rest
    end

    return link
end

function queue_length()
    return #manual_priority_queue + #foreground_generation_queue + #background_generation_queue
end

function is_area_active(area_id)
    return (active_area_counts[area_id] or 0) > 0
end

function push_queue_item(item, use_foreground, to_front)
    local target_queue = use_foreground and foreground_generation_queue or background_generation_queue

    if to_front then
        table.insert(target_queue, 1, item)
    else
        table.insert(target_queue, item)
    end
end

function push_manual_priority_item(item, to_front)
    if to_front then
        table.insert(manual_priority_queue, 1, item)
    else
        table.insert(manual_priority_queue, item)
    end
end

function evict_oldest_background_item()
    local evicted = table.remove(background_generation_queue, 1)
    if not evicted then
        return nil
    end

    queued_links[evicted.link] = nil
    link_retry_after[evicted.link] = nil

    print('[hyperlinks] evicted oldest background queued link ' .. evicted.link)
    return evicted
end

function ensure_queue_room_for_priority_item()
    if queue_length() < max_queued_links then
        return true
    end

    local evicted = evict_oldest_background_item()
    return evicted ~= nil
end

function pop_next_ready_item(queue)
    local now = os.time()

    for index = 1, #queue do
        local candidate = queue[index]
        local retry_after = link_retry_after[candidate.link] or 0

        if retry_after <= now then
            return table.remove(queue, index)
        end
    end

    return nil
end

function move_area_items_between_queues(from_queue, to_queue, area_id, to_front)
    for index = #from_queue, 1, -1 do
        local item = from_queue[index]
        if item.area_id == area_id then
            table.remove(from_queue, index)
            if to_front then
                table.insert(to_queue, 1, item)
            else
                table.insert(to_queue, item)
            end
        end
    end
end

function promote_area_queue_items(area_id)
    move_area_items_between_queues(background_generation_queue, foreground_generation_queue, area_id, true)
end

function demote_area_queue_items(area_id)
    move_area_items_between_queues(foreground_generation_queue, background_generation_queue, area_id, false)
end

function update_player_area_priority(player_id, new_area_id)
    local old_area_id = player_current_area[player_id]

    if old_area_id == new_area_id then
        return
    end

    if old_area_id then
        active_area_counts[old_area_id] = math.max(0, (active_area_counts[old_area_id] or 1) - 1)
        if active_area_counts[old_area_id] <= 0 then
            active_area_counts[old_area_id] = nil
            demote_area_queue_items(old_area_id)
        end
    end

    player_current_area[player_id] = new_area_id

    if new_area_id then
        active_area_counts[new_area_id] = (active_area_counts[new_area_id] or 0) + 1
        promote_area_queue_items(new_area_id)
    end
end

function jittered_delay_seconds(delay_seconds)
    local max_jitter = math.max(1, math.floor(delay_seconds / 2))
    return delay_seconds + math.random(0, max_jitter)
end

function promote_queued_link(link, area_id)
    link_retry_after[link] = nil

    for index = 1, #manual_priority_queue do
        if manual_priority_queue[index].link == link then
            local item = table.remove(manual_priority_queue, index)
            item.area_id = area_id or item.area_id
            table.insert(manual_priority_queue, 1, item)
            return true
        end
    end

    for index = 1, #foreground_generation_queue do
        if foreground_generation_queue[index].link == link then
            local item = table.remove(foreground_generation_queue, index)
            item.area_id = area_id or item.area_id
            table.insert(manual_priority_queue, 1, item)
            return true
        end
    end

    for index = 1, #background_generation_queue do
        if background_generation_queue[index].link == link then
            local item = table.remove(background_generation_queue, index)
            item.area_id = area_id or item.area_id
            table.insert(manual_priority_queue, 1, item)
            return true
        end
    end

    return false
end

function add_link_waiter(link, area_id, object_id)
    if not link_waiters[link] then
        link_waiters[link] = {}
    end

    local waiter_key = tostring(area_id) .. "::" .. tostring(object_id)
    link_waiters[link][waiter_key] = {
        area_id = area_id,
        object_id = object_id
    }
end

function activate_warp(area_id, link_object, link, target_area_id)
    if not link_object then
        return
    end

    if not area_warps_active[area_id] then
        area_warps_active[area_id] = {}
    end

    if area_warps_active[area_id][link_object.id] then
        return
    end

    local n_area_properties = Net.get_area_custom_properties(target_area_id)
    if not n_area_properties or not n_area_properties["Background Texture"] then
        return
    end

    local end_characters = string.len("background.png")
    local warp_active_texture_server_path = string.sub(
        n_area_properties["Background Texture"],
        1,
        string.len(n_area_properties["Background Texture"]) - end_characters
    )
    warp_active_texture_server_path = warp_active_texture_server_path .. "warp_active.png"

    area_warps_active[area_id][link_object.id] = target_area_id
    spawn_warp_active_overlay_bot(area_id, link_object, link, warp_active_texture_server_path)
end

function activate_waiters_for_link(link, target_area_id)
    link_to_tmx[link] = target_area_id

    local waiters = link_waiters[link]
    if not waiters then
        return
    end

    for _, waiter in pairs(waiters) do
        local object = Net.get_object_by_id(waiter.area_id, waiter.object_id)
        if object and object.custom_properties and object.custom_properties.link then
            activate_warp(waiter.area_id, object, link, target_area_id)
        end
    end

    link_waiters[link] = nil
end

function requeue_link(area_id, object_id, link, text, delay_seconds)
    link_retry_after[link] = os.time() + jittered_delay_seconds(delay_seconds)
    queued_links[link] = true

    push_queue_item({
        area_id = area_id,
        object_id = object_id,
        link = link,
        text = text
    }, is_area_active(area_id), false)
end

function lib.handle_custom_warp(player_id, object_id)
    local area_id = Net.get_player_area(player_id)
    local link_object = Net.get_object_by_id(area_id, object_id)
    local url = link_object.custom_properties['link']
    local is_back_link = link_object.custom_properties['is_back_link']
    if is_back_link then
        local last_warp_info = player_last_warp_info[area_id][player_id]
        transfer_player_from_warp_to_warp(player_id, area_id, last_warp_info.area_id, link_object.id, last_warp_info.warp_id, true)
        return
    end
    if url then
        local normalized_link = normalize_link(url)

        if normalized_link and link_to_tmx[normalized_link] and (not area_warps_active[area_id] or not area_warps_active[area_id][link_object.id]) then
            activate_warp(area_id, link_object, normalized_link, link_to_tmx[normalized_link])
        end

        --if the warp is inactive, give this link priority and warp the player back to where they were
        if not area_warps_active[area_id] or not area_warps_active[area_id][link_object.id] then
            print("[hyperlinks] warp not active yet, giving priority")
            queue_hyperlink_preperation(area_id, link_object, true)
            Net.message_player(player_id, "The next area is offline, giving it priority...")
            local direction = link_object.custom_properties['Direction']
            Net.transfer_player(player_id, area_id, true, link_object.x, link_object.y, link_object.z, direction)
            return
        end

        --get link details
        local target_area_id = area_warps_active[area_id][link_object.id]

        --transfer player
        local target_area_properties = Net.get_area_custom_properties(target_area_id)
        transfer_player_from_warp_to_warp(player_id, area_id, target_area_id, link_object.id, target_area_properties.entry_warp_id, false)
    end
end

function lib.handle_player_transfer(player_id)
    print('[hyperlinks] handle player transfer', player_id)
    local area_id = Net.get_player_area(player_id)
    update_player_area_priority(player_id, area_id)
    prepare_all_warps_in_area(area_id)
end

function lib.handle_player_join(player_id)
    print('[hyperlinks] handle player join', player_id)
    local area_id = Net.get_player_area(player_id)
    update_player_area_priority(player_id, area_id)
    prepare_all_warps_in_area(area_id)
end

function lib.handle_player_disconnect(player_id)
    print('[hyperlinks] handle player disconnect', player_id)
    update_player_area_priority(player_id, nil)
end


function prepare_all_warps_in_area(area_id)
    local objects = Net.list_objects(area_id)
    for _, object_id in pairs(objects) do
        local object = Net.get_object_by_id(area_id, object_id)
        if object and object.custom_properties and object.custom_properties.link and object.custom_properties.text then
            queue_hyperlink_preperation(area_id, object)
        end
    end
end

function tablelength(T)
    local count = 0
    for _ in pairs(T) do count = count + 1 end
    return count
end

function map_is_already_loaded(asset_path)
    return Net.has_asset(asset_path)
end

function queue_hyperlink_preperation(area_id, object, prioritize_now)
    if not object or not object.custom_properties then
        return
    end

    local link = normalize_link(object.custom_properties.link)
    local text = object.custom_properties.text

    if not link or not text then
        return
    end

    add_link_waiter(link, area_id, object.id)

    if link_to_tmx[link] then
        activate_warp(area_id, object, link, link_to_tmx[link])
        return
    end

    if websites_being_generated[link] then
        return
    end

    local use_foreground = is_area_active(area_id)

    if queued_links[link] then
        if prioritize_now then
            promote_queued_link(link, area_id)
        end
        return
    end

    if queue_length() >= max_queued_links then
        -- Manual and active-area links are allowed to displace old background crawl work.
        if prioritize_now or use_foreground then
            if not ensure_queue_room_for_priority_item() then
                print('[hyperlinks] queue full and no background item could be evicted for ' .. link)
                return
            end
        else
            return
        end
    end

    queued_links[link] = true

    local item = {
        area_id = area_id,
        object_id = object.id,
        link = link,
        text = text
    }

    if prioritize_now then
        push_manual_priority_item(item, true)
    else
        push_queue_item(item, use_foreground, use_foreground)
    end

    try_prepare_next_hyperlink_from_queue()
end

function try_prepare_next_hyperlink_from_queue()
    local generating_currently = tablelength(websites_being_generated)
    local manual_count = #manual_priority_queue
    local foreground_count = #foreground_generation_queue
    local background_count = #background_generation_queue
    local total_count = manual_count + foreground_count + background_count

    print('generating ' .. generating_currently .. ' / ' .. max_generated_at_time ..
        ' maps, ' .. total_count .. ' in queue (manual=' .. manual_count ..
        ', fg=' .. foreground_count .. ', bg=' .. background_count .. ')')

    while generating_currently < max_generated_at_time do
        local next_item = pop_next_ready_item(manual_priority_queue)

        if not next_item then
            next_item = pop_next_ready_item(foreground_generation_queue)
        end

        if not next_item then
            next_item = pop_next_ready_item(background_generation_queue)
        end

        if not next_item then
            return
        end

        queued_links[next_item.link] = nil
        prepare_hyperlink(next_item.area_id, next_item.object_id, next_item.link, next_item.text)
        generating_currently = tablelength(websites_being_generated)
    end
end

function prepare_hyperlink(area_id, object_id, link, text)
    local link_object = Net.get_object_by_id(area_id, object_id)

    if not link then
        if not link_object or not link_object.custom_properties then
            return try_prepare_next_hyperlink_from_queue()
        end
        link = normalize_link(link_object.custom_properties.link)
        text = link_object.custom_properties.text
    end

    if not link then
        return try_prepare_next_hyperlink_from_queue()
    end

    if link_object then
        add_link_waiter(link, area_id, link_object.id)
    end

    if link_to_tmx[link] then
        activate_waiters_for_link(link, link_to_tmx[link])
        return try_prepare_next_hyperlink_from_queue()
    end

    if websites_being_generated[link] then
        print('[hyperlinks] ' .. link .. ' is already being generated...')
        return try_prepare_next_hyperlink_from_queue()
    end

    websites_being_generated[link] = true
    link_retry_after[link] = nil

    Async.promisify(coroutine.create(function()
        local generate_map_promise = generate_linked_map(link, text)
        local area_info = Async.await(generate_map_promise)

        if area_info.status == "queued" then
            print('[hyperlinks] server queued ' .. link)
            websites_being_generated[link] = nil
            requeue_link(area_id, object_id, link, text, retry_delay_seconds)
            return try_prepare_next_hyperlink_from_queue()
        end

        if area_info.status == "queue_full" then
            print('[hyperlinks] server queue full for ' .. link)
            websites_being_generated[link] = nil
            requeue_link(area_id, object_id, link, text, queue_full_retry_delay_seconds)
            return try_prepare_next_hyperlink_from_queue()
        end

        if area_info.status ~= "ok" then
            print('[hyperlinks] map generation failed ' .. link)
            websites_being_generated[link] = nil
            return try_prepare_next_hyperlink_from_queue()
        end

        print('[hyperlinks] received map info ' .. area_info.area_path)

        if area_info.fresh then
            print('[hyperlinks] new map was generated ' .. area_info.area_path)

            local read_file_promise = Async.read_file(area_info.area_path)
            local area_data = Async.await(read_file_promise)

            print("[hyperlinks] read tmx, updating area " .. area_info.area_id)
            Net.update_area(area_info.area_id, area_data)
            print("[hyperlinks] updated area " .. area_info.area_id)

            local n_area_properties = Net.get_area_custom_properties(area_info.area_id)

            print("[hyperlinks] loading assets...")
            local tilesheet_promises = {}

            local end_characters = string.len("background.png")
            local warp_active_texture_server_path = string.sub(
                n_area_properties["Background Texture"],
                1,
                string.len(n_area_properties["Background Texture"]) - end_characters
            )
            warp_active_texture_server_path = warp_active_texture_server_path .. "warp_active.png"

            local background_texture_relative_path = n_area_properties["Background Texture"]:gsub("/server/", "./")
            local background_animation_relative_path = n_area_properties["Background Animation"]:gsub("/server/", "./")
            local warp_active_texture_relative_path = warp_active_texture_server_path:gsub("/server/", "./")

            tilesheet_promises[#tilesheet_promises + 1] = load_asset_promise(background_texture_relative_path)
            tilesheet_promises[#tilesheet_promises + 1] = load_asset_promise(background_animation_relative_path)
            tilesheet_promises[#tilesheet_promises + 1] = load_asset_promise(warp_active_texture_relative_path)

            for _, value in ipairs(area_info.assets) do
                tilesheet_promises[#tilesheet_promises + 1] = load_asset_promise(value)
            end

            Async.await_all(tilesheet_promises)
            print("[hyperlinks] loaded all assets!")
            Net:emit('new_area_added', area_info.area_id)
        else
            print('[hyperlinks] area already existed ' .. area_info.area_path)
        end

        activate_waiters_for_link(link, area_info.area_id)

        websites_being_generated[link] = nil
        return try_prepare_next_hyperlink_from_queue()
    end))
end

function spawn_warp_active_overlay_bot(area_id, link_object, link_url, warp_overlay_texture_path)
    local bot_name = link_url
    local static_anim_path = '/server/assets/shared/objects/link_overlay_bot.animation'
    local offset_to_fix_sorting = 1/32
    local bot_info = { name=bot_name, area_id=area_id, warp_in=false, texture_path=warp_overlay_texture_path, animation_path=static_anim_path, x=link_object.x+offset_to_fix_sorting, y=link_object.y+offset_to_fix_sorting, z=link_object.z}
    Net.create_bot(bot_info) -- bot_id
end

function load_asset_promise(system_asset_path)
    local co = coroutine.create(function()
        if not Net.has_asset(system_asset_path) then
            print("[hyperlinks] loading new asset " .. system_asset_path)
            local read_asset_promise = Async.read_file(system_asset_path)
            local asset_data = Async.await(read_asset_promise)

            local server_asset_path = system_asset_path:gsub("%./", "/server/")
            print("[hyperlinks] new asset name (server) " .. server_asset_path)
            Net.update_asset(server_asset_path, asset_data)
        else
            print("[hyperlinks] asset already exists " .. system_asset_path)
        end
    end)
    return Async.promisify(co)
end

function transfer_player_from_warp_to_warp(player_id, from_area_id, to_area_id, from_warp_id, to_warp_id, used_back_link)
    print('[hyperlinks] transfering player to ' .. to_area_id)
    local destination_warp = Net.get_object_by_id(to_area_id, to_warp_id)
    if not player_last_warp_info[to_area_id] then
        player_last_warp_info[to_area_id] = {}
    end
    if not used_back_link then
        player_last_warp_info[to_area_id][player_id] = { area_id = from_area_id, warp_id = from_warp_id }
    end
    Net.transfer_player(player_id, to_area_id, true, destination_warp.x, destination_warp.y, destination_warp.z, destination_warp.custom_properties.Direction)
end

function generate_linked_map(link, text)
    return async(function()
        print('generating '..link)
        local url = "http://localhost:4000"
        local headers = {}
        headers["Content-Type"] = "application/json"
        local body = {
            link = link,
            text = text
        }
        local response = await(Async.request(url, {
            method = "POST",
            headers = headers,
            body = json.encode(body)
        }))
        local data = json.decode(response.body)
        return data
    end)
end

print('[hyperlinks] loaded')

return lib
