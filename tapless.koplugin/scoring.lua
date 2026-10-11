-- Tapless scoring facade with a replacement position-indexed matcher.
-- Historical Ligature adaptation and unresolved license scope are documented
-- in docs/THIRD_PARTY_CODE.md and docs/MATCHER_REWRITE.md; notices are retained.
local source_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local Matcher = dofile(source_dir .. "/gesture_matcher.lua")
local Scoring = {
    EDIT_DISTANCE_MAX = 2,
    SCORE_UNIT = 3000,
    REPEAT_BONUS = 4500,
    FIRST_LETTER_COST = 6,
    START_MISMATCH_COST = 1,
    ENDPOINT_MISMATCH_COST = 2,
    NEAR_KEY_COST = 0.5,
    NEAR_KEY_LIMIT = 2,
    NEAR_KEY_REACH = 1.2,
    NEAR_KEY_MIN_TURN = 0.3,
    MISSING_LETTER_COST = 2,
}
Scoring.__index = Scoring

local ASCII_A = string.byte("a")

function Scoring:new(normalization)
    local scoring = setmetatable({ normalization = assert(normalization), warmed = false }, self)
    scoring.matcher = Matcher:new(scoring)
    return scoring
end

function Scoring:prepareGesture(trace_chars, observations)
    local work = { trace_chars = trace_chars, codes = {}, weights = {},
        prefix = { [0] = 0 }, distances = {}, greedy = {}, dynamic = {},
        short_scores = {}, edits = {}, positions = {}, near_positions = {} }
    local data = self.matcher:prepare(trace_chars, observations, work)
    work.weights, work.prefix = data.weights, data.prefix
    for index, byte in ipairs(data.letters) do work.codes[index] = byte - 96 end
    return work
end

function Scoring:_adjacency(key_centers)
    return self.matcher:adjacency(key_centers)
end

function Scoring:buildNextPositions(trace)
    local trace_chars = self.normalization:splitChars(trace)
    local trace_end = #trace_chars + 1
    local next_positions = { [trace_end] = {} }
    local next_for_char = {}
    for code = 1, 26 do
        next_for_char[code] = trace_end
        next_positions[trace_end][code] = trace_end
    end
    for position = #trace_chars, 1, -1 do
        local row = {}
        for code = 1, 26 do
            row[code] = next_for_char[code]
        end
        local code = string.byte(trace_chars[position]) - ASCII_A + 1
        if code >= 1 and code <= 26 then
            next_for_char[code] = position
            row[code] = position
        end
        next_positions[position] = row
    end
    return trace_chars, next_positions
end

local edit_rows, edit_spare = {}, {}
function Scoring:editDistance(left, right, max_distance)
    max_distance = max_distance or self.EDIT_DISTANCE_MAX
    local left_len = #left
    local right_len = #right
    if math.abs(left_len - right_len) > max_distance then
        return max_distance + 1
    end

    local infinity = max_distance + 1
    local previous, current = edit_rows, edit_spare
    for j = 0, math.min(right_len, max_distance) do
        previous[j] = j
    end
    previous[math.min(right_len, max_distance) + 1] = infinity
    for i = 1, left_len do
        local from = math.max(1, i - max_distance)
        local to = math.min(right_len, i + max_distance)
        current[0] = i <= max_distance and i or infinity
        -- Cells just outside the moving band must not retain older calls.
        if from > 1 then current[from - 1] = infinity end
        current[to + 1] = infinity
        local row_min = current[0]
        for j = from, to do
            local cost = string.byte(left, i) == string.byte(right, j) and 0 or 1
            local deletion = (previous[j] or infinity) + 1
            local insertion = (current[j - 1] or infinity) + 1
            local substitution = (previous[j - 1] or infinity) + cost
            local value = math.min(deletion, insertion, substitution)
            if value > infinity then
                value = infinity
            end
            current[j] = value
            row_min = math.min(row_min, value)
        end
        if row_min > max_distance then
            return infinity
        end
        previous, current = current, previous
    end
    return previous[right_len] or infinity
end

function Scoring:buildNearPositions(chars, centers, observations)
    return self.matcher:neighbours(chars, centers, observations)
end

function Scoring:matchScore(word, chars, nexts, allow_end, points, endpoint,
        centers, observations, allow_start, near, budget, work, positions)
    local data = self.matcher:prepare(chars, observations, work)
    return self.matcher:greedy(word, data, nexts, allow_start, allow_end,
        near, budget or 0, points, endpoint, centers, positions)
end

function Scoring:dynamicMatchScore(word, chars, allow_end, points, endpoint,
        centers, observations, allow_start, near, missing_cost, work)
    local data = self.matcher:prepare(chars, observations, work)
    return self.matcher:align(word, data, allow_start, allow_end, near,
        missing_cost, points, endpoint, centers)
end

function Scoring:shortWordEndpointScore(trace, candidate, trace_chars)
    if #candidate > 4 or #trace < #candidate or #trace > 10 then
        return
    end
    trace_chars = trace_chars or self.normalization:splitChars(trace)
    local candidate_chars = self.normalization:splitChars(candidate)
    if trace_chars[1] ~= candidate_chars[1] then
        return
    end
    local pos = 1
    local matched = 0
    local last_match
    for i = 1, #candidate_chars do
        for j = pos, #trace_chars do
            if trace_chars[j] == candidate_chars[i] then
                matched = matched + 1
                last_match = j
                pos = j + 1
                break
            end
        end
    end
    local missing = #candidate_chars - matched
    if missing > 1 then
        return
    end
    local trailing = #trace_chars - (last_match or #trace_chars)
    if trailing > 1 then
        return
    end
    return math.max(0,
        math.floor(#trace / 2) + missing * 3 + trailing * 2 - 2)
end

function Scoring:finishEntryScore(signature, entry, score, matched_positions,
        trace_info, context_bonus, work)
    local candidate = entry.gesture_signature or entry.signature
    if #candidate <= 3 or (#candidate == 4 and (entry.freq or 0) >= 6500) then
        local endpoint_score = work and work.short_scores[candidate]
        if endpoint_score == nil then
            endpoint_score = self:shortWordEndpointScore(signature, candidate,
                work and work.trace_chars)
            if work then work.short_scores[candidate] = endpoint_score or false end
        end
        if endpoint_score then
            score = math.min(score, math.max(endpoint_score, score - 1))
        end
    end
    local length_gap = math.abs(#signature - #candidate)
    if length_gap <= self.EDIT_DISTANCE_MAX
            and score > math.floor(#signature / 2) + length_gap then
        local edit_score = work and work.edits[candidate]
        if edit_score == nil then
            edit_score = self:editDistance(signature, candidate, self.EDIT_DISTANCE_MAX)
            if work then work.edits[candidate] = edit_score end
        end
        if edit_score <= self.EDIT_DISTANCE_MAX then
            score = math.min(score, edit_score + math.floor(#signature / 2))
        end
    end
    local repeat_bonus = 0
    if entry.repeat_positions and trace_info and trace_info.observations then
        for candidate_position, repeat_count in pairs(entry.repeat_positions) do
            local trace_position = matched_positions[candidate_position]
            local observation = trace_position
                and trace_info.observations[trace_position]
            if observation then
                repeat_bonus = repeat_bonus
                    + (observation.repeat_confidence or 0)
                        * math.min(2, repeat_count)
            end
        end
    end
    return score,
        score * self.SCORE_UNIT - (entry.freq or 0) - (context_bonus or 0)
            - math.floor(repeat_bonus * self.REPEAT_BONUS)
end

function Scoring:scoreEntry(signature, entry, trace_chars, next_positions,
        trace_info, key_centers, allow_endpoint_mismatch, context_bonus,
        allow_start_mismatch, near, work)
    local candidate = entry.gesture_signature or entry.signature
    local flags = (allow_endpoint_mismatch and 1 or 0) + (allow_start_mismatch and 2 or 0)
    local cache = work and work.greedy[flags]
    if work and not cache then cache = {}; work.greedy[flags] = cache end
    local cached = cache and cache[candidate]
    if cached then
        local spatial, ranked = self:finishEntryScore(signature, entry,
            cached.score, cached.positions, trace_info, context_bonus, work)
        return spatial, ranked, cached.near
    end
    local letter_points = trace_info and trace_info.letter_points
    local endpoint_pos = trace_info and trace_info.endpoint_pos
    local observations = trace_info and trace_info.observations
    -- Keep the per-entry hot path free of newly created closures.
    local score, _, matched_positions = self:matchScore(candidate, trace_chars,
        next_positions, allow_endpoint_mismatch, letter_points, endpoint_pos,
        key_centers, observations, allow_start_mismatch, near, 0, work,
        work and work.positions)
    local used_near = false
    if score >= 1000 and near and self.matcher:canFinish(candidate,
            self.matcher:prepare(trace_chars, observations, work),
            allow_start_mismatch, allow_endpoint_mismatch, near, true) then
        local near_score, _, near_positions = self:matchScore(candidate,
            trace_chars, next_positions, allow_endpoint_mismatch, letter_points,
            endpoint_pos, key_centers, observations, allow_start_mismatch,
            near, self.NEAR_KEY_LIMIT, work, work and work.near_positions)
        if near_score < score then
            score, matched_positions = near_score, near_positions
            used_near = true
        end
    end
    -- Failed prefix matches are cheap and numerous; retain useful alignments
    -- only, rather than keeping every rejected word's temporary position table.
    if cache and score < 1000 then
        local saved = {}
        for i, position in ipairs(matched_positions) do saved[i] = position end
        cache[candidate] = { score = score, positions = saved, near = used_near }
    end
    local spatial_score, ranked_score = self:finishEntryScore(signature,
        entry, score, matched_positions, trace_info, context_bonus, work)
    return spatial_score, ranked_score, used_near
end

-- Compatibility entry point used by recognition invariant tests.
function Scoring:_mayAlign(word, chars, allow_end, allow_start, near, work)
    return self.matcher:canFinish(word, self.matcher:prepare(chars, nil, work),
        allow_start, allow_end, near)
end

function Scoring:scoreEntryDynamic(signature, entry, trace_chars, trace_info,
        key_centers, allow_endpoint_mismatch, context_bonus,
        allow_start_mismatch, near, missing_cost, work)
    local candidate = entry.gesture_signature or entry.signature
    local flags = (allow_endpoint_mismatch and 1 or 0)
        + (allow_start_mismatch and 2 or 0) + (near and 4 or 0)
    local key = flags .. ":" .. tostring(missing_cost)
    local cache = work and work.dynamic[key]
    if work and not cache then cache = {}; work.dynamic[key] = cache end
    local cached = cache and cache[candidate]
    if cached then
        return self:finishEntryScore(signature, entry, cached.score,
            cached.positions, trace_info, context_bonus, work)
    end
    local letter_points = trace_info and trace_info.letter_points
    local endpoint_pos = trace_info and trace_info.endpoint_pos
    local observations = trace_info and trace_info.observations
    -- The plain alignment is left out only where it could not match every
    -- letter: most words a long swipe's shape finds are missing some.
    local score, _, matched_positions
    if not missing_cost or self:_mayAlign(candidate, trace_chars,
            allow_endpoint_mismatch, allow_start_mismatch, near, work) then
        score, _, matched_positions = self:dynamicMatchScore(
            candidate, trace_chars, allow_endpoint_mismatch, letter_points,
            endpoint_pos, key_centers, observations, allow_start_mismatch,
            near, nil, work)
    end
    if missing_cost and (not score or score >= 1000) then
        score, _, matched_positions = self:dynamicMatchScore(
            candidate, trace_chars, allow_endpoint_mismatch, letter_points,
            endpoint_pos, key_centers, observations, allow_start_mismatch,
            near, missing_cost, work)
    end
    if cache then cache[candidate] = { score = score, positions = matched_positions } end
    return self:finishEntryScore(signature, entry, score, matched_positions,
        trace_info, context_bonus, work)
end

function Scoring:addCandidate(results, seen, entry, spatial_score,
        ranked_score, limit, metadata)
    if seen[entry.word] then
        return
    end
    seen[entry.word] = true
    local candidate = {
        word = entry.word,
        signature = entry.signature,
        gesture_signature = entry.gesture_signature or entry.signature,
        spatial_score = spatial_score,
        ranked_score = ranked_score,
        metadata = metadata,
        personal = entry.personal == true,
    }
    local inserted = false
    for i = 1, #results do
        if ranked_score < results[i].ranked_score then
            table.insert(results, i, candidate)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(results, candidate)
    end
    while #results > limit do
        local removed = table.remove(results)
        if removed then
            seen[removed.word] = nil
        end
    end
end

function Scoring:warm()
    if self.warmed then
        return
    end
    local traces = {
        { trace = "nkiuytre", candidates = { "nie", "numer", "nurt" } },
        { trace = "treredsaz", candidates = { "teraz", "tez", "trasa" } },
        { trace = "produktywny", candidates = { "produktywny", "probny", "prosty" } },
    }
    for iteration = 1, 80 do
        local sample = traces[(iteration - 1) % #traces + 1]
        local trace_chars, next_positions = self:buildNextPositions(sample.trace)
        for _, candidate in ipairs(sample.candidates) do
            self:matchScore(candidate, trace_chars, next_positions, false)
            self:dynamicMatchScore(candidate, trace_chars, false)
            self:shortWordEndpointScore(sample.trace, candidate)
            self:editDistance(sample.trace, candidate, self.EDIT_DISTANCE_MAX)
        end
    end
    self.warmed = true
end

return Scoring
