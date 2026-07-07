local json = require("chatterino.json")
local util = require("lib.util")

local settings = {}

local FILE_CANDIDATES = { "settings.json", "data/settings.json" }

settings.DEFAULTS = {
    threshold = 5,
    window_s  = 30,
    popup_s   = 5,
    auto      = false,
    channels  = {},
}

settings.LIMITS = {
    threshold = { 2, 100 },
    window_s  = { 5, 600 },
    popup_s   = { 2, 120 },
}

settings.MAX_CHANNELS = 15

settings.values = nil

local active_path = nil

local function fresh_defaults()
    local d = settings.DEFAULTS
    return {
        threshold = d.threshold,
        window_s  = d.window_s,
        popup_s   = d.popup_s,
        auto      = d.auto,
        channels  = {},
    }
end

local function sanitize(raw)
    local v = fresh_defaults()
    if type(raw) ~= "table" then return v end

    for key, range in pairs(settings.LIMITS) do
        local n = tonumber(raw[key])
        if n then
            v[key] = util.clamp_int(n, range[1], range[2])
        end
    end
    if type(raw.auto) == "boolean" then
        v.auto = raw.auto
    end
    if type(raw.channels) == "table" then
        local seen = {}
        for _, name in ipairs(raw.channels) do
            if type(name) == "string" then
                name = name:lower():gsub("^#", "")
                if name ~= "" and not seen[name]
                    and #v.channels < settings.MAX_CHANNELS then
                    seen[name] = true
                    v.channels[#v.channels + 1] = name
                end
            end
        end
    end
    return v
end

function settings.load(log)
    settings.values = fresh_defaults()

    for _, path in ipairs(FILE_CANDIDATES) do
        local ok, file = pcall(io.open, path, "r")
        if ok and file then
            local content = file:read("a")
            file:close()
            active_path = path
            if content and content ~= "" then
                local parsed_ok, parsed = pcall(json.parse, content)
                if parsed_ok then
                    settings.values = sanitize(parsed)
                    if log then log("settings loaded from " .. path) end
                elseif log then
                    log("settings file is corrupted, using defaults")
                end
            end
            return
        end
    end
    if log then log("settings file not found, using defaults") end
end

function settings.save(log)
    local payload = json.stringify(settings.values, { pretty = true })

    local paths = {}
    if active_path then paths[#paths + 1] = active_path end
    for _, p in ipairs(FILE_CANDIDATES) do
        if p ~= active_path then paths[#paths + 1] = p end
    end

    for _, path in ipairs(paths) do
        local ok, file = pcall(io.open, path, "w")
        if ok and file then
            file:write(payload)
            file:close()
            active_path = path
            return true
        end
    end

    if log then log("failed to save settings (missing FilesystemWrite permission?)") end
    return false
end

function settings.reset(clear_channels)
    local channels = settings.values.channels
    settings.values = fresh_defaults()
    if not clear_channels then
        settings.values.channels = channels
    end
end

function settings.has_channel(name)
    for _, ch in ipairs(settings.values.channels) do
        if ch == name then return true end
    end
    return false
end

function settings.add_channel(name)
    if settings.has_channel(name) then
        return false, "already"
    end
    if #settings.values.channels >= settings.MAX_CHANNELS then
        return false, "limit"
    end
    table.insert(settings.values.channels, name)
    return true
end

function settings.remove_channel(name)
    for i, ch in ipairs(settings.values.channels) do
        if ch == name then
            table.remove(settings.values.channels, i)
            return true
        end
    end
    return false
end

function settings.clear_channels()
    settings.values.channels = {}
end

function settings.channels_pretty()
    if #settings.values.channels == 0 then
        return "none"
    end
    local copy = {}
    for i, ch in ipairs(settings.values.channels) do copy[i] = ch end
    table.sort(copy)
    return table.concat(copy, ", ")
end

return settings
