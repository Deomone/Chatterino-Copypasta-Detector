local util = require("lib.util")

local commands = {}

local SUBCOMMANDS = {
    "on", "off", "auto", "send", "timeout", "threshold", "window",
    "status", "list", "reset", "help",
}

function commands.register(app)
    local settings = app.settings
    local cmd = app.command
    local TAG = "[" .. cmd:gsub("^/", "") .. "] "

    local function reply(channel, text)
        pcall(function()
            channel:add_system_message(TAG .. text)
        end)
    end

    local function is_twitch_chat(channel)
        local ok, t = pcall(function() return channel:get_type() end)
        return ok and t == c2.ChannelType.Twitch
    end

    local function chan_name(channel)
        local ok, name = pcall(function() return channel:get_name() end)
        if ok then return name end
        return nil
    end

    local function numeric_setter(key, label, unit)
        return function(ctx)
            local raw = ctx.words[3]
            if not raw then
                reply(ctx.channel, label .. " is currently: "
                    .. settings.values[key] .. " " .. unit
                    .. ". Usage: " .. cmd .. " " .. ctx.words[2] .. " <number>")
                return
            end
            local n = tonumber(raw)
            if not n then
                reply(ctx.channel, "\"" .. raw .. "\" is not a number")
                return
            end
            local lo, hi = settings.LIMITS[key][1], settings.LIMITS[key][2]
            local applied = util.clamp_int(n, lo, hi)
            settings.values[key] = applied
            app.save()
            local note = (applied ~= math.floor(n))
                and " (clamped to the " .. lo .. "-" .. hi .. " range)" or ""
            reply(ctx.channel, label .. ": " .. applied .. " " .. unit .. note)
        end
    end

    local handlers = {}

    handlers.on = function(ctx)
        if not is_twitch_chat(ctx.channel) then
            reply(ctx.channel, "this command only works in a Twitch chat")
            return
        end
        local name = chan_name(ctx.channel)
        if not name then return end

        local ok, err = settings.add_channel(name)
        if err == "limit" then
            reply(ctx.channel, "watched channel limit reached ("
                .. settings.MAX_CHANNELS .. "), free a slot with " .. cmd .. " off in another channel")
            return
        end
        app.sync()
        if ok then
            app.save()
            reply(ctx.channel, "pasta detection in #" .. name .. " ENABLED · threshold "
                .. settings.values.threshold .. " users in " .. settings.values.window_s .. " s")
        else
            reply(ctx.channel, "already enabled in #" .. name)
        end

        local anon = false
        pcall(function()
            local acc = c2.current_account()
            anon = (not acc:is_valid()) or acc:is_anon()
        end)
        if anon then
            reply(ctx.channel, "note: you are not logged in to Twitch - pastas will be detected, but sending will not work")
        end
    end

    handlers.off = function(ctx)
        if (ctx.words[3] or ""):lower() == "all" then
            settings.clear_channels()
            app.popup.close_all()
            app.detector:clear()
            app.sync()
            app.save()
            reply(ctx.channel, "pasta detection disabled in ALL channels")
            return
        end
        if not is_twitch_chat(ctx.channel) then
            reply(ctx.channel, "this command only works in a Twitch chat (or use " .. cmd .. " off all)")
            return
        end
        local name = chan_name(ctx.channel)
        if not name then return end
        if settings.remove_channel(name) then
            app.popup.close(name)
            app.detector:clear(name)
            app.sync()
            app.save()
            reply(ctx.channel, "pasta detection in #" .. name .. " disabled")
        else
            reply(ctx.channel, "already disabled in #" .. name)
        end
    end

    handlers.auto = function(ctx)
        local arg = (ctx.words[3] or ""):lower()
        if arg == "on" then
            settings.values.auto = true
        elseif arg == "off" then
            settings.values.auto = false
        elseif arg == "" then
            settings.values.auto = not settings.values.auto
        else
            reply(ctx.channel, "usage: " .. cmd .. " auto [on|off]")
            return
        end
        app.save()
        reply(ctx.channel, "auto-send: " .. (settings.values.auto and "ENABLED" or "disabled"))
    end

    handlers.send = function(ctx)
        if not is_twitch_chat(ctx.channel) then
            reply(ctx.channel, "pastas can only be sent in a Twitch chat")
            return
        end
        local ok, err = app.try_send(ctx.channel)
        if ok then
            return
        end
        if err == "no_pasta" then
            reply(ctx.channel, "no active pasta right now (the popup expired or never appeared)")
        else
            reply(ctx.channel, "not sent: " .. (app.sender.ERRORS[err] or tostring(err)))
        end
    end

    handlers.timeout   = numeric_setter("popup_s",   "popup duration",     "s")
    handlers.threshold = numeric_setter("threshold", "detection threshold", "users")
    handlers.window    = numeric_setter("window_s",  "analysis window",    "s")

    handlers.status = function(ctx)
        local name = chan_name(ctx.channel)
        local here = "-"
        if name and is_twitch_chat(ctx.channel) then
            here = "#" .. name .. ": " .. (settings.has_channel(name) and "ON" or "off")
        end
        local channels_n, texts_n = app.detector:stats()
        reply(ctx.channel, here .. " · IRC watcher: " .. app.irc.status())
        reply(ctx.channel, "threshold: " .. settings.values.threshold
            .. " users · window: " .. settings.values.window_s
            .. " s · popup: " .. settings.values.popup_s
            .. " s · auto: " .. (settings.values.auto and "on" or "off"))
        reply(ctx.channel, "channels (" .. #settings.values.channels .. "/" .. settings.MAX_CHANNELS
            .. "): " .. settings.channels_pretty()
            .. " · active popups: " .. app.popup.active_count()
            .. " · analyzing: " .. texts_n .. " text(s) in " .. channels_n .. " channel(s)")
    end

    handlers.list = function(ctx)
        reply(ctx.channel, "watched channels: " .. settings.channels_pretty()
            .. " · IRC: " .. app.irc.status())
    end

    handlers.reset = function(ctx)
        local all = (ctx.words[3] or ""):lower() == "all"
        settings.reset(all)
        if all then
            app.popup.close_all()
            app.detector:clear()
            app.sync()
        end
        app.save()
        reply(ctx.channel, "settings reset to defaults"
            .. (all and " (including the channel list)"
                or " (channel list kept; full reset: " .. cmd .. " reset all)"))
    end

    handlers.help = function(ctx)
        reply(ctx.channel, "commands: " .. cmd .. " on · off [all] · auto [on|off] · send · "
            .. "timeout N · threshold N · window N · status · list · reset [all]")
        reply(ctx.channel, "clicking the popup = " .. cmd .. " send: sends the pasta and restarts the timer")
    end

    local ok = c2.register_command(cmd, function(ctx)
        local run_ok, err = pcall(function()
            local sub = (ctx.words[2] or "help"):lower()
            local handler = handlers[sub] or handlers.help
            handler(ctx)
        end)
        if not run_ok then
            app.log("error in the " .. cmd .. " handler: " .. tostring(err))
            reply(ctx.channel, "internal error, see the Chatterino logs")
        end
    end)
    if not ok then
        c2.log(c2.LogLevel.Warning, "copypasta: command " .. cmd .. " is already taken by another plugin")
    end

    local prefix = cmd .. " "
    c2.register_callback(c2.EventType.CompletionRequested, function(event)
        local full = event.full_text_content or ""
        if not event.is_first_word and full:sub(1, #prefix) == prefix then
            local q = (event.query or ""):lower()
            local values = {}
            for _, sub in ipairs(SUBCOMMANDS) do
                if sub:sub(1, #q) == q then
                    values[#values + 1] = sub
                end
            end
            return { hide_others = #values > 0, values = values }
        end
        return { hide_others = false, values = {} }
    end)
end

return commands
