-- Additional candidates selected by the whole path, including words
-- missing from the letter-alignment shortlist. Inspired by Ligature 1.0.0.
local ShapeChannel = {
    TRIGGER_LETTERS = 5,
    MIN_LETTERS = 3,
    REACH = 1,
    MIN_RATIO = 0.7,
    MAX_RATIO = 1.4,
    MAX_SHAPE_SCORE = 1,
    KEEP = 10,
    SHAPE_WEIGHT = 6000,
    ALIGNMENT_WEIGHT = 1000,
    MAX_END_LETTERS = 4,
    MAX_ENTRIES = 20000,
    MAX_COMPARISONS = 2048,
    BUDGET_MS = 50,
}
ShapeChannel.__index = ShapeChannel

function ShapeChannel:new(store, geometry, personal)
    return setmetatable({ store = assert(store), geometry = assert(geometry),
        personal = personal, time = store.time,
        paths = setmetatable({}, { __mode = "k" }) }, self)
end

function ShapeChannel:triggered(signature)
    return #(signature or "") >= self.TRIGGER_LETTERS
end

function ShapeChannel:_lettersNear(point, centers)
    local near = {}
    for byte = 97, 122 do
        local center = centers[byte]
        if center then
            local dx, dy = center.x - point.x, center.y - point.y
            local distance = dx * dx + dy * dy
            local reach = self.REACH * math.max(1, center.size or 1)
            if distance <= reach * reach then
                near[#near + 1] = { letter = string.char(byte), distance = distance }
            end
        end
    end
    table.sort(near, function(a, b)
        if a.distance == b.distance then return a.letter < b.letter end
        return a.distance < b.distance
    end)
    local letters = {}
    for index = 1, math.min(#near, self.MAX_END_LETTERS) do
        letters[index] = near[index].letter
    end
    return letters
end

function ShapeChannel:candidates(options)
    local stats = { entries = 0, compared = 0, buckets = 0, exhausted = false }
    self.last_stats = stats
    if not self:triggered(options.signature) then return {} end
    local swipe = options.swipe or self.geometry:prepareTrace(options.points)
    if not swipe then return {} end
    local centers = options.key_centers or {}
    self.geometry:_ensureGeometry(centers)
    local layout = self.geometry.cache_geometry
    if self.layout ~= layout then
        self.paths = setmetatable({}, { __mode = "k" })
        self.layout = layout
    end
    local clock = self.time
    local start = clock and clock.now()
    local deadline = start and start + clock.ms(self.BUDGET_MS)
    local function outOfTime()
        return deadline and clock.now() >= deadline
    end
    local found, seen, shape_scores, shape_bounds = {}, {}, {}, {}
    local dictionary = options.dictionary or "en"
    local language = options.data_language or dictionary
    local function consider(entry, paths, index)
        if not entry.word or seen[entry.word] or (entry.lang
                and entry.lang ~= dictionary and entry.lang ~= language) then return end
        seen[entry.word] = true
        local signature = entry.gesture_signature or entry.signature
        if not signature or #(entry.signature or signature) < self.MIN_LETTERS then return end
        local length, scale = paths.lengths[index], paths.scales[index]
        if length == nil then
            length, scale = self.geometry:measurePath(signature, centers)
            paths.lengths[index], paths.scales[index] = length or 0, scale or 0
        end
        if not length or length <= 0 then return end
        local ratio = swipe.length / length
        if ratio < self.MIN_RATIO or ratio > self.MAX_RATIO then return end
        if stats.compared >= self.MAX_COMPARISONS then
            stats.exhausted = true
            return
        end
        stats.compared = stats.compared + 1
        local shape = shape_scores[signature]
        if shape == nil then
            local worst = #found >= self.KEEP and found[self.KEEP].rank
            local bound = shape_bounds[signature]
            if bound and (bound > self.MAX_SHAPE_SCORE or (worst
                    and self.SHAPE_WEIGHT * bound - (entry.freq or 0) >= worst)) then return end
            local partial
            shape, partial = self.geometry:scorePathUntil(signature, centers, length, scale,
                swipe, worst, entry.freq or 0, self.SHAPE_WEIGHT, self.MAX_SHAPE_SCORE)
            -- Partial sums are lower bounds, not scores or unconditional
            -- rejections. A higher-frequency spelling may still beat the cutoff.
            if shape == nil then
                if partial then shape_bounds[signature] = math.max(bound or 0, partial) end
                return
            end
            shape_scores[signature] = shape
        end
        if shape > self.MAX_SHAPE_SCORE then return end
        local rank = self.SHAPE_WEIGHT * shape - (entry.freq or 0)
        local position = #found + 1
        while position > 1 and found[position - 1].rank > rank do
            position = position - 1
        end
        if position <= self.KEEP then
            table.insert(found, position, { entry = entry, shape = shape, rank = rank })
            if #found > self.KEEP then found[#found] = nil end
        end
    end
    local function scan(bucket, primary)
        local entries = bucket and bucket.entries
        if not entries then return end
        local paths = self.paths[entries]
        if not paths or paths.count ~= #entries then
            paths = { count = #entries, lengths = {}, scales = {} }
            self.paths[entries] = paths
        end
        for index, entry in ipairs(entries) do
            if stats.entries >= self.MAX_ENTRIES or stats.exhausted
                    or (not primary and stats.entries % 32 == 0 and outOfTime()) then
                stats.exhausted = true
                break
            end
            stats.entries = stats.entries + 1
            consider(entry, paths, index)
        end
    end
    local first, last = swipe.samples[1], swipe.samples[#swipe.samples]
    local starts, ends = self:_lettersNear(first, centers), self:_lettersNear(last, centers)
    for _, a in ipairs(starts) do
        for _, b in ipairs(ends) do
            if outOfTime() or stats.exhausted then stats.exhausted = true; break end
            -- Finish the closest endpoint pair even if its first load or
            -- path measurements exceed the clock budget. Otherwise cold
            -- recognition depends on where a word lies in that bucket.
            -- Entry/comparison caps still apply; the clock limits extra pairs.
            local primary = stats.buckets == 0
            if self.personal then
                scan(self.personal:getBucket(a, b, dictionary, options.normalization_profile),
                    primary)
            end
            if not stats.exhausted then
                stats.buckets = stats.buckets + 1
                scan(self.store:loadBucket(a, b, dictionary), primary)
            end
        end
        if stats.exhausted then break end
    end
    if start then stats.elapsed_ms = (clock.now() - start) / clock.ms(1) end
    return found
end

return ShapeChannel
