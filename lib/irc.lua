local util = require("lib.util")

local irc = {}

local WSS_URL          = "wss://irc-ws.chat.twitch.tv:443"
local PING_INTERVAL_MS = 240 * 1000
local STALL_MS         = 360 * 1000
local MAX_BACKOFF_MS   = 30 * 1000

local deps = nil

local ws = nil
local gen = 0
local registered = false
local attempts = 0
local last_rx = 0
local want = {}

function irc.init(d)
    deps = d
end

local function send(line)
    local sock = ws
    if not sock then return end
    pcall(function() sock:send_text(line .. "\r\n") end)
end

local function join_all()
    local names = {}
    for name in pairs(want) do
        names[#names + 1] = "#" .. name
    end
    if #names > 0 then
        send("JOIN " .. table.concat(names, ","))
    end
end

local function handle_line(line)
    local msg = util.parse_irc(line)
    if not msg then return end
    local cmd = msg.command

    if cmd == "PING" then
        send("PONG :" .. (msg.params[#msg.params] or "tmi.twitch.tv"))

    elseif cmd == "001" then
        registered = true
        attempts = 0
        deps.log("IRC watcher connected")
        join_all()

    elseif cmd == "RECONNECT" then
        deps.log("IRC: server requested a reconnect")
        irc.force_reconnect()

    elseif cmd == "PRIVMSG" then
        if #msg.params < 2 then return end
        local name = msg.params[1]:gsub("^#", ""):lower()
        if not want[name] then return end
        local login = util.nick(msg.prefix)
        if not login then return end

        local ts = tonumber(msg.tags["tmi-sent-ts"])
        if ts then
            ts = math.floor(ts)
            deps.clock.bump(ts)
        else
            ts = deps.clock.now()
        end

        deps.on_chat(name, login:lower(), util.normalize(msg.params[#msg.params]), ts)

    elseif cmd == "NOTICE" then
        deps.log("IRC NOTICE: " .. tostring(msg.params[#msg.params]))
    end
end

local connect

local function ping_loop(my_gen)
    c2.later(function()
        if my_gen ~= gen or ws == nil then return end
        if deps.clock.now() - last_rx > STALL_MS then
            deps.log("IRC: server has been silent for too long, reconnecting")
            irc.force_reconnect()
            return
        end
        send("PING :copypasta-keepalive")
        ping_loop(my_gen)
    end, PING_INTERVAL_MS)
end

local function on_closed(my_gen)
    if my_gen ~= gen then return end
    ws = nil
    registered = false

    if next(want) == nil then
        deps.log("IRC watcher disconnected")
        return
    end

    attempts = attempts + 1
    local delay = math.min(MAX_BACKOFF_MS, 1000 * (2 ^ math.min(attempts, 5)))
    deps.log("IRC: connection lost, retrying in " .. math.floor(delay / 1000) .. " s")

    local sched_gen = gen
    c2.later(function()
        if gen ~= sched_gen or ws ~= nil or next(want) == nil then return end
        connect()
    end, delay)
end

connect = function()
    gen = gen + 1
    local my_gen = gen
    registered = false
    last_rx = deps.clock.now()

    local ok, sock = pcall(c2.WebSocket.new, WSS_URL, {
        on_open = function()
            if my_gen ~= gen then return end
            send("CAP REQ :twitch.tv/tags twitch.tv/commands")
            send("NICK justinfan" .. math.random(10000, 99999))
        end,
        on_text = function(data)
            if my_gen ~= gen then return end
            last_rx = deps.clock.now()
            for line in util.iter_lines(data) do
                local ok_line, err = pcall(handle_line, line)
                if not ok_line then
                    deps.log("IRC: error while handling a line: " .. tostring(err))
                end
            end
        end,
        on_close = function()
            on_closed(my_gen)
        end,
    })

    if not ok then
        ws = nil
        c2.log(c2.LogLevel.Critical,
            "copypasta: failed to create a WebSocket (missing Network permission in info.json?): "
            .. tostring(sock))
        return
    end

    ws = sock
    ping_loop(my_gen)
end

function irc.sync(channels)
    local new_want = {}
    for _, name in ipairs(channels) do
        new_want[name] = true
    end

    if ws and registered then
        for name in pairs(want) do
            if not new_want[name] then send("PART #" .. name) end
        end
        local to_join = {}
        for name in pairs(new_want) do
            if not want[name] then to_join[#to_join + 1] = "#" .. name end
        end
        if #to_join > 0 then
            send("JOIN " .. table.concat(to_join, ","))
        end
    end

    want = new_want

    if next(want) == nil then
        irc.disconnect()
    elseif ws == nil then
        attempts = 0
        connect()
    end
end

function irc.disconnect()
    gen = gen + 1
    registered = false
    local sock = ws
    ws = nil
    if sock then
        pcall(function() sock:close() end)
    end
end

function irc.force_reconnect()
    local sock = ws
    if sock then
        pcall(function() sock:close() end)
    elseif next(want) ~= nil then
        connect()
    end
end

function irc.is_watching(name)
    return want[name] == true
end

function irc.status()
    if next(want) == nil then
        return "off"
    elseif ws == nil then
        return "reconnecting..."
    elseif registered then
        return "connected"
    else
        return "connecting..."
    end
end

return irc
