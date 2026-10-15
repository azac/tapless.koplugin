-- Experimental adapter: one native scoring call per dictionary entry array.
-- Dictionary words/repeat metadata are immutable; appended entries invalidate
-- the packed group. Frequencies and context bonuses are refreshed each call.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
return function(Matcher, ffi, C, geometry)
    local f=assert(io.open(dir..'/native/scan.h','rb'))
    local header=f:read('*a'); f:close()
    if not pcall(ffi.typeof,'TCScanEntry') then ffi.cdef(header) end
    assert(C.tc_scan_version()==1 and C.tc_scan_entry_size()==ffi.sizeof('TCScanEntry')
        and C.tc_scan_policy_size()==ffi.sizeof('TCScanPolicy')
        and C.tc_scan_result_size()==ffi.sizeof('TCScanResult'), 'batch ABI mismatch')

    local function pack(entries)
        local count=#entries
        local group={count=count, words={}, repeat_tables={},
            entries=ffi.new('TCScanEntry[?]',count),
            results=ffi.new('TCScanResult[?]',count)}
        local repeats={}
        for i,entry in ipairs(entries) do
            local word=entry.gesture_signature or entry.signature
            if type(word)~='string' or #word>64 or word:find('[^a-z]') then return nil end
            group.words[i]=word -- Anchor strings referenced by FFI pointers.
            group.repeat_tables[i]=entry.repeat_positions
            local e=group.entries[i-1]
            e.word,e.length=word,#word
            e.repeat_count=0
            for position,n in pairs(entry.repeat_positions or {}) do
                if type(position)=='number' and position%1==0 and position>=1 and position<=#word then
                    repeats[#repeats+1]={position,n}
                    e.repeat_count=e.repeat_count+1
                end
            end
        end
        group.repeats=ffi.new('TCScanRepeat[?]',#repeats)
        for i,r in ipairs(repeats) do
            group.repeats[i-1].position,group.repeats[i-1].count=r[1],r[2]
        end
        local offset=0
        for i=0,count-1 do
            group.entries[i].repeats=group.repeats+offset
            offset=offset+group.entries[i].repeat_count
        end
        return group
    end

    function Matcher:scanEntries(signature, entries, data, nexts, trace, centers,
            start, ends, near, dictionary, language, context_bonus, work)
        if self.policy.EDIT_DISTANCE_MAX<0 or self.policy.EDIT_DISTANCE_MAX>32
            or self.policy.EDIT_DISTANCE_MAX%1~=0 or #signature~=data.size
            or signature:find('[^a-z]') or not entries or #entries==0 then return nil end
        self.scan_groups=self.scan_groups or setmetatable({}, {__mode='k'})
        local group=self.scan_groups[entries]
        if group and group.count==#entries then
            for i,entry in ipairs(entries) do
                if group.words[i]~=(entry.gesture_signature or entry.signature)
                    or group.repeat_tables[i]~=entry.repeat_positions then group=nil; break end
            end
        else group=nil end
        if not group then
            group=pack(entries)
            if not group then self.scan_fallbacks=(self.scan_fallbacks or 0)+1; return nil end
            self.scan_groups[entries]=group
        end
        local h=self:packed('a',data,near)
        if not h then self.scan_fallbacks=(self.scan_fallbacks or 0)+1; return nil end
        local points=trace and trace.letter_points
        geometry(h,data,points,trace and trace.endpoint_pos,centers)
        if not h.scan_policy then
            h.scan_policy=ffi.new('TCScanPolicy[1]')
            h.repeat_confidence=ffi.new('double[?]',data.size+1)
            for p=1,data.size do
                local observation=trace and trace.observations and trace.observations[p]
                h.repeat_confidence[p]=observation and observation.repeat_confidence or 0
            end
            h.scan_policy[0].repeat_confidence=h.repeat_confidence
        end
        local policy=h.scan_policy[0]
        policy.start,policy['end'],policy.near=start and 1 or 0,ends and 1 or 0,near and 1 or 0
        policy.points,policy.has_next=points and 1 or 0,nexts and 1 or 0
        policy.edit_limit=self.policy.EDIT_DISTANCE_MAX
        policy.score_unit,policy.repeat_bonus=self.policy.SCORE_UNIT,self.policy.REPEAT_BONUS
        -- Match the scalar callback order, including ultimately rejected words.
        for i,entry in ipairs(entries) do
            local e=group.entries[i-1]
            local enabled=not entry.lang or entry.lang==dictionary or entry.lang==language
            e.enabled=enabled and 1 or 0
            if enabled then
                e.frequency=entry.freq or 0
                e.context_bonus=context_bonus and context_bonus(trace and trace.previous_word,entry.word) or 0
            end
        end
        C.tc_scan(h.g,signature,#signature,group.entries,#entries,h.scan_policy,group.results)
        self.scan_calls=(self.scan_calls or 0)+1
        self.scan_words=(self.scan_words or 0)+#entries
        return group
    end
end
