-- Native whole-path scanning; dictionary access and deadline checks remain Lua.
-- Native pointer owners are FFI arrays and explicitly anchored Lua strings.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
return function(ffi,C)
    if not pcall(ffi.typeof,'TSShapeState') then
        local f=assert(io.open(dir..'/native/shape.h','rb'))
        local header=f:read('*a'); f:close(); ffi.cdef(header)
    end
    assert(C.ts_abi_version()==2 and C.ts_state_size()==ffi.sizeof('TSShapeState')
        and C.ts_entry_size()==ffi.sizeof('TSShapeEntry')
        and C.ts_word_slot_size()==ffi.sizeof('TSWordSlot')
        and C.ts_signature_slot_size()==ffi.sizeof('TSSignatureSlot')
        and C.ts_hit_size()==ffi.sizeof('TSShapeHit'),'shape ABI mismatch')
    assert(C.ts_shape_scan)
    local Native={}; Native.__index=Native
    local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
    local function integer(v,lo,hi) return finite(v) and v==math.floor(v) and v>=lo and v<=hi end
    local function group(self,entries,dictionary,language)
        local g=self.groups[entries]
        local valid=g and g.count==#entries
        local language_changed=not g or g.dictionary~=dictionary or g.language~=language
        if valid then
            for i,e in ipairs(entries) do
                if g.words[i]~=e.word or g.signatures[i]~=(e.gesture_signature or e.signature)
                    or g.base_signatures[i]~=e.signature then valid=false; break end
                local frequency=e.freq or 0
                if g.frequencies[i]~=frequency then
                    if not finite(frequency) then return nil end
                    g.data[i-1].frequency=frequency; g.frequencies[i]=frequency
                end
                if language_changed or g.languages[i]~=e.lang then
                    g.data[i-1].enabled=(not e.lang or e.lang==dictionary or e.lang==language) and 1 or 0
                    g.languages[i]=e.lang
                end
            end
        end
        if not valid then
            g={count=#entries,data=ffi.new('TSShapeEntry[?]',math.max(1,#entries)),words={},signatures={},
                base_signatures={},frequencies={},languages={}}
            for i,e in ipairs(entries) do
                local word,signature=e.word,e.gesture_signature or e.signature
                if word~=nil and type(word)~='string' then return nil end
                if signature~=nil and (type(signature)~='string' or signature:find('[^a-z]')) then return nil end
                local frequency=e.freq or 0
                if not finite(frequency) then return nil end
                local minimum=e.signature and #e.signature or #(signature or '')
                g.words[i],g.signatures[i],g.base_signatures[i]=word,signature,e.signature
                g.frequencies[i],g.languages[i]=frequency,e.lang
                local v=g.data[i-1]
                v.word,v.signature=word,signature
                v.word_length,v.signature_length=#(word or ''),#(signature or '')
                v.minimum_length,v.frequency=minimum,frequency
                v.enabled=(not e.lang or e.lang==dictionary or e.lang==language) and 1 or 0
            end
            self.groups[entries]=g
        end
        g.dictionary,g.language=dictionary,language
        return g
    end
    function Native:candidates(channel,options)
        local stats={entries=0,compared=0,buckets=0,exhausted=false,backend='c',native_calls=0}
        channel.last_stats=stats
        if not channel:triggered(options.signature) then return {} end
        local swipe=options.swipe or channel.geometry:prepareTrace(options.points)
        if not swipe then return {} end
        local count=channel.geometry.SAMPLE_COUNT
        if not integer(count,2,64) or #swipe.samples~=count or not finite(swipe.length)
            or not integer(channel.KEEP,1,64) or not integer(channel.MAX_ENTRIES,0,32768)
            or not integer(channel.MAX_COMPARISONS,0,1000000)
            or not integer(channel.MIN_LETTERS,0,1000000) then return nil end
        for _,v in ipairs({channel.MIN_RATIO,channel.MAX_RATIO,channel.MAX_SHAPE_SCORE,
            channel.SHAPE_WEIGHT,channel.geometry.MAX_SCORE}) do if not finite(v) then return nil end end
        local centers=options.key_centers or {}
        for code=97,122 do
            local v=centers[code]
            if v and (not finite(v.x) or not finite(v.y) or not finite(v.size or 1)) then return nil end
        end
        for _,v in ipairs(swipe.samples) do if not finite(v.x) or not finite(v.y) then return nil end end
        channel.geometry:_ensureGeometry(centers)
        local layout=channel.geometry.cache_geometry
        if self.layout~=layout then
            self.groups=setmetatable({},{__mode='k'}); self.layout=layout
        end
        local capacity=2
        while capacity<2*channel.MAX_ENTRIES do capacity=capacity*2 end
        if self.capacity~=capacity then
            self.words=ffi.new('TSWordSlot[?]',capacity)
            self.signatures=ffi.new('TSSignatureSlot[?]',capacity)
            self.capacity=capacity
        end
        -- Generation stamps avoid clearing several MiB for each gesture.
        -- Stale key pointers are never dereferenced, including after GC.
        self.generation=(self.generation or 0)+1
        if self.generation>=4294967296 then
            ffi.fill(self.words,ffi.sizeof(self.words)); ffi.fill(self.signatures,ffi.sizeof(self.signatures))
            self.generation=1
        end
        ffi.fill(self.state,ffi.sizeof(self.state))
        local s=self.state[0]
        s.words,s.signatures,s.hits=self.words,self.signatures,self.hits
        s.capacity,s.samples,s.length=capacity,count,swipe.length
        s.generation=self.generation
        s.min_letters,s.max_entries,s.max_comparisons,s.keep=channel.MIN_LETTERS,channel.MAX_ENTRIES,channel.MAX_COMPARISONS,channel.KEEP
        s.min_ratio,s.max_ratio,s.max_shape,s.shape_weight,s.max_score=channel.MIN_RATIO,channel.MAX_RATIO,channel.MAX_SHAPE_SCORE,channel.SHAPE_WEIGHT,channel.geometry.MAX_SCORE
        for code=97,122 do
            local v=centers[code]
            if v then s.centers[code-97].x,s.centers[code-97].y,s.centers[code-97].size=v.x,v.y,v.size or 1
                s.centers[code-97].present=1 end
        end
        for i,v in ipairs(swipe.samples) do s.x[i-1],s.y[i-1]=v.x,v.y end
        local clock=channel.time
        -- Start at the same logical point as Lua; native packing above is timed
        -- in total recognition, but not charged to the shape-search allowance.
        local start=clock and clock.now()
        local deadline=start and start+clock.ms(channel.BUDGET_MS)
        local function outOfTime() return deadline and clock.now()>=deadline end
        local dictionary=options.dictionary or 'en'
        local language=options.data_language or dictionary
        local groups,entry_arrays={},{}
        local function scan(bucket,primary)
            local entries=bucket and bucket.entries
            if not entries then return true end
            local g=group(self,entries,dictionary,language)
            if not g then return false end
            -- Hold groups and entry arrays throughout the call, including keys
            -- discarded by a dictionary cache while another bucket is loaded.
            groups[#groups+1]=g; entry_arrays[#entry_arrays+1]=entries
            local id=#groups-1
            local offset=0
            while offset<#entries do
                if s.entries>=s.max_entries or s.exhausted~=0
                    or (not primary and s.entries%32==0 and outOfTime()) then
                    s.exhausted=1; break
                end
                local n=primary and (#entries-offset) or math.min(#entries-offset,32-tonumber(s.entries)%32)
                local processed=C.ts_shape_scan(self.state,g.data+offset,n,id,offset)
                stats.native_calls=stats.native_calls+1
                self.calls=(self.calls or 0)+1
                if s.overflow~=0 then return false end
                offset=offset+processed
                if processed==0 then break end
            end
            return true
        end
        local first,last=swipe.samples[1],swipe.samples[#swipe.samples]
        local starts,ends=channel:_lettersNear(first,centers),channel:_lettersNear(last,centers)
        for _,a in ipairs(starts) do
            for _,b in ipairs(ends) do
                if outOfTime() or s.exhausted~=0 then s.exhausted=1; break end
                local primary=stats.buckets==0
                if channel.personal and not scan(channel.personal:getBucket(a,b,dictionary,options.normalization_profile),primary) then return nil end
                if s.exhausted==0 then
                    stats.buckets=stats.buckets+1
                    if not scan(channel.store:loadBucket(a,b,dictionary),primary) then return nil end
                end
            end
            if s.exhausted~=0 then break end
        end
        stats.entries,stats.compared,stats.exhausted=tonumber(s.entries),tonumber(s.compared),s.exhausted~=0
        if start then stats.elapsed_ms=(clock.now()-start)/clock.ms(1) end
        local found={}
        for i=0,tonumber(s.count)-1 do
            local hit=self.hits[i]
            found[#found+1]={entry=entry_arrays[tonumber(hit.group)+1][tonumber(hit.index)+1],
                shape=tonumber(hit.shape),rank=tonumber(hit.rank)}
        end
        return found
    end
    return function()
        return setmetatable({state=ffi.new('TSShapeState[1]'),hits=ffi.new('TSShapeHit[64]'),
            groups=setmetatable({},{__mode='k'})},Native)
    end
end
