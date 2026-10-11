-- Position-indexed gesture matching for Tapless.
-- This replacement was developed after reviewing the previous implementation.
-- It is NOT a clean-room implementation or a declaration of relicensing.
-- See docs/MATCHER_REWRITE.md and docs/THIRD_PARTY_CODE.md.
local Matcher = {}
Matcher.__index = Matcher

local function seek(list, minimum)
    if not list then return nil end
    local left, right = 1, #list
    while left <= right do
        local middle = math.floor((left + right) / 2)
        if list[middle] < minimum then left = middle + 1
        else right = middle - 1 end
    end
    return list[left]
end

function Matcher:new(policy)
    return setmetatable({ policy = policy, reachable = {}, reachable_spare = {},
        frontier_a = {}, frontier_b = {}, events = {}, marks = {}, generation = 0,
        nodes = { positions = {}, costs = {}, parents = {}, taken = {} } }, self)
end

function Matcher:prepare(chars, observations, work)
    if work and work.matcher then return work.matcher end
    local data = { size = #chars, letters = {}, weights = {}, prefix = { [0] = 0 },
        occurrences = {}, distances = work and work.distances or {} }
    for position, char in ipairs(chars) do
        local byte = char:byte()
        local weight = observations and observations[position]
            and observations[position].intent or 1
        data.letters[position], data.weights[position] = byte, weight
        data.prefix[position] = data.prefix[position - 1] + weight
        local list = data.occurrences[byte]
        if not list then list = {}; data.occurrences[byte] = list end
        list[#list + 1] = position
    end
    if work then work.matcher = data end
    return data
end

function Matcher:adjacency(centers)
    local cache = self.layout
    local count, equal = 0, cache and cache.reach == self.policy.NEAR_KEY_REACH
    for byte, key in pairs(centers) do
        count = count + 1
        local old = cache and cache.keys[byte]
        if not old or old.x ~= key.x or old.y ~= key.y or old.size ~= key.size then
            equal = false
        end
    end
    if equal and count == cache.count then return cache.adjacent end
    cache = { keys = {}, adjacent = {}, count = count, reach = self.policy.NEAR_KEY_REACH }
    for byte, key in pairs(centers) do
        cache.keys[byte] = { x = key.x, y = key.y, size = key.size }
    end
    for byte = 97, 122 do
        local row, key = {}, centers[byte]
        cache.adjacent[byte - 96] = row
        if key then
            local radius = cache.reach * math.max(1, key.size or 1)
            for other = 97, 122 do
                local target = centers[other]
                if other ~= byte and target then
                    local x, y = target.x - key.x, target.y - key.y
                    if math.sqrt(x * x + y * y) <= radius then row[other - 96] = true end
                end
            end
        end
    end
    self.layout = cache
    return cache.adjacent
end

function Matcher:neighbours(chars, centers, observations)
    if not observations or not centers or not next(centers) then return nil end
    local result = { events = {}, lending = {}, present = {}, lendable = {} }
    local active = false
    for position, char in ipairs(chars) do
        local observation = observations[position]
        local turn = observation and math.abs(observation.signed_turn or 0) or 0
        result.lending[position] = observation ~= nil and turn >= self.policy.NEAR_KEY_MIN_TURN
        active = active or result.lending[position]
        result.present[char:byte() - 96] = true
    end
    if not active then return nil end
    result.adjacent = self:adjacency(centers)
    for position, char in ipairs(chars) do
        if result.lending[position] then
            for code in pairs(result.adjacent[char:byte() - 96] or {}) do
                local list = result.events[code]
                if not list then list = {}; result.events[code] = list end
                list[#list + 1] = position
                result.lendable[code] = true
            end
        end
    end
    return result
end

-- Earliest feasible endpoint for each allowed number of substitutions.
-- Exact and neighbouring positions are queried from sorted event lists.
function Matcher:canFinish(word, data, start_slip, end_slip, near, reuse_release)
    local length, size = #word, data.size
    if length == 0 or size == 0 then return false end
    if reuse_release then
        -- Dictionary scanning only needs a cheap necessary condition. It
        -- must still run partial greedy attempts, whose positions can supply
        -- repeat evidence when edit-distance recovery later accepts the word.
        if not data.occurrences[word:byte(1)] and not start_slip then return false end
        if not data.occurrences[word:byte(length)] and not end_slip then return false end
        local required = 0
        for letter = 2, length - 1 do
            local byte = word:byte(letter)
            if not data.occurrences[byte] then
                if not near or not near.events[byte - 96] then return false end
                required = required + 1
                if required > self.policy.NEAR_KEY_LIMIT then return false end
            end
        end
        return true
    end
    local budget = near and self.policy.NEAR_KEY_LIMIT or 0
    local previous, current = self.reachable, self.reachable_spare
    for allowance = 0, budget do previous[allowance] = 0 end
    for letter = 1, length do
        local byte = word:byte(letter)
        for allowance = 0, budget do
            local minimum = previous[allowance] + 1
            local position = seek(data.occurrences[byte], minimum) or size + 1
            if letter == 1 and start_slip and length > 1 and size > 1 then
                position = 1
            end
            if letter == length and end_slip
                    and minimum <= size + (reuse_release and 1 or 0) then
                position = math.min(position, size)
            end
            if near and letter > 1 and letter < length and allowance > 0 then
                local borrowed = seek(near.events[byte - 96], previous[allowance - 1] + 1)
                if borrowed then position = math.min(position, borrowed) end
            end
            current[allowance] = position
        end
        previous, current = current, previous
        if previous[budget] > size then return false end
    end
    return true
end

local function distance(data, byte, position, point, centers)
    local target = centers and centers[byte]
    if not point or not target then return nil end
    local row = data.distances[position]
    if not row then row = {}; data.distances[position] = row end
    local cached = row[byte]
    if cached == nil then
        local x, y = point.x - target.x, point.y - target.y
        cached = math.min(2, math.sqrt(x * x + y * y) / math.max(1, target.size or 1))
        row[byte] = cached
    end
    return cached
end

-- Cheap ordered match used during dictionary scanning. Boundary substitution
-- at release retains the existing ability to reuse the last observation.
function Matcher:greedy(word, data, nexts, start_slip, end_slip, near, budget,
        points, endpoint, centers, positions)
    positions = positions or {}
    for key in pairs(positions) do positions[key] = nil end
    local size, length = data.size, #word
    if size == 0 or length == 0 then return 1000 + length * 20, false, positions end
    local cursor, accepted, borrowed = 1, 0, 0
    local slipped_start, slipped_end = false, false
    local first, last, geometry, measured = nil, nil, 0, 0
    for letter = 1, length do
        local byte = word:byte(letter)
        local row = nexts and nexts[cursor]
        local position = row and row[byte - 96]
        if position and position > size then position = nil end
        if letter == 1 and start_slip and length > 1 and size > 1
                and data.letters[1] ~= byte then
            position, slipped_start = 1, true
        end
        if not position and near and borrowed < budget and letter > 1 and letter < length then
            position = seek(near.events[byte - 96], cursor)
            if position then borrowed = borrowed + 1 end
        end
        local release = not position and end_slip and letter == length and size > 0
        if release then position, slipped_end = size, true end
        if not position then break end
        accepted = letter
        positions[letter] = position
        if not release then first = first or position end
        last = position
        if points and (not release or endpoint) then
            local value = distance(data, byte, release and 0 or position,
                release and endpoint or points[position], centers)
            if value then geometry, measured = geometry + value, measured + 1 end
        end
        cursor = position + 1
    end
    local score
    if accepted < length then score = 1000 + (length - accepted) * 20
    else
        -- Positions are ordered, including a possibly reused release point.
        -- Three accumulators preserve the previous summation order without
        -- allocating a membership table or a per-candidate function.
        local skipped, leading, trailing, matched = 0, 0, 0, 1
        for position = 1, size do
            while positions[matched] and positions[matched] < position do matched = matched + 1 end
            if positions[matched] ~= position then
                local weight = data.weights[position]
                skipped = skipped + weight
                if position < (first or 1) then leading = leading + weight end
                if position > (last or size) then trailing = trailing + weight end
            end
        end
        score = skipped + leading * 2
        score = score + trailing * 2
        if slipped_start then score = score + self.policy.START_MISMATCH_COST
        elseif data.letters[1] ~= word:byte(1) then score = score + self.policy.FIRST_LETTER_COST end
        if slipped_end then score = score + self.policy.ENDPOINT_MISMATCH_COST
        elseif data.letters[size] ~= word:byte(length) then score = score + 4 end
        score = score + borrowed * self.policy.NEAR_KEY_COST
    end
    if measured > 0 then score = score + math.min(4, math.floor(geometry * 2 / measured + 0.5)) end
    return score, slipped_end, positions
end

local function appendEvents(events, marks, stamp, list)
    for _, position in ipairs(list or {}) do
        if marks[position] ~= stamp then
            marks[position] = stamp
            events[#events + 1] = position
        end
    end
end

-- Sparse minimum-cost paths. Only actual match events and retained omission
-- endpoints create nodes; intermediate observations never create DP cells.
function Matcher:align(word, data, start_slip, end_slip, near, omission,
        points, endpoint, centers)
    local size, length = data.size, #word
    if size == 0 or length == 0 then return 1000 + length * 20, false, {}, 0 end
    local limit = near and self.policy.NEAR_KEY_LIMIT or 0
    local previous, current = self.frontier_a, self.frontier_b
    local nodes, events, marks = self.nodes, self.events, self.marks
    local locations, costs, parents, taken = nodes.positions, nodes.costs, nodes.parents, nodes.taken
    local prefix, letters = data.prefix, data.letters
    local count = 1
    locations[1], costs[1], parents[1], taken[1] = 0, 0, nil, nil
    for allowance = 0, limit do
        previous[allowance] = previous[allowance] or {}
        current[allowance] = current[allowance] or {}
        for i = #previous[allowance], 1, -1 do previous[allowance][i] = nil end
    end
    previous[0][1] = 1
    local minima, origins, cursors = {}, {}, {}
    for letter = 1, length do
        local byte = word:byte(letter)
        local inner = letter > 1 and letter < length
        local allow_omission = inner and omission ~= nil
        local stamp = self.generation + 1
        self.generation = stamp
        for i = #events, 1, -1 do events[i] = nil end
        appendEvents(events, marks, stamp, data.occurrences[byte])
        if inner and near then appendEvents(events, marks, stamp, near.events[byte - 96]) end
        if letter == 1 and start_slip and length > 1 and size > 1 and marks[1] ~= stamp then
            marks[1], events[#events + 1] = stamp, 1
        end
        if letter == length and end_slip and marks[size] ~= stamp then
            marks[size], events[#events + 1] = stamp, size
        end
        for allowance = 0, limit do
            local frontier = current[allowance]
            for i = #frontier, 1, -1 do frontier[i] = nil end
            minima[allowance], origins[allowance], cursors[allowance] = math.huge, nil, 1
            if allow_omission then
                for _, node in ipairs(previous[allowance]) do
                    local position = locations[node]
                    if marks[position] ~= stamp then
                        marks[position], events[#events + 1] = stamp, position
                    end
                end
            end
        end
        table.sort(events)
        for _, position in ipairs(events) do
            for allowance = 0, limit do
                local frontier, cursor = previous[allowance], cursors[allowance]
                while frontier[cursor] and locations[frontier[cursor]] < position do
                    local node = frontier[cursor]
                    local value = costs[node] - prefix[locations[node]]
                    if value < minima[allowance] then
                        minima[allowance], origins[allowance] = value, node
                    end
                    cursor = cursor + 1
                end
                cursors[allowance] = cursor
            end
            local start = letter == 1 and start_slip and position == 1
                and length > 1 and size > 1 and letters[position] ~= byte
            local release = letter == length and end_slip and position == size
                and letters[position] ~= byte
            local exact = letters[position] == byte or start or release
            local borrowed = near and inner and letters[position] ~= byte
                and near.lending[position] and near.adjacent[letters[position] - 96]
                and near.adjacent[letters[position] - 96][byte - 96]
            local geometry
            if (exact or borrowed) and points then
                geometry = distance(data, byte, release and 0 or position,
                    release and endpoint or points[position], centers)
                if geometry then geometry = geometry * 2 / length end
            end
            for allowance = 0, limit do
                local score, parent, consumes = math.huge, nil, false
                local source = exact and allowance or borrowed and allowance > 0 and allowance - 1
                if source ~= nil and source ~= false and origins[source] then
                    parent, consumes = origins[source], true
                    if letter == 1 then
                        score = prefix[position - 1] * 3
                        if letters[1] ~= byte then
                            score = score + (start and self.policy.START_MISMATCH_COST
                                or self.policy.FIRST_LETTER_COST)
                        end
                    else score = minima[source] + prefix[position - 1] end
                    if borrowed then score = score + self.policy.NEAR_KEY_COST end
                    if geometry then score = score + geometry end
                end
                if allow_omission then
                    local node = previous[allowance][cursors[allowance]]
                    if node and locations[node] == position and costs[node] + omission < score then
                        score, parent, consumes = costs[node] + omission, node, false
                    end
                end
                if parent then
                    count = count + 1
                    locations[count], costs[count], parents[count], taken[count] = position, score, parent, consumes
                    local frontier = current[allowance]
                    frontier[#frontier + 1] = count
                end
            end
        end
        previous, current = current, previous
    end
    local best, final_node, final_position, final_allowance = math.huge, nil, nil, nil
    for allowance = 0, limit do
        for _, node in ipairs(previous[allowance]) do
            local position = locations[node]
            local score = costs[node] + (prefix[size] - prefix[position]) * 3
            if score < best or (score == best and (position < final_position
                    or (position == final_position and allowance < final_allowance))) then
                best, final_node, final_position, final_allowance = score, node, position, allowance
            end
        end
    end
    if not final_node then return 1000 + length * 20, false, {}, 0 end
    local positions, omitted = {}, 0
    for letter = length, 1, -1 do
        if taken[final_node] then positions[letter] = locations[final_node]
        else omitted = omitted + 1 end
        final_node = parents[final_node]
    end
    local mismatch = letters[final_position] ~= word:byte(length)
    if mismatch then best = best + self.policy.ENDPOINT_MISMATCH_COST
    elseif letters[size] ~= word:byte(length) then best = best + 4 end
    return best, mismatch, positions, omitted
end

return Matcher
