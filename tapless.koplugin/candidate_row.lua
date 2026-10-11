local CandidateRow = {}

local function slotText(index, candidates, dictionary_label, personal_offer)
    if index == 1 then
        return dictionary_label
    end
    if personal_offer then
        if index == 2 then
            return personal_offer.word
        elseif index == 3 then
            return personal_offer.added and "✓" or "+"
        end
        return " "
    end
    local candidate = candidates[index - 1]
    return candidate and (candidate.output_word or candidate.word) or " "
end

function CandidateRow:create(options)
    local slot_count = options.slot_count or 4
    local horizontal_group = options.HorizontalGroup:new{
        allow_mirroring = false,
    }
    local layout = {}
    local keys = {}
    local candidates = options.candidates or {}
    local candidate_width = math.floor(
        (options.width - (slot_count + 1) * options.key_padding
            - 2 * options.padding) / slot_count)

    for index = 1, slot_count do
        local word = slotText(index, candidates, options.dictionary_label,
            options.personal_offer)
        local virtual_key = options.VirtualKey:new{
            key = word,
            label = word,
            keyboard = options.keyboard,
            width = candidate_width,
            height = options.height,
        }
        virtual_key.is_swype_candidate = true
        virtual_key.swipe_callback = nil
        virtual_key.hold_callback = index == 1 and options.on_open_manager or nil
        virtual_key.callback = function()
            if index == 1 then
                options.on_toggle_dictionary()
            else
                local offer = options.get_personal_offer
                    and options.get_personal_offer()
                if offer then
                    if index == 3 then
                        options.on_add_personal_word()
                    end
                else
                    options.on_select_candidate(index - 1)
                end
            end
        end
        table.insert(keys, virtual_key)
        table.insert(horizontal_group, virtual_key)
        table.insert(layout, virtual_key)
        if index ~= slot_count then
            table.insert(horizontal_group, options.horizontal_padding)
        end
    end

    return {
        widget = horizontal_group,
        layout = layout,
        keys = keys,
    }
end

function CandidateRow:refresh(options)
    local candidates = options.candidates or {}
    local refresh_region
    for index, virtual_key in ipairs(options.keys or {}) do
        if not options.only_index or index == options.only_index then
            local word = slotText(index, candidates, options.dictionary_label,
                options.personal_offer)
            local changed = virtual_key.label ~= word
            virtual_key.key = word
            virtual_key.label = word
            if changed and virtual_key.swype_mvp_label_widget then
                virtual_key.swype_mvp_label_widget:setText(word)
            end
            if changed and virtual_key[1] and virtual_key[1].dimen then
                local dimen = virtual_key[1].dimen
                options.UIManager:widgetRepaint(
                    virtual_key[1], dimen.x, dimen.y)
                -- Include the gaps between changed keys so the display gets
                -- one update for the suggestions instead of one per key.
                refresh_region = refresh_region and refresh_region:combine(dimen)
                    or dimen:copy()
            end
        end
    end
    if refresh_region then
        options.UIManager:setDirty(nil, options.refresh_type or "ui", refresh_region)
    end
end

return CandidateRow
