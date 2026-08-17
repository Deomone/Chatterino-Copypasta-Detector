local clock = {
    last = 0,
}

function clock.now()
    local ok, t = pcall(function()
        local msg = c2.Message.new({
            elements = {
                { type = "timestamp" },
            },
        })
        local elements = msg:elements()
        return elements[1].time
    end)
    if ok and type(t) == "number" then
        t = math.floor(t)
        if t > clock.last then
            clock.last = t
        end
    end
    return clock.last
end

function clock.bump(ms)
    if type(ms) == "number" then
        ms = math.floor(ms)
        if ms > clock.last then
            clock.last = ms
        end
    end
end

return clock
