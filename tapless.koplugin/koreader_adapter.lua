local KoreaderAdapter = {}
KoreaderAdapter.__index = KoreaderAdapter

function KoreaderAdapter:new(options)
    return setmetatable(options, self)
end

function KoreaderAdapter:install(VirtualKeyboard)
    if VirtualKeyboard._tapless_adapter_installed then
        return VirtualKeyboard
    end
    VirtualKeyboard._tapless_adapter_installed = true

    local original_init = assert(VirtualKeyboard.init)
    local original_show = assert(VirtualKeyboard.onShow)
    local original_close_widget = assert(VirtualKeyboard.onCloseWidget)
    local adapter = self

    function VirtualKeyboard:init()
        self.swype_mvp_closed = false
        self.swype_mvp_session = self.swype_mvp_session
            or adapter.input_session:new()
        self.swype_mvp_prefetch_controller = self.swype_mvp_prefetch_controller
            or adapter.prefetch_controller:new(
                adapter.dictionary_store,
                adapter.ui_manager,
                function() return self.swype_mvp_trace ~= nil end,
                adapter.prefetch_batch_size,
                adapter.prefetch_work_ms)
        adapter.dictionary_controller:initialize(self)
        original_init(self)
    end

    function VirtualKeyboard:addKeys()
        self:free()
        self.layout = {}
        local row_count = #self.KEYS + 1
        local keys_height = adapter.settings:isTrue("keyboard_key_compact")
            and 48 or 64
        self.height = adapter.screen:scaleBySize(keys_height * row_count)
        local base_key_width = math.floor((self.width
            - (#self.KEYS[1] + 1) * self.key_padding - 2 * self.padding)
            / #self.KEYS[1])
        local base_key_height = math.floor((self.height
            - (row_count + 1) * self.key_padding - 2 * self.padding)
            / row_count)
        local h_key_padding = adapter.horizontal_span:new{
            width = self.key_padding,
        }
        local v_key_padding = adapter.vertical_span:new{
            width = self.key_padding,
        }
        local vertical_group = adapter.vertical_group:new{
            allow_mirroring = false,
        }
        local candidate_row = adapter.keyboard_ui:createCandidateRow(self, {
            width = self.width,
            height = base_key_height,
            key_padding = self.key_padding,
            padding = self.padding,
            horizontal_padding = h_key_padding,
        })
        self.swype_mvp_candidate_keys = candidate_row.keys
        table.insert(vertical_group, candidate_row.widget)
        table.insert(self.layout, candidate_row.layout)
        table.insert(vertical_group, v_key_padding)

        for row_index = 1, #self.KEYS do
            local horizontal_group = adapter.horizontal_group:new{
                allow_mirroring = false,
            }
            local layout_row = {}
            for key_index = 1, #self.KEYS[row_index] do
                local definition = self.KEYS[row_index][key_index]
                local key_chars = definition[self.keyboard_layer]
                local key
                local label
                local alt_label
                local width_factor
                if type(key_chars) == "table" then
                    key = key_chars[1]
                    label = key_chars.label
                    alt_label = key_chars.alt_label
                    width_factor = key_chars.width
                else
                    key = key_chars
                    key_chars = nil
                end
                width_factor = width_factor or definition.width
                    or self.KEYS[row_index].width or 1.0
                local key_width = math.floor(
                    (base_key_width + self.key_padding) * width_factor)
                    - self.key_padding
                label = label or definition.label or key
                if label == "" and self.shiftmode
                        and (not self.release_shift or self.symbolmode) then
                    key = label
                    label = ""
                end
                local virtual_key = adapter.virtual_key:new{
                    key = key,
                    key_chars = key_chars,
                    icon = definition.icon,
                    label = label,
                    alt_label = alt_label,
                    bold = definition.bold,
                    keyboard = self,
                    width = key_width,
                    height = base_key_height,
                }
                if not virtual_key.key_chars and label ~= "" then
                    virtual_key.swipe_callback = nil
                end
                table.insert(horizontal_group, virtual_key)
                table.insert(layout_row, virtual_key)
                if key_index ~= #self.KEYS[row_index] then
                    table.insert(horizontal_group, h_key_padding)
                end
            end
            table.insert(vertical_group, horizontal_group)
            table.insert(self.layout, layout_row)
            if row_index ~= #self.KEYS then
                table.insert(vertical_group, v_key_padding)
            end
        end

        local keyboard_frame = adapter.frame_container:new{
            margin = 0,
            bordersize = adapter.size.border.default,
            background = adapter.settings:nilOrTrue("keyboard_key_border")
                and adapter.blitbuffer.COLOR_LIGHT_GRAY
                or adapter.blitbuffer.COLOR_WHITE,
            radius = 0,
            padding = self.padding,
            allow_mirroring = false,
            adapter.center_container:new{
                dimen = adapter.geometry:new{
                    w = self.width - 2 * adapter.size.border.default
                        - 2 * self.padding,
                    h = self.height - 2 * adapter.size.border.default
                        - 2 * self.padding,
                },
                vertical_group,
            },
        }
        self[1] = adapter.bottom_container:new{
            dimen = adapter.screen:getSize(),
            keyboard_frame,
        }
        keyboard_frame.dimen = keyboard_frame:getSize()
        self.dimen = keyboard_frame.dimen
        adapter.keyboard_ui:registerGestureRanges(self)
    end

    function VirtualKeyboard:_swypeScheduleWarmUp(delay)
        adapter.dictionary_controller:scheduleWarmUp(self, delay)
    end

    function VirtualKeyboard:onShow()
        self.swype_mvp_closed = false
        local result = original_show(self)
        self:_swypeScheduleWarmUp()
        return result
    end

    function VirtualKeyboard:onCloseWidget()
        self.swype_mvp_closed = true
        self:_swypeReset()
        adapter.dictionary_controller:stopWarmUp(self)
        self:_swypeCancelBucketPrefetch()
        self:_swypeCommitPendingContext()
        self:_swypeSaveContext()
        self:_swypeClearCandidateState()
        return original_close_widget(self)
    end

    function VirtualKeyboard:isSwypeMvpEnabled()
        return adapter.settings:nilOrTrue("keyboard_swype_mvp_enabled")
            and not self.symbolmode and not self.umlautmode
    end

    function VirtualKeyboard:_swypeKeyAt(pos)
        return adapter.keyboard_geometry:keyAt(
            self.layout, pos, self.swype_mvp_normalization_profile)
    end

    function VirtualKeyboard:_swypeEndpointLetters(pos, exact_last)
        return adapter.keyboard_geometry:endpointLetters(
            self.layout, pos, exact_last,
            self.swype_mvp_normalization_profile)
    end

    function VirtualKeyboard:_swypeDrawTraceSegment(previous, current)
        adapter.trace_renderer:drawSegment(
            self.swype_mvp_trace, previous, current)
    end

    function VirtualKeyboard:_swypeClearTracePixels(refresh_type)
        adapter.trace_renderer:clear(self.swype_mvp_trace, refresh_type)
    end

    function VirtualKeyboard:_swypeCancelBucketPrefetch()
        self.swype_mvp_prefetch_controller:cancel()
    end

    function VirtualKeyboard:_swypeScheduleBucketPrefetch()
        local trace = self.swype_mvp_trace
        local priority_lasts
        if trace and trace.points and #trace.points > 0
                and trace.letters and #trace.letters > 0 then
            priority_lasts = adapter.keyboard_geometry:endpointLetters(
                self.layout, trace.points[#trace.points],
                trace.letters[#trace.letters],
                self.swype_mvp_normalization_profile)
        end
        self.swype_mvp_prefetch_controller:schedule(
            trace, self.swype_mvp_dictionary or "en", priority_lasts)
    end

    function VirtualKeyboard:_swypeReset(keep_prefetch)
        adapter.gesture_controller:reset(self, keep_prefetch)
    end

    function VirtualKeyboard:_swypePickCandidates(signature, limit, trace_info)
        local key_centers = trace_info
            and adapter.keyboard_geometry:keyCenters(
                self.layout, self.swype_mvp_normalization_profile) or {}
        return adapter.recognition_engine:pickCandidates{
            signature = signature,
            limit = limit,
            dictionary = self.swype_mvp_dictionary or "en",
            trace_info = trace_info,
            key_centers = key_centers,
            start_letters = function(first)
                local point = trace_info and trace_info.points and trace_info.points[1]
                return adapter.keyboard_geometry:startLetters(
                    self.layout, point, first, self.swype_mvp_normalization_profile)
            end,
            endpoint_letters = function(last)
                return self:_swypeEndpointLetters(
                    trace_info.endpoint_pos, last)
            end,
            context_bonus = function(previous_word, word)
                return self:_swypeContextBonus(previous_word, word)
            end,
            normalization_profile = self.swype_mvp_normalization_profile,
        }
    end

    function VirtualKeyboard:_swypeGetPreviousWord()
        return adapter.input_controller:getPreviousWord(self)
    end

    function VirtualKeyboard:_swypeContextBonus(previous_word, word)
        return adapter.input_controller:contextBonus(previous_word, word)
    end

    function VirtualKeyboard:_swypeCommitPendingContext()
        adapter.input_controller:commitPendingContext(self)
    end

    function VirtualKeyboard:_swypeSaveContext()
        adapter.input_controller:saveContext()
    end

    function VirtualKeyboard:_swypeDictionaryLabel()
        return adapter.dictionary_controller:label(self)
    end

    function VirtualKeyboard:_swypeToggleDictionary()
        adapter.dictionary_controller:toggle(self)
    end

    function VirtualKeyboard:_swypeSetDictionary(dictionary)
        return adapter.dictionary_controller:setDictionary(self, dictionary)
    end

    function VirtualKeyboard:_swypeRefreshCandidateRow(refresh_type, only_index)
        adapter.keyboard_ui:refreshCandidateRow(
            self, refresh_type, only_index)
    end

    function VirtualKeyboard:_swypeClearCandidateState(keep_debug)
        adapter.input_controller:clearCandidateState(self, keep_debug)
    end

    function VirtualKeyboard:_swypeClearCandidateRow(refresh_type)
        adapter.input_controller:clearCandidateRow(self, refresh_type)
    end

    function VirtualKeyboard:_swypeSelectCandidate(candidate)
        adapter.input_controller:selectCandidate(self, candidate)
    end

    function VirtualKeyboard:_swypeAddPersonalWord()
        return adapter.input_controller:addPersonalWord(self)
    end

    function VirtualKeyboard:_swypeFinalizeSignature(signature, trace_info)
        return adapter.input_controller:finalizeSignature(
            self, signature, trace_info)
    end

    function VirtualKeyboard:onSwypeWordPan(_, ges)
        return adapter.gesture_controller:onPan(self, ges)
    end

    function VirtualKeyboard:_onSwypeWordPathRelease(_, ges, source_key)
        return adapter.gesture_controller:onPathRelease(
            self, ges, source_key)
    end

    function VirtualKeyboard:onSwypeWordSwipe(_, ges, source_key)
        return self:_onSwypeWordPathRelease(_, ges, source_key)
    end

    function VirtualKeyboard:onSwypeWordMultiswipe(_, ges, source_key)
        return self:_onSwypeWordPathRelease(_, ges, source_key)
    end

    function VirtualKeyboard:onSwypeWordPanRelease(_, ges)
        return adapter.gesture_controller:onPanRelease(self, ges)
    end

    function VirtualKeyboard:addChar(key, keep_swype_candidates)
        adapter.input_controller:addChar(
            self, key, keep_swype_candidates)
    end

    function VirtualKeyboard:delChar()
        adapter.input_controller:delChar(self)
    end

    return VirtualKeyboard
end

return KoreaderAdapter
