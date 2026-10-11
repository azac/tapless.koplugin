local TraceRenderer = {
    MAX_CURVE_OFFSET = 2,
}
TraceRenderer.__index = TraceRenderer

function TraceRenderer:new(screen, ui_manager, geometry)
    return setmetatable({
        screen = assert(screen),
        ui_manager = assert(ui_manager),
        geometry = assert(geometry),
        new_pixels = {},
        row_pool = {},
        sorted_xs = {},
    }, self)
end

local function invertRow(renderer, y, xs)
    table.sort(xs)
    local run_start, previous_x = xs[1], xs[1]
    if not run_start then
        return
    end
    for index = 2, #xs do
        local x = xs[index]
        if x ~= previous_x + 1 then
            renderer.screen.bb:invertRect(
                run_start, y, previous_x - run_start + 1, 1)
            run_start = x
        end
        previous_x = x
    end
    renderer.screen.bb:invertRect(
        run_start, y, previous_x - run_start + 1, 1)
    return xs[1], previous_x
end

function TraceRenderer:invertPixelSet(pixel_set, dense_rows)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    if not pixel_set then
        return
    end
    for y, row in pairs(pixel_set) do
        local xs = row
        if not dense_rows then
            xs = self.sorted_xs
            for x in pairs(row) do
                xs[#xs + 1] = x
            end
        end
        local first_x, last_x = invertRow(self, y, xs)
        if first_x then
            min_x = math.min(min_x, first_x)
            min_y = math.min(min_y, y)
            max_x = math.max(max_x, last_x)
            max_y = math.max(max_y, y)
        end
        -- Keep scratch tables and their capacity, without retaining pixels.
        for index = #xs, 1, -1 do
            xs[index] = nil
        end
        if dense_rows then
            pixel_set[y] = nil
            self.row_pool[#self.row_pool + 1] = xs
        end
    end
    if min_x == math.huge then
        return
    end
    return self.geometry:new{
        x = min_x,
        y = min_y,
        w = max_x - min_x + 1,
        h = max_y - min_y + 1,
    }
end

function TraceRenderer:drawSegment(trace, previous, current)
    if not trace or not current then
        return
    end
    trace.drawn_pixels = trace.drawn_pixels or {}
    local before = trace.render_before
    trace.render_before = previous
    local new_pixels = self.new_pixels
    local radius = 1
    local start_x = previous and previous.x or current.x
    local start_y = previous and previous.y or current.y
    local dx = current.x - start_x
    local dy = current.y - start_y
    local tangent_x, tangent_y = dx, dy
    if before and previous and (dx ~= 0 or dy ~= 0) then
        local incoming_x = previous.x - before.x
        local incoming_y = previous.y - before.y
        -- A sharp reversal stays straight, without a loop at the turn.
        if incoming_x * dx + incoming_y * dy > 0 then
            local length = math.sqrt(dx * dx + dy * dy)
            local proposed_x = (current.x - before.x) / 2
            local proposed_y = (current.y - before.y) / 2
            local along = math.max(0, math.min(length,
                (proposed_x * dx + proposed_y * dy) / length))
            -- t * (1 - t)^2 peaks at 4/27. Limit the perpendicular
            -- tangent so the curve stays within MAX_CURVE_OFFSET pixels
            -- of the straight segment, even after a long previous step.
            local limit = math.min(length / 2,
                self.MAX_CURVE_OFFSET * 27 / 4)
            local across = math.max(-limit, math.min(limit,
                (proposed_y * dx - proposed_x * dy) / length))
            tangent_x = (along * dx - across * dy) / length
            tangent_y = (along * dy + across * dx) / length
        end
    end
    local bend_x, bend_y = tangent_x - dx, tangent_y - dy
    -- A conservative derivative bound keeps adjacent samples within
    -- one pixel per axis, including curved parts of the segment.
    local steps = math.max(1, math.ceil(
        math.max(math.abs(dx), math.abs(dy))
            + math.max(math.abs(bend_x), math.abs(bend_y))))
    for step = 0, steps do
        local t = step / steps
        -- Cubic Hermite interpolation: follow the incoming direction,
        -- then arrive at the current touch point with the segment's
        -- tangent. No future touch sample is needed to draw the tip.
        local curve = t * (1 - t) * (1 - t)
        local center_x = math.floor(start_x + dx * t + bend_x * curve + 0.5)
        local center_y = math.floor(start_y + dy * t + bend_y * curve + 0.5)
        for offset_y = -radius, radius do
            local y = center_y + offset_y
            local row = trace.drawn_pixels[y]
            if not row then
                row = {}
                trace.drawn_pixels[y] = row
            end
            for offset_x = -radius, radius do
                local x = center_x + offset_x
                if not row[x] then
                    row[x] = true
                    local new_row = new_pixels[y]
                    if not new_row then
                        local pool = self.row_pool
                        new_row = pool[#pool] or {}
                        pool[#pool] = nil
                        new_pixels[y] = new_row
                    end
                    new_row[#new_row + 1] = x
                end
            end
        end
    end
    local region = self:invertPixelSet(new_pixels, true)
    if region then
        self.ui_manager:setDirty(nil, "a2", region)
    end
end

function TraceRenderer:clear(trace, refresh_type)
    if not trace then
        return
    end
    trace.render_before = nil
    if not trace.drawn_pixels then
        return
    end
    local region = self:invertPixelSet(trace.drawn_pixels)
    trace.drawn_pixels = nil
    if region then
        self.ui_manager:setDirty(nil, refresh_type or "ui", region)
    end
end

return TraceRenderer
