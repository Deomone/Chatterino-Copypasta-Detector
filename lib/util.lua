local util = {}

function util.iter_lines(data)
    return data:gmatch("[^\r\n]+")
end

local TAG_UNESCAPE = {
    [":"] = ";",
    ["s"] = " ",
    ["r"] = "\r",
    ["n"] = "\n",
    ["\\"] = "\\",
}

function util.unescape_tag(value)
    return (value:gsub("\\(.)", function(c)
        return TAG_UNESCAPE[c] or c
    end))
end

function util.parse_irc(line)
    local msg = { tags = {}, params = {} }
    local pos = 1

    if line:sub(1, 1) == "@" then
        local sp = line:find(" ", 1, true)
        if not sp then return nil end
        local raw = line:sub(2, sp - 1)
        for pair in raw:gmatch("[^;]+") do
            local k, v = pair:match("^([^=]+)=?(.*)$")
            if k then
                msg.tags[k] = util.unescape_tag(v or "")
            end
        end
        pos = sp + 1
    end

    if line:sub(pos, pos) == ":" then
        local sp = line:find(" ", pos, true)
        if not sp then return nil end
        msg.prefix = line:sub(pos + 1, sp - 1)
        pos = sp + 1
    end

    local rest = line:sub(pos)
    local trailing
    local tpos = rest:find(" :", 1, true)
    if tpos then
        trailing = rest:sub(tpos + 2)
        rest = rest:sub(1, tpos - 1)
    end
    for word in rest:gmatch("%S+") do
        if not msg.command then
            msg.command = word
        else
            msg.params[#msg.params + 1] = word
        end
    end
    if trailing ~= nil then
        msg.params[#msg.params + 1] = trailing
    end

    if not msg.command then return nil end
    return msg
end

function util.nick(prefix)
    if not prefix then return nil end
    return prefix:match("^([^!@%s]+)")
end

local DUP_TAIL = "\243\160\128\128"

function util.normalize(text)
    local action = text:match("^\1ACTION (.-)\1$") or text:match("^\1ACTION (.*)$")
    if action then
        text = "/me " .. action
    end

    text = text:gsub("[\r\n]", " ")

    while true do
        local trimmed = text:gsub("%s+$", "")
        if trimmed:sub(-#DUP_TAIL) == DUP_TAIL then
            trimmed = trimmed:sub(1, -(#DUP_TAIL + 1))
        end
        if trimmed == text then break end
        text = trimmed
    end

    return (text:gsub("^%s+", ""))
end

function util.is_unsafe_command(text)
    if text:sub(1, 4) == "/me " then return false end
    local first = text:sub(1, 1)
    return first == "/" or first == "."
end

function util.bar(remaining_ms, total_ms, cells)
    if total_ms <= 0 then total_ms = 1 end
    local filled = math.ceil((remaining_ms / total_ms) * cells)
    if filled < 0 then filled = 0 end
    if filled > cells then filled = cells end
    return string.rep("▰", filled) .. string.rep("▱", cells - filled)
end

function util.ceil_s(ms)
    if ms <= 0 then return 0 end
    return math.ceil(ms / 1000) | 0
end

function util.clamp_int(v, lo, hi)
    v = math.floor(v)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function util.shorten(s, max_cp)
    local ok, res = pcall(function()
        if utf8.len(s) == nil then
            if #s <= max_cp then return s end
            return s:sub(1, max_cp) .. "…"
        end
        if utf8.len(s) <= max_cp then return s end
        return s:sub(1, utf8.offset(s, max_cp + 1) - 1) .. "…"
    end)
    if ok then return res end
    return s:sub(1, max_cp)
end

return util
