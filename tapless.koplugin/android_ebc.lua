local EBC = {}

local function read(path)
    local file = io.open(path, "rb")
    if not file then return end
    local value = file:read("*a")
    file:close()
    return value
end

function EBC.supported(o, dependencies)
    local d = dependencies or {}
    local ffi = d.ffi or require("ffi")
    if not o.android or not o.android.app or not o.android.app.activity
            or tonumber(o.android.app.activity.sdkVersion) ~= 27
            or ffi.os ~= "Linux" or ffi.arch ~= "arm"
            or not ffi.abi("32bit") or not ffi.abi("le") or ffi.abi("hardfp") then
        return false, "unsupported Android ABI or API"
    end
    local full_ok, full = pcall(o.android.isEinkFull)
    if not full_ok or full then return false, "unsupported display backend" end
    if not o.history or not o.keyboard or not o.controller or not o.renderer
            or not o.ui or not o.screen or type(o.ui._repaint) ~= "function"
            or type(o.screen._updateWindow) ~= "function"
            or type(o.controller.finalizeTrace) ~= "function" then
        return false, "unsupported keyboard or display hooks"
    end
    local bb = o.screen.bb
    if not bb or tonumber(bb.w) ~= 758 or tonumber(bb.h) ~= 1024
            or bb:getRotation() ~= 0 or bb:getType() ~= 5 then
        return false, "unsupported framebuffer"
    end
    local get = d.read or read
    if not (get("/proc/ebc_version") or ""):match("software: 3%.36")
            or not (get("/proc/version") or ""):find("#1794", 1, true)
            or not (get("/sys/devices/platform/eink/waveform_version") or ""):match("ED060XCDU2") then
        return false, "unsupported EBC firmware or panel"
    end
    local hwc = get("/vendor/lib/hw/hwcomposer.rk30board.so")
    if not hwc then return false, "display compositor unavailable" end
    local hash = d.sha256 or require("ffi/sha2").sha256
    local digest = hash(hwc)
    if type(digest) == "string" and #digest == 32 then
        digest = digest:gsub(".", function(byte) return string.format("%02x", byte:byte()) end)
    end
    if type(digest) ~= "string" or digest:lower()
            ~= "60e572bac2e07407f955c673710176be75c609ed2f07732fe35a43a0a148612c" then
        return false, "unsupported display compositor"
    end
    return true
end

function EBC.install(o, dependencies)
    local supported, reason = EBC.supported(o, dependencies)
    if not supported then return nil, reason end
    return dofile(o.plugin_dir .. "/android_ebc_session.lua").install(o)
end

return EBC
