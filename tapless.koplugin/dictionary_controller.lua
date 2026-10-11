local DictionaryController = {}
DictionaryController.__index = DictionaryController

function DictionaryController:new(options)
    return setmetatable({
        plugin_dir = assert(options.plugin_dir),
        manager = assert(options.manager),
        registry = assert(options.registry),
        store = assert(options.store),
        scoring = assert(options.scoring),
        ui_manager = assert(options.ui_manager),
        settings = assert(options.settings),
        logger = assert(options.logger),
        setting_key = assert(options.setting_key),
        default_profile = assert(options.default_profile),
    }, self)
end

function DictionaryController:initialize(keyboard)
    local dictionary = self.settings:readSetting(self.setting_key, "en")
    if not self.manager:isDictionaryAvailable(dictionary, self.plugin_dir) then
        dictionary = "en"
    end
    keyboard.swype_mvp_dictionary = dictionary
    local descriptor = self.registry:get(dictionary, self.plugin_dir)
    keyboard.swype_mvp_normalization_profile = descriptor
        and descriptor.normalization_profile or self.default_profile
end

function DictionaryController:label(keyboard)
    return self.manager:shortLabel(keyboard.swype_mvp_dictionary)
end

function DictionaryController:toggle(keyboard)
    keyboard:_swypeCommitPendingContext()
    local installed = self.manager:listInstalled(self.plugin_dir)
    if #installed < 2 then
        self.manager:open(keyboard, self.plugin_dir)
        return
    end
    local current_index
    for index, info in ipairs(installed) do
        if info.id == keyboard.swype_mvp_dictionary then
            current_index = index
            break
        end
    end
    local next_info = installed[(current_index or 0) % #installed + 1]
    keyboard:_swypeSetDictionary(next_info.id)
end

function DictionaryController:setDictionary(keyboard, dictionary)
    if not self.manager:isDictionaryAvailable(dictionary, self.plugin_dir) then
        return false
    end
    keyboard:_swypeCommitPendingContext()
    keyboard:_swypeCancelBucketPrefetch()
    self.store:invalidate(dictionary)
    keyboard.swype_mvp_dictionary = dictionary
    local descriptor = self.registry:get(dictionary, self.plugin_dir)
    keyboard.swype_mvp_normalization_profile = descriptor
        and descriptor.normalization_profile or self.default_profile
    self.store:keepOnly(dictionary)
    self.settings:saveSetting(self.setting_key, dictionary)
    self.logger.info(
        "swype mvp dictionary selected", keyboard.swype_mvp_dictionary)
    -- Refresh the language tile before clearing suggestions: the row refresh
    -- also updates its label, which would make the flashing refresh a no-op.
    keyboard:_swypeRefreshCandidateRow("flashui", 1)
    keyboard:_swypeClearCandidateRow("ui")
    keyboard:_swypeScheduleWarmUp(0.1)
    return true
end

function DictionaryController:scheduleWarmUp(keyboard, delay)
    keyboard.swype_mvp_warm_generation =
        (keyboard.swype_mvp_warm_generation or 0) + 1
    local generation = keyboard.swype_mvp_warm_generation
    local dictionary = keyboard.swype_mvp_dictionary or "en"
    self.ui_manager:scheduleIn(delay or 0.35, function()
        if keyboard.swype_mvp_warm_generation ~= generation
                or not keyboard.visible
                or keyboard.swype_mvp_dictionary ~= dictionary then
            return
        end
        if keyboard.swype_mvp_trace then
            keyboard:_swypeScheduleWarmUp(0.5)
            return
        end
        self.store:keepOnly(dictionary)
        self.store:open(dictionary)
        self.scoring:warm()
    end)
end

function DictionaryController:stopWarmUp(keyboard)
    keyboard.swype_mvp_warm_generation =
        (keyboard.swype_mvp_warm_generation or 0) + 1
end

return DictionaryController
