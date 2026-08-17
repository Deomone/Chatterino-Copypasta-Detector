local detector = {}
detector.__index = detector

local MAX_TEXTS_PER_CHANNEL = 400
local MAX_TEXT_BYTES        = 2000

function detector.new(threshold_fn, window_ms_fn)
    return setmetatable({
        threshold_fn = threshold_fn,
        window_ms_fn = window_ms_fn,
        state = {},
    }, detector)
end

local function prune_entry(entry, cutoff)
    local count = 0
    for login, ts in pairs(entry.users) do
        if ts < cutoff then
            entry.users[login] = nil
        else
            count = count + 1
        end
    end
    return count
end

local function evict_oldest(chan_state)
    local oldest_text, oldest_ts = nil, math.huge
    for text, entry in pairs(chan_state.texts) do
        if entry.last < oldest_ts then
            oldest_ts = entry.last
            oldest_text = text
        end
    end
    if oldest_text then
        chan_state.texts[oldest_text] = nil
        chan_state.n = chan_state.n - 1
    end
end

function detector:on_message(channel, login, text, now)
    if text == "" or #text > MAX_TEXT_BYTES then
        return nil
    end

    local chan_state = self.state[channel]
    if not chan_state then
        chan_state = { n = 0, texts = {} }
        self.state[channel] = chan_state
    end

    local entry = chan_state.texts[text]
    if not entry then
        if chan_state.n >= MAX_TEXTS_PER_CHANNEL then
            evict_oldest(chan_state)
        end
        entry = { users = {}, last = now, announced = false }
        chan_state.texts[text] = entry
        chan_state.n = chan_state.n + 1
    end

    entry.users[login] = now
    entry.last = now

    local count = prune_entry(entry, now - self.window_ms_fn())

    if not entry.announced and count >= self.threshold_fn() then
        entry.announced = true
        return { text = text, count = count }
    end
    return nil
end

function detector:sweep(now)
    for channel, chan_state in pairs(self.state) do
        local cutoff = now - self.window_ms_fn()
        for text, entry in pairs(chan_state.texts) do
            if prune_entry(entry, cutoff) == 0 then
                chan_state.texts[text] = nil
                chan_state.n = chan_state.n - 1
            end
        end
        if chan_state.n == 0 then
            self.state[channel] = nil
        end
    end
end

function detector:clear(channel)
    if channel then
        self.state[channel] = nil
    else
        self.state = {}
    end
end

function detector:stats()
    local channels, texts = 0, 0
    for _, chan_state in pairs(self.state) do
        channels = channels + 1
        texts = texts + chan_state.n
    end
    return channels, texts
end

return detector
