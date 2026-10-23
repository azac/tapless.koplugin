-- Persistent CalypsoPlus trace: A2 during movement, ordinary repaint on clear.
-- Per-keyboard calibration/lifecycle; no test counter or expiry disables EBC.
local M={}
local unpack=unpack or table.unpack
local function pack(...) return {n=select('#',...),...} end
local function union(a,b)
    if not a then return {x=b.x,y=b.y,w=b.w,h=b.h} end
    local x,y=math.min(a.x,b.x),math.min(a.y,b.y)
    return {x=x,y=y,w=math.max(a.x+a.w,b.x+b.w)-x,h=math.max(a.y+a.h,b.y+b.h)-y}
end
function M.install(o,dependencies)
    local d=dependencies or {};local folder=o.plugin_dir
    local s={ready=false,failed=false,generation=0,epoch=0,frames=0,max_frame_us=0}
    local function log(kind,value)
        if o.logger and (kind=='fallback' or kind=='input_error') then
            o.logger.warn('Tapless: EBC '..kind,tostring(value))
        end
    end
    local function visible()
        local k=s.keyboard
        return k and not k.swype_mvp_closed and k:isSwypeMvpEnabled()
    end
    local function active()
        if not visible() then return false end
        if o.android and not d.ignore_activity then
            local app=o.android.app
            if app.window==nil or app.destroyRequested~=0
                or tonumber(app.activityState)~=require('ffi').C.APP_CMD_RESUME then return false end
        end
        return not d.active or d.active()
    end
    local function cancelFrame()
        s.generation=s.generation+1
        if s.callback then o.ui:unschedule(s.callback);s.callback=nil end
    end
    local function cancelPreparation()
        if s.prepare_callback then o.ui:unschedule(s.prepare_callback);s.prepare_callback=nil end
    end
    local function mode(enabled)
        if not s.bridge then return true end
        local ok,err=pcall(s.bridge.setMode,s.bridge,enabled)
        if not ok then log('input_error',err) end
        return ok
    end
    local function closeResources(reason)
        s.ready=false;cancelFrame();cancelPreparation()
        if s.finish then s.finish:close(reason) end
        s.all=nil;s.current_trace=nil;s.last_started=nil
        if s.bridge then
            local bridge=s.bridge;s.bridge=nil
            -- Java restoration is queued on Android UI before releasing the ref;
            -- its independent 90-second watchdog survives a stalled Lua thread.
            local ok,err=pcall(bridge.close,bridge)
            log('input_close',ok and reason or err)
        end
        if s.backend then
            local backend=s.backend;s.backend=nil
            local ok,err=pcall(backend.close,backend)
            log('backend_close',ok and reason or err)
        end
    end
    local function fallback(reason)
        local text=tostring(reason)
        if text:find('GET_BUFFER',1,true) or text:find('SEND_BUFFER',1,true)
            or text:find('reserved offset',1,true) or text:find('slow-submit',1,true) then
            s.disabled=true -- no further driver reservations in this process after a hard IO failure
        end
        s.failed=true;closeResources('fallback');log('fallback',reason)
        o.ui:setDirty(nil,'ui')
    end
    local prepare,schedulePrepare
    schedulePrepare=function(delay)
        if s.prepare_callback or s.failed or not s.keyboard then return end
        local epoch=s.epoch;local callback
        callback=function()
            if s.prepare_callback~=callback or epoch~=s.epoch then return end
            s.prepare_callback=nil;prepare()
        end
        s.prepare_callback=callback;o.ui:scheduleIn(delay,callback)
    end
    prepare=function()
        if s.failed or s.ready or not active() then return end
        -- Never switch renderer or calibrate while a normal gesture is underway.
        if s.current_trace then schedulePrepare(0.1);return end
        local ok,err=pcall(function()
            if not s.backend then
                if d.backend then s.backend=d.backend()
                else
                    local module=dofile(folder..'/android_ebc_backend.lua')
                    s.backend=module.open{now=o.time.monotonic}
                    module.attach(s.backend,o)
                end
            end
            s.tries=(s.tries or 0)+1
            if not s.backend:idle() then
                if s.tries<30 then schedulePrepare(0.1);return end
                error('busy during calibration')
            end
            local c=s.backend:calibrate(o.screen.bb)
            if d.bridge then s.bridge=d.bridge()
            else s.bridge=dofile(folder..'/android_ebc_input.lua'):new{
                android=o.android,jar=folder..'/native/ebc-input.jar'}:install() end
            assert(s.bridge,'input helper unavailable')
            assert(mode(false),'input restoration unavailable')
            s.ready=true;s.tries=0
            if s.finish then s.finish:prepare() end
            local best=c[1]
            log('ready','persistent A2; normal-only clear; turn='..best.turn..';high='..best.high)
        end)
        if not ok then fallback(err) end
    end
    local function queue(renderer,trace,region)
        s.all=union(s.all,region)
        if s.callback then return end
        local token,epoch=s.generation,s.epoch
        local callback
        callback=function()
            if token~=s.generation or epoch~=s.epoch or s.callback~=callback then return end
            s.callback=nil
            if not s.ready or s.failed or not active() or s.current_trace~=trace then
                cancelFrame();o.ui:setDirty(nil,'ui');return
            end
            local ok,err=pcall(function()
                local before=o.time.monotonic()
                -- Intentionally no idle gate: tested driver coalesces pending A2.
                s.backend:submit_bb(renderer.screen.bb,s.all,2)
                local after=o.time.monotonic()
                s.last_started=before;s.frames=s.frames+1
                local elapsed=after-before;s.max_frame_us=math.max(s.max_frame_us,elapsed)
                if elapsed>100000 then fallback('slow-submit-ms:'..elapsed/1000) end
            end)
            if not ok then fallback(err) end
        end
        s.callback=callback
        local delay=s.last_started and math.max(0,50000-(o.time.monotonic()-s.last_started))/1000000 or 0
        o.ui:scheduleIn(delay,callback)
    end
    -- A cached full plane stays coherent only while the trace is the sole
    -- source of changed pixels. Ordinary dirty UI/publication forces a fresh
    -- full conversion BEFORE the next native frame. Never reuse an old screen.
    local setDirty=o.ui.setDirty
    o.ui.setDirty=function(manager,...)
        if s.backend then s.backend:invalidate() end
        return setDirty(manager,...)
    end
    local updateWindow=o.screen._updateWindow
    if type(updateWindow)=='function' then
        o.screen._updateWindow=function(screen,...)
            if s.backend then s.backend:invalidate() end
            return updateWindow(screen,...)
        end
    end
    local draw,clear=o.renderer.drawSegment,o.renderer.clear
    o.renderer.drawSegment=function(renderer,trace,...)
        if s.keyboard and trace then
            s.current_trace=trace
        end
        if not s.ready or s.failed or not active() then return draw(renderer,trace,...) end
        local manager=renderer.ui_manager
        renderer.ui_manager={setDirty=function(_,widget,refresh,region)
            if region and refresh=='a2' then queue(renderer,trace,region)
            else manager:setDirty(widget,refresh,region) end
        end}
        local result=pack(pcall(draw,renderer,trace,...));renderer.ui_manager=manager
        if not result[1] then fallback(result[2]);error(result[2]) end
        return unpack(result,2,result.n)
    end
    o.renderer.clear=function(renderer,trace,...)
        -- No direct PART on release: ordinary clear + recognized word repaint.
        cancelFrame();s.all=nil;s.current_trace=nil;s.last_started=nil
        if s.backend then s.backend:invalidate() end
        local result=pack(clear(renderer,trace,...))
        return unpack(result,1,result.n)
    end
    local function monitor(epoch)
        if epoch~=s.epoch or not s.keyboard then return end
        s.monitor_callback=nil
        if not active() then
            if not s.paused then
                s.paused=true;closeResources('inactive');o.ui:setDirty(nil,'ui')
            end
        elseif s.paused then
            s.paused=false
            if not s.failed then s.tries=0;schedulePrepare(2) end
        end
        local callback=function() monitor(epoch) end
        s.monitor_callback=callback;o.ui:scheduleIn(0.25,callback)
    end
    local function closeKeyboard(reason)
        s.epoch=s.epoch+1
        if s.monitor_callback then o.ui:unschedule(s.monitor_callback);s.monitor_callback=nil end
        closeResources(reason)
        log('closed',reason..';frames='..s.frames..';max_frame_ms='..s.max_frame_us/1000)
        s.keyboard=nil
    end
    local show,hide=o.keyboard.onShow,o.keyboard.onCloseWidget
    o.keyboard.onShow=function(k,...)
        if s.keyboard then closeKeyboard('reopen') end
        local result=pack(show(k,...))
        s.keyboard=k;s.failed=s.disabled or false;s.paused=false;s.tries=0;s.frames=0;s.max_frame_us=0
        s.epoch=s.epoch+1;schedulePrepare(2)
        local epoch=s.epoch;local callback=function() monitor(epoch) end
        s.monitor_callback=callback;o.ui:scheduleIn(0.25,callback)
        return unpack(result,1,result.n)
    end
    o.keyboard.onCloseWidget=function(k,...)
        local result=pack(hide(k,...))
        if s.keyboard==k then closeKeyboard('keyboard-close') end
        return unpack(result,1,result.n)
    end
    if o.history then
        local previous=o.history.o.on_down
        o.history.o.on_down=function(...)
            if previous then previous(...) end
            if s.ready and not s.failed and active() then
                if not mode(true) then fallback('input rearm failed') end
            end
        end
    end
    s.close=closeKeyboard
    s.finish=(d.finish_module or dofile(folder..'/android_ebc_finish.lua')).install(o,s,d)
    log('installed','persistent EBC ROI trace; 50ms start cadence; coherent cache; no extra PART clear')
    return s
end
return M
