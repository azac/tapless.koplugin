-- Scoped final EBC repaint with ordinary Android publication for UI transitions.
local M={}
local unpack=unpack or table.unpack
local function pack(...) return {n=select('#',...),...} end
local function rect(r)
    return type(r)=='table' and type(r.x)=='number' and type(r.y)=='number'
        and type(r.w)=='number' and type(r.h)=='number' and r.w>0 and r.h>0
        and r.x>=0 and r.y>=0 and r.x+r.w<=758 and r.y+r.h<=1024
end
local function combined(a,b)
    if not rect(a) or not rect(b) then return end
    local x,y=math.min(a.x,b.x),math.min(a.y,b.y)
    return {x=x,y=y,w=math.max(a.x+a.w,b.x+b.w)-x,h=math.max(a.y+a.h,b.y+b.h)-y}
end
local function copy(r) if rect(r) then return {x=r.x,y=r.y,w=r.w,h=r.h} end end
local function same(a,b) return rect(a) and rect(b) and a.x==b.x and a.y==b.y and a.w==b.w and a.h==b.h end
local function inside(a,b)
    return rect(a) and rect(b) and a.x>=b.x and a.y>=b.y
        and a.x+a.w<=b.x+b.w and a.y+a.h<=b.y+b.h
end
local function dialogRegion(keyboard)
    local input=keyboard.inputbox
    local frame=input and input.parent and input.parent.dialog_frame
    local region=frame and frame.dimen
    if rect(region) and region.w*region.h<758*1024 and inside(input.dimen,region) then
        return region
    end
end
function M.install(o,s,d)
    d=d or {};local f={pending=nil,jobs=0,disabled=false,owned=false}
    local function log(kind,value)
        if o.logger and kind=='native_error' then
            o.logger.warn('Tapless: EBC final repaint unavailable',tostring(value))
        end
    end
    local function active()
        if not s.ready or s.failed or not s.keyboard or s.keyboard.swype_mvp_closed
            or not s.keyboard:isSwypeMvpEnabled() then return false end
        if o.android and not d.ignore_activity then
            local app=o.android.app
            if app.window==nil or app.destroyRequested~=0
                or tonumber(app.activityState)~=require('ffi').C.APP_CMD_RESUME then return false end
        end
        return not d.active or d.active()
    end
    local function cancelWatchdog()
        if f.watchdog then o.ui:unschedule(f.watchdog);f.watchdog=nil end
    end
    function f:prepare()
        self.disabled=false;self.jobs=0
        -- The kernel may discard older queued PART/A2 buffers. Every subsequent
        -- trace buffer must also carry all deferred text changes in its region.
        local backend=s.backend
        if backend and self.wrapped_backend~=backend then
            self.wrapped_backend=backend
            local submit=backend.submit_bb
            backend.submit_bb=function(b,bb,region,mode)
                if f.owned and f.deferred_region then region=combined(region,f.deferred_region) or region end
                local result=pack(submit(b,bb,region,mode))
                if f.owned then f.last_activity=o.time.monotonic() end
                return unpack(result,1,result.n)
            end
        end
        log('ready','unlimited direct final EBC; sync/rearm on ordinary repaint; sync after 60s idle')
    end
    function f:close(reason)
        self.pending=nil;self.disabled=true;cancelWatchdog()
        if self.owned then
            log('restore_queued',reason)
            -- Paint the current UI before publishing it, including removed keyboard.
            -- If paused/window gone, normal resume repaint performs synchronization.
            o.ui:setDirty(nil,'ui')
        end
    end
    local function canPublish()
        if d.window_available then return d.window_available() end
        if not o.android or d.ignore_activity then return true end
        local app=o.android.app
        return app.window~=nil and app.destroyRequested==0
            and tonumber(app.activityState)==require('ffi').C.APP_CMD_RESUME
    end
    local function watchdog()
        cancelWatchdog()
        local callback
        callback=function()
            f.watchdog=nil
            if not f.owned then return end
            local remaining=60-(o.time.monotonic()-(f.last_activity or 0))/1000000
            if s.current_trace or f.pending then remaining=math.max(1,remaining) end
            if remaining>0 then
                f.watchdog=callback;o.ui:scheduleIn(remaining,callback);return
            end
            log('idle_sync','60s without native input/output; normal repaint queued')
            o.ui:setDirty(nil,'ui')
        end
        f.watchdog=callback;o.ui:scheduleIn(60,callback)
    end
    if not o.controller or type(o.controller.finalizeTrace)~='function'
        or type(o.ui._repaint)~='function' or type(o.screen._updateWindow)~='function' then
        f.unsupported=true;log('unavailable','unsupported hooks');return f
    end
    if o.android and not d.ignore_activity then
        local ok,full=pcall(o.android.isEinkFull)
        if not ok or full then f.unsupported=true;log('unavailable','full eink API/unknown backend');return f end
    end
    local finalize=o.controller.finalizeTrace
    o.controller.finalizeTrace=function(controller,keyboard,...)
        if not f.disabled and active() and s.keyboard==keyboard and keyboard.swype_mvp_trace then
            if not f.pending then
                local before=o.time.monotonic()
                local ok,err=pcall(s.backend.snapshot_finish,s.backend,o.screen.bb)
                if ok then f.jobs=f.jobs+1;f.pending={seq=f.jobs,keyboard=keyboard,epoch=s.epoch,backend=s.backend,
                    snapshot_ms=(o.time.monotonic()-before)/1000,ready=false,
                    input_region=copy(keyboard.inputbox and keyboard.inputbox.dimen),keyboard_region=copy(keyboard.dimen),
                    dialog_region=copy(dialogRegion(keyboard))}
                else log('fallback','snapshot:'..tostring(err)) end
            end
        end
        local result=pack(pcall(finalize,controller,keyboard,...))
        if not result[1] then f:close('finalize-error');error(result[2],0) end
        if f.pending then f.pending.ready=true end
        return unpack(result,2,result.n)
    end
    local repaint=o.ui._repaint
    o.ui._repaint=function(...)
        local pending=f.pending
        if not pending then return repaint(...) end
        if f.painting then f.pending=nil;return repaint(...) end
        f.painting=true;f.decision=nil;f.posted=false
        local result=pack(pcall(repaint,...))
        f.painting=false;f.pending=nil
        if not result[1] then f:close('repaint-error');error(result[2],0) end
        return unpack(result,2,result.n)
    end
    local update=o.screen._updateWindow
    o.screen._updateWindow=function(screen,...)
        local p=f.pending
        if not f.painting or not p then
            if f.owned then
                if not canPublish() then log('sync_deferred','window unavailable/inactive');return end
                log('sync_android','ordinary-publication');cancelWatchdog()
                local result=pack(pcall(update,screen,...))
                if not result[1] then error(result[2],0) end
                f.owned=false;f.deferred_region=nil
                return unpack(result,2,result.n)
            end
            return update(screen,...)
        end
        if f.decision==nil then
            local ok,reason=pcall(function()
                assert(p.ready and active() and p.keyboard==s.keyboard and p.epoch==s.epoch
                    and p.backend==s.backend and not s.current_trace,'stale/active-gesture')
                assert(same(p.input_region,p.keyboard.inputbox and p.keyboard.inputbox.dimen)
                    and same(p.keyboard_region,p.keyboard.dimen),'layout changed')
                local allowed=combined(p.input_region,p.keyboard_region)
                assert(allowed,'unknown widget bounds')
                if p.dialog_region then
                    assert(same(p.dialog_region,dialogRegion(p.keyboard)),'dialog layout changed')
                    allowed=combined(allowed,p.dialog_region)
                else
                    assert(not dialogRegion(p.keyboard),'dialog appeared')
                end
                local stack=o.ui._refresh_stack
                assert(type(stack)=='table' and #stack>0,'unknown refresh queue')
                for _,entry in ipairs(stack) do
                    assert((entry.mode=='ui' or entry.mode=='a2') and not entry.dither
                        and inside(entry.region,allowed),'strong/unrelated refresh')
                end
                local before=o.time.monotonic()
                local damage=s.backend:diff_finish(o.screen.bb)
                p.diff_ms=(o.time.monotonic()-before)/1000
                if damage.pixels<=0 or not inside(damage,allowed) then
                    local function bounds(r)
                        return r and table.concat({r.x,r.y,r.w,r.h},',') or 'nil'
                    end
                    log('damage_guard',table.concat({'seq='..p.seq,'pixels='..damage.pixels,
                        'damage='..bounds(damage),'allowed='..bounds(allowed),
                        'input='..bounds(p.input_region),'keyboard='..bounds(p.keyboard_region)},';'))
                end
                assert(damage.pixels>0,'no RGB damage')
                assert(inside(damage,allowed),'RGB damage outside editable region')
                assert(damage.w*damage.h<758*1024,'full-screen damage')
                p.damage=damage;f.decision=true

            end)
            if not ok then
                f.decision=false;cancelWatchdog();log('fallback',reason)
            end
        end
        if f.decision then
            if f.posted then return end
            f.posted=true
            local before=o.time.monotonic()
            local target=f.deferred_region and combined(f.deferred_region,p.damage) or p.damage
            local ok,err=pcall(s.backend.submit_bb,s.backend,screen.bb,target,3)
            if ok then
                f.owned=true;f.deferred_region=copy(target);f.last_activity=o.time.monotonic()
                if not f.watchdog then watchdog() end
                return
            end
            f.disabled=true;cancelWatchdog();log('native_error',err)
            -- An ioctl failure must stop further native reservations in this session.
            s.disabled=true;s.failed=true
            if s.close then s.close('takeover-native-error') end
            f.decision=false
        end
        if f.owned then
            if not canPublish() then log('sync_deferred','fallback window unavailable');return end
            -- A rejected final repaint still synchronizes all previously deferred words.
            local result=pack(pcall(update,screen,...))
            if not result[1] then error(result[2],0) end
            f.owned=false;f.deferred_region=nil;log('sync_android','fallback-final');return unpack(result,2,result.n)
        end
        return update(screen,...)
    end
    return f
end
return M
