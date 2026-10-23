-- Bionic builds are distinct from glibc builds. External/shared storage may be
-- mounted noexec, so copy the selected library into KOReader's private files.
return function(dir, Original, ffi, deps, android)
    local function fallback(reason)
        Original.backend_reason = 'Android native unavailable: ' .. tostring(reason)
        return Original
    end
    local loaded, result = pcall(function()
        assert(ffi.os == 'Linux' and ffi.abi('le'), 'unsupported Android platform')
        local variant
        if ffi.arch == 'arm' and ffi.abi('32bit') and not ffi.abi('hardfp') then
            variant = {name='android-armeabi-v7a', class=1, machine=40, sdk=18}
        elseif ffi.arch == 'arm64' and ffi.abi('64bit') then
            variant = {name='android-arm64-v8a', class=2, machine=183, sdk=21}
        end
        assert(variant, 'unsupported Android process ABI')
        local sdk = tonumber(android.app.activity.sdkVersion)
        assert(sdk and sdk % 1 == 0 and sdk >= variant.sdk, 'unsupported Android API level')
        local read = deps.read or function(path, count)
            local f = io.open(path, 'rb')
            if not f then return nil end
            local data = f:read(count or '*a'); f:close(); return data
        end
        local filename = 'libtapless-core-' .. variant.name .. '.so'
        local source = dir .. '/native/' .. filename
        local data = assert(read(source), 'Android library missing')
        assert(#data >= (variant.class == 1 and 52 or 64)
            and data:sub(1, 7) == '\127ELF' .. string.char(variant.class, 1, 1)
            and data:byte(17) == 3 and data:byte(18) == 0
            and data:byte(19) == variant.machine and data:byte(20) == 0,
            'incompatible Android ELF library')
        if variant.class == 1 then
            assert(data:byte(40) == 5 and data:byte(38) % 8 == 2, 'incompatible Android float ABI')
        end
        -- Adler-32 identifies cache entries, not a security boundary. A full
        -- byte comparison verifies both existing and newly written entries.
        local a, b = 1, 0
        for i = 1, #data do
            a = (a + data:byte(i)) % 65521; b = (b + a) % 65521
        end
        local private = assert(android.dir, 'private application directory unavailable')
        assert(type(private) == 'string' and private:sub(1, 1) == '/', 'invalid private directory')
        local folder = private .. '/tapless-native'
        local mkdir = deps.mkdir or function(path)
            local ok, lfs = pcall(require, 'libs/libkoreader-lfs')
            if not ok then lfs = require('lfs') end
            if not lfs.attributes(path) then assert(lfs.mkdir(path)) end
            assert(lfs.attributes(path, 'mode') == 'directory', 'native cache is not a directory')
        end
        mkdir(folder)
        local cache = folder .. '/' .. filename:gsub('%.so$', '')
            .. '-' .. #data .. '-' .. string.format('%08x', b * 65536 + a) .. '.so'
        local existing = read(cache)
        if existing then
            assert(existing == data, 'native cache content mismatch')
        else
            -- Use a new inode; never write through a potentially mapped .so.
            local temporary = cache .. '.tmp-' .. tostring({}):gsub('[^%w]', '') .. '-' .. os.time()
            local file = assert(io.open(temporary, 'wb'))
            local wrote, err = file:write(data)
            local closed, close_err = file:close()
            if not wrote or not closed then
                os.remove(temporary); error(err or close_err or 'native cache write failed')
            end
            local chmod = deps.chmod or function(path)
                ffi.cdef('int chmod(const char *path, unsigned int mode);')
                return ffi.C.chmod(path, 292) == 0 -- 0444, code is read-only.
            end
            if not chmod(temporary) then os.remove(temporary); error('native cache chmod failed') end
            local renamed, rename_err = os.rename(temporary, cache)
            if not renamed then os.remove(temporary); error(rename_err) end
            assert(read(cache) == data, 'native cache copy verification failed')
        end
        if not pcall(ffi.typeof, 'TCGesture') then
            local header = assert(read(dir .. '/native/core.h'), 'native header missing')
            ffi.cdef(header)
        end
        local C = ffi.load(cache)
        assert(C.tc_abi_version() == 1 and C.tc_gesture_size() == ffi.sizeof('TCGesture')
            and C.tc_result_size() == ffi.sizeof('TCResult'), 'native ABI mismatch')
        for _, name in ipairs({'tc_new', 'tc_free', 'tc_init_distances',
            'tc_can_finish', 'tc_greedy', 'tc_align'}) do assert(C[name]) end
        local native = (deps.factory or dofile)(dir .. '/c_matcher.lua')(Original, ffi, C)
        native.backend_variant, native.backend_library = variant.name, cache
        return native
    end)
    if loaded then return result end
    return fallback(result)
end
