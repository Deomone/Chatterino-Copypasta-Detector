local json  = require("chatterino.json")
local util  = require("lib.util")
local clock = require("lib.clock")
local settings = {}
local FILE_CANDIDATES = { "settings.json", "data/settings.json" }

settings.DEFAULTS = {
    threshold     = 5,
    window_s      = 30,
    popup_s       = 5,
    auto          = false,
    channels      = {},
    blocked_terms = {},
    tz_offset_h   = 0,
    sent_today    = 0,
    sent_date     = "",
}

settings.LIMITS = {
    threshold   = { 2, 100 },
    window_s    = { 5, 600 },
    popup_s     = { 2, 120 },
    tz_offset_h = { -14, 14 },
}

settings.MAX_CHANNELS = 15
settings.values = nil
local active_path = nil

local function fresh_defaults()
    local d = settings.DEFAULTS
    return {
        threshold     = d.threshold,
        window_s      = d.window_s,
        popup_s       = d.popup_s,
        auto          = d.auto,
        channels      = {},
        blocked_terms = {},
        tz_offset_h   = d.tz_offset_h,
        sent_today    = 0,
        sent_date     = "",
    }
end

local function civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460)
        + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp + (mp < 10 and 3 or -9)
    if m <= 2 then y = y + 1 end
    return y, m, d
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

    if type(raw.blocked_terms) == "table" then
        local seen = {}
        for _, term in ipairs(raw.blocked_terms) do
            if type(term) == "string" then
                term = term:lower()
                if term ~= "" and not seen[term] then
                    seen[term] = true
                    v.blocked_terms[#v.blocked_terms + 1] = term
                end
            end
        end
    end

    local sent = tonumber(raw.sent_today)
    if sent then
        sent = math.floor(sent)
        if sent ~= sent or sent < 0 then
            sent = 0
        end
        v.sent_today = sent
    end

    if type(raw.sent_date) == "string" then
        v.sent_date = raw.sent_date
    end

    return v
end

function settings.load(log)
    settings.values = fresh_defaults()
    for _, path in ipairs(FILE_CANDIDATES) do
        local ok, file = pcall(io.open, path, "r")
        if ok and file then
            local content = file:read("*a")
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
    local channels      = settings.values and settings.values.channels or {}
    local blocked_terms = settings.values and settings.values.blocked_terms or {}
    local sent_today    = settings.values and settings.values.sent_today or 0
    local sent_date     = settings.values and settings.values.sent_date or ""

    settings.values = fresh_defaults()

    if not clear_channels then
        settings.values.channels = channels
    end
    settings.values.blocked_terms = blocked_terms
    settings.values.sent_today = sent_today
    settings.values.sent_date = sent_date
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

function settings.has_blocked_term(term)
    term = term:lower()
    for _, t in ipairs(settings.values.blocked_terms) do
        if t == term then return true end
    end
    return false
end

function settings.add_blocked_term(term)
    term = term:lower()
    if settings.has_blocked_term(term) then return false end
    table.insert(settings.values.blocked_terms, term)
    return true
end

function settings.remove_blocked_term(term)
    term = term:lower()
    for i, t in ipairs(settings.values.blocked_terms) do
        if t == term then
            table.remove(settings.values.blocked_terms, i)
            return true
        end
    end
    return false
end

function settings.blocked_terms_pretty()
    if #settings.values.blocked_terms == 0 then
        return "none"
    end
    local copy = {}
    for i, t in ipairs(settings.values.blocked_terms) do copy[i] = t end
    table.sort(copy)
    return table.concat(copy, ", ")
end

function settings.today_date()
    local now = clock.now()
    if type(now) ~= "number" or now <= 0 then
        return "unknown"
    end
    local offset_ms = (settings.values.tz_offset_h or 0) * 3600000
    local y, m, d = civil_from_days(math.floor((now + offset_ms) / 86400000))
    return string.format("%04d-%02d-%02d", y, m, d)
end

function settings.get_sent_today()
    if not settings.values then return 0 end
    if settings.values.sent_date == settings.today_date() then
        return settings.values.sent_today or 0
    end
    return 0
end

function settings.record_sent_today()
    if not settings.values then
        settings.values = fresh_defaults()
    end
    local today = settings.today_date()
    if settings.values.sent_date ~= today then
        settings.values.sent_date = today
        settings.values.sent_today = 1
    else
        settings.values.sent_today = (settings.values.sent_today or 0) + 1
    end
    return settings.values.sent_today
end

return settings