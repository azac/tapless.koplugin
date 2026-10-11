local RecognitionEngine = {}
RecognitionEngine.__index = RecognitionEngine

local DYNAMIC_CANDIDATE_LIMIT = 40
local GEOMETRY_CANDIDATE_LIMIT = 12

function RecognitionEngine:new(dictionary_store, scoring, geometry_reranker,
        personal_dictionary, shape_channel)
    return setmetatable({
        dictionary_store = assert(dictionary_store),
        scoring = assert(scoring),
        geometry_reranker = geometry_reranker,
        personal_dictionary = personal_dictionary,
        shape_channel = shape_channel,
    }, self)
end

function RecognitionEngine:pickCandidates(options)
    local profiler = self.profiler
    if profiler then profiler:phase("scan") end
    local signature = options.signature
    local limit = options.limit or 3
    local dictionary = options.dictionary or "en"
    local trace_info = options.trace_info
    local key_centers = options.key_centers or {}
    local package = self.dictionary_store:open(dictionary)
    if not package then
        return {}
    end
    local data_lang = package.descriptor.data_language or dictionary
    local trace_chars, next_positions = self.scoring:buildNextPositions(signature)
    local work = self.scoring:prepareGesture(trace_chars,
        trace_info and trace_info.observations)
    local near = self.scoring:buildNearPositions(trace_chars, key_centers,
        trace_info and trace_info.observations)
    local first = string.sub(signature, 1, 1)
    local last = string.sub(signature, -1)
    local max_spatial = math.max(6, #signature)
    local shortlist, seen = {}, {}

    local function scan(entries, allow_endpoint_mismatch, allow_start_mismatch)
        for _, entry in ipairs(entries or {}) do
            if not entry.lang or entry.lang == dictionary or entry.lang == data_lang then
                local context_bonus = options.context_bonus
                    and options.context_bonus(
                        trace_info and trace_info.previous_word, entry.word) or 0
                local spatial_score, ranked_score, used_near = self.scoring:scoreEntry(
                    signature,
                    entry,
                    trace_chars,
                    next_positions,
                    trace_info,
                    key_centers,
                    allow_endpoint_mismatch,
                    context_bonus,
                    allow_start_mismatch, near, work)
                if spatial_score <= max_spatial then
                    self.scoring:addCandidate(shortlist, seen, entry,
                        spatial_score, ranked_score,
                        math.max(limit, DYNAMIC_CANDIDATE_LIMIT), {
                            allow_endpoint_mismatch = allow_endpoint_mismatch,
                            allow_start_mismatch = allow_start_mismatch,
                            allow_near = used_near,
                            context_bonus = context_bonus,
                            entry = entry,
                        })
                end
            end
        end
    end

    local function scanBuckets(a, b, end_mismatch, start_mismatch)
        local personal_bucket = self.personal_dictionary
            and self.personal_dictionary:getBucket(a, b, dictionary,
                options.normalization_profile)
        scan(personal_bucket and personal_bucket.entries, end_mismatch, start_mismatch)
        local bucket = self.dictionary_store:loadBucket(a, b, dictionary)
        for length = 2, math.min(14, #signature) do
            scan(bucket and bucket.by_gesture_length[length], end_mismatch, start_mismatch)
        end
    end
    local starts, ends = { first }, { last }
    if #signature >= 3 and trace_info then
        if options.start_letters then starts = options.start_letters(first) end
        if trace_info.endpoint_pos and options.endpoint_letters then
            ends = options.endpoint_letters(last)
        end
    end
    -- Exact endpoints first; then single-end and combined boundary slips.
    scanBuckets(first, last)
    for index = 2, #ends do scanBuckets(first, ends[index], true) end
    for index = 2, #starts do scanBuckets(starts[index], last, false, true) end
    for a = 2, #starts do
        for b = 2, #ends do scanBuckets(starts[a], ends[b], true, true) end
    end

    if #shortlist == 0 then
        local popular_entries = self.dictionary_store:loadPopularWords(
            first, dictionary)
        if popular_entries then
            scan(popular_entries)
        else
            scan(self.dictionary_store:loadFirstBuckets(first, dictionary))
        end
    end
    local results, final_seen = {}, {}
    if profiler then profiler:phase("dynamic") end
    for _, candidate in ipairs(shortlist) do
        local metadata = candidate.metadata
        local entry = metadata and metadata.entry
        if entry then
            local spatial_score, ranked_score = self.scoring:scoreEntryDynamic(
                signature,
                entry,
                trace_chars,
                trace_info,
                key_centers,
                metadata.allow_endpoint_mismatch,
                metadata.context_bonus,
                metadata.allow_start_mismatch,
                metadata.allow_near and near or nil, nil, work)
            if spatial_score <= max_spatial then
                self.scoring:addCandidate(results, final_seen, entry,
                    spatial_score, ranked_score,
                    math.max(limit, GEOMETRY_CANDIDATE_LIMIT))
            end
        end
    end
    local channel = self.shape_channel
    local prepared, shape_active
    if channel and self.geometry_reranker and channel:triggered(signature) then
        if profiler then profiler:phase("shape") end
        prepared = self.geometry_reranker:prepareTrace(trace_info and trace_info.points)
        local found = channel:candidates{
            signature = signature, swipe = prepared,
            points = trace_info and trace_info.points, key_centers = key_centers,
            dictionary = dictionary, data_language = data_lang,
            normalization_profile = options.normalization_profile,
        }
        shape_active = #found > 0
        if profiler then profiler:phase("shape_align") end
        for _, item in ipairs(found) do
            local entry = item.entry
            if not final_seen[entry.word] then
                local bonus = options.context_bonus
                    and options.context_bonus(trace_info and trace_info.previous_word,
                        entry.word) or 0
                local spatial, ranked = self.scoring:scoreEntryDynamic(
                    signature, entry, trace_chars, trace_info, key_centers,
                    true, bonus, true, near, self.scoring.MISSING_LETTER_COST, work)
                if spatial < 1000 then
                    self.scoring:addCandidate(results, final_seen, entry, spatial, ranked,
                        math.max(limit, GEOMETRY_CANDIDATE_LIMIT) + channel.KEEP)
                end
            end
        end
        if shape_active then
            -- Whole-path candidates need a common scale when merged with
            -- letter matches; retain frequency, context and repeat bonuses.
            for _, candidate in ipairs(results) do
                candidate.ranked_score = candidate.ranked_score
                    + candidate.spatial_score * (channel.ALIGNMENT_WEIGHT
                        - self.scoring.SCORE_UNIT)
            end
        end
    end
    if #results > 0 then
        if profiler then profiler:phase("rerank") end
        if self.geometry_reranker then
            return self.geometry_reranker:rerank(
                results, trace_info, key_centers, limit,
                shape_active and channel.SHAPE_WEIGHT or nil, prepared)
        end
        while #results > limit do
            table.remove(results)
        end
        return results
    end

    local fallback = {}
    for index = 1, math.min(limit, #shortlist) do
        local candidate = shortlist[index]
        fallback[index] = {
            word = candidate.word,
            signature = candidate.signature,
            spatial_score = candidate.spatial_score,
            ranked_score = candidate.ranked_score,
        }
    end
    return fallback
end

return RecognitionEngine
