local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
-- Native kernel adapter; Lua preparation and scoring policy stay shared.
return function(Original, ffi, C)
local Matcher = setmetatable({}, {__index=Original})
Matcher.__index = Matcher
Matcher.backend = "c"
local function bit(v) return v and 1 or 0 end
function Matcher:new(policy)
    local ok, o = pcall(function()
        local instance = Original.new(self, policy)
        local context = C.tc_new()
        if context == nil then error("C allocation failed") end
        -- Retain the library until the finalizer has freed the context.
        instance.context = ffi.gc(context, function(ctx) C.tc_free(ctx) end)
        instance.result, instance.positions = ffi.new('TCResult[1]'), ffi.new('int[65]')
        instance.c_calls, instance.c_fallbacks = 0, 0
        return instance
    end)
    if ok then return o end
    local fallback = Original:new(policy)
    fallback.backend_reason = "native allocation failed"
    return fallback
end
local function alloc(h, name, kind, count)
    h[name] = ffi.new(kind .. '[?]', count)
    h.g[0][name] = h[name]
    return h[name]
end
function Matcher:packed(word, data, near)
    if #word > 64 or word:find('[^a-z]') or data.size > 512
        or self.policy.NEAR_KEY_LIMIT > 32 then return nil end
    local h = data.c_packed
    if not h then
        local n = data.size
        h = {g=ffi.new('TCGesture[1]')}; data.c_packed = h
        local g = h.g[0]
        g.size, g.near_limit = n, self.policy.NEAR_KEY_LIMIT
        g.first_cost, g.start_cost = self.policy.FIRST_LETTER_COST, self.policy.START_MISMATCH_COST
        g.end_cost, g.near_cost = self.policy.ENDPOINT_MISMATCH_COST, self.policy.NEAR_KEY_COST
        alloc(h,'letters','unsigned char',n+1)
        alloc(h,'weights','double',n+1); alloc(h,'prefix','double',n+1)
        for p=1,n do
            if data.letters[p] < 97 or data.letters[p] > 122 then data.c_packed=nil; return nil end
            h.letters[p], h.weights[p], h.prefix[p] = data.letters[p]-97, data.weights[p], data.prefix[p]
        end
        alloc(h,'next','int',(n+2)*26)
        for code=0,25 do h.next[(n+1)*26+code]=n+1 end
        for p=n,1,-1 do
            for code=0,25 do h.next[p*26+code]=h.next[(p+1)*26+code] end
            h.next[p*26+h.letters[p]]=p
        end
        alloc(h,'lending','unsigned char',n+1); alloc(h,'adjacent','unsigned char',26*26)
        alloc(h,'near_present','unsigned char',26); alloc(h,'near_next','int',(n+2)*26)
        alloc(h,'px','double',n+1); alloc(h,'py','double',n+1)
        alloc(h,'cx','double',26); alloc(h,'cy','double',26); alloc(h,'cs','double',26)
        alloc(h,'point_valid','unsigned char',n+1); alloc(h,'center_valid','unsigned char',26)
        alloc(h,'distances','double',(n+1)*26)
        C.tc_init_distances(h.g)
    end
    if near and h.near ~= near then
        h.near = near
        ffi.fill(h.adjacent,26*26); ffi.fill(h.near_present,26)
        for p=1,data.size do h.lending[p]=bit(near.lending[p]) end
        for source=1,26 do
            for target in pairs(near.adjacent[source] or {}) do h.adjacent[(source-1)*26+target-1]=1 end
        end
        for code=0,25 do
            local events = near.events[code+1]
            h.near_present[code]=bit(events)
            local cursor = events and #events or 0
            local closest = data.size+1
            h.near_next[(data.size+1)*26+code]=closest
            for p=data.size,1,-1 do
                if cursor > 0 and events[cursor]==p then closest=p; cursor=cursor-1 end
                h.near_next[p*26+code]=closest
            end
        end
    end
    self.c_calls=self.c_calls+1
    return h
end
local function geometry(h, data, points, endpoint, centers)
    if not points then return end
    if h.points == points and h.endpoint == endpoint and h.centers == centers then return end
    h.points,h.endpoint,h.centers=points,endpoint,centers
    ffi.fill(h.point_valid,data.size+1); ffi.fill(h.center_valid,26)
    for p=0,data.size do
        local v = p==0 and endpoint or p>0 and points[p]
        if v then h.point_valid[p]=1; h.px[p],h.py[p]=v.x,v.y end
    end
    for code=0,25 do
        local v=centers and centers[code+97]
        if v then h.center_valid[code]=1; h.cx[code],h.cy[code],h.cs[code]=v.x,v.y,v.size or 1 end
    end
    C.tc_init_distances(h.g)
end
local function output(self, length, positions)
    positions=positions or {}
    for key in pairs(positions) do positions[key]=nil end
    for i=1,length do if self.positions[i]~=0 then positions[i]=tonumber(self.positions[i]) end end
    return tonumber(self.result[0].score), self.result[0].mismatch~=0, positions, tonumber(self.result[0].omitted)
end
function Matcher:canFinish(word,data,start,ends,near,reuse)
    local h=self:packed(word,data,near)
    if not h then self.c_fallbacks=self.c_fallbacks+1; return Original.canFinish(self,word,data,start,ends,near,reuse) end
    return C.tc_can_finish(h.g,word,#word,bit(start),bit(ends),bit(near),bit(reuse))~=0
end
function Matcher:greedy(word,data,nexts,start,ends,near,budget,points,endpoint,centers,positions)
    local h=self:packed(word,data,near)
    if not h then self.c_fallbacks=self.c_fallbacks+1; return Original.greedy(self,word,data,nexts,start,ends,near,budget,points,endpoint,centers,positions) end
    geometry(h,data,points,endpoint,centers)
    C.tc_greedy(h.g,word,#word,bit(start),bit(ends),bit(near),budget or 0,bit(points),bit(nexts),self.positions,self.result)
    local score,mismatch,out=output(self,#word,positions)
    return score,mismatch,out
end
function Matcher:align(word,data,start,ends,near,omission,points,endpoint,centers)
    local h=self:packed(word,data,near)
    if not h then self.c_fallbacks=self.c_fallbacks+1; return Original.align(self,word,data,start,ends,near,omission,points,endpoint,centers) end
    geometry(h,data,points,endpoint or (points and points[data.size]),centers)
    if C.tc_align(self.context,h.g,word,#word,bit(start),bit(ends),bit(near),bit(omission~=nil),omission or 0,bit(points),self.positions,self.result)==0 then
        self.c_fallbacks=self.c_fallbacks+1
        return Original.align(self,word,data,start,ends,near,omission,points,endpoint,centers)
    end
    return output(self,#word)
end
dofile(dir..'/scan_matcher.lua')(Matcher,ffi,C,geometry)
local ok, shape_factory = pcall(function()
    return dofile(dir..'/shape_native.lua')(ffi, C)
end)
if ok then Matcher.shape_factory = shape_factory end
local engine_ok, engine_factory = pcall(function()
    return dofile(dir..'/engine_native.lua')(ffi,C)
end)
if engine_ok then Matcher.engine_factory=engine_factory end
return Matcher
end
