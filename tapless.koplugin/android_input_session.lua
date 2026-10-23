local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

return function(o)
    local state = {}
    local function active()
        local keyboard = state.keyboard
        return keyboard and not keyboard.swype_mvp_closed and keyboard:isSwypeMvpEnabled()
    end
    local history, reason = dofile(o.plugin_dir .. "/android_input.lua"):new{
        android = o.android,
        backend = o.input and o.input.input,
        active = active,
    }:install()
    if not history then return nil, reason end
    state.history = history

    local show, close = o.keyboard.onShow, o.keyboard.onCloseWidget
    o.keyboard.onShow = function(keyboard, ...)
        local result = pack(show(keyboard, ...))
        state.keyboard = keyboard
        return unpack(result, 1, result.n)
    end
    o.keyboard.onCloseWidget = function(keyboard, ...)
        if state.keyboard == keyboard then state.keyboard = nil end
        return close(keyboard, ...)
    end
    for _, name in ipairs({ "onPan", "onPanRelease", "onPathRelease" }) do
        local original = o.controller[name]
        o.controller[name] = function(controller, keyboard, gesture, ...)
            local previous = state.sample_time
            state.sample_time = active() and gesture and gesture.time or nil
            local result = pack(pcall(original, controller, keyboard, gesture, ...))
            state.sample_time = previous
            if not result[1] then error(result[2], 0) end
            return unpack(result, 2, result.n)
        end
    end
    local add = o.collector.addPoint
    o.collector.addPoint = function(collector, trace, pos, letter, dimen, timestamp)
        return add(collector, trace, pos, letter, dimen, state.sample_time or timestamp)
    end

    o.history = history
    -- Installation is synchronous. Restore original hooks if setup cannot finish.
    local hooks = {}
    local function save(object, names)
        for _, name in ipairs(names) do
            hooks[#hooks + 1] = { object = object, name = name, original = object[name] }
        end
    end
    save(o.keyboard, { "onShow", "onCloseWidget" })
    save(o.controller, { "finalizeTrace" })
    save(o.renderer, { "drawSegment", "clear" })
    save(o.ui, { "setDirty", "_repaint" })
    save(o.screen, { "_updateWindow" })
    save(history.o, { "on_down" })
    local ok, ebc = pcall(function()
        return dofile(o.plugin_dir .. "/android_ebc.lua").install(o)
    end)
    if ok then
        state.ebc = ebc
    else
        for _, hook in ipairs(hooks) do hook.object[hook.name] = hook.original end
        if o.logger then o.logger.warn("Tapless: EBC unavailable", tostring(ebc)) end
    end
    return state
end
