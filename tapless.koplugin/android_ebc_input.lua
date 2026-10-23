-- The Java helper applies per-window input changes on Android's UI thread.
-- Restricted to the API 27 installation whose ViewRootImpl was inspected.
local Bridge={}
Bridge.__index=Bridge
local function read(path)
    local f=io.open(path,'rb');if not f then return end
    local data=f:read('*a');f:close();return data
end

function Bridge:new(o)
    return setmetatable({o=o},self)
end

function Bridge:context(fn)
    local ffi=self.ffi;local vm=self.o.android.app.activity.vm
    local env=ffi.new('JNIEnv*[1]')
    local attached=false
    local result=vm[0].GetEnv(vm,ffi.cast('void**',env),0x00010006)
    if result==-2 then
        assert(vm[0].AttachCurrentThread(vm,env,nil)==0,'JNI attach failed');attached=true
    else assert(result==0,'JNI environment unavailable') end
    local e=env[0]
    assert(e[0].PushLocalFrame(e,64)==0,'JNI local frame failed')
    local ok,value=pcall(fn,e,e[0])
    if e[0].ExceptionCheck(e)~=0 then e[0].ExceptionClear(e);ok=false;value='JNI exception' end
    e[0].PopLocalFrame(e,nil)
    if attached then vm[0].DetachCurrentThread(vm) end
    assert(ok,value)
    return value
end

function Bridge:check(env,j,value,label)
    if j.ExceptionCheck(env)~=0 then j.ExceptionClear(env);error('JNI '..label) end
    assert(value~=nil,'JNI '..label..' unavailable')
    return value
end

function Bridge:install()
    local o=self.o;local android=o.android
    if not android or tonumber(android.app.activity.sdkVersion)~=27 then return nil,'API 27 required' end
    self.ffi=require('ffi')
    local lfs=o.lfs or require('libs/libkoreader-lfs')
    local folder=android.dir..'/tapless-ebc-input'
    if not lfs.attributes(folder) then assert(lfs.mkdir(folder)) end
    local bytes=assert(read(o.jar),'input helper missing')
    -- Content identity changes the inode/path; never replace an already loaded helper.
    local a,b=1,0
    for i=1,#bytes do a=(a+bytes:byte(i))%65521;b=(b+a)%65521 end
    local path=folder..'/input-'..#bytes..'-'..string.format('%08x',b*65536+a)..'.jar'
    if read(path)~=bytes then
        assert(not lfs.attributes(path),'helper cache collision')
        local temp=path..'.tmp';local f=assert(io.open(temp,'wb'));assert(f:write(bytes));assert(f:close())
        self.ffi.cdef'int chmod(const char*, unsigned int);'
        assert(self.ffi.C.chmod(temp,292)==0,'helper chmod failed')
        assert(os.rename(temp,path))
    end
    assert(read(path)==bytes,'helper copy mismatch')
    self:context(function(env,j)
        local function check(v,label) return self:check(env,j,v,label) end
        local function method(object,name,signature)
            local class=check(j.GetObjectClass(env,object),'object class')
            return check(j.GetMethodID(env,class,name,signature),name)
        end
        local activity=android.app.activity.clazz
        local parent=check(j.CallObjectMethodA(env,activity,method(activity,'getClassLoader','()Ljava/lang/ClassLoader;'),nil),'parent loader')
        local class=check(j.FindClass(env,'dalvik/system/DexClassLoader'),'DexClassLoader')
        local constructor=check(j.GetMethodID(env,class,'<init>','(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V'),'dex constructor')
        local args=self.ffi.new('jvalue[4]')
        args[0].l=check(j.NewStringUTF(env,path),'helper path')
        args[1].l=check(j.NewStringUTF(env,folder),'optimized path')
        args[2].l=nil;args[3].l=parent
        local loader=check(j.NewObjectA(env,class,constructor,args),'helper loader')
        local name=self.ffi.new('jvalue[1]');name[0].l=check(j.NewStringUTF(env,'tapless.input.UnbufferedProbe'),'helper class name')
        local helper=check(j.CallObjectMethodA(env,loader,method(loader,'loadClass','(Ljava/lang/String;)Ljava/lang/Class;'),name),'load helper')
        self.class=check(j.NewGlobalRef(env,helper),'helper global reference')
        self.methods={}
        for key,signature in pairs({setMode='(Ljava/lang/Object;Z)V',status='()Ljava/lang/String;',enabled='()Z'}) do
            self.methods[key]=check(j.GetStaticMethodID(env,self.class,key,signature),key)
        end
    end)
    return self
end

function Bridge:setMode(enabled)
    return self:context(function(env,j)
        local args=self.ffi.new('jvalue[2]');args[0].l=self.o.android.app.activity.clazz;args[1].z=enabled and 1 or 0
        j.CallStaticVoidMethodA(env,self.class,self.methods.setMode,args)
        self:check(env,j,true,'setMode')
    end)
end

function Bridge:status()
    return self:context(function(env,j)
        local value=self:check(env,j,j.CallStaticObjectMethodA(env,self.class,self.methods.status,nil),'status')
        local chars=self:check(env,j,j.GetStringUTFChars(env,value,nil),'status UTF')
        local result=self.ffi.string(chars);j.ReleaseStringUTFChars(env,value,chars)
        return result
    end)
end

function Bridge:enabled()
    return self:context(function(env,j)
        local value=j.CallStaticBooleanMethodA(env,self.class,self.methods.enabled,nil)
        self:check(env,j,true,'enabled');return value~=0
    end)
end

function Bridge:close()
    if not self.class then return end
    self:setMode(false)
    -- The queued UI Runnable retains its own Java class until restoration completes.
    self:context(function(env,j) j.DeleteGlobalRef(env,self.class) end)
    self.class=nil
end

return Bridge
