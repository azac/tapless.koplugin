-- Opt-in diagnostic instrumentation. No typed text or raw coordinates are logged.
local Profiler = {}
Profiler.__index = Profiler
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local fields = { "id", "source", "dictionary", "letters", "clock", "event_delay_ms",
    "handler_wall_ms", "handler_cpu_ms", "to_insert_ms", "to_submit_ms", "paint_status",
    "handler_to_insert_ms", "handler_to_submit_ms",
    "heap_delta_kib", "snapshot_wall_ms", "previous_word_wall_ms", "clear_trace_wall_ms",
    "key_centers_wall_ms", "recognition_wall_ms", "recognition_cpu_ms",
    "scan_wall_ms", "scan_cpu_ms", "dynamic_wall_ms", "dynamic_cpu_ms",
    "fast_dynamic_wall_ms", "fast_dynamic_cpu_ms", "fast_rerank_wall_ms", "fast_rerank_cpu_ms",
    "shape_wall_ms", "shape_cpu_ms", "shape_align_wall_ms", "shape_align_cpu_ms",
    "rerank_wall_ms", "rerank_cpu_ms", "bucket_wall_ms", "bucket_cpu_ms", "bucket_calls",
    "insert_wall_ms", "candidate_row_wall_ms", "paint_wall_ms", "paint_cpu_ms",
    "driver_wall_ms", "driver_cpu_ms", "driver_calls", "wait_complete_wall_ms",
    "wait_submission_wall_ms", "shape_entries", "shape_compared", "shape_exhausted",
    "fast_enabled", "fast_profile", "fast_checked", "fast_attempted", "fast_accepted", "fast_reason",
    "fast_signature_length", "fast_trace_points", "fast_has_endpoint",
    "fast_has_start_center", "fast_has_end_center", "fast_start", "fast_endpoint",
    "fast_length", "fast_shape", "fast_spatial", "fast_margin", "fast_alt_margin", "fast_stable",
    "fast_boundary_limit", "fast_shape_limit", "fast_spatial_limit", "fast_margin_limit", "fast_min_length" }
local gate_reasons = { trace = true, boundary = true, competition = true, geometry = true,
    scale = true, length = true, shape = true, spatial = true, margin = true, accepted = true }
local gate_numbers = { "start", "endpoint", "length", "shape", "spatial", "margin", "alt_margin" }
local gate_limits = { boundary = "fast_boundary_limit", shape = "fast_shape_limit",
    spatial = "fast_spatial_limit", margin = "fast_margin_limit", min_length = "fast_min_length" }

function Profiler:new(options)
    return setmetatable({ time = assert(options.time), cpu = options.cpu or os.clock,
        heap = options.heap or function() return collectgarbage("count") end,
        path = assert(options.path), event_now = options.event_now,
        writer = options.writer, ui = assert(options.ui), limit = options.limit or 30,
        count = 0, enabled = true, hooks = {}, inputs = setmetatable({}, { __mode = "k" }) }, self)
end

function Profiler:_write(record)
    local values = {}
    for i, field in ipairs(fields) do
        local value = record[field]
        if type(value) == "number" then value = string.format("%.3f", value) end
        values[i] = tostring(value or ""):gsub("[\r\n\t]", " ")
    end
    if self.writer then self.writer(record, fields); return end
    local file = io.open(self.path, "a")
    if file then
        if file:seek("end") == 0 then file:write(table.concat(fields, "\t"), "\n") end
        file:write(table.concat(values, "\t"), "\n"); file:close()
    end
end

function Profiler:_duration(record, name, wall, cpu)
    record[name .. "_wall_ms"] = (record[name .. "_wall_ms"] or 0)
        + (self.time.now() - wall) / self.time.ms(1)
    record[name .. "_cpu_ms"] = (record[name .. "_cpu_ms"] or 0)
        + (self.cpu() - cpu) * 1000
end

function Profiler:phase(name)
    local record = self.active
    if not record then return end
    if record.phase then self:_duration(record, record.phase, record.phase_wall, record.phase_cpu) end
    record.phase = name
    record.phase_wall, record.phase_cpu = self.time.now(), self.cpu()
end

function Profiler:_captureFastGate(engine, attempt)
    local record = self.active
    if not record then return end
    local gate = engine.fast_gate
    record.fast_enabled = gate and 1 or 0
    record.fast_checked, record.fast_attempted, record.fast_accepted = 0, 0, 0
    record.fast_reason = gate and "not_checked" or "disabled"
    if not gate then return end
    record.fast_profile = gate.profile
    local signature = attempt.signature or ""
    local trace = attempt.trace_info or {}
    local centers = attempt.key_centers or {}
    record.fast_signature_length = #signature
    record.fast_trace_points = trace.points and #trace.points or 0
    record.fast_has_endpoint = trace.endpoint_pos and 1 or 0
    record.fast_has_start_center = centers[signature:byte(1)] and 1 or 0
    record.fast_has_end_center = centers[signature:byte(-1)] and 1 or 0
    for name, field in pairs(gate_limits) do
        record[field] = gate.policy and gate.policy[name]
    end
    local stats = engine.fast_stats
    if not stats then return end
    record.fast_checked = stats.reason and 1 or 0
    record.fast_attempted = stats.attempted and 1 or 0
    record.fast_accepted = stats.accepted and 1 or 0
    if stats.reason then record.fast_reason = gate_reasons[stats.reason] and stats.reason or "unknown" end
    -- Copy only numeric diagnostics; stats.word and the gesture remain private.
    for _, name in ipairs(gate_numbers) do
        if type(stats[name]) == "number" then record["fast_" .. name] = stats[name] end
    end
    if stats.stable ~= nil then record.fast_stable = stats.stable and 1 or 0 end
end

function Profiler:_flush(record, status)
    if record.flushed then return end
    record.flushed, record.paint_status = true, status
    if self.pending == record then self.pending = nil end
    self:_write(record)
    if self.count >= self.limit then self:stop() end
end

function Profiler:stop()
    self.enabled, self.active, self.pending = false, nil, nil
    for index = #self.hooks, 1, -1 do
        local hook = self.hooks[index]
        if hook.object[hook.name] == hook.wrapper then hook.object[hook.name] = hook.original end
    end
    if self.engine and self.engine.profiler == self then self.engine.profiler = nil end
end

function Profiler:_wrap(object, name, wrapper)
    if not object or type(object[name]) ~= "function" then return end
    local original = object[name]
    local fn = function(...) return wrapper(original, ...) end
    object[name] = fn
    self.hooks[#self.hooks + 1] = { object = object, name = name, original = original, wrapper = fn }
end

function Profiler:span(object, name, label)
    self:_wrap(object, name, function(original, ...)
        local record = self.active or self.painting
        if not record then return original(...) end
        local wall, cpu = self.time.now(), self.cpu()
        local result = pack(original(...))
        self:_duration(record, label, wall, cpu)
        record[label .. "_calls"] = (record[label .. "_calls"] or 0) + 1
        if label == "recognition" then
            self:phase(nil)
        elseif label == "insert" then
            record.inserted = true
            record.handler_to_insert_ms = (self.time.now() - record.started) / self.time.ms(1)
            if record.event_delay_ms then record.to_insert_ms = record.handler_to_insert_ms
                + record.event_delay_ms end
        end
        return unpack(result, 1, result.n)
    end)
end

function Profiler:_release(original, controller, keyboard, gesture, ...)
    if not self.enabled or not keyboard:isSwypeMvpEnabled() or self.active then
        return original(controller, keyboard, gesture, ...)
    end
    if self.pending then self:_flush(self.pending, "superseded") end
    if not self.enabled then return original(controller, keyboard, gesture, ...) end
    self.count = self.count + 1
    local record = { id = self.count, source = gesture and gesture.ges or "timer",
        dictionary = keyboard.swype_mvp_dictionary or "en", started = self.time.now(),
        cpu_started = self.cpu(), heap_started = self.heap(), clock = "unknown" }
    if gesture and gesture.time and self.event_now then
        local event_now, clock = self.event_now()
        if event_now then
            local delay = (event_now - gesture.time) / self.time.ms(1)
            if delay >= 0 and delay < 10000 then record.event_delay_ms = delay; record.clock = clock end
        end
    end
    self.active = record
    -- Wrap only the actual inputbox instance used by this gesture.
    if keyboard.inputbox and not self.inputs[keyboard.inputbox] then
        self.inputs[keyboard.inputbox] = true
        self:span(keyboard.inputbox, "addChars", "insert")
    end
    local result = pack(original(controller, keyboard, gesture, ...))
    self:phase(nil)
    record.handler_wall_ms = (self.time.now() - record.started) / self.time.ms(1)
    record.handler_cpu_ms = (self.cpu() - record.cpu_started) * 1000
    record.heap_delta_kib = self.heap() - record.heap_started
    self.active, self.pending = nil, record
    if record.handler_to_submit_ms then self:_flush(record, "submitted"); return unpack(result, 1, result.n) end
    self.ui:scheduleIn(2, function() if not record.flushed then self:_flush(record, "no_paint") end end)
    return unpack(result, 1, result.n)
end

function Profiler:install(options)
    local gesture = options.gesture_controller
    for _, name in ipairs({ "onPanRelease", "onPathRelease" }) do
        self:_wrap(gesture, name, function(original, ...) return self:_release(original, ...) end)
    end
    -- Timer fallback has no release event timestamp, so it is reported separately.
    self:_wrap(gesture, "finalizeTrace", function(original, controller, keyboard)
        if self.active then return original(controller, keyboard) end
        return self:_release(function(c, k) return original(c, k) end, controller, keyboard, nil)
    end)
    self:span(options.trace_collector, "snapshot", "snapshot")
    self:_wrap(options.trace_collector, "snapshot", function(original, ...)
        local result = pack(original(...))
        if self.active and result[1] then self.active.letters = #(result[1].signature or "") end
        return unpack(result, 1, result.n)
    end)
    self:span(options.trace_renderer, "clear", "clear_trace")
    self:span(options.keyboard_geometry, "keyCenters", "key_centers")
    self:span(options.input_controller, "getPreviousWord", "previous_word")
    self:span(options.keyboard_ui, "refreshCandidateRow", "candidate_row")
    self:span(options.dictionary_store, "loadBucket", "bucket")
    self.engine = options.engine; self.engine.profiler = self
    self:span(options.engine, "pickCandidates", "recognition")
    self:_wrap(options.engine, "pickCandidates", function(original, engine, attempt)
        local result = pack(original(engine, attempt))
        self:_captureFastGate(engine, attempt)
        local stats = options.shape_channel and options.shape_channel.last_stats
        -- A fast result never runs shape search; its previous counters are stale.
        if self.active and self.active.shape_wall_ms and stats then
            self.active.shape_entries, self.active.shape_compared = stats.entries, stats.compared
            self.active.shape_exhausted = stats.exhausted and 1 or 0
        end
        return unpack(result, 1, result.n)
    end)
    self:_wrap(self.ui, "_repaint", function(original, ...)
        local record = self.pending
        if not record then return original(...) end
        self.painting = record
        local wall, cpu = self.time.now(), self.cpu()
        local result = pack(original(...))
        self:_duration(record, "paint", wall, cpu)
        self.painting = nil
        if record.handler_to_submit_ms then self:_flush(record, "submitted") end
        return unpack(result, 1, result.n)
    end)
    local screen = options.screen
    self:span(screen, "mech_wait_update_complete", "wait_complete")
    self:span(screen, "mech_wait_update_submission", "wait_submission")
    self:_wrap(screen, "mech_refresh", function(original, ...)
        local record = self.painting or self.active
        if not record then return original(...) end
        local wall, cpu = self.time.now(), self.cpu()
        local result = pack(original(...))
        self:_duration(record, "driver", wall, cpu)
        record.driver_calls = (record.driver_calls or 0) + 1
        if record.inserted then
            record.handler_to_submit_ms = (self.time.now() - record.started) / self.time.ms(1)
            if record.event_delay_ms then record.to_submit_ms = record.handler_to_submit_ms
                + record.event_delay_ms end
        end
        return unpack(result, 1, result.n)
    end)
    return self
end

return Profiler
