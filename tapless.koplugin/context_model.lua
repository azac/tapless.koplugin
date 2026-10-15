local ContextModel = {}
ContextModel.__index = ContextModel

function ContextModel:new(settings, setting_key)
    return setmetatable({
        settings = assert(settings),
        setting_key = assert(setting_key),
        counts = nil,
        dirty = false,
    }, self)
end

function ContextModel:getCounts()
    if self.counts then
        return self.counts
    end
    local counts = self.settings:readSetting(self.setting_key, {})
    if type(counts) ~= "table" then
        counts = {}
    end
    self.counts = counts
    return counts
end

function ContextModel:bonus(previous_word, word)
    if not previous_word or not word then
        return 0
    end
    local previous_counts = self:getCounts()[previous_word]
    local count = previous_counts and previous_counts[word] or 0
    if count <= 0 then
        return 0
    end
    return math.min(3600,
        math.floor(600 * math.log(count + 1) / math.log(2)))
end

function ContextModel:learn(previous_word, word)
    if not previous_word or not word or #previous_word == 0 or #word == 0 then
        return
    end
    local counts = self:getCounts()
    counts[previous_word] = counts[previous_word] or {}
    local previous_counts = counts[previous_word]
    previous_counts[word] = math.min(255, (previous_counts[word] or 0) + 1)

    local entries = 0
    for _ in pairs(previous_counts) do
        entries = entries + 1
    end
    if entries > 24 then
        local least_word
        local least_count
        for candidate_word, candidate_count in pairs(previous_counts) do
            if not least_count or candidate_count < least_count then
                least_word = candidate_word
                least_count = candidate_count
            end
        end
        if least_word and least_word ~= word then
            previous_counts[least_word] = nil
        end
    end
    self.dirty = true
end

function ContextModel:commit(pending)
    if not pending or pending.context_committed then
        return
    end
    self:learn(pending.previous_word, pending.word)
    pending.context_committed = true
end

function ContextModel:save()
    if self.dirty and self.counts then
        self.settings:saveSetting(self.setting_key, self.counts)
        self.dirty = false
    end
end

function ContextModel:countsAfter(previous_word)
    return previous_word and self:getCounts()[previous_word] or {}
end

return ContextModel
