local GeometryReranker = {
    SAMPLE_COUNT = 20,
    RANK_WEIGHT = 1800,
    MAX_SCORE = 2,
    IDEAL_CACHE_LIMIT = 128,
}
GeometryReranker.__index = GeometryReranker
local EMPTY_CENTERS = {}

local function distance(left, right)
    local dx = left.x - right.x
    local dy = left.y - right.y
    return math.sqrt(dx * dx + dy * dy)
end

local function trimTrace(points)
    if not points or #points < 2 then
        return points or {}
    end
    local first
    local last
    for index, point in ipairs(points) do
        if point.letter or point.letter_index then
            first = first or index
            last = index
        end
    end
    if not first or (first == 1 and last == #points) then
        return points
    end
    local trimmed = {}
    for index = first, last do
        table.insert(trimmed, points[index])
    end
    return trimmed
end

local function resample(points, sample_count)
    if not points or #points < 2 then
        return nil
    end
    local cumulative = { 0 }
    for index = 2, #points do
        cumulative[index] = cumulative[index - 1]
            + distance(points[index - 1], points[index])
    end
    local total_length = cumulative[#points]
    if total_length <= 0 then
        return nil
    end

    local samples = {}
    local segment = 2
    for sample_index = 1, sample_count do
        local target = total_length * (sample_index - 1) / (sample_count - 1)
        while segment < #points and cumulative[segment] < target do
            segment = segment + 1
        end
        local previous_length = cumulative[segment - 1]
        local segment_length = cumulative[segment] - previous_length
        local ratio = segment_length > 0
            and (target - previous_length) / segment_length or 0
        samples[sample_index] = {
            x = points[segment - 1].x
                + (points[segment].x - points[segment - 1].x) * ratio,
            y = points[segment - 1].y
                + (points[segment].y - points[segment - 1].y) * ratio,
        }
    end
    return samples, total_length
end

local function candidatePath(signature, key_centers)
    local points = {}
    local size_total = 0
    for index = 1, #signature do
        local center = key_centers[string.byte(signature, index)]
        if not center then
            return nil
        end
        table.insert(points, { x = center.x, y = center.y })
        size_total = size_total + math.max(1, center.size or 1)
    end
    if #points < 2 then
        return nil
    end
    return points, size_total / #points
end

function GeometryReranker:new()
    return setmetatable({ ideal_cache = {}, cache_order = {}, cache_next = 1 }, self)
end

function GeometryReranker:_ensureGeometry(key_centers)
    local unchanged = self.cache_geometry
        and self.cache_sample_count == self.SAMPLE_COUNT
        and self.cache_limit == self.IDEAL_CACHE_LIMIT
    local count = 0
    if unchanged then
        -- keyCenters() returns a new table for each recognition. Compare
        -- coordinates, sizes and membership rather than table identity.
        for byte, center in pairs(key_centers) do
            count = count + 1
            local cached = self.cache_geometry[byte]
            if not cached or cached.x ~= center.x or cached.y ~= center.y
                    or cached.size ~= center.size then
                unchanged = false
                break
            end
        end
        unchanged = unchanged and count == self.cache_center_count
    end
    if unchanged then
        return
    end
    local geometry = {}
    count = 0
    for byte, center in pairs(key_centers) do
        geometry[byte] = { x = center.x, y = center.y, size = center.size }
        count = count + 1
    end
    self.cache_geometry = geometry
    self.cache_center_count = count
    self.cache_sample_count = self.SAMPLE_COUNT
    self.cache_limit = self.IDEAL_CACHE_LIMIT
    self.ideal_cache = {}
    self.cache_order = {}
    self.cache_next = 1
end

function GeometryReranker:_idealPath(signature, key_centers)
    local cached = self.ideal_cache[signature]
    if cached ~= nil then
        return cached or nil
    end
    local ideal_points, scale = candidatePath(signature, key_centers)
    local ideal
    if ideal_points then
        local samples, length = resample(ideal_points, self.SAMPLE_COUNT)
        if samples then
            ideal = { samples = samples, length = length, scale = scale }
        end
    end
    -- A FIFO ring bounds retained paths and makes eviction constant-time.
    -- Missing/zero-length paths are cached too, within the same limit.
    if self.IDEAL_CACHE_LIMIT > 0 then
        local slot = self.cache_next
        local evicted = self.cache_order[slot]
        if evicted then
            self.ideal_cache[evicted] = nil
        end
        self.cache_order[slot] = signature
        self.ideal_cache[signature] = ideal or false
        self.cache_next = slot % self.IDEAL_CACHE_LIMIT + 1
    end
    return ideal
end

function GeometryReranker:_scoreSamples(actual_samples, actual_length,
        signature, key_centers)
    if not actual_samples then
        return nil
    end
    local ideal = self:_idealPath(signature, key_centers)
    if not ideal then
        return nil
    end
    local ideal_samples, ideal_length, scale =
        ideal.samples, ideal.length, ideal.scale
    local distance_total = 0
    for index = 1, self.SAMPLE_COUNT do
        distance_total = distance_total
            + distance(actual_samples[index], ideal_samples[index])
    end
    local shape_score = distance_total / self.SAMPLE_COUNT / scale
    local length_score = math.min(self.MAX_SCORE,
        math.abs(actual_length - ideal_length) / math.max(scale, ideal_length))
    return math.min(self.MAX_SCORE, shape_score * 0.85 + length_score * 0.15)
end

function GeometryReranker:score(points, signature, key_centers)
    key_centers = key_centers or EMPTY_CENTERS
    self:_ensureGeometry(key_centers)
    local actual_samples, actual_length = resample(
        trimTrace(points), self.SAMPLE_COUNT)
    return self:_scoreSamples(actual_samples, actual_length, signature, key_centers)
end

function GeometryReranker:prepareTrace(points)
    local samples, length = resample(trimTrace(points), self.SAMPLE_COUNT)
    if samples then return { samples = samples, length = length } end
end

function GeometryReranker:measurePath(signature, key_centers)
    if #signature < 2 then return end
    local total, size, previous = 0, 0, nil
    for index = 1, #signature do
        local center = key_centers[string.byte(signature, index)]
        if not center then return end
        size = size + math.max(1, center.size or 1)
        if previous then total = total + distance(previous, center) end
        previous = center
    end
    if total > 0 then return total, size / #signature end
end

-- Flat scratch samples for shape search; do not fill the bounded ideal
-- cache with the hundreds of paths inspected but not returned as words.
function GeometryReranker:samplePathInto(signature, key_centers, length, samples)
    local segment, passed = 2, 0
    local a, b = key_centers[signature:byte(1)], key_centers[signature:byte(2)]
    local segment_length = distance(a, b)
    for index = 1, self.SAMPLE_COUNT do
        local target = length * (index - 1) / (self.SAMPLE_COUNT - 1)
        while segment < #signature and passed + segment_length < target do
            passed = passed + segment_length
            segment = segment + 1
            a, b = b, key_centers[signature:byte(segment)]
            segment_length = distance(a, b)
        end
        local ratio = segment_length > 0 and (target - passed) / segment_length or 0
        samples[index * 2 - 1] = a.x + (b.x - a.x) * ratio
        samples[index * 2] = a.y + (b.y - a.y) * ratio
    end
end

-- Generate each ideal sample only when it will be compared. The partial
-- distance sum is a lower bound on the final score: stop at the same
-- bound as shape search, before producing the unused remaining samples.
function GeometryReranker:scorePathUntil(signature, key_centers, length, scale,
        swipe, worst, frequency, rank_weight, max_shape)
    local segment, passed, total = 2, 0, 0
    local a, b = key_centers[signature:byte(1)], key_centers[signature:byte(2)]
    local segment_length = distance(a, b)
    local count = self.SAMPLE_COUNT
    local length_term = math.min(self.MAX_SCORE,
        math.abs(swipe.length - length) / math.max(scale, length)) * 0.15
    for index = 1, count do
        local target = length * (index - 1) / (count - 1)
        while segment < #signature and passed + segment_length < target do
            passed = passed + segment_length
            segment = segment + 1
            a, b = b, key_centers[signature:byte(segment)]
            segment_length = distance(a, b)
        end
        local ratio = segment_length > 0 and (target - passed) / segment_length or 0
        local point = swipe.samples[index]
        local dx = point.x - (a.x + (b.x - a.x) * ratio)
        local dy = point.y - (a.y + (b.y - a.y) * ratio)
        total = total + math.sqrt(dx * dx + dy * dy)
        local bound = math.min(self.MAX_SCORE, total / count / scale * 0.85 + length_term)
        if (max_shape and bound > max_shape)
                or (worst and rank_weight * bound - frequency >= worst) then
            return nil, bound
        end
    end
    return math.min(self.MAX_SCORE, total / count / scale * 0.85 + length_term)
end

function GeometryReranker:rerank(candidates, trace_info, key_centers, limit,
        rank_weight, prepared)
    limit = limit or #candidates
    if #candidates == 0 then
        return candidates
    end

    local scores = {}
    local score_total = 0
    local score_count = 0
    local points = trace_info and trace_info.points
    if points and #points >= 2 then
        key_centers = key_centers or EMPTY_CENTERS
        self:_ensureGeometry(key_centers)
        -- Actual samples belong to this call only: the caller may edit or
        -- reuse a trace before the next recognition.
        prepared = prepared or self:prepareTrace(points)
        local actual_samples = prepared and prepared.samples
        local actual_length = prepared and prepared.length
        for index, candidate in ipairs(candidates) do
            local signature = candidate.gesture_signature or candidate.signature
            local score = self:_scoreSamples(
                actual_samples, actual_length, signature, key_centers)
            scores[index] = score
            if score then
                score_total = score_total + score
                score_count = score_count + 1
            end
        end
    end

    if score_count >= 2 then
        local neutral_score = score_total / score_count
        for index, candidate in ipairs(candidates) do
            local score = scores[index] or neutral_score
            candidate.geometry_score = score
            candidate.ranked_score = candidate.ranked_score
                + math.floor(score * (rank_weight or self.RANK_WEIGHT) + 0.5)
            candidate.geometry_order = index
        end
        table.sort(candidates, function(left, right)
            if left.ranked_score == right.ranked_score then
                return left.geometry_order < right.geometry_order
            end
            return left.ranked_score < right.ranked_score
        end)
    end

    while #candidates > limit do
        table.remove(candidates)
    end
    for _, candidate in ipairs(candidates) do
        candidate.geometry_order = nil
    end
    return candidates
end

return GeometryReranker
