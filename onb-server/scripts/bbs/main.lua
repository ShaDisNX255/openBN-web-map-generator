--== Script for user posts on BBS ==--
-- Create a tile object
--
-- Properties for Minimap:
--   Type: Board
--
-- Required Custom Properties:
--   BBS: bool (true)
--   Name: name (make sure this is unique)
--   Color: color
--   Post Limit: int
--
-- Optional Custom Properties:
--   Character Limit: int
--
-- Required libs:
--   json.lua by rxi (store as scripts/libs/json.lua)
local json                   = require("scripts/bbs/json")
local admin_manager           = require("scripts/bbs/admin_manager")

local BBS_BOARD_DATA         = "scripts/bbs/data.json"

local TITLE_LIMIT            = 14
local AUTHOR_LIMIT           = 7

local last_read_time         = {}
local player_states          = {}
local save_data              = {}
local saving                 = false
local pending_save           = false
local posts                  = {}
local color                  = { r = 0, g = 0, b = 0 }

function async(p)
    local co = coroutine.create(p)
    return Async.promisify(co)
end

function await(v) return Async.await(v) end

Async.read_file(BBS_BOARD_DATA).and_then(function(value)
    local status, err = pcall(function()
        if value ~= "" then
            save_data = json.decode(value)
        end
    end)

    if not status then
        print("Failed to read data from \"" .. BBS_BOARD_DATA .. "\":")
        print(err)
    end
end)

Net:on("player_connect", function(event)
    local player_id = event.player_id
    last_read_time[player_id] = os.time()
    admin_manager.on_player_connect(player_id)
end)

function handle_player_disconnect(player_id)
    last_read_time[player_id] = nil
    player_states[player_id] = nil
end

Net:on("object_interaction", function (event)
    if event.button ~= 0 then return end

    local player_id = event.player_id
    local object_id = event.object_id
    local area_id = Net.get_player_area(player_id)
    local object = Net.get_object_by_id(area_id, object_id)
    if object.type ~= "Admin Console" and object.class ~= "Admin Console" then return end
    if admin_manager.is_admin(player_id) then
      Net.message_player(player_id, "You are already an admin")
    else
      async(function()
          local question = await(Async.question_player(player_id, "Would you like to enter admin password?"))
          if question == 1 then
              local password = await(Async.prompt_player(player_id))
              if admin_manager.check_password_and_grant(player_id, password) then
                  Net.message_player(player_id, "Password correct. You are now an admin.")
              else
                print("FAILED TO OBTAIN ADMIN STATUS")
              end
          end
      end)
    end
end)

function handle_object_interaction(player_id, object_id)
    local area = Net.get_player_area(player_id)
    local object = Net.get_object_by_id(area, object_id)

    if not object or not object.custom_properties.BBS then
        return
    end

    local name = object.custom_properties.Name
    local color_string = object.custom_properties.Color

    -- FIX: Interpret Postable property correctly
    local postable = true  -- default when property not present
    if object.custom_properties.Postable ~= nil then
        -- Only boolean true makes the board postable; anything else (including strings) is false
        postable = (object.custom_properties.Postable == true)
    end

    color = {
        r = tonumber(string.sub(color_string, 4, 5), 16),
        g = tonumber(string.sub(color_string, 6, 7), 16),
        b = tonumber(string.sub(color_string, 8, 9), 16)
    }

    posts = {
        {
            id = "POST",
            read = true,
            title = "POST"
        },
    }

    local last_time = last_read_time[player_id]
    local board_data = save_data[name]

    if board_data then
        local _, pinned, unpinned = bbs_display_order_ids(board_data)

        local function add_display_post(src)
            local post = shallow_copy(src)
    
            -- Title formatting
            if post.pin then
                post.title = "PIN: " .. string.sub(post.title, 1, TITLE_LIMIT - 5)
            else
                post.title = string.sub(post.title, 1, TITLE_LIMIT)
            end

            -- Read/unread should be based on ORIGINAL post.time (not pin_time)
            local t = tonumber(post.time) or 0
            if last_time == nil or t < last_time then
                post.read = true
            end

            posts[#posts + 1] = post
        end

    for _, p in ipairs(pinned) do add_display_post(p) end
    for _, p in ipairs(unpinned) do add_display_post(p) end
end
    Net.open_board(player_id, name, color, posts)

    player_states[player_id] = {
        status = "READING",
        area_id = area,
        board_id = object.id,
        board_name = name,
        current_board_postable = postable
    }
end

function shallow_copy(original)
    local copy = {}
    for key, value in pairs(original) do
        copy[key] = value
    end
    return copy
end

function bbs_compare_pinned(a, b)
    local at = tonumber(a.pin_time or a.time) or 0
    local bt = tonumber(b.pin_time or b.time) or 0
    if at ~= bt then return at > bt end

    local at2 = tonumber(a.time) or 0
    local bt2 = tonumber(b.time) or 0
    if at2 ~= bt2 then return at2 > bt2 end

    return tostring(a.id) > tostring(b.id)
end

function bbs_compare_unpinned(a, b)
    local at = tonumber(a.time) or 0
    local bt = tonumber(b.time) or 0
    if at ~= bt then return at > bt end
    return tostring(a.id) > tostring(b.id)
end

function bbs_display_order_ids(board_data)
    local pinned, unpinned = {}, {}
    local posts_table = (board_data and board_data.posts) or {}

    for _, p in ipairs(posts_table) do
        if p.pin then
            pinned[#pinned + 1] = p
        else
            unpinned[#unpinned + 1] = p
        end
    end

    table.sort(pinned, bbs_compare_pinned)
    table.sort(unpinned, bbs_compare_unpinned)

    local ids = {}
    for _, p in ipairs(pinned) do ids[#ids + 1] = p.id end
    for _, p in ipairs(unpinned) do ids[#ids + 1] = p.id end
    return ids, pinned, unpinned
end

function handle_post_selection(player_id, post_id)
    if not player_states[player_id] then
        return
    end

    local board_name = player_states[player_id].board_name
    local is_admin = admin_manager.is_admin(player_id)

    if post_id == "POST" then
        if player_states[player_id].current_board_postable or is_admin then
            send_post_form(player_id)
        else
            Net.message_player(player_id, "It appears you do not have permission to post here...")
        end
        elseif is_admin then
            Async.quiz_player(player_id, "Show Post", "Pin Post", "Delete Post", nil, nil).and_then(function(response)
                if response == 0 then
                    show_post(player_id, post_id)
                elseif response == 1 then
                -- ===== PIN/UNPIN without changing id/time (no "NEW" icon bug) =====
                local board_data = save_data[board_name]
                if not board_data then return end
                local posts_table = board_data.posts or {}

                -- Locate the post by id
                local post = nil
                for _, p in ipairs(posts_table) do
                    if p.id == post_id then
                        post = p
                        break
                    end
                end
                if not post then return end

                -- Toggle pin and set/clear pin_time (used only for pinned ordering)
                post.pin = not post.pin
                if post.pin then
                    post.pin_time = os.time()
                else
                    post.pin_time = nil
                end

                save()

                -- Everyone currently viewing this board
                local viewers = {}
                for pid, state in pairs(player_states) do
                    if state.board_name == board_name then
                        viewers[#viewers + 1] = pid
                    end
                end

                -- Figure out where it should be inserted now (based on sorted display order)
                local ordered_ids = bbs_display_order_ids(board_data)
                local anchor_id = "POST"
                for i, id in ipairs(ordered_ids) do
                    if id == post_id then
                        anchor_id = (i == 1) and "POST" or ordered_ids[i - 1]
                        break
                    end
                end

                -- Base display post (title formatting only)
                local base_display = shallow_copy(post)
                if post.pin then
                    base_display.title = "PIN: " .. string.sub(base_display.title, 1, TITLE_LIMIT - 5)
                else
                    base_display.title = string.sub(base_display.title, 1, TITLE_LIMIT)
                end

                -- Update every viewer: remove then insert at correct position, preserving read state
                for _, pid in ipairs(viewers) do
                    local display_post = shallow_copy(base_display)
                
                    local last_time_for_viewer = last_read_time[pid]
                    local t = tonumber(post.time) or 0
                    if last_time_for_viewer == nil or t < last_time_for_viewer then
                        display_post.read = true
                    end

                    Net.remove_post(pid, post_id)
                    Net.append_posts(pid, { display_post }, anchor_id)
                end
                -- ===============================================================
            elseif response == 2 then
                -- Delete post (also update all viewers for consistency)
                local posts = save_data[board_name].posts
                for i, p in ipairs(posts) do
                    if p.id == post_id then
                        table.remove(posts, i)
                        break
                    end
                end
                save()

                -- Remove from all viewers
                for pid, state in pairs(player_states) do
                    if state.board_name == board_name then
                        Net.remove_post(pid, post_id)
                    end
                end
            end
        end)
    else
        show_post(player_id, post_id)
    end
end

function send_post_form(player_id)
    local player_state = player_states[player_id]
    local board = Net.get_object_by_id(player_state.area_id, player_state.board_id)
    Net.prompt_player(player_id, board.custom_properties["Character Limit"])
    player_state.status = "EDITING"
end

function show_post(player_id, post_id)
    local board_name = player_states[player_id].board_name
    local posts = save_data[board_name].posts
    local post

    for _, p in ipairs(posts) do
        if p.id == post_id then
            post = p
            break
        end
    end

    if post then
        Net.message_player(player_id, post.body)
    end
end

function handle_textbox_response(player_id, response)
    local player_state = player_states[player_id]

    if not player_state then
        return
    end

    if player_state.status == "EDITING" then
        if not contains_only_whitespace(response) then
            player_state.submission_text = response
            player_state.status = "SUBMITTING"
            Net.question_player(player_id, "Do you want to submit?")
            return
        end
    elseif player_state.status == "SUBMITTING" then
        if response == 1 then
            Net.message_player(player_id, "Title:")
            Net.prompt_player(player_id, TITLE_LIMIT, sanitize_title(player_state.submission_text, TITLE_LIMIT))
            player_state.status = "INFORMED_OF_INPUT"
            return
        end
    elseif player_state.status == "INFORMED_OF_INPUT" then
        player_state.status = "TITLING"
        return
    elseif player_state.status == "TITLING" then
        player_state.submission_title = response
        create_post(player_id, player_state)
    end

    player_state.status = "READING"
end

function create_post(player_id, player_state, pinned)
    local board = Net.get_object_by_id(player_state.area_id, player_state.board_id)
    local board_data = save_data[player_state.board_name]

    if not board_data then
        board_data = {
            posts = {},
            next_id = 1
        }
    end

    local player_name = Net.get_player_name(player_id)
    local character_limit = tonumber(board.custom_properties["Character Limit"])

    local title = player_state.submission_title

    if contains_only_whitespace(title) then
        title = player_state.submission_text
    end

    if (pinned == nil) then pinned = false end
    local post = {
        time = os.time(),
        author = sanitize_title(player_name, AUTHOR_LIMIT),
        title = sanitize_title(title, TITLE_LIMIT),
        id = tostring(board_data.next_id),
        body = string.sub(player_state.submission_text, 1, character_limit),
        pin = pinned
    }

    board_data.next_id = board_data.next_id + 1

    local post_limit = tonumber(board.custom_properties["Post Limit"])

    if #board_data.posts >= post_limit then
        for i, old_post in ipairs(board_data.posts) do
            if not old_post.pin then
                table.remove(board_data.posts, i)
                break
            end
        end
    end

    push_post(player_state.board_name, player_state.area_id, post)

    board_data.posts[#board_data.posts + 1] = post
    save_data[player_state.board_name] = board_data
    save()
end

function contains_only_whitespace(text)
    return not string.find(text, "[^ \t\r\n]")
end

function sanitize_title(text, limit)
    return string.sub(string.gsub(text, "[\t\r\n]", " ", limit), 1, limit)
end

function push_post(board_name, area_id, post)
    local next_id = nil

    local board_data = save_data[board_name]

    if board_data then
        local posts = save_data[board_name].posts
        for i = #posts, 1, -1 do
            local post = posts[i]
            if not post.pin then
                next_id = post.id
                break
            end
        end
    end

    local push_func
    if next_id then
        push_func = Net.prepend_posts
    else
        push_func = Net.append_posts
    end

    local new_posts = { post }

    for i, player_id in ipairs(Net.list_players(area_id)) do
        push_func(player_id, new_posts, next_id)
    end
end

function handle_board_close(player_id)
    last_read_time[player_id] = os.time()
end

function save()
    if saving then
        pending_save = true
        return
    end

    saving = true

    Async.write_file(BBS_BOARD_DATA, json.encode(save_data, true)).and_then(function()
        saving = false
        if pending_save then
            pending_save = false
            save()
        end
    end)
end
