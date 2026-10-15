-- Native dictionary preparation and recognition, with Lua input/result packing.
-- Borrowed pointer anchors live until the call returns; C keeps its own dictionary.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
return function(ffi,C)
    if not pcall(ffi.typeof,'TERequest') then
        local f=assert(io.open(dir..'/native/engine.h','rb'))
        local h=f:read('*a');f:close();ffi.cdef(h)
    end
    assert(C.te_abi_version()==1 and C.te_request_size()==ffi.sizeof('TERequest')
        and C.te_group_size()==ffi.sizeof('TEGroup') and C.te_output_size()==ffi.sizeof('TEOutput'),'engine ABI mismatch')
    assert(C.te_run)
    local catalog_available=pcall(function()
        if not pcall(ffi.typeof,'TDQuery') then
            local f=assert(io.open(dir..'/native/store.h','rb'));local h=f:read('*a');f:close();ffi.cdef(h)
        end
        assert(C.td_abi_version()==2 and C.td_run and C.td_word and C.td_free)
    end)
    local Native={};Native.__index=Native
    local function bit(v)return v and 1 or 0 end
    local function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end
    local function integer(v,a,b)return finite(v) and v%1==0 and v>=a and v<=b end
    local function refresh(g,e,i,dictionary,language,context_bonus,previous,language_changed)
        local freq=e.freq or 0
        if g.frequencies[i]~=freq then
            if not finite(freq) then error('unsupported frequency') end
            g.scores[i-1].frequency,g.shapes[i-1].frequency=freq,freq
            g.frequencies[i]=freq
        end
        local enabled=not e.lang or e.lang==dictionary or e.lang==language
        if language_changed or g.languages[i]~=e.lang then
            g.scores[i-1].enabled,g.shapes[i-1].enabled=bit(enabled),bit(enabled)
            g.languages[i]=e.lang
        end
        local bonus=enabled and context_bonus and context_bonus(previous,e.word) or 0
        if g.bonuses[i]~=bonus then
            if not finite(bonus) then error('unsupported context bonus') end
            g.scores[i-1].context_bonus=bonus;g.bonuses[i]=bonus
        end
    end
    local function packed(self,entries,dictionary,language,context_bonus,previous)
        local g=self.groups[entries]
        if g and g.count==#entries then
            local changed=g.dictionary~=dictionary or g.language~=language
            for i,e in ipairs(entries) do
                if g.words[i]~=e.word or g.signatures[i]~=(e.gesture_signature or e.signature)
                    or g.base[i]~=e.signature or g.repeat_tables[i]~=e.repeat_positions then g=nil;break end
                refresh(g,e,i,dictionary,language,context_bonus,previous,changed)
            end
        else g=nil end
        if not g then
            g={count=#entries,words={},signatures={},base={},repeat_tables={},frequencies={},languages={},bonuses={},
                scores=ffi.new('TCScanEntry[?]',math.max(1,#entries)),
                shapes=ffi.new('TSShapeEntry[?]',math.max(1,#entries))}
            local repeats={}
            for i,e in ipairs(entries) do
                local word,sig=e.word,e.gesture_signature or e.signature
                if type(word)~='string' or type(sig)~='string' or #sig<1 or #sig>64 or sig:find('[^a-z]') then return nil end
                g.words[i],g.signatures[i],g.base[i],g.repeat_tables[i]=word,sig,e.signature,e.repeat_positions
                local v,h=g.scores[i-1],g.shapes[i-1]
                v.word,v.length=sig,#sig
                h.word,h.word_length,h.signature,h.signature_length=word,#word,sig,#sig
                h.minimum_length=#(e.signature or sig)
                refresh(g,e,i,dictionary,language,context_bonus,previous,true)
                for position,count in pairs(e.repeat_positions or {}) do
                    if not integer(position,1,#sig) or not finite(count) then return nil end
                    repeats[#repeats+1]={position,count};v.repeat_count=v.repeat_count+1
                end
            end
            g.repeats=ffi.new('TCScanRepeat[?]',math.max(1,#repeats))
            for i,v in ipairs(repeats) do g.repeats[i-1].position,g.repeats[i-1].count=v[1],v[2] end
            local offset=0
            for i=0,g.count-1 do g.scores[i].repeats=g.repeats+offset;offset=offset+g.scores[i].repeat_count end
            self.groups[entries]=g
        end
        g.dictionary,g.language=dictionary,language
        return g
    end
    function Native:candidates(engine,o)
        self.store_reason=nil
        local geom,ch,sc=engine.geometry_reranker,engine.shape_channel,engine.scoring
        local sig=o.signature
        if not geom or not ch or ch.store~=engine.dictionary_store
            or ch.personal~=engine.personal_dictionary or ch.BUDGET_MS<0 or type(sig)~='string' or not integer(#sig,1,512) or sig:find('[^a-z]')
            or not integer(o.limit or 3,1,16) or not integer(geom.SAMPLE_COUNT,2,64)
            or geom.IDEAL_CACHE_LIMIT~=128 or not integer(sc.NEAR_KEY_LIMIT,0,32)
            or not integer(sc.EDIT_DISTANCE_MAX,0,32) or not integer(ch.KEEP,1,32)
            or not integer(ch.MAX_ENTRIES,0,32768) or not integer(ch.MAX_COMPARISONS,0,1000000)
            or not integer(ch.MIN_LETTERS,0,1000000)
            or (o.context_bonus and not o.native_context_pure) then return nil end
        for _,v in ipairs({sc.SCORE_UNIT,sc.REPEAT_BONUS,sc.FIRST_LETTER_COST,sc.START_MISMATCH_COST,
                sc.ENDPOINT_MISMATCH_COST,sc.NEAR_KEY_COST,sc.NEAR_KEY_REACH,sc.NEAR_KEY_MIN_TURN,
                sc.MISSING_LETTER_COST,geom.RANK_WEIGHT,geom.MAX_SCORE,ch.MIN_RATIO,ch.MAX_RATIO,
                ch.MAX_SHAPE_SCORE,ch.SHAPE_WEIGHT,ch.ALIGNMENT_WEIGHT,ch.BUDGET_MS}) do
            if not finite(v) then return nil end
        end
        engine.fast_stats={accepted=false,attempted=false}
        local profiler=engine.profiler
        if profiler then profiler:phase('native_prepare') end
        local dictionary=o.dictionary or 'en'
        local store=engine.dictionary_store
        local paths=catalog_available and store.nativePaths and store:nativePaths(dictionary)
        if o.native_store_disable or (o.context_bonus and not o.native_context_counts) then paths=nil end
        local language,bonus_values,bonus_owners,bonus_count
        if paths then
            language=paths.data_language or dictionary
            local generation=store.native_generation or 0
            local identity=table.concat({paths.files.bucket_data,paths.files.bucket_index,
                paths.files.popular_data or '',paths.files.popular_index or ''},'\n')
            local cached=self.catalog
            if not cached or cached.identity~=store or cached.dictionary~=dictionary
                    or cached.generation~=generation or cached.paths~=identity or cached.language~=language then
                if cached then
                    ffi.gc(cached.ptr,nil);C.td_free(cached.ptr);self.catalog=nil
                end
                local ptr=C.td_open(paths.files.bucket_data,paths.files.bucket_index,
                    paths.files.popular_data,paths.files.popular_index,dictionary,language)
                if ptr==nil then return nil end
                cached={ptr=ffi.gc(ptr,function(v) C.td_free(v) end),identity=store,
                    dictionary=dictionary,generation=generation,paths=identity,language=language}
                self.catalog=cached
            end
            bonus_count=0;bonus_owners={}
            for word,count in pairs(o.native_context_counts or {}) do
                if type(word)~='string' or word:find('%z') or #word>4096 or not finite(count) or count<0 then return nil end
                if count>0 then
                    bonus_count=bonus_count+1;if bonus_count>256 then return nil end
                    bonus_owners[bonus_count]={word,math.min(3600,math.floor(600*math.log(count+1)/math.log(2)))}
                end
            end
            bonus_values=ffi.new('TDBonus[?]',math.max(1,bonus_count))
            for i,v in ipairs(bonus_owners) do bonus_values[i-1].word,bonus_values[i-1].bonus=v[1],v[2] end
        else
            local package=store:open(dictionary)
            if not package then return {} end
            language=package.descriptor.data_language or dictionary
        end
        local trace=o.trace_info or {};local points=trace.points or {};local centers=o.key_centers or {}
        if #points>4096 then return nil end
        geom:_ensureGeometry(centers)
        if self.layout~=geom.cache_geometry then
            self.groups=setmetatable({},{__mode='k'});self.layout=geom.cache_geometry
        end
        local req=self.request[0];ffi.fill(self.request,ffi.sizeof('TERequest'))
        req.signature,req.length,req.limit=sig,#sig,o.limit or 3
        req.samples,req.geometry_weight,req.geometry_max=geom.SAMPLE_COUNT,geom.RANK_WEIGHT,geom.MAX_SCORE
        req.alignment_weight,req.shape_trigger=ch.ALIGNMENT_WEIGHT,bit(ch:triggered(sig))
        req.first_cost,req.start_cost,req.end_cost=sc.FIRST_LETTER_COST,sc.START_MISMATCH_COST,sc.ENDPOINT_MISMATCH_COST
        req.near_cost,req.near_reach,req.near_limit=sc.NEAR_KEY_COST,sc.NEAR_KEY_REACH,sc.NEAR_KEY_LIMIT
        req.min_turn,req.missing_cost=sc.NEAR_KEY_MIN_TURN,sc.MISSING_LETTER_COST
        req.shape_budget_ms=engine.native_no_deadline and -1 or ch.BUDGET_MS
        for c=0,25 do
            local v=centers[c+97]
            if v then
                if not finite(v.x) or not finite(v.y) or not finite(v.size or 1) then return nil end
                req.centers[c].present=1;req.centers[c].x,req.centers[c].y,req.centers[c].size=v.x,v.y,v.size or 1
            end
        end
        local pp=ffi.new('TEPoint[?]',math.max(1,#points))
        local first,last
        for i,v in ipairs(points) do
            if not finite(v.x) or not finite(v.y) then return nil end
            pp[i-1].x,pp[i-1].y,pp[i-1].present,pp[i-1].letter=v.x,v.y,1,bit(v.letter or v.letter_index)
            if v.letter or v.letter_index then first=first or i;last=i end
        end
        req.points,req.point_count=pp,#points
        local lp=ffi.new('TEPoint[?]',#sig+1)
        local weights,turns,repeats=ffi.new('double[?]',#sig+1),ffi.new('double[?]',#sig+1),ffi.new('double[?]',#sig+1)
        local observed=ffi.new('unsigned char[?]',#sig+1)
        req.has_letter_points,req.has_observations,req.has_endpoint=bit(trace.letter_points),bit(trace.observations),bit(trace.endpoint_pos)
        local function point(p,v)
            if not v then return true end
            if not finite(v.x) or not finite(v.y) then return false end
            lp[p].present,lp[p].x,lp[p].y=1,v.x,v.y;return true
        end
        if not point(0,trace.endpoint_pos) then return nil end
        for p=1,#sig do
            if not point(p,trace.letter_points and trace.letter_points[p]) then return nil end
            local v=trace.observations and trace.observations[p]
            weights[p],turns[p],repeats[p]=(v and v.intent or 1),(v and v.signed_turn or 0),(v and v.repeat_confidence or 0)
            observed[p]=bit(v)
            if not finite(tonumber(weights[p])) or not finite(tonumber(turns[p])) or not finite(tonumber(repeats[p])) then return nil end
        end
        req.letter_points,req.weights,req.turns,req.repeats,req.observed=lp,weights,turns,repeats,observed
        req.scoring.edit_limit,req.scoring.score_unit,req.scoring.repeat_bonus=sc.EDIT_DISTANCE_MAX,sc.SCORE_UNIT,sc.REPEAT_BONUS
        req.scoring.repeat_confidence=repeats
        local gate=engine.fast_gate and engine.fast_gate.policy
        if gate then
            if not integer(gate.min_length,0,512) then return nil end
            for _,v in ipairs({gate.min_length,gate.boundary,gate.shape,gate.spatial,gate.margin}) do if not finite(v) then return nil end end
            req.gate_enabled,req.gate_min_length=1,gate.min_length
            req.gate_boundary,req.gate_shape,req.gate_spatial,req.gate_margin=gate.boundary,gate.shape,gate.spatial,gate.margin
        end
        local groups,owners,entries_by_id,map,scans,shape_pairs,queries={}, {}, {}, {}, {}, {}, {}
        local function group(entries)
            if not entries then entries=self.empty end
            if map[entries] then return map[entries] end
            local g=packed(self,entries,dictionary,language,o.context_bonus,trace.previous_word);if not g then error('unsupported dictionary entry') end
            local id=#groups
            groups[id+1]=g;owners[id+1]=g;entries_by_id[id+1]=entries;map[entries]=id
            queries[id+1]={kind=-1}
            return id
        end
        local function native_group(a,b,length,kind)
            local key=kind..':'..a..':'..b..':'..length
            if map[key] then return map[key] end
            local id=#groups;groups[id+1]={count=0};map[key]=id
            queries[id+1]={first=a:byte()-97,last=b:byte()-97,length=length,kind=kind}
            return id
        end
        local personal=engine.personal_dictionary
        local function bucket(a,b,ends,start,phase)
            local p=personal and personal:getBucket(a,b,dictionary,o.normalization_profile)
            scans[#scans+1]={group(p and p.entries),bit(start),bit(ends),phase}
            local normal=not paths and store:loadBucket(a,b,dictionary)
            for n=2,math.min(14,#sig) do
                scans[#scans+1]={paths and native_group(a,b,n,0) or group(normal and normal.by_gesture_length[n]),bit(start),bit(ends),phase}
            end
        end
        local a,b=sig:sub(1,1),sig:sub(-1)
        local starts,ends={a},{b}
        if #sig>=3 and o.trace_info then
            if o.start_letters then starts=o.start_letters(a) end
            if trace.endpoint_pos and o.endpoint_letters then ends=o.endpoint_letters(b) end
        end
        bucket(a,b,false,false,0)
        for i=2,#ends do bucket(a,ends[i],true,false,1) end
        for i=2,#starts do bucket(starts[i],b,false,true,1) end
        for i=2,#starts do for j=2,#ends do bucket(starts[i],ends[j],true,true,1) end end
        -- Preload potential fallback too: its real cost belongs in the benchmark.
        if paths then
            scans[#scans+1]={native_group(a,b,0,1),0,0,2}
        else
            local fallback=store:loadPopularWords(a,dictionary)
            if not fallback then fallback=store:loadFirstBuckets(a,dictionary) end
            scans[#scans+1]={group(fallback),0,0,2}
        end
        if req.shape_trigger~=0 and #points>=2 then
            first,last=first or 1,last or #points
            if last>first then
                local ps,pe=ch:_lettersNear(points[first],centers),ch:_lettersNear(points[last],centers)
                for _,x in ipairs(ps) do for _,y in ipairs(pe) do
                    local pb=personal and personal:getBucket(x,y,dictionary,o.normalization_profile)
                    local nb=not paths and store:loadBucket(x,y,dictionary)
                    shape_pairs[#shape_pairs+1]={pb and group(pb.entries) or -1,paths and native_group(x,y,0,0) or group(nb and nb.entries)}
                end end
            end
        end
        local gg=ffi.new('TEGroup[?]',math.max(1,#groups))
        for i,g in ipairs(groups) do gg[i-1].scores,gg[i-1].shapes,gg[i-1].count=g.scores,g.shapes,g.count end
        local ss=ffi.new('TEScan[?]',#scans)
        for i,v in ipairs(scans) do ss[i-1].group,ss[i-1].start,ss[i-1]['end'],ss[i-1].fallback=v[1],v[2],v[3],v[4] end
        local sp=ffi.new('TEShapePair[?]',math.max(1,#shape_pairs))
        for i,v in ipairs(shape_pairs) do sp[i-1].personal,sp[i-1].normal=v[1],v[2] end
        req.groups,req.group_count,req.scans,req.scan_count,req.pairs,req.pair_count=gg,#groups,ss,#scans,sp,#shape_pairs
        local capacity=2;while capacity<2*ch.MAX_ENTRIES do capacity=capacity*2 end
        if self.capacity~=capacity then
            self.capacity=capacity;self.words=ffi.new('TSWordSlot[?]',capacity);self.signatures=ffi.new('TSSignatureSlot[?]',capacity)
            self.shape[0].generation=0
        end
        local state=self.shape[0]
        state.words,state.signatures,state.hits=self.words,self.signatures,self.hits
        state.capacity,state.keep,state.max_entries,state.max_comparisons=capacity,ch.KEEP,ch.MAX_ENTRIES,ch.MAX_COMPARISONS
        state.min_letters,state.min_ratio,state.max_ratio=ch.MIN_LETTERS,ch.MIN_RATIO,ch.MAX_RATIO
        state.max_shape,state.shape_weight=ch.MAX_SHAPE_SCORE,ch.SHAPE_WEIGHT
        -- Retain every owner until C returns; C does not dereference borrowed strings after this call.
        local qq,tdstats
        if paths then
            qq=ffi.new('TDQuery[?]',#queries);tdstats=ffi.new('TDStats[1]')
            for i,q in ipairs(queries) do
                qq[i-1].kind=q.kind
                qq[i-1].first,qq[i-1].last,qq[i-1].length=q.first or 0,q.last or 0,q.length or 0
            end
        end
        self.anchors={sig,pp,lp,weights,turns,repeats,observed,gg,ss,sp,owners,entries_by_id,qq,bonus_values,bonus_owners}
        if profiler then profiler:phase('native_compute') end
        local ok
        if paths then
            ok=C.td_run(self.catalog.ptr,qq,bonus_values,bonus_count,self.matcher.context,self.workspace,
                self.request,self.shape,self.output,tdstats)
            self.store_calls=(self.store_calls or 0)+1
            self.store_stats={wall_ms=tonumber(tdstats[0].wall_ms),cpu_ms=tonumber(tdstats[0].cpu_ms),
                loaded=tonumber(tdstats[0].loaded),entries=tonumber(tdstats[0].entries)}
        else
            ok=C.te_run(self.matcher.context,self.workspace,self.request,self.shape,self.output)
            self.store_stats=nil
        end
        self.calls=self.calls+1
        if ok<=0 then
            if ok==-1 then
                self.repeat_guard_fallbacks=(self.repeat_guard_fallbacks or 0)+1
                local guarded_stats=self.store_stats
                local options={};for key,value in pairs(o) do options[key]=value end
                options.native_store_disable=true
                local counts=o.native_context_counts or {}
                options.context_bonus=function(_,word)
                    local count=counts[word] or 0
                    if count<=0 then return 0 end
                    return math.min(3600,math.floor(600*math.log(count+1)/math.log(2)))
                end
                options.native_context_pure=true
                self.anchors=nil
                local result=self:candidates(engine,options)
                self.store_stats=guarded_stats;guarded_stats.fallback=true
                self.store_reason='repeat-order rounding compatibility'
                return result
            end
            self.anchors=nil;return nil
        end
        if profiler then profiler:phase('native_results') end
        local out=self.output[0];local results={}
        local view=paths and ffi.new('TDWord[1]')
        local function entry(group_id,index)
            local id=tonumber(group_id)+1;local at=tonumber(index)
            if entries_by_id[id] then return entries_by_id[id][at+1] end
            assert(paths and C.td_word(self.catalog.ptr,qq[id-1],at,view)~=0,'missing native result')
            return {word=ffi.string(view[0].word),signature=ffi.string(view[0].signature),
                gesture_signature=ffi.string(view[0].gesture_signature)}
        end
        for i=0,out.count-1 do
            local h=out.hits[i];local e=entry(h.group,h.index)
            local v={word=e.word,signature=e.signature,spatial_score=tonumber(h.spatial),ranked_score=tonumber(h.ranked)}
            if out.fallback==0 then
                v.gesture_signature=e.gesture_signature or e.signature;v.personal=e.personal==true
                if h.has_geometry~=0 then v.geometry_score=tonumber(h.geometry) end
            end
            results[i+1]=v
        end
        local g=out.gate;local stats={accepted=g.accepted~=0,attempted=g.attempted~=0}
        local reasons={'trace','boundary','competition','geometry','scale','length','shape','spatial','margin','accepted'}
        if g.reason~=0 then stats.reason=reasons[tonumber(g.reason)] end
        if g.has_boundary~=0 then stats.start,stats.endpoint=tonumber(g.start),tonumber(g.endpoint) end
        if g.has_choice~=0 then
            stats.word=entry(g.group,g.index).word;stats.length,stats.shape,stats.spatial,stats.margin=tonumber(g.length),tonumber(g.shape),tonumber(g.spatial),tonumber(g.margin)
            if g.reason~=4 then stats.stable,stats.alt_margin=g.stable~=0,tonumber(g.alt_margin) end
        end
        engine.fast_stats=stats
        self.last_stats={scan_calls=tonumber(out.scan_calls),scan_words=tonumber(out.scan_words),dynamic_calls=tonumber(out.dynamic_calls)}
        ch.last_stats={entries=tonumber(out.shape_entries),compared=tonumber(out.shape_compared),buckets=tonumber(out.shape_buckets),
            exhausted=out.shape_exhausted~=0,backend='whole-c',native_calls=tonumber(out.shape_calls)}
        self.anchors=nil
        return results
    end
    return function(matcher)
        local memory=ffi.new('double[?]',math.ceil(C.te_workspace_size()/8))
        return setmetatable({matcher=matcher,storage=memory,workspace=ffi.cast('TEWorkspace *',memory),
            request=ffi.new('TERequest[1]'),output=ffi.new('TEOutput[1]'),shape=ffi.new('TSShapeState[1]'),
            hits=ffi.new('TSShapeHit[64]'),groups=setmetatable({},{__mode='k'}),empty={},calls=0,store_available=catalog_available},Native)
    end
end
