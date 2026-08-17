local util         = require("lib.util")
local clock        = require("lib.clock")
local settings     = require("lib.settings")
local detector_mod = require("lib.detector")
local sender       = require("lib.sender")
local popup        = require("lib.popup")
local irc          = require("lib.irc")
local commands     = require("lib.commands")

local COMMAND = "/cp"

local function log(text)
    c2.log(c2.LogLevel.Info, "copypasta: " .. tostring(text))
end

settings.load(log)

local detector = detector_mod.new(
    function() return settings.values.threshold end,
    function() return settings.values.window_s * 1000 end
)

popup.init({
    clock        = clock,
    log          = log,
    popup_ms     = function() return settings.values.popup_s * 1000 end,
    send_command = COMMAND .. " send",
})

sender.init({ clock = clock, log = log })

local me_cache = { login = nil, valid_until = 0 }

local function my_login()
    local now = clock.now()
    if now < me_cache.valid_until then
        return me_cache.login
    end
    local login = nil
    pcall(function()
        local acc = c2.current_account()
        if acc:is_valid() and not acc:is_anon() then
            login = acc:login():lower()
        end
    end)
    me_cache.login = login
    me_cache.valid_until = now + 5000
    return login
end

local function try_send(channel)
    local ok_name, name = pcall(function() return channel:get_name() end)
    if not ok_name then
        return false, "channel_invalid"
    end
    local st = popup.get(name)
    if not st then
        return false, "no_pasta"
    end
    local ok, err = sender.send(channel, st.text)
    if ok then
        popup.on_sent(st)
    end
    return ok, err
end

local function on_pasta(name, ev)
    local ok_ch, channel = pcall(c2.Channel.by_name, name)
    if not ok_ch or not channel then
        return
    end
    local ok_type, ctype = pcall(function() return channel:get_type() end)
    if not ok_type or ctype ~= c2.ChannelType.Twitch then
        return
    end
    
    -- Popup is always shown, regardless of blocked terms
    local st = popup.show(channel, name, ev.text, ev.count)
    log("pasta in #" .. name .. " (" .. ev.count .. " users): " .. util.shorten(ev.text, 80))
    
    if settings.values.auto and st then
        -- NEW: Check if the pasta contains any blocked terms
        if util.contains_blocked_term(ev.text, settings.values.blocked_terms) then
            pcall(function()
                channel:add_system_message("[cp] auto-send blocked: message contains a blocked term")
            end)
        else
            local sent, err = try_send(channel)
            if not sent then
                pcall(function()
                    channel:add_system_message("[cp] auto-send failed: " .. (sender.ERRORS[err] or tostring(err)))
                end)
            end
        end
    end
end

local function on_chat(name, login, text, ts)
    local me = my_login()
    if me and login == me then
        return
    end
    if util.is_unsafe_command(text) then
        return
    end
    local ev = detector:on_message(name, login, text, ts)
    if ev then
        on_pasta(name, ev)
    end
end

irc.init({ clock = clock, log = log, on_chat = on_chat })

local app = {
    settings = settings,
    irc      = irc,
    popup    = popup,
    sender   = sender,
    detector = detector,
    clock    = clock,
    log      = log,
    command  = COMMAND,
    save     = function() settings.save(log) end,
    sync     = function() irc.sync(settings.values.channels) end,
    try_send = try_send,
}

commands.register(app)

local SWEEP_MS = 15 * 1000

local function sweep_loop()
    pcall(function() detector:sweep(clock.now()) end)
    c2.later(sweep_loop, SWEEP_MS)
end

sweep_loop()
app.sync()

log("plugin loaded · threshold " .. settings.values.threshold
    .. " users in " .. settings.values.window_s
    .. " s · popup " .. settings.values.popup_s
    .. " s · auto: " .. (settings.values.auto and "on" or "off")
    .. " · channels: " .. settings.channels_pretty()
    .. " · blocked terms: " .. #settings.values.blocked_terms)