-- Experimental gate; these fixed thresholds are hypotheses, not calibrated
-- probabilities. Never use a score margin on its own to accept a word.
local Gate = {}
Gate.__index = Gate
Gate.PROFILES = {
    clean = { boundary = 0.20, shape = 0.10, spatial = 0.50, margin = 1500, min_length = 4 },
    strict = { boundary = 0.22, shape = 0.12, spatial = 0.22, margin = 3000, min_length = 5 },
    balanced = { boundary = 0.30, shape = 0.22, spatial = 0.35, margin = 1500, min_length = 4 },
}
function Gate:new(profile)
    return setmetatable({ policy = assert(self.PROFILES[profile]), profile = profile }, self)
end
local function normalizedDistance(point, center)
    if not point or not center then return math.huge end
    local dx,dy = point.x-center.x, point.y-center.y
    return math.sqrt(dx*dx+dy*dy)/math.max(1,center.size or 1)
end
function Gate:eligible(options, stats)
    local trace = options.trace_info
    local points = trace and trace.points
    local signature = options.signature
    if not points or #points < 2 or #signature < self.policy.min_length then
        stats.reason = 'trace'; return false
    end
    local centers = options.key_centers or {}
    stats.start = normalizedDistance(points[1], centers[signature:byte(1)])
    stats.endpoint = normalizedDistance(trace.endpoint_pos, centers[signature:byte(-1)])
    if stats.start > self.policy.boundary or stats.endpoint > self.policy.boundary then
        stats.reason = 'boundary'; return false
    end
    return true
end
function Gate:choose(candidates, signature, scoring, geometry, channel, stats)
    local best,second = candidates[1],candidates[2]
    if not best or not second or not best.geometry_score or not second.geometry_score then
        stats.reason = 'competition'; return false
    end
    stats.word = best.word
    stats.length = #(best.gesture_signature or best.signature)
    stats.shape = best.geometry_score
    stats.spatial = best.spatial_score / math.max(1,#signature)
    stats.margin = second.ranked_score-best.ranked_score
    -- Full recognition changes alignment/geometry weights when shape search
    -- finds words. Require the same winner and a margin under both scales.
    local shape_active = channel and channel:triggered(signature)
    local alt = {}
    for i,c in ipairs(candidates) do
        if not c.geometry_score then stats.reason='geometry'; return false end
        local score = c.ranked_score
        if shape_active then
            score = score + c.spatial_score*(channel.ALIGNMENT_WEIGHT-scoring.SCORE_UNIT)
                - math.floor(c.geometry_score*geometry.RANK_WEIGHT+0.5)
                + math.floor(c.geometry_score*channel.SHAPE_WEIGHT+0.5)
        end
        alt[#alt+1] = {candidate=c,score=score,order=i}
    end
    table.sort(alt,function(a,b)
        if a.score==b.score then return a.order<b.order end
        return a.score<b.score
    end)
    stats.stable = alt[1].candidate.word == best.word
    stats.alt_margin = alt[2].score-alt[1].score
    if not stats.stable then stats.reason='scale'; return false end
    if stats.length < self.policy.min_length then stats.reason='length'; return false end
    if stats.shape > self.policy.shape then stats.reason='shape'; return false end
    if stats.spatial > self.policy.spatial then stats.reason='spatial'; return false end
    if math.min(stats.margin,stats.alt_margin) < self.policy.margin then
        stats.reason='margin'; return false
    end
    -- Return the scale used by the full shape path, with the same accepted
    -- top word on the ordinary scale. No provisional insertion or replacement.
    for i,item in ipairs(alt) do
        candidates[i] = item.candidate
        candidates[i].ranked_score = item.score
    end
    stats.reason='accepted'; stats.accepted=true
    return true
end
return Gate
