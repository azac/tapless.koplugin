-- Gesture-scoped text-first refresh batching. Operates after deferred input refreshes,
-- before ioctl submission; keeps waveform quality and unrelated updates intact.
local Batch = {};Batch.__index=Batch
local unpack=unpack or table.unpack
local function pack(...)return {n=select('#',...),...}end
local function rectangle(r)
    if type(r)~='table' then return false end
    for _,key in ipairs({'x','y','w','h'}) do
        local v=r[key];if type(v)~='number' or v~=v or math.abs(v)==math.huge then return false end
    end
    return r.w>0 and r.h>0
end
local function overlap(a,b)
    return rectangle(a) and rectangle(b) and a.x<=b.x+b.w and b.x<=a.x+a.w
        and a.y<=b.y+b.h and b.y<=a.y+a.h
end
local function inside(a,b)
    return rectangle(a) and rectangle(b) and a.x>=b.x and a.y>=b.y
        and a.x+a.w<=b.x+b.w and a.y+a.h<=b.y+b.h
end
function Batch:role(job,r)
    if overlap(r,job.input_region) then
        if overlap(r,job.keyboard_region) then return 'text+keyboard' end
        return 'text'
    end
    if inside(r,job.keyboard_region) then return 'keyboard' end
    return 'other'
end
local function area(queue)
    local total=0
    for _,entry in ipairs(queue) do total=total+entry.region.w*entry.region.h end
    return total
end
-- Merge UI text and the ordinary keyboard updates for every gesture.
-- Preserve stronger/unrelated regions and refuse a union crossing one of them.
function Batch:mergeSingle(job)
    local queue=self.ui._refresh_stack
    local members,combined,dither={},nil,false
    local count,has_text,has_keyboard=0,false,false
    for i,entry in ipairs(queue) do
        local text=inside(entry.region,job.input_region)
        local keyboard=inside(entry.region,job.keyboard_region)
            and not overlap(entry.region,job.input_region)
        if text and entry.mode~='ui' then job.reason='single-text-mode';return end
        if (text or keyboard) and (entry.mode=='ui' or entry.mode=='a2') then
            if type(entry.region.copy)~='function' or type(entry.region.combine)~='function' then
                job.reason='single-unsupported';return
            end
            members[i]=true;count=count+1
            has_text=has_text or text;has_keyboard=has_keyboard or keyboard
            combined=combined and combined:combine(entry.region) or entry.region:copy()
            dither=dither or entry.dither
        end
    end
    if count<2 or not has_text or not has_keyboard then job.reason='single-missing-region';return end
    for i,entry in ipairs(queue) do
        if not members[i] and overlap(combined,entry.region) then
            job.reason='single-collision';return
        end
    end
    local proposed={{mode='ui',region=combined,dither=dither}}
    for i,entry in ipairs(queue) do if not members[i] then proposed[#proposed+1]=entry end end
    self.ui._refresh_stack=proposed
    job.single_applied=1;job.reason='single-applied'
end
function Batch:plan(job)
    local queue=self.ui._refresh_stack
    if type(queue)~='table' or not rectangle(job.input_region) or not rectangle(job.keyboard_region) then
        job.reason='unsupported';return
    end
    for _,entry in ipairs(queue) do
        if type(entry)~='table' or not rectangle(entry.region) or type(entry.mode)~='string' then
            job.reason='unsupported';return
        end
    end
    job.before=#queue;job.after=#queue;job.merged=0;job.reordered=0;job.supported=1
    job.area_before=area(queue);job.single_requested=job.single and 1 or 0;job.single_applied=0
    if not job.enabled then job.reason='control';return end
    local members,combined,mode,dither={},nil,'a2',false
    for i,entry in ipairs(queue) do
        if inside(entry.region,job.keyboard_region) and not overlap(entry.region,job.input_region)
                and (entry.mode=='ui' or entry.mode=='a2') then
            if type(entry.region.combine)~='function' then job.reason='unsupported';return end
            members[i]=true;combined=combined and combined:combine(entry.region) or entry.region:copy()
            if entry.mode=='ui' then mode='ui' end
            dither=dither or entry.dither
        end
    end
    local count=0;for _ in pairs(members) do count=count+1 end
    -- Do not introduce an overlap with a stronger/unrelated refresh.
    if count>1 then for i,entry in ipairs(queue) do
        if not members[i] and overlap(combined,entry.region) then count=0;break end
    end end
    local proposed={};local inserted=false
    for i,entry in ipairs(queue) do
        if count>1 and members[i] then
            if not inserted then
                proposed[#proposed+1]={mode=mode,region=combined,dither=dither};inserted=true
            end
        else proposed[#proposed+1]=entry end
    end
    local ordered={}
    for _,entry in ipairs(proposed) do if overlap(entry.region,job.input_region) then ordered[#ordered+1]=entry end end
    for _,entry in ipairs(proposed) do if not overlap(entry.region,job.input_region) then ordered[#ordered+1]=entry end end
    for i,entry in ipairs(ordered) do if entry~=proposed[i] then job.reordered=1;break end end
    job.after=#ordered;job.merged=#queue-#ordered;job.reason='applied'
    self.ui._refresh_stack=ordered
    if job.single then self:mergeSingle(job) end
    job.after=#self.ui._refresh_stack;job.merged=job.before-job.after
    job.area_after=area(self.ui._refresh_stack)
end
function Batch:queue(keyboard)
    if self.stopped then return end
    local enabled=true
    if self.select then enabled=self.select() end
    local single=enabled
    if enabled and self.single_select then single=self.single_select() end
    local job={enabled=enabled,single=single,
        variant=enabled and (single and 'single-ui-union' or 'text-first+merged') or 'control',keyboard=keyboard}
    self.pending=job;return job
end
function Batch:new(ui)
    local self=setmetatable({ui=ui},Batch)
    if type(ui._repaint)~='function' or type(ui.setDirty)~='function'
            or type(ui._refresh_stack)~='table' or type(ui._refresh_func_stack)~='table' then self.stopped=true;return self end
    self.original=ui._repaint
    self.wrapper=function(...)
        local job=self.pending;self.pending=nil
        if not job then return self.original(...) end
        local keyboard=job.keyboard;job.keyboard=nil
        if not keyboard.swype_mvp_closed then
            job.input_region=keyboard.inputbox and keyboard.inputbox.dimen
            job.keyboard_region=keyboard.dimen
        end
        self.current=job
        -- Added at repaint entry, after all callbacks queued by the handler.
        local adjust
        adjust=function()
            -- Painting/callbacks can append more deferred refreshes. Move to
            -- the tail until every prior callback has supplied its region.
            local functions=ui._refresh_func_stack
            if type(functions)=='table' and functions[#functions]~=adjust then
                functions[#functions+1]=adjust;return nil
            end
            local ok=pcall(self.plan,self,job)
            if not ok then job.reason='unsupported';job.supported=0 end
            return nil
        end
        ui:setDirty(nil,adjust)
        local result=pack(pcall(self.original,...));self.current=nil
        if not result[1] then error(result[2],0) end
        return unpack(result,2,result.n)
    end
    ui._repaint=self.wrapper;return self
end
function Batch:stop()
    self.stopped=true;self.pending=nil
    if self.ui._repaint==self.wrapper then self.ui._repaint=self.original end
end
return Batch
