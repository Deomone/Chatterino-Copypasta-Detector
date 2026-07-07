local util = require("lib.util")

local popup = {}

local TICK_MS   = 200
local BAR_CELLS = 12
local HIGHLIGHT = "#3f2b6cb0"

local deps = nil
local state = {}
local id_counter = 0

function popup.init(d)
    deps = d
end

local function combined_flags(names)
    local ok, value = pcall(function()
        local v = 0
        for _, n in ipairs(names) do
            v = v | c2.MessageFlag[n]
        end
        return v
    end)
    if ok then return value end
    local ok_single, single = pcall(function() return c2.MessageFlag[names[1]] end)
    if ok_single then return single end
    return nil
end

local function send_link()
    return { type = c2.LinkType.UserAction, value = deps.send_command }
end

local function build_active(st, remaining_ms)
    local secs = util.ceil_s(remaining_ms)
    local bar  = util.bar(remaining_ms, st.total_ms, BAR_CELLS)

    local elements = {
        {
            type    = "text",
            text    = "📋 Pasta ×" .. st.count,
            color   = "system",
            style   = c2.FontStyle.ChatMediumBold,
            tooltip = st.count .. " different users sent this message",
        },
        {
            type    = "text",
            text    = st.text,
            color   = "text",
            link    = send_link(),
            tooltip = "Click to send this pasta to the chat",
        },
        { type = "linebreak" },
        {
            type    = "text",
            text    = "▶ Send",
            color   = "link",
            style   = c2.FontStyle.ChatMediumBold,
            link    = send_link(),
            tooltip = "Send this pasta to the channel (" .. deps.send_command .. ")",
        },
        {
            type  = "text",
            text  = bar .. " " .. secs .. " s",
            color = "system",
        },
    }
    if st.sent > 0 then
        elements[#elements + 1] = {
            type    = "text",
            text    = "✓ sent ×" .. st.sent,
            color   = "system",
            tooltip = "How many times you sent this pasta from the popup",
        }
    end

    return c2.Message.new({
        id              = st.id,
        flags           = combined_flags({
            "Highlighted",
            "DoNotTriggerNotification",
            "DoNotLog",
        }),
        highlight_color = HIGHLIGHT,
        elements        = elements,
    })
end

local function build_expired(st)
    return c2.Message.new({
        id    = st.id .. "-done",
        flags = combined_flags({ "System", "DoNotTriggerNotification", "DoNotLog" }),
        elements = {
            {
                type    = "text",
                text    = "⌛ pasta window closed · \"" .. util.shorten(st.text, 60) .. "\"",
                color   = "system",
                tooltip = st.text,
            },
        },
    })
end

local function build_blank(st)
    return c2.Message.new({
        id       = st.id .. "-gone",
        flags    = combined_flags({ "DoNotTriggerNotification", "DoNotLog" }),
        elements = {},
    })
end

local function swap_message(st, msg)
    if st.norender or st.msg == nil then return false end
    local ok = pcall(function()
        st.channel:replace_message(st.msg, msg)
    end)
    if ok then
        st.msg = msg
        return true
    end
    st.norender = true
    deps.log("failed to redraw the popup in #" .. st.name .. " (message pushed out of the buffer?)")
    return false
end

local function is_last(st)
    if st.msg == nil then return false end
    local ok, last = pcall(function() return st.channel:last_message() end)
    if not ok then return true end
    if last == nil then return false end
    local id_ok, last_id = pcall(function() return last.id end)
    return id_ok and last_id == st.id
end

local function repin(st, remaining_ms)
    local old = st.msg
    st.rev = st.rev + 1
    st.id = st.base_id .. "-" .. st.rev

    local built, msg = pcall(build_active, st, remaining_ms)
    if not built then
        deps.log("failed to build the popup: " .. tostring(msg))
        return
    end

    local added = pcall(function()
        st.channel:add_message(msg, c2.MessageContext.Original)
    end)
    if not added then
        added = pcall(function() st.channel:add_message(msg) end)
    end
    if not added then
        st.norender = true
        return
    end

    st.msg = msg
    st.norender = false

    if old ~= nil then
        local blank_ok, blank = pcall(build_blank, st)
        if blank_ok then
            pcall(function() st.channel:replace_message(old, blank) end)
        end
    end
end

local function finish(st)
    if state[st.name] == st then
        state[st.name] = nil
    end
    local ok, expired = pcall(build_expired, st)
    if ok then
        swap_message(st, expired)
    end
end

local function tick(st)
    if state[st.name] ~= st then return end

    local valid_ok, valid = pcall(function() return st.channel:is_valid() end)
    if not valid_ok or not valid then
        state[st.name] = nil
        return
    end

    local remaining = st.expires - deps.clock.now()
    if remaining <= 0 then
        finish(st)
        return
    end

    local key = util.bar(remaining, st.total_ms, BAR_CELLS)
        .. "|" .. util.ceil_s(remaining) .. "|" .. st.sent

    if not is_last(st) then
        st.last_key = key
        repin(st, remaining)
    elseif key ~= st.last_key then
        st.last_key = key
        local ok, msg = pcall(build_active, st, remaining)
        if ok then swap_message(st, msg) end
    end

    c2.later(function() tick(st) end, TICK_MS)
end

function popup.show(channel, name, text, count)
    local old = state[name]
    if old then
        finish(old)
    end

    id_counter = id_counter + 1
    local total = deps.popup_ms()
    local st = {
        name     = name,
        channel  = channel,
        text     = text,
        count    = count,
        total_ms = total,
        expires  = deps.clock.now() + total,
        sent     = 0,
        base_id  = "copypasta." .. name .. "." .. id_counter,
        rev      = 0,
        id       = nil,
        msg      = nil,
        last_key = nil,
        norender = false,
    }

    repin(st, total)
    if st.msg == nil then
        pcall(function()
            channel:add_system_message(
                "[cp] pasta detected (" .. count .. " users): "
                .. util.shorten(text, 200) .. " - send it with " .. deps.send_command)
        end)
        st.norender = true
    end

    state[name] = st
    c2.later(function() tick(st) end, TICK_MS)
    return st
end

function popup.get(name)
    local st = state[name]
    if not st then return nil end
    if st.expires - deps.clock.now() <= 0 then
        finish(st)
        return nil
    end
    return st
end

function popup.on_sent(st)
    st.sent = st.sent + 1
    st.expires = deps.clock.now() + deps.popup_ms()
    st.total_ms = deps.popup_ms()
    st.last_key = nil
    local ok, msg = pcall(build_active, st, st.total_ms)
    if ok then swap_message(st, msg) end
end

function popup.close(name)
    local st = state[name]
    if st then
        finish(st)
    end
end

function popup.close_all()
    for _, st in pairs(state) do
        finish(st)
    end
end

function popup.active_count()
    local n = 0
    for _ in pairs(state) do n = n + 1 end
    return n
end

return popup
