local GestureController = {}
GestureController.__index = GestureController

function GestureController:new(trace_collector, ui_manager, time_api, geometry)
    return setmetatable({
        trace_collector = assert(trace_collector),
        ui_manager = assert(ui_manager),
        time = assert(time_api),
        geometry = assert(geometry),
    }, self)
end

function GestureController:reset(keyboard, keep_prefetch)
    if keyboard.swype_mvp_finalize_callback then
        self.ui_manager:unschedule(keyboard.swype_mvp_finalize_callback)
        keyboard.swype_mvp_finalize_callback = nil
    end
    keyboard.swype_mvp_finalize_deadline = nil
    if keyboard.swype_mvp_trace then
        keyboard:_swypeClearTracePixels("ui")
    end
    if not keep_prefetch then
        keyboard:_swypeCancelBucketPrefetch()
    end
    keyboard.swype_mvp_trace_generation =
        (keyboard.swype_mvp_trace_generation or 0) + 1
    keyboard.swype_mvp_trace = nil
    keyboard.swype_mvp_last_point_time = nil
end

function GestureController:scheduleFinalize(keyboard)
    -- Points only move the deadline. The same pending callback checks it
    -- and reschedules itself, instead of adding a closure for every point.
    keyboard.swype_mvp_finalize_deadline =
        keyboard.swype_mvp_last_point_time + self.time.ms(400)
    if keyboard.swype_mvp_finalize_callback then
        return
    end
    local callback
    callback = function()
        if keyboard.swype_mvp_finalize_callback ~= callback then
            return
        end
        if keyboard.swype_mvp_closed
                or not keyboard.swype_mvp_trace
                or not keyboard.swype_mvp_last_point_time then
            keyboard.swype_mvp_finalize_callback = nil
            keyboard.swype_mvp_finalize_deadline = nil
            return
        end
        local remaining = keyboard.swype_mvp_finalize_deadline - self.time.now()
        if remaining > 0 then
            self.ui_manager:scheduleIn(self.time.to_s(remaining), callback)
            return
        end
        keyboard.swype_mvp_finalize_callback = nil
        keyboard.swype_mvp_finalize_deadline = nil
        self:finalizeTrace(keyboard)
    end
    keyboard.swype_mvp_finalize_callback = callback
    self.ui_manager:scheduleIn(0.4, callback)
end

function GestureController:addPoint(keyboard, pos)
    if not pos or not pos.x or not pos.y then
        return
    end
    local now = self.time.now()
    if keyboard.swype_mvp_trace and keyboard.swype_mvp_last_point_time
            and now - keyboard.swype_mvp_last_point_time > self.time.ms(500) then
        self:reset(keyboard)
    end
    keyboard.swype_mvp_last_point_time = now
    if not keyboard.swype_mvp_trace then
        keyboard.swype_mvp_trace = self.trace_collector:newTrace()
    end
    local letter, key = keyboard:_swypeKeyAt(pos)
    local result = self.trace_collector:addPoint(
        keyboard.swype_mvp_trace, pos, letter, key and key.dimen, now)
    if result and result.point_added then
        keyboard:_swypeDrawTraceSegment(result.previous_point, result.point)
    end
    if not letter then
        self:scheduleFinalize(keyboard)
        return
    end
    if result and result.letter_rejected then
        self:scheduleFinalize(keyboard)
        return
    end
    if result and result.letter_added then
        keyboard:_swypeScheduleBucketPrefetch()
    end
    self:scheduleFinalize(keyboard)
end

function GestureController:addKeyCenter(keyboard, key)
    if key and key.dimen then
        self:addPoint(keyboard, self.geometry:new{
            x = key.dimen.x + math.floor(key.dimen.w / 2),
            y = key.dimen.y + math.floor(key.dimen.h / 2),
            w = 1,
            h = 1,
        })
    end
end

function GestureController:finalizeTrace(keyboard)
    if not keyboard.swype_mvp_trace then
        return false
    end
    local snapshot = self.trace_collector:snapshot(keyboard.swype_mvp_trace)
    local trace_info = {
        letter_points = snapshot.letter_points,
        endpoint_pos = snapshot.endpoint_pos,
        points = snapshot.points,
        observations = snapshot.observations,
        previous_word = keyboard:_swypeGetPreviousWord(),
    }
    self:reset(keyboard, true)
    local finalized = keyboard:_swypeFinalizeSignature(
        snapshot.signature, trace_info)
    keyboard:_swypeCancelBucketPrefetch()
    return finalized
end

function GestureController:onPan(keyboard, ges)
    if not keyboard:isSwypeMvpEnabled() then
        self:reset(keyboard)
        return false
    end
    if not keyboard.swype_mvp_trace then
        local start_pos = ges and ges.start_pos
        local start_letter = keyboard:_swypeKeyAt(start_pos)
        if not start_letter then
            return false
        end
        keyboard:_swypeCommitPendingContext()
        keyboard:_swypeClearCandidateState()
        self:addPoint(keyboard, start_pos)
    end
    self:addPoint(keyboard, ges and ges.pos)
    return true
end

function GestureController:onPathRelease(keyboard, ges, source_key)
    if not keyboard:isSwypeMvpEnabled() then
        self:reset(keyboard)
        return false
    end
    local start_pos
    if not keyboard.swype_mvp_trace then
        start_pos = ges and (ges.start_pos or ges.pos)
        if start_pos then
            local start_letter = keyboard:_swypeKeyAt(start_pos)
            if not start_letter then
                return false
            end
        elseif not source_key then
            return false
        end
    end
    keyboard:_swypeCommitPendingContext()
    keyboard:_swypeClearCandidateState()
    if not keyboard.swype_mvp_trace then
        if start_pos then
            self:addPoint(keyboard, start_pos)
        else
            self:addKeyCenter(keyboard, source_key)
        end
    end

    local end_pos = ges and (ges.end_pos or ges.pos)
    self:addPoint(keyboard, end_pos)
    if not keyboard.swype_mvp_trace then
        self:addKeyCenter(keyboard, source_key)
    end
    return self:finalizeTrace(keyboard)
end

function GestureController:onPanRelease(keyboard, ges)
    if not keyboard:isSwypeMvpEnabled() then
        self:reset(keyboard)
        return false
    end
    if not keyboard.swype_mvp_trace then
        local start_pos = ges and ges.start_pos
        local start_letter = keyboard:_swypeKeyAt(start_pos)
        if not start_letter then
            return false
        end
        keyboard:_swypeCommitPendingContext()
        keyboard:_swypeClearCandidateState()
        self:addPoint(keyboard, start_pos)
    end
    if not keyboard.swype_mvp_trace then
        self:reset(keyboard)
        return false
    end
    self:addPoint(keyboard, ges and ges.pos)
    return self:finalizeTrace(keyboard)
end

return GestureController
