-- CalypsoPlus #1794 / EBC3.36 only: real trace, latest-frame coalescing.
local M = {}
function M.open(env)
    env=env or {}
    local ffi=env.ffi or require('ffi')
    local C=env.C or ffi.C
    assert(ffi.sizeof('void*')==4,'ARM32 userspace required')
    for name,decl in pairs({
        open='int open(const char*,int,...);', close='int close(int);',
        ioctl='int ioctl(int,unsigned long,...);',
        mmap='void *mmap(void*,unsigned long,int,int,int,long);',
        munmap='int munmap(void*,unsigned long);',
    }) do
        if not pcall(function() return C[name] end) then ffi.cdef(decl) end
    end
    local function read(path)
        if env.read then return env.read(path) end
        local f=assert(io.open(path,'r'),path);local v=f:read('*a');f:close();return v
    end
    assert(read('/proc/ebc_version'):match('software: 3%.36'),'EBC version mismatch')
    assert(read('/proc/version'):find('#1794',1,true),'kernel build mismatch')
    assert(read('/sys/devices/platform/eink/waveform_version'):match('ED060XCDU2'),'panel mismatch')
    local fd=C.open('/dev/ebc',0x80000+0x800+2) -- O_RDWR|NONBLOCK|CLOEXEC
    assert(fd>=0,'EBC open errno '..ffi.errno())
    local self={fd=fd,ffi=ffi,C=C,closed=false}
    self.last_timing={reserve_us=0,copy_us=0,send_us=0}
    function self:idle() return read('/proc/ebc_idle'):match('^%s*1%s*$')~=nil end
    function self:close()
        if self.closed then return end
        if self.map then self.C.munmap(self.map,self.length);self.map=nil end
        self.C.close(self.fd);self.fd=-1;self.closed=true
    end
    local ok,err=pcall(function()
        self.info=ffi.new('int32_t[16]')
        assert(C.ioctl(fd,0x7003,ffi.cast('void*',self.info))==0,'GET_INFO failed')
        local i=self.info
        assert(i[2]==758 and i[3]==1024 and i[4]==758 and i[5]==1024
            and i[6]==1024 and i[7]==758 and i[8]==0,'geometry mismatch')
        self.width=1024;self.height=758;self.bytes=1024*758/2
        self.length=1024*758*3
        local map=C.mmap(nil,self.length,3,1,fd,0) -- READ|WRITE, SHARED
        assert(map~=ffi.cast('void*',-1),'EBC mmap failed')
        self.map=ffi.cast('uint8_t*',map)
        self.current=ffi.new('int32_t[16]')
        self.reserved=ffi.new('int32_t[16]')
        self.send=ffi.new('int32_t[16]')
        self.current_ptr=ffi.cast('void*',self.current)
        self.reserved_ptr=ffi.cast('void*',self.reserved)
        self.send_ptr=ffi.cast('void*',self.send)
        self.slots={}
        for n=0,5 do self.slots[n]=self.map+n*self.bytes end
        self.original=ffi.new('uint8_t[?]',self.bytes)
        self.marked=ffi.new('uint8_t[?]',self.bytes)
        self.restored=ffi.new('uint8_t[?]',self.bytes)
        self.last_sent=ffi.new('uint8_t[?]',self.bytes)
        -- Even X, byte-aligned; safely inside the physical panel.
        self.region={x=384,y=372,w=256,h=12}
        self.expected_geometry={}
        for n=2,8 do self.expected_geometry[n]=tonumber(i[n]) end
    end)
    if not ok then self:close();error(err) end
    local function valid_offset(offset)
        return offset>=0 and offset%self.bytes==0 and offset+self.bytes<=self.length
    end
    function self:snapshot()
        assert(not self.closed and self:idle(),'EBC busy')
        -- Current displayed buffer: confirmed non-allocating ioctl in CURRENT kernel.
        assert(self.C.ioctl(self.fd,0x7002,ffi.cast('void*',self.current))==0,'GET_CURRENT failed')
        local offset=tonumber(self.current[0])
        assert(valid_offset(offset),'current offset outside mapped pool')
        ffi.copy(self.original,self.map+offset,self.bytes)
        ffi.copy(self.marked,self.original,self.bytes)
        return offset
    end
    local function submit(payload,mode)
        assert(not self.closed,'EBC closed') -- intentionally submit while the waveform is busy
        -- All allocations and input validation happen BEFORE acquiring a buffer.
        ffi.fill(self.send,64,0)
        for n=2,8 do self.send[n]=self.expected_geometry[n] end
        self.send[14]=tonumber(self.info[14]);self.send[15]=tonumber(self.info[15])
        -- Unused output fields from GET_INFO are deliberately not propagated.
        self.send[13]=0
        local r=self.region
        assert((mode==2 or mode==3) and r.x>=0 and r.y>=0 and r.w>0 and r.h>0
            and r.x%2==0 and r.w%2==0 and r.x+r.w<=1024 and r.y+r.h<=758,'invalid EBC region/mode')
        self.send[1]=mode -- A2=2 for both series, PART=3 for cleanup; per buffer only
        self.send[9]=r.x;self.send[10]=r.y;self.send[11]=r.x+r.w;self.send[12]=r.y+r.h
        local t0=env.now and env.now() or 0
        local rc=self.C.ioctl(self.fd,0x7000,self.reserved_ptr)
        if rc~=0 then error('GET_BUFFER failed '..tonumber(rc)) end
        local offset=tonumber(self.reserved[0])
        -- Firmware/geometry guards ensure the same pool contract as system HWC.
        -- An unexpected offset disables this backend; never write outside mapping.
        assert(valid_offset(offset),'reserved offset outside mapped pool')
        self.send[0]=offset
        local t1=env.now and env.now() or 0
        ffi.copy(self.slots[offset/self.bytes],payload,self.bytes)
        local t2=env.now and env.now() or 0
        rc=self.C.ioctl(self.fd,0x7001,self.send_ptr)
        if rc~=0 then error('SEND_BUFFER failed '..tonumber(rc)) end
        local t3=env.now and env.now() or 0
        self.last_timing.reserve_us=t1-t0
        self.last_timing.copy_us=t2-t1
        self.last_timing.send_us=t3-t2
        return offset
    end
    function self:submit_payload(payload,mode) return submit(payload,mode) end
    return self
end
local function readbytes(path)
    local f=io.open(path,'rb');if not f then return end
    local b=f:read('*a');f:close();return b
end
function M.attach(b,o)
    local ffi=b.ffi
    ffi.cdef[[int tapless_trace_pack(uint8_t*,const uint8_t*,int,int,int,int);
      int tapless_trace_compare(const uint8_t*,const uint8_t*,int,int,int,int,uint32_t[4]);
      int tapless_trace_pack_rect(uint8_t*,const uint8_t*,int,int,int,int,int,int,int,int);
      int chmod(const char*,unsigned int);
      int tapless_finish_snapshot(uint32_t*,const uint8_t*,int);
      int tapless_finish_diff(const uint32_t*,const uint8_t*,int,int[5]);]]
    local info=dofile(o.plugin_dir..'/ebc_assets.lua')
    local bytes=assert(readbytes(o.plugin_dir..'/'..info.library),'pixel helper missing')
    local lfs=require('libs/libkoreader-lfs')
    local dir=o.android.dir..'/tapless-ebc-native'
    if not lfs.attributes(dir) then assert(lfs.mkdir(dir)) end
    local path=dir..'/'..info.name
    if readbytes(path)~=bytes then
        assert(not lfs.attributes(path),'pixel helper cache collision')
        local temp=path..'.pending';local f=assert(io.open(temp,'wb'))
        assert(f:write(bytes));assert(f:close());assert(ffi.C.chmod(temp,292)==0)
        assert(os.rename(temp,path))
    end
    assert(readbytes(path)==bytes,'pixel helper copy mismatch')
    local lib=ffi.load(path);b.pixel_lib=lib
    local stats=ffi.new('uint32_t[4]')
    local function source(bb)
        assert(bb and tonumber(bb.w)==758 and tonumber(bb.h)==1024
            and bb:getRotation()==0 and bb:getType()==5,'expected full portrait RGB32 shadow buffer')
        assert(tonumber(bb.stride)>=3032 and tonumber(bb.stride)<=16384,'unexpected RGB stride')
        return ffi.cast('const uint8_t*',bb.data),tonumber(bb.stride),bb:getInverse()
    end
    function b:calibrate(bb)
        local data,stride,inverse=source(bb)
        self:snapshot() -- read-only, only on a settled keyboard
        local candidates={}
        for turn=0,1 do for high=0,1 do
            assert(lib.tapless_trace_compare(self.original,data,stride,inverse,turn,high,stats)==0)
            local all=tonumber(stats[1])/tonumber(stats[0])
            local count=tonumber(stats[2])
            local contrast=count>0 and tonumber(stats[3])/count or 99
            candidates[#candidates+1]={turn=turn,high=high,all=all,contrast=contrast,count=count,score=contrast+all/4}
        end end
        table.sort(candidates,function(a,c) return a.score<c.score end)
        local best=candidates[1]
        self.calibration_candidates=candidates
        assert(best.count>=200 and best.all<2 and best.contrast<2.5
            and candidates[2].score-best.score>1,'pixel mapping calibration ambiguous')
        self.turn=best.turn;self.high=best.high;self.inverse=inverse;self.calibrated=true
        self.cache_valid=false
        return candidates
    end
    local finish_before=ffi.new('uint32_t[?]',758*1024)
    local finish_result=ffi.new('int[5]')
    function b:snapshot_finish(bb)
        local data,stride,inverse=source(bb)
        assert(lib.tapless_finish_snapshot(finish_before,data,stride)==0,'finish snapshot failed')
        self.finish_source=data;self.finish_inverse=inverse;self.finish_stride=stride
    end
    function b:diff_finish(bb)
        local data,stride,inverse=source(bb)
        assert(data==self.finish_source and inverse==self.finish_inverse and stride==self.finish_stride,
            'finish source changed')
        assert(lib.tapless_finish_diff(finish_before,data,stride,finish_result)==0,'finish diff failed')
        return {x=tonumber(finish_result[0]),y=tonumber(finish_result[1]),
            w=tonumber(finish_result[2]),h=tonumber(finish_result[3]),pixels=tonumber(finish_result[4])}
    end
    function b:invalidate() self.cache_valid=false end
    function b:prepare_bb(bb,logical)
        assert(self.calibrated,'pixel helper not calibrated')
        local data,stride,inverse=source(bb)
        assert(inverse==self.inverse,'inverse changed during gesture')
        local x=math.max(0,math.floor(logical.x));local y=math.max(0,math.floor(logical.y))
        local x2=math.min(758,math.ceil(logical.x+logical.w))
        local y2=math.min(1024,math.ceil(logical.y+logical.h))
        assert(x2>x and y2>y,'empty EBC region')
        local px,py,pw,ph
        if self.turn==0 then px=y;py=758-x2;pw=y2-y;ph=x2-x
        else px=1024-y2;py=x;pw=y2-y;ph=x2-x end
        local right=math.min(1024,2*math.ceil((px+pw)/2));px=2*math.floor(px/2)
        self.region={x=px,y=py,w=right-px,h=ph}
        local before=o.time.monotonic()
        local full=not self.cache_valid or self.cache_data~=data or self.cache_stride~=stride
        if full then
            -- Full conversion once after ordinary UI changes/clear/new source.
            assert(lib.tapless_trace_pack(self.marked,data,stride,inverse,self.turn,self.high)==0,'pixel packing failed')
        else
            -- Refresh ALL previous stroke pixels, not just the newest segment:
            -- pending frames may be discarded by the driver's latest-frame queue.
            assert(lib.tapless_trace_pack_rect(self.marked,data,stride,inverse,self.turn,self.high,
                x,y,x2-x,y2-y)==0,'region pixel packing failed')
        end
        self.cache_valid=true;self.cache_data=data;self.cache_stride=stride
        self.last_timing.pack_us=o.time.monotonic()-before
        self.last_timing.pack_full=full
        self.last_timing.pack_pixels=full and 758*1024 or (x2-x)*2*(math.ceil(y2/2)-math.floor(y/2))
        return self.marked
    end
    function b:submit_bb(bb,logical,mode)
        local payload=self:prepare_bb(bb,logical)
        return self:submit_payload(payload,mode)
    end
    return b
end
return M
