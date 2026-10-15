-- Match the process ABI, CPU features and libc, never a device-model whitelist.
-- Keep the previously validated ARM hard-float binary first on newer systems.
return function(dir, Original, dependencies)
    local deps = dependencies or {}
    local read = deps.read or function(path, count)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local value = f:read(count or '*a')
        f:close()
        return value
    end
    local function fallback(reason)
        Original.backend_reason = reason
        return Original
    end
    local ok, ffi = pcall(deps.require_ffi or function() return require('ffi') end)
    if not ok then return fallback('FFI unavailable') end
    if ffi.os ~= 'Linux' or ffi.arch ~= 'arm' or not ffi.abi('32bit')
        or not ffi.abi('le') then return fallback('unsupported platform ABI') end
    local hardfp = ffi.abi('hardfp')
    local cpu = read('/proc/cpuinfo') or ''
    local count = 0
    for features in cpu:gmatch('[Ff]eatures%s*:%s*([^\n]+)') do
        count = count + 1
        features = ' ' .. features .. ' '
        if not features:match('%sneon%s') or not features:match('%svfpv3%s') then
            return fallback('CPU lacks NEON or VFPv3')
        end
    end
    local architectures = 0
    for architecture in cpu:gmatch('CPU architecture%s*:%s*(%d+)') do
        architectures = architectures + 1
        if tonumber(architecture) ~= 7 then
            return fallback('ARMv7 CPU could not be confirmed')
        end
    end
    if count == 0 or architectures == 0 then
        return fallback('ARMv7 CPU could not be confirmed')
    end
    local libc_ok, major, minor = pcall(function()
        ffi.cdef('const char *gnu_get_libc_version(void);')
        local a, b = ffi.string(ffi.C.gnu_get_libc_version()):match('^(%d+)%.(%d+)')
        assert(a and b, 'invalid libc version')
        return tonumber(a), tonumber(b)
    end)
    if not libc_ok then return fallback('glibc unavailable: ' .. tostring(major)) end
    local variants = hardfp and {
        {name='armv7-hf-current', file='libtapless-core.so', minor=17},
        {name='armv7-hf-glibc215', file='libtapless-core-armv7-hf-glibc215.so', minor=15},
    } or {
        {name='armv7-softfp-glibc212', file='libtapless-core-armv7-softfp-glibc212.so', minor=12},
        {name='armv7-softfp-glibc25', file='libtapless-core-armv7-softfp-glibc25.so', minor=5},
    }
    local errors = {}
    for _, variant in ipairs(variants) do
        if major > 2 or major == 2 and minor >= variant.minor then
            local loaded, native = pcall(function()
                local path = dir .. '/native/' .. variant.file
                local elf = assert(read(path, 52), 'native library missing')
                assert(#elf == 52 and elf:sub(1, 7) == '\127ELF\1\1\1'
                    and elf:byte(17) == 3 and elf:byte(18) == 0
                    and elf:byte(19) == 40 and elf:byte(20) == 0
                    and elf:byte(40) == 5, 'incompatible ELF library')
                local float_flags = elf:byte(38) % 8
                assert(float_flags == (hardfp and 4 or 2), 'incompatible ELF float ABI')
                if not pcall(ffi.typeof, 'TCGesture') then
                    local header = assert(read(dir .. '/native/core.h'), 'native header missing')
                    ffi.cdef(header)
                end
                local C = ffi.load(path)
                assert(C.tc_abi_version() == 1 and C.tc_gesture_size() == ffi.sizeof('TCGesture')
                    and C.tc_result_size() == ffi.sizeof('TCResult'), 'native ABI mismatch')
                for _, name in ipairs({'tc_new', 'tc_free', 'tc_init_distances',
                    'tc_can_finish', 'tc_greedy', 'tc_align'}) do assert(C[name]) end
                local factory = (deps.factory or dofile)(dir .. '/c_matcher.lua')
                return factory(Original, ffi, C)
            end)
            if loaded then
                native.backend_variant = variant.name
                native.backend_library = dir .. '/native/' .. variant.file
                return native
            end
            errors[#errors + 1] = variant.name .. ': ' .. tostring(native)
        end
    end
    return fallback(#errors > 0 and 'native library unavailable: ' .. table.concat(errors, '; ')
        or 'unsupported glibc version')
end
