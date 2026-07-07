local util = require("lib.util")

local sender = {}

local MIN_INTERVAL_MS = 1100

local deps = nil
local last_sent = {}

function sender.init(d)
    deps = d
end

sender.ERRORS = {
    channel_invalid = "the channel is no longer open",
    anon            = "you are not logged in to Twitch - cannot send",
    unsafe          = "the text looks like a command, sending is blocked for safety",
    ratelimited     = "too fast, wait a second",
    send_failed     = "Chatterino failed to send the message",
}

function sender.send(channel, text)
    local valid_ok, valid = pcall(function() return channel:is_valid() end)
    if not valid_ok or not valid then
        return false, "channel_invalid"
    end

    local acc_ok, is_anon = pcall(function()
        local acc = c2.current_account()
        return (not acc:is_valid()) or acc:is_anon()
    end)
    if acc_ok and is_anon then
        return false, "anon"
    end

    if text == "" or util.is_unsafe_command(text) then
        return false, "unsafe"
    end

    local name_ok, name = pcall(function() return channel:get_name() end)
    if not name_ok then
        return false, "channel_invalid"
    end

    local now = deps.clock.now()
    if now - (last_sent[name] or 0) < MIN_INTERVAL_MS then
        return false, "ratelimited"
    end

    local sent_ok = pcall(function() channel:send_message(text) end)
    if not sent_ok then
        return false, "send_failed"
    end

    last_sent[name] = now
    return true
end

return sender
