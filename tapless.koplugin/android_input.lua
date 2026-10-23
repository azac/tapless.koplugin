-- Restore real, historical single-finger samples while the swipe keyboard is open.
-- The original Android backend still handles every current/down/up/cancel event.
local Input = {}
Input.__index = Input
local function upvalue(fn,wanted)
    if type(fn)~='function' then return end
    for index=1,100 do
        local name,value=debug.getupvalue(fn,index)
        if not name then break end
        if name==wanted then return value,index end
    end
end

function Input:new(o)
    return setmetatable({o=o,stats={packets=0,history=0,skipped=0,failures=0},last=nil},self)
end

function Input:restore()
    if self.hook then
        local h=self.hook;local _,current=debug.getupvalue(h.fn,h.index)
        if current==h.wrapper then debug.setupvalue(h.fn,h.index,h.original) end
        self.hook=nil
    end
end

function Input:install()
    local o=self.o
    if not o.android or not o.backend then return nil,'not Android input' end
    local original,index=upvalue(o.backend.waitForEvent,'motionEventHandler')
    local move=upvalue(original,'genTouchMoveEvent')
    local emit=upvalue(move,'genEmuEvent')
    local timeval=upvalue(original,'genInputTimeval')
    local pointers=upvalue(original,'pointers')
    if not original or type(move)~='function' or type(emit)~='function'
            or type(timeval)~='function' or type(pointers)~='table' then
        return nil,'unrecognized Android input backend'
    end
    local lib=o.android.lib
    if not o.test then
        local ffi=require('ffi')
        ffi.cdef[[size_t AMotionEvent_getHistorySize(const AInputEvent *event);
            int64_t AMotionEvent_getHistoricalEventTime(const AInputEvent *event, size_t history_index);
            float AMotionEvent_getHistoricalX(const AInputEvent *event, size_t pointer_index, size_t history_index);
            float AMotionEvent_getHistoricalY(const AInputEvent *event, size_t pointer_index, size_t history_index);]]
    end
    local getN,getTime,getX,getY=lib.AMotionEvent_getHistorySize,
        lib.AMotionEvent_getHistoricalEventTime,lib.AMotionEvent_getHistoricalX,lib.AMotionEvent_getHistoricalY
    local function read(event,current)
        local n=tonumber(getN(event))
        if n<0 or n>256 then return nil,'oversized history' end
        local samples={};local last=self.last
        for h=0,n-1 do
            local timestamp=getTime(event,h)
            if (not last or timestamp>last) and timestamp<current then
                local x,y=tonumber(getX(event,0,h)),tonumber(getY(event,0,h))
                if x~=x or y~=y or math.abs(x)==math.huge or math.abs(y)==math.huge then
                    return nil,'invalid coordinates'
                end
                samples[#samples+1]={time=timeval(timestamp),x=x,y=y}
                last=timestamp
            else
                self.stats.skipped=self.stats.skipped+1
            end
        end
        return samples
    end
    local wrapper=function(event,...)
        local action=tonumber(lib.AMotionEvent_getAction(event))%256
        local current=lib.AMotionEvent_getEventTime(event)
        if action==0 and o.on_down and o.active() then pcall(o.on_down) end
        if action==0 or action==5 then self.last=nil end
        if action==2 and o.active() and not o.android.isTouchscreenIgnored()
                and tonumber(lib.AMotionEvent_getPointerCount(event))==1 then
            local slot=tonumber(lib.AMotionEvent_getPointerId(event,0))
            if pointers[slot] then
                -- Read and validate first; an unavailable API cannot leave half a frame queued.
                local ok,samples=pcall(read,event,current)
                self.stats.packets=self.stats.packets+1
                if ok and samples then
                    for _,sample in ipairs(samples) do
                        emit(3,47,slot,sample.time) -- EV_ABS / ABS_MT_SLOT
                        emit(3,53,sample.x,sample.time)
                        emit(3,54,sample.y,sample.time)
                        emit(0,0,0,sample.time) -- EV_SYN / SYN_REPORT
                    end
                    self.stats.history=self.stats.history+#samples
                else
                    self.stats.failures=self.stats.failures+1
                end
            end
        end
        self.last=current
        if action==1 or action==3 or action==6 then self.last=nil end
        return original(event,...)
    end
    debug.setupvalue(o.backend.waitForEvent,index,wrapper)
    self.hook={fn=o.backend.waitForEvent,index=index,original=original,wrapper=wrapper}
    return self
end

return Input
