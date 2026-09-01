local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local KeyboardLayoutDialog = require("ui/widget/keyboardlayoutdialog")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local Screen = Device.screen

-- Keep the dictionaries with the plugin. 
local SWYPE_MVP_PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.+)/virtualkeyboard%.lua$") or ".")

local keyboard_state = {
    force_current_layout = false, -- Set to true to get/set current layout (instead of default layout)
}

local DEFAULT_LABEL_SIZE = 22

local VirtualKeyPopup

local VirtualKey = InputContainer:extend{
    key = nil,
    icon = nil,
    label = nil,
    bold = nil,

    keyboard = nil,
    callback = nil,
    -- This is to inhibit the key's own refresh (useful to avoid conflicts on Layer changing keys)
    skiptap = nil,
    skiphold = nil,

    width = nil,
    height = math.max(Screen:getWidth(), Screen:getHeight())*0.33,
    bordersize = 0,
    focused_bordersize = Size.border.default,
    radius = 0,
    face = Font:getFace("infont"),
}

-- For caps lock, it's necessary because after setLayout, the new shift key is no longer the same virtual key
-- thus rendering its preset .ignore_key_release property useless
local ignore_key_release

local SWYPE_MVP_FALLBACK_WORDS = {
    { signature = "tak", word = "tak" },
    { signature = "nie", word = "nie" },
    { signature = "ok", word = "ok" },
    { signature = "czesc", word = "cześć" },
    { signature = "prosze", word = "proszę" },
    { signature = "dzieki", word = "dzięki" },
    { signature = "jest", word = "jest" },
    { signature = "mozliwe", word = "możliwe" },
    { signature = "kindle", word = "kindle" },
    { signature = "koreader", word = "koreader" },
    { signature = "asystent", word = "asystent" },
    { signature = "pytanie", word = "pytanie" },
    { signature = "odpowiedz", word = "odpowiedź" },
    { signature = "tlumacz", word = "tłumacz" },
    { signature = "slownik", word = "słownik" },
    { signature = "notatka", word = "notatka" },
    { signature = "test", word = "test" },
}
local swype_mvp_words
local swype_mvp_words_by_first
local swype_mvp_words_by_first_length_last
local swype_mvp_bucket_packages = {}
local swype_mvp_bucket_cache = {}
local swype_mvp_first_bucket_cache = {}
local swype_mvp_popular_cache = {}
local swype_mvp_bucket_prefetch_jobs = {}
local swype_mvp_scoring_warmed = false
local SWYPE_MVP_CONTEXT_SETTING = "keyboard_swype_mvp_context_counts"
local SWYPE_MVP_DICTIONARY_SETTING = "keyboard_swype_mvp_dictionary"
local SWYPE_MVP_SCORE_UNIT = 3000
local SWYPE_MVP_EDIT_DISTANCE_MAX = 2
local SWYPE_MVP_ASCII_A = string.byte("a")
local SWYPE_MVP_PREFETCH_BATCH_SIZE = 96
local SWYPE_MVP_PREFETCH_WORK_MS = 3

local function swypeSplitChars(text)
    return util.splitToChars(text or "")
end

local function swypeNormalizeChar(char)
    char = string.lower(char or "")
    local map = {
        ["ą"] = "a", ["ć"] = "c", ["ę"] = "e", ["ł"] = "l", ["ń"] = "n",
        ["ó"] = "o", ["ś"] = "s", ["ź"] = "z", ["ż"] = "z",
    }
    char = map[char] or char
    if char:match("^[a-z]$") then
        return char
    end
end

local function swypeNormalizeText(text)
    if type(text) ~= "string" then
        return ""
    end
    local normalized = {}
    for _, char in ipairs(swypeSplitChars(text or "")) do
        char = swypeNormalizeChar(char)
        if char then
            table.insert(normalized, char)
        end
    end
    return table.concat(normalized)
end

local function swypeBuildNextPositions(trace)
    local trace_chars = swypeSplitChars(trace)
    local trace_end = #trace_chars + 1
    local next_positions = { [trace_end] = {} }
    local next_for_char = {}
    for code = 1, 26 do
        next_for_char[code] = trace_end
        next_positions[trace_end][code] = trace_end
    end
    for position = #trace_chars, 1, -1 do
        local row = {}
        for code = 1, 26 do
            row[code] = next_for_char[code]
        end
        local code = string.byte(trace_chars[position]) - string.byte("a") + 1
        if code >= 1 and code <= 26 then
            next_for_char[code] = position
            row[code] = position
        end
        next_positions[position] = row
    end
    return trace_chars, next_positions
end

local function swypeEditDistance(left, right, max_distance)
    max_distance = max_distance or SWYPE_MVP_EDIT_DISTANCE_MAX
    local left_len = #left
    local right_len = #right
    if math.abs(left_len - right_len) > max_distance then
        return max_distance + 1
    end

    -- Signatures are ASCII. Keep only the diagonal band needed by the limit.
    local infinity = max_distance + 1
    local previous = {}
    for j = 0, math.min(right_len, max_distance) do
        previous[j] = j
    end
    for i = 1, left_len do
        local current = {}
        local from = math.max(1, i - max_distance)
        local to = math.min(right_len, i + max_distance)
        current[0] = i <= max_distance and i or infinity
        local row_min = current[0]
        for j = from, to do
            local cost = string.byte(left, i) == string.byte(right, j) and 0 or 1
            local deletion = (previous[j] or infinity) + 1
            local insertion = (current[j - 1] or infinity) + 1
            local substitution = (previous[j - 1] or infinity) + cost
            local value = math.min(deletion, insertion, substitution)
            if value > infinity then
                value = infinity
            end
            current[j] = value
            row_min = math.min(row_min, value)
        end
        if row_min > max_distance then
            return infinity
        end
        previous = current
    end
    return previous[right_len] or infinity
end

local function swypeMatchScore(candidate, trace_chars, next_positions,
        allow_endpoint_mismatch, trace_letter_points, endpoint_pos, key_centers)
    local trace_len = #trace_chars
    local trace_end = trace_len + 1
    local candidate_len = #candidate
    local pos = 1
    local matched = 0
    local first_match
    local last_match
    local endpoint_mismatch = false
    local geometry_total = 0
    local geometry_measured = 0

    for i = 1, candidate_len do
        local code = string.byte(candidate, i) - SWYPE_MVP_ASCII_A + 1
        local row = next_positions and next_positions[pos]
        local found = row and row[code] or nil
        if (not found or found == trace_end) and allow_endpoint_mismatch
                and i == candidate_len and matched == candidate_len - 1
                and trace_len > 0 then
            matched = matched + 1
            last_match = trace_len
            endpoint_mismatch = true
            if trace_letter_points and endpoint_pos and key_centers then
                local target = key_centers[code]
                if target then
                    local dx = endpoint_pos.x - target.x
                    local dy = endpoint_pos.y - target.y
                    local scale = math.max(1, target.size or 1)
                    geometry_total = geometry_total
                        + math.min(2, math.sqrt(dx * dx + dy * dy) / scale)
                    geometry_measured = geometry_measured + 1
                end
            end
            break
        end
        if not found or found == trace_end then
            break
        end
        matched = matched + 1
        first_match = first_match or found
        last_match = found
        if trace_letter_points and key_centers then
            local point = trace_letter_points[found]
            local target = key_centers[code]
            if point and target then
                local dx = point.x - target.x
                local dy = point.y - target.y
                local scale = math.max(1, target.size or 1)
                geometry_total = geometry_total
                    + math.min(2, math.sqrt(dx * dx + dy * dy) / scale)
                geometry_measured = geometry_measured + 1
            end
        end
        pos = found + 1
    end

    local score
    if matched < candidate_len then
        score = 1000 + (candidate_len - matched) * 20
    else
        score = trace_len - candidate_len
        score = score + ((first_match or 1) - 1) * 2
        score = score + (trace_len - (last_match or trace_len)) * 2
        local first_code = string.byte(candidate, 1) - SWYPE_MVP_ASCII_A + 1
        local last_code = string.byte(candidate, candidate_len)
            - SWYPE_MVP_ASCII_A + 1
        if string.byte(trace_chars[1]) - SWYPE_MVP_ASCII_A + 1 ~= first_code then
            score = score + 6
        end
        if not endpoint_mismatch
                and string.byte(trace_chars[trace_len]) - SWYPE_MVP_ASCII_A + 1
                    ~= last_code then
            score = score + 4
        end
        if endpoint_mismatch then
            score = score + 5
        end
    end
    if geometry_measured > 0 then
        score = score + math.min(4,
            math.floor(geometry_total * 2 / geometry_measured + 0.5))
    end
    return score, endpoint_mismatch
end

local function swypeShortWordEndpointScore(trace, candidate)
    if #candidate > 4 or #trace < #candidate or #trace > 10 then
        return
    end
    local t = swypeSplitChars(trace)
    local c = swypeSplitChars(candidate)
    if t[1] ~= c[1] then
        return
    end
    local pos = 1
    local matched = 0
    local last_match
    for i = 1, #c do
        for j = pos, #t do
            if t[j] == c[i] then
                matched = matched + 1
                last_match = j
                pos = j + 1
                break
            end
        end
    end
    local missing = #c - matched
    if missing > 1 then
        return
    end
    local trailing = #t - (last_match or #t)
    if trailing > 1 then
        return
    end
    return math.max(0, math.floor(#trace / 2) + missing * 3 + trailing * 2 - 2)
end

local function swypeWarmScoring()
    if swype_mvp_scoring_warmed then
        return
    end

    local traces = {
        { trace = "nkiuytre", candidates = { "nie", "numer", "nurt" } },
        { trace = "treredsaz", candidates = { "teraz", "tez", "trasa" } },
        { trace = "produktywny", candidates = { "produktywny", "probny", "prosty" } },
    }
    for iteration = 1, 80 do
        local sample = traces[(iteration - 1) % #traces + 1]
        local trace_chars, next_positions = swypeBuildNextPositions(sample.trace)
        for _, candidate in ipairs(sample.candidates) do
            swypeMatchScore(candidate, trace_chars, next_positions, false)
            swypeShortWordEndpointScore(sample.trace, candidate)
            swypeEditDistance(sample.trace, candidate, SWYPE_MVP_EDIT_DISTANCE_MAX)
        end
    end
    swype_mvp_scoring_warmed = true
end

local function swypeLoadWords()
    if swype_mvp_words then
        return swype_mvp_words, swype_mvp_words_by_first
    end

    swype_mvp_words = {}
    swype_mvp_words_by_first = {}
    swype_mvp_words_by_first_length_last = {}

    local function add_entry(entry)
        table.insert(swype_mvp_words, entry)
        local first = string.sub(entry.signature, 1, 1)
        swype_mvp_words_by_first[first] = swype_mvp_words_by_first[first] or {}
        table.insert(swype_mvp_words_by_first[first], entry)

        local length = #entry.signature
        local last = string.sub(entry.signature, -1)
        local by_length = swype_mvp_words_by_first_length_last[first]
        if not by_length then
            by_length = {}
            swype_mvp_words_by_first_length_last[first] = by_length
        end
        by_length[length] = by_length[length] or {}
        by_length[length][last] = by_length[length][last] or {}
        table.insert(by_length[length][last], entry)
    end

    local file
    local paths = {
        SWYPE_MVP_PLUGIN_DIR .. "/dictionaries/pl/words.tsv",
        "data/swype_words.tsv",
        "./data/swype_words.tsv",
        "/mnt/us/koreader/data/swype_words.tsv",
    }
    for _, path in ipairs(paths) do
        file = io.open(path, "r")
        if file then
            logger.info("swype mvp dictionary", path)
            break
        end
    end

    if file then
        for line in file:lines() do
            if string.sub(line, 1, 1) ~= "#" then
                local signature, word, freq, lang = line:match(
                    "^([^\t]+)\t([^\t]+)\t([0-9]+)\t([a-z][a-z]*)")
                if signature and word and freq and #signature >= 2 then
                    local entry = {
                        signature = signature,
                        word = word,
                        freq = tonumber(freq) or 0,
                        lang = lang,
                    }
                    add_entry(entry)
                end
            end
        end
        file:close()
    end

    if #swype_mvp_words == 0 then
        logger.warn("swype mvp dictionary missing; using fallback list")
        for _, entry in ipairs(SWYPE_MVP_FALLBACK_WORDS) do
            entry.freq = entry.freq or 0
            add_entry(entry)
        end
    else
        logger.info("swype mvp dictionary entries", #swype_mvp_words)
    end

    return swype_mvp_words, swype_mvp_words_by_first
end

local function swypeOpenBucketDictionary(dictionary)
    dictionary = dictionary or "en"
    if swype_mvp_bucket_packages[dictionary] ~= nil then
        return swype_mvp_bucket_packages[dictionary]
    end

    local package_root = "data/swype/dictionaries/" .. dictionary
    local plugin_package_root = SWYPE_MVP_PLUGIN_DIR .. "/dictionaries/" .. dictionary
    local path_pairs = {
        { plugin_package_root .. "/words.buckets.idx", plugin_package_root .. "/words.buckets.tsv" },
        { package_root .. "/words.buckets.idx", package_root .. "/words.buckets.tsv" },
        { "./" .. package_root .. "/words.buckets.idx", "./" .. package_root .. "/words.buckets.tsv" },
        { "/mnt/us/koreader/" .. package_root .. "/words.buckets.idx", "/mnt/us/koreader/" .. package_root .. "/words.buckets.tsv" },
    }
    for _, paths in ipairs(path_pairs) do
        local index_file = io.open(paths[1], "r")
        local data_file = io.open(paths[2], "rb")
        if index_file and data_file then
            local index = {}
            for line in index_file:lines() do
                local key, offset, bytes, rows = line:match("^([a-z][a-z])\t([0-9]+)\t([0-9]+)\t([0-9]+)$")
                if key then
                    index[key] = {
                        offset = tonumber(offset),
                        bytes = tonumber(bytes),
                        rows = tonumber(rows),
                    }
                end
            end
            index_file:close()
            if next(index) then
                local popular_index_path = paths[1]:gsub(
                    "words%.buckets%.idx$", "words.popular.idx")
                local popular_data_path = paths[2]:gsub(
                    "words%.buckets%.tsv$", "words.popular.tsv")
                local popular_index_file = io.open(popular_index_path, "r")
                local popular_data_file = io.open(popular_data_path, "rb")
                local popular_index
                if popular_index_file and popular_data_file then
                    popular_index = {}
                    for line in popular_index_file:lines() do
                        local key, offset, bytes, rows = line:match(
                            "^([a-z])\t([0-9]+)\t([0-9]+)\t([0-9]+)$")
                        if key then
                            popular_index[key] = {
                                offset = tonumber(offset),
                                bytes = tonumber(bytes),
                                rows = tonumber(rows),
                            }
                        end
                    end
                    popular_index_file:close()
                    if not next(popular_index) then
                        popular_index = nil
                        popular_data_file:close()
                    end
                else
                    if popular_index_file then
                        popular_index_file:close()
                    end
                    if popular_data_file then
                        popular_data_file:close()
                    end
                end
                swype_mvp_bucket_packages[dictionary] = {
                    index = index,
                    file = data_file,
                    popular_index = popular_index,
                    popular_file = popular_data_file,
                }
                logger.info("swype mvp bucket dictionary", paths[2])
                return swype_mvp_bucket_packages[dictionary]
            end
            data_file:close()
        else
            if index_file then
                index_file:close()
            end
            if data_file then
                data_file:close()
            end
        end
    end

    swype_mvp_bucket_packages[dictionary] = false
    logger.warn("swype mvp bucket dictionary missing; using full dictionary", dictionary)
    return false
end

local function swypeKeepOnlyBucketDictionary(dictionary)
    for cached_dictionary, package in pairs(swype_mvp_bucket_packages) do
        if cached_dictionary ~= dictionary then
            if package and package.file then
                package.file:close()
            end
            if package and package.popular_file then
                package.popular_file:close()
            end
            swype_mvp_bucket_packages[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(swype_mvp_bucket_cache) do
        if cached_dictionary ~= dictionary then
            swype_mvp_bucket_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(swype_mvp_first_bucket_cache) do
        if cached_dictionary ~= dictionary then
            swype_mvp_first_bucket_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(swype_mvp_popular_cache) do
        if cached_dictionary ~= dictionary then
            swype_mvp_popular_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary, jobs in pairs(swype_mvp_bucket_prefetch_jobs) do
        if cached_dictionary ~= dictionary then
            for _, job in pairs(jobs) do
                job.cancelled = true
            end
            swype_mvp_bucket_prefetch_jobs[cached_dictionary] = nil
        end
    end
end

local function swypeAddBucketLine(bucket, line)
    local signature, word, freq, lang = line:match(
        "^([^\t]+)\t([^\t]+)\t([0-9]+)\t([a-z][a-z]*)$")
    if not signature or not word or not freq then
        return
    end
    local entry = {
        signature = signature,
        word = word,
        freq = tonumber(freq) or 0,
        lang = lang,
    }
    table.insert(bucket.entries, entry)
    local length = #signature
    bucket.by_length[length] = bucket.by_length[length] or {}
    table.insert(bucket.by_length[length], entry)
end

local function swypeAdvanceBucketPrefetch(job, max_entries, max_work_ms)
    if not job or job.cancelled or job.completed then
        return not job or job.completed
    end
    local work_start = time.now()
    local parsed = 0
    while not max_entries or parsed < max_entries do
        local line = job.next_line and job.next_line()
        if not line then
            job.completed = true
            swype_mvp_bucket_cache[job.dictionary][job.key] = job.bucket
            break
        end
        swypeAddBucketLine(job.bucket, line)
        parsed = parsed + 1
        if max_work_ms and parsed % 16 == 0
                and time.now() - work_start >= time.ms(max_work_ms) then
            break
        end
    end
    return job.completed
end

local function swypeStartBucketPrefetch(first, last, dictionary)
    dictionary = dictionary or "en"
    swype_mvp_bucket_cache[dictionary] = swype_mvp_bucket_cache[dictionary] or {}
    local cache = swype_mvp_bucket_cache[dictionary]
    local key = (first or "") .. (last or "")
    if cache[key] then
        return
    end
    swype_mvp_bucket_prefetch_jobs[dictionary] = swype_mvp_bucket_prefetch_jobs[dictionary] or {}
    local jobs = swype_mvp_bucket_prefetch_jobs[dictionary]
    if jobs[key] then
        return jobs[key]
    end
    local package = swypeOpenBucketDictionary(dictionary)
    if not package then
        return
    end

    local job = {
        dictionary = dictionary,
        key = key,
        bucket = { entries = {}, by_length = {} },
    }
    local meta = package.index[key]
    if meta then
        package.file:seek("set", meta.offset)
        local data = package.file:read(meta.bytes) or ""
        job.next_line = data:gmatch("[^\n]+")
    else
        job.completed = true
        cache[key] = job.bucket
    end
    jobs[key] = job
    return job
end

local function swypeLoadBucket(first, last, dictionary)
    dictionary = dictionary or "en"
    swype_mvp_bucket_cache[dictionary] = swype_mvp_bucket_cache[dictionary] or {}
    local cache = swype_mvp_bucket_cache[dictionary]
    local key = (first or "") .. (last or "")
    local jobs = swype_mvp_bucket_prefetch_jobs[dictionary]
    local prefetch_job = jobs and jobs[key]
    if cache[key] then
        if prefetch_job then
            prefetch_job.used = true
        end
        return cache[key]
    end
    if prefetch_job and not prefetch_job.cancelled then
        prefetch_job.used = true
        while not swypeAdvanceBucketPrefetch(prefetch_job) do end
        return prefetch_job.bucket
    end
    local package = swypeOpenBucketDictionary(dictionary)
    if not package then
        return
    end

    local bucket = {
        entries = {},
        by_length = {},
    }
    local meta = package.index[key]
    if meta then
        package.file:seek("set", meta.offset)
        local data = package.file:read(meta.bytes) or ""
        for line in data:gmatch("[^\n]+") do
            swypeAddBucketLine(bucket, line)
        end
    end
    cache[key] = bucket
    return bucket
end

local function swypeLoadFirstBuckets(first, dictionary)
    dictionary = dictionary or "en"
    swype_mvp_first_bucket_cache[dictionary] = swype_mvp_first_bucket_cache[dictionary] or {}
    local cache = swype_mvp_first_bucket_cache[dictionary]
    if cache[first] then
        return cache[first]
    end
    local entries = {}
    for code = string.byte("a"), string.byte("z") do
        local bucket = swypeLoadBucket(first, string.char(code), dictionary)
        for _, entry in ipairs(bucket and bucket.entries or {}) do
            table.insert(entries, entry)
        end
    end
    cache[first] = entries
    return entries
end

local function swypeLoadPopularWords(first, dictionary)
    dictionary = dictionary or "en"
    swype_mvp_popular_cache[dictionary] = swype_mvp_popular_cache[dictionary] or {}
    local cache = swype_mvp_popular_cache[dictionary]
    if cache[first] then
        return cache[first]
    end

    local package = swypeOpenBucketDictionary(dictionary)
    if not package or not package.popular_index or not package.popular_file then
        return nil
    end
    local meta = package.popular_index[first]
    local bucket = {
        entries = {},
        by_length = {},
    }
    if meta then
        package.popular_file:seek("set", meta.offset)
        local data = package.popular_file:read(meta.bytes) or ""
        for line in data:gmatch("[^\n]+") do
            swypeAddBucketLine(bucket, line)
        end
    end
    cache[first] = bucket.entries
    return bucket.entries
end

function VirtualKey:init()
    local label_font_size = G_reader_settings:readSetting("keyboard_key_font_size", DEFAULT_LABEL_SIZE)
    self.face = Font:getFace("infont", label_font_size)
    self.bold = G_reader_settings:isTrue("keyboard_key_bold")
    if self.keyboard.symbolmode_keys[self.label] ~= nil then
        self.callback = function () self.keyboard:setLayer("Sym") end
        self.skiptap = true
    elseif self.keyboard.shiftmode_keys[self.label] ~= nil or self.keyboard.shiftmode_keys[self.key] ~= nil then
        -- self.key needed because the shift key's label could be the capslock instead of the shift
        local key = self.key or self.label
        local releasable = key == ""
        self.callback = function()
            self.keyboard.release_shift = releasable
            self.keyboard:setLayer("Shift")
        end
        self.hold_callback = function()
            ignore_key_release = true
            if releasable then self.keyboard.release_shift = false end
            self.keyboard:setLayer("Shift")
        end
        self.skiptap = true
    elseif self.keyboard.utf8mode_keys[self.label] ~= nil then
        self.key_chars = self:genKeyboardLayoutKeyChars()
        self.callback = function ()
            self.keyboard:onSwitchingKeyboardLayout()
            local current = G_reader_settings:readSetting("keyboard_layout")
            local default = G_reader_settings:readSetting("keyboard_layout_default")
            local keyboard_layouts = G_reader_settings:readSetting("keyboard_layouts", {})
            local next_layout = nil
            local layout_index = util.arrayContains(keyboard_layouts, current)
            if layout_index then
                if layout_index == #keyboard_layouts then
                    layout_index = 1
                else
                    layout_index = layout_index + 1
                end
            else
                if default and current ~= default then
                    next_layout = default
                else
                    layout_index = 1
                end
            end
            next_layout = next_layout or keyboard_layouts[layout_index] or "en"
            self.keyboard:setKeyboardLayout(next_layout)
        end
        self.hold_callback = function()
            self.keyboard:onSwitchingKeyboardLayout()
            if util.tableSize(self.key_chars) > 5 then -- 2 or more layouts enabled
                self.popup = VirtualKeyPopup:new{
                    parent_key = self,
                }
            else
                self.keyboard_layout_dialog = KeyboardLayoutDialog:new{
                    parent = self,
                    keyboard_state = keyboard_state,
                }
                UIManager:show(self.keyboard_layout_dialog)
            end
        end
        self.hold_cb_is_popup = true
        self.swipe_callback = function(ges)
            self.keyboard:onSwitchingKeyboardLayout()
            local key_function = self.key_chars[ges.direction.."_func"]
            if key_function then
                key_function()
            end
        end
        self.skiptap = true
    elseif self.keyboard.umlautmode_keys[self.label] ~= nil then
        self.callback = function () self.keyboard:setLayer("Äéß") end
        self.skiptap = true
    elseif self.label == "" then
        self.callback = function () self.keyboard:delChar() end
        self.hold_callback = function ()
            self.ignore_key_release = true -- don't have delChar called on release
            self.keyboard:delToStartOfLine()
        end
        self.swipe_callback = function(ges)
            if ges.direction == "west" then
                self.keyboard:delWord(true) -- left to cursor
            elseif ges.direction == "north" then
                self.keyboard:delWord()
            end
        end
        --self.skiphold = true
    elseif self.label == "←" then
        self.callback = function() self.keyboard:leftChar() end
        self.hold_callback = function()
            self.ignore_key_release = true
            self.keyboard:goToStartOfLine()
        end
    elseif self.label == "→" then
        self.callback = function() self.keyboard:rightChar() end
        self.hold_callback = function()
            self.ignore_key_release = true
            self.keyboard:goToEndOfLine()
        end
    elseif self.label == "↑" then
        self.callback = function() self.keyboard:upLine() end
        self.hold_callback = function()
            self.ignore_key_release = true
            self.keyboard:scrollUp()
        end
    elseif self.label == "↓" then
        self.callback = function() self.keyboard:downLine() end
        self.hold_callback = function()
            self.ignore_key_release = true
            self.keyboard:scrollDown()
        end
    else
        self.callback = function()
            self.keyboard:addChar(self.key)
            if self.close_after_callback_widget then
                UIManager:close(self.close_after_callback_widget)
            end
            if self.keyboard.shiftmode and not self.keyboard.symbolmode and self.keyboard.release_shift then
                self.keyboard:setLayer("Shift")
            end
        end
        self.hold_callback = function()
            if not self.key_chars then return end

            VirtualKeyPopup:new{
                parent_key = self,
            }
        end
        self.hold_cb_is_popup = true
        if #swypeNormalizeText(self.key) ~= 1 then
            self.swipe_callback = function(ges)
                local key_string = self.key_chars[ges.direction] or self.key
                local key_function = self.key_chars[ges.direction.."_func"]

                if not key_function and key_string then
                    if type(key_string) == "table" and key_string.key then
                        key_string = key_string.key
                    end
                    self.keyboard:addChar(key_string)
                elseif key_function then
                    key_function()
                end
            end
        end
    end

    local label_widget
    if self.icon then
        -- Scale icon to fit other characters height
        -- (use *1.5 as our icons have a bit of white padding)
        local icon_height = math.ceil(self.face.size * 1.5)
        label_widget = ImageWidget:new{
            file = self.icon,
            scale_factor = 0, -- keep icon aspect ratio
            height = icon_height,
            width = self.width - 2*self.bordersize,
        }
    else
        label_widget = TextWidget:new{
            text = self.label,
            face = self.face,
            bold = self.bold or false,
        }
        -- Make long labels fit by decreasing font size
        local max_width = self.width - 2*self.bordersize - 2*Size.padding.small
        while label_widget:getWidth() > max_width do
            local new_size = label_widget.face.orig_size - 1
            label_widget:free()
            if new_size < 8 then break end -- don't go too small
            label_widget = TextWidget:new{
                text = self.label,
                face = Font:getFace(self.face.orig_font, new_size),
                bold = self.bold or false,
            }
        end
    end

    if self.alt_label then
        local OverlapGroup = require("ui/widget/overlapgroup")
        local alt_label_widget = TextWidget:new{
            text = self.alt_label,
            face = Font:getFace(self.face.orig_font, label_font_size - 4),
            bold = self.bold or false,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            padding = 0, -- no additional padding to font line height
        }
        local key_inner_dimen = Geom:new{
            w = self.width - 2*self.bordersize - 2*Size.padding.default,
            h = self.height - 2*self.bordersize - 2*Size.padding.small, -- already some padding via line height
        }
        label_widget = OverlapGroup:new{
            CenterContainer:new{
                dimen = key_inner_dimen,
                label_widget,
            },
            WidgetContainer:new{
                overlap_align = "right",
                dimen = Geom:new{
                    w = alt_label_widget:getSize().w,
                    h = key_inner_dimen.h,
                },
                alt_label_widget,
            },
        }
    end
    self.swype_mvp_label_widget = label_widget
    self[1] = FrameContainer:new{
        margin = 0,
        bordersize = self.bordersize,
        background = Blitbuffer.COLOR_WHITE,
        radius = 0,
        padding = 0,
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geom:new{
                w = self.width - 2*self.bordersize,
                h = self.height - 2*self.bordersize,
            },
            label_widget,
        },
    }
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    --self.dimen = self[1]:getSize()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
        HoldReleaseKey = {
            GestureRange:new{
                ges = "hold_release",
                range = self.dimen,
            },
        },
        PanReleaseKey = {
            GestureRange:new{
                ges = "pan_release",
                range = self.dimen,
            },
        },
        SwipeKey = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        },
        MultiswipeKey = {
            GestureRange:new{
                ges = "multiswipe",
                range = self.dimen,
            },
        },
    }
    if ((self.keyboard.shiftmode_keys[self.label] ~= nil or self.keyboard.shiftmode_keys[self.key])  and self.keyboard.shiftmode) or
        (self.keyboard.umlautmode_keys[self.label] ~= nil and self.keyboard.umlautmode) or
        (self.keyboard.symbolmode_keys[self.label] ~= nil and self.keyboard.symbolmode) then
        self[1].background = Blitbuffer.COLOR_LIGHT_GRAY
    end
    self.flash_keyboard = G_reader_settings:nilOrTrue("flash_keyboard")
end

function VirtualKey:paintTo(...)
    InputContainer.paintTo(self, ...)

    -- Fudge self.dimen to include the padding, to make sure said padding is covered by our ges_events range...
    -- Like Geom, floor coordinates & ceil dims, to fill the gaps without overlaps.
    local coords_padding = math.floor(self.keyboard.key_padding / 2)
    local dims_padding = self.keyboard.key_padding -- i.e., coords_padding + math.ceil(self.keyboard.key_padding / 2)
    self.dimen.x = self.dimen.x - coords_padding
    self.dimen.w = self[1].dimen.w + dims_padding
    self.dimen.y = self.dimen.y - coords_padding
    self.dimen.h = self[1].dimen.h + dims_padding
end

function VirtualKey:genKeyboardLayoutKeyChars()
    local positions = {
        "northeast",
        "north",
        "northwest",
        "west",
    }
    local keyboard_layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    local key_chars = {
        { label = "🌐",
        },
        east = { label = "⋮", },
        east_func = function ()
            UIManager:close(self.popup)
            self.keyboard_layout_dialog = KeyboardLayoutDialog:new{
                parent = self,
                keyboard_state = keyboard_state,
            }
            UIManager:show(self.keyboard_layout_dialog)
        end,
    }
    for i = 1, #keyboard_layouts do
        key_chars[positions[i]] = string.sub(keyboard_layouts[i], 1, 2)
        key_chars[positions[i] .. "_func"] = function()
            UIManager:close(self.popup)
            self.keyboard:setKeyboardLayout(keyboard_layouts[i])
        end
    end
    return key_chars
end

-- NOTE: We currently don't ever set want_flash to true (c.f., our invert method).
function VirtualKey:update_keyboard(want_flash, want_a2)
    -- NOTE: We use "a2" for the highlights.
    --       We flash the *full* keyboard when we release a hold.
    if want_flash then
        UIManager:setDirty(self.keyboard, function()
            return "flashui", self.keyboard.dimen
        end)
    else
        local refresh_type = "ui"
        if want_a2 then
            refresh_type = "a2"
        end
        -- Only repaint the key itself, not the full board...
        -- NOTE: We use self[1] (i.e., FrameContainer),
        --       because we fudge self.dimen to include the padding for the gesture hitbox...
        UIManager:widgetRepaint(self[1], self[1].dimen.x, self[1].dimen.y)
        logger.dbg("update key", self.key)
        UIManager:setDirty(nil, refresh_type, self[1].dimen)

        -- NOTE: On MTK, we'd have to forcibly stall a bit for the highlights to actually show.
        --[[
        UIManager:forceRePaint()
        UIManager:yieldToEPDC(3000)
        --]]
    end
end

function VirtualKey:onFocus()
    self[1].inner_bordersize = self.focused_bordersize
end

function VirtualKey:onUnfocus()
    self[1].inner_bordersize = 0
end

function VirtualKey:onTapSelect(skip_flash)
    Device:performHapticFeedback("KEYBOARD_TAP")
    -- just in case it's not flipped to false on hold release where it's supposed to
    self.keyboard.ignore_first_hold_release = false
    if self.flash_keyboard and not skip_flash and not self.skiptap then
        self:invert(true)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()

        self:invert(false)
        if self.callback then
            self.callback()
        end
        UIManager:forceRePaint()
    else
        if self.callback then
            self.callback()
        end
    end
    return true
end

function VirtualKey:onHoldSelect()
    Device:performHapticFeedback("LONG_PRESS")
    -- No visual feedback necessary if we're going to show a popup on top of the key ;).
    if self.flash_keyboard and not self.skiphold and not self.hold_cb_is_popup then
        self:invert(true)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()

        -- NOTE: We do *NOT* set hold to true here,
        --       because some mxcfb drivers apparently like to merge the flash that it would request
        --       with the following key redraw, leading to an unsightly double flash :/.
        self:invert(false)
        if self.hold_callback then
            self.hold_callback()
        end
        UIManager:forceRePaint()
    else
        if self.hold_callback then
            self.hold_callback()
        end
    end
    return true
end

function VirtualKey:onSwipeKey(arg, ges)
    if self.keyboard and self.keyboard:isSwypeMvpEnabled() then
        local is_text_key = not self.is_swype_candidate and #swypeNormalizeText(self.key or self.label) == 1
        if is_text_key then
            self.keyboard:onSwypeWordSwipe(arg, ges, self)
            return true
        elseif self.keyboard.swype_mvp_trace then
            self.keyboard:_swypeReset()
        end
    end
    if G_reader_settings:isFalse("keyboard_swipes_enabled") then
        return self:onTapSelect()
    end
    Device:performHapticFeedback("KEYBOARD_TAP")
    if self.flash_keyboard then
        self:invert(true)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()

        self:invert(false)
        if self.swipe_callback then
            self.swipe_callback(ges)
        end
        UIManager:forceRePaint()
    else
        if self.swipe_callback then
            self.swipe_callback(ges)
        end
    end
    return true
end

function VirtualKey:onMultiswipeKey(arg, ges)
    if self.keyboard and self.keyboard:isSwypeMvpEnabled() then
        local is_text_key = not self.is_swype_candidate and #swypeNormalizeText(self.key or self.label) == 1
        if is_text_key then
            self.keyboard:onSwypeWordMultiswipe(arg, ges, self)
            return true
        elseif self.keyboard.swype_mvp_trace then
            self.keyboard:_swypeReset()
        end
    end
    return self:onSwipeKey(arg, ges)
end

function VirtualKey:onHoldReleaseKey()
    if ignore_key_release then
        ignore_key_release = nil
        return true
    end
    if self.ignore_key_release then
        self.ignore_key_release = nil
        return true
    end
    Device:performHapticFeedback("LONG_PRESS")
    if self.keyboard.ignore_first_hold_release then
        self.keyboard.ignore_first_hold_release = false
        return true
    end
    self:onTapSelect()
    return true
end

function VirtualKey:onPanReleaseKey(arg, ges)
    if self.keyboard and self.keyboard:isSwypeMvpEnabled() and self.keyboard:onSwypeWordPanRelease(arg, ges) then
        return true
    end
    if self.ignore_key_release then
        self.ignore_key_release = nil
        return true
    end
    Device:performHapticFeedback("LONG_PRESS")
    if self.keyboard.ignore_first_hold_release then
        self.keyboard.ignore_first_hold_release = false
        return true
    end
    self:onTapSelect()
    return true
end

-- NOTE: We currently don't ever set hold to true (c.f., our onHoldSelect method)
function VirtualKey:invert(invert, hold)
    if invert then
        self[1].inner_bordersize = self.focused_bordersize
    else
        self[1].inner_bordersize = 0
    end
    self:update_keyboard(hold, true)
end

VirtualKeyPopup = FocusManager:extend{
    modal = true,
    disable_double_tap = true,
    inputbox = nil,
    layout = nil, -- array
}

function VirtualKeyPopup:onTapClose(arg, ges)
    if ges.pos:notIntersectWith(self.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function VirtualKeyPopup:onClose()
    UIManager:close(self)
    return true
end

function VirtualKeyPopup:onCloseWidget()
    self:free()
    UIManager:setDirty(nil, function()
        return "ui", self.dimen
    end)
end

function VirtualKeyPopup:init()
    local parent_key = self.parent_key
    local key_chars = parent_key.key_chars
    local key_char_orig = key_chars[1]
    local key_char_orig_func = parent_key.callback

    self.layout = {}
    local rows = {
        extra_key_chars = {
            key_chars[2],
            key_chars[3],
            key_chars[4],
            -- _func equivalent for unnamed extra keys
            key_chars[5],
            key_chars[6],
            key_chars[7],
        },
        top_key_chars = {
            key_chars.northwest,
            key_chars.north,
            key_chars.northeast,
            key_chars.northwest_func,
            key_chars.north_func,
            key_chars.northeast_func,
        },
        middle_key_chars = {
            key_chars.west,
            key_char_orig,
            key_chars.east,
            key_chars.west_func,
            key_char_orig_func,
            key_chars.east_func,
        },
        bottom_key_chars = {
            key_chars.southwest,
            key_chars.south,
            key_chars.southeast,
            key_chars.southwest_func,
            key_chars.south_func,
            key_chars.southeast_func,
        },
    }
    if util.tableSize(rows.extra_key_chars) == 0 then rows.extra_key_chars = nil end
    if util.tableSize(rows.top_key_chars) == 0 then rows.top_key_chars = nil end
    -- we should always have a middle
    if util.tableSize(rows.bottom_key_chars) == 0 then rows.bottom_key_chars = nil end

    -- to store if a column exists
    local columns = {}
    local blank = {
        HorizontalSpan:new{width = 0},
        HorizontalSpan:new{width = parent_key.width},
        HorizontalSpan:new{width = 0},
    }
    local h_key_padding = {
        HorizontalSpan:new{width = 0},
        HorizontalSpan:new{width = parent_key.keyboard.key_padding},
        HorizontalSpan:new{width = 0},
    }
    local v_key_padding = VerticalSpan:new{width = parent_key.keyboard.key_padding}

    local vertical_group = VerticalGroup:new{ allow_mirroring = false }
    local horizontal_group_extra = HorizontalGroup:new{ allow_mirroring = false }
    local horizontal_group_top = HorizontalGroup:new{ allow_mirroring = false }
    local horizontal_group_middle = HorizontalGroup:new{ allow_mirroring = false }
    local horizontal_group_bottom = HorizontalGroup:new{ allow_mirroring = false }

    local function horizontalRow(chars, group)
        local layout_horizontal = {}

        for i = 1,3 do
            local v = chars[i]
            local v_func = chars[i+3]

            if v then
                columns[i] = true
                blank[i].width = blank[2].width
                if i == 1 then
                    h_key_padding[i].width = h_key_padding[2].width
                end

                local key = type(v) == "table" and v.key or v
                local label = type(v) == "table" and v.label or key
                local icon = type(v) == "table" and v.icon
                local bold = type(v) == "table" and v.bold
                local virtual_key = VirtualKey:new{
                    key = key,
                    label = label,
                    icon = icon,
                    bold = bold,
                    keyboard = parent_key.keyboard,
                    key_chars = key_chars,
                    width = parent_key.width,
                    height = parent_key.height,
                    close_after_callback_widget = self,
                }
                -- Support any function as a callback.
                if v_func then
                    virtual_key.callback = v_func
                end
                -- don't open another popup on hold
                virtual_key.hold_callback = nil
                -- close popup on hold release
                virtual_key.onHoldReleaseKey = function()
                    -- NOTE: Check our *parent* key!
                    if parent_key.ignore_key_release then
                        parent_key.ignore_key_release = nil
                        return true
                    end
                    Device:performHapticFeedback("LONG_PRESS")
                    if virtual_key.keyboard.ignore_first_hold_release then
                        virtual_key.keyboard.ignore_first_hold_release = false
                        return true
                    end

                    virtual_key:onTapSelect(true)
                    UIManager:close(self)
                    return true
                end
                virtual_key.onPanReleaseKey = virtual_key.onHoldReleaseKey

                if v == key_char_orig then
                    virtual_key[1].background = Blitbuffer.COLOR_LIGHT_GRAY

                    -- restore ability to hold/pan release on central key after opening popup
                    virtual_key._keyOrigHoldPanHandler = function()
                        virtual_key.onHoldReleaseKey = virtual_key._onHoldReleaseKey
                        virtual_key.onPanReleaseKey = virtual_key._onPanReleaseKey
                    end
                    virtual_key._onHoldReleaseKey = virtual_key.onHoldReleaseKey
                    virtual_key.onHoldReleaseKey = virtual_key._keyOrigHoldPanHandler
                    virtual_key._onPanReleaseKey = virtual_key.onPanReleaseKey
                    virtual_key.onPanReleaseKey = virtual_key._keyOrigHoldPanHandler
                end

                table.insert(group, virtual_key)
                table.insert(layout_horizontal, virtual_key)
            else
                table.insert(group, blank[i])
            end
            table.insert(group, h_key_padding[i])
        end
        table.insert(vertical_group, group)
        table.insert(self.layout, layout_horizontal)
    end
    if rows.extra_key_chars then
        horizontalRow(rows.extra_key_chars, horizontal_group_extra)
        table.insert(vertical_group, v_key_padding)
    end
    if rows.top_key_chars then
        horizontalRow(rows.top_key_chars, horizontal_group_top)
        table.insert(vertical_group, v_key_padding)
    end
    -- always middle row
    horizontalRow(rows.middle_key_chars, horizontal_group_middle)
    if rows.bottom_key_chars then
        table.insert(vertical_group, v_key_padding)
        horizontalRow(rows.bottom_key_chars, horizontal_group_bottom)
    end

    if not columns[3] then
        h_key_padding[2].width = 0
    end

    local num_rows = util.tableSize(rows)
    local num_columns = util.tableSize(columns)

    local keyboard_frame = FrameContainer:new{
        margin = 0,
        bordersize = Size.border.default,
        background = G_reader_settings:nilOrTrue("keyboard_key_border") and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        radius = 0,
        padding = parent_key.keyboard.padding,
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geom:new{
                w = parent_key.width*num_columns + 2*Size.border.default + (num_columns+1)*parent_key.keyboard.key_padding,
                h = parent_key.height*num_rows + 2*Size.border.default + (num_rows+1)*parent_key.keyboard.key_padding,
            },
            vertical_group,
        }
    }
    keyboard_frame.dimen = keyboard_frame:getSize()
    self.dimen = keyboard_frame.dimen

    self.ges_events.TapClose = {
        GestureRange:new{
            ges = "tap",
        }
    }
    self.tap_interval_override = time.ms(G_reader_settings:readSetting("ges_tap_interval_on_keyboard_ms", 0))

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local offset_x = 2*keyboard_frame.bordersize + keyboard_frame.padding + parent_key.keyboard.key_padding
    if columns[1] then
        offset_x = offset_x + parent_key.width + parent_key.keyboard.key_padding
    end

    local offset_y = 2*keyboard_frame.bordersize + keyboard_frame.padding + parent_key.keyboard.key_padding
    if rows.extra_key_chars then
        offset_y = offset_y + parent_key.height + parent_key.keyboard.key_padding
    end
    if rows.top_key_chars then
        offset_y = offset_y + parent_key.height + parent_key.keyboard.key_padding
    end

    local position_container = WidgetContainer:new{
        dimen = {
            x = parent_key.dimen.x - offset_x,
            y = parent_key.dimen.y - offset_y,
            h = Screen:getSize().h,
            w = Screen:getSize().w,
        },
        keyboard_frame,
    }
    if position_container.dimen.x < 0 then
        position_container.dimen.x = 0
        -- We effectively move the popup, which means the key underneath our finger may no longer *exactly* be parent_key.
        -- Make sure we won't close the popup right away, as that would risk being a *different* key, in order to make that less confusing.
        parent_key.ignore_key_release = true
    elseif position_container.dimen.x + keyboard_frame.dimen.w > Screen:getWidth() then
        position_container.dimen.x = Screen:getWidth() - keyboard_frame.dimen.w
        parent_key.ignore_key_release = true
    end
    if position_container.dimen.y < 0 then
        position_container.dimen.y = 0
        parent_key.ignore_key_release = true
    elseif position_container.dimen.y + keyboard_frame.dimen.h > Screen:getHeight() then
        position_container.dimen.y = Screen:getHeight() - keyboard_frame.dimen.h
        parent_key.ignore_key_release = true
    end

    self[1] = position_container

    UIManager:show(self)
    -- Ensure the post-paint refresh will be able to grab updated coordinates from keyboard_frame by using a refresh function
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

local VirtualKeyboard = FocusManager:extend{
    name = "VirtualKeyboard",
    visible = false,
    lock_visibility = false,
    covers_footer = true,
    modal = true,
    disable_double_tap = true,
    inputbox = nil,
    KEYS = nil, -- table to store layouts
    shiftmode_keys = nil, -- table
    symbolmode_keys = nil, -- table
    utf8mode_keys = nil, -- table
    umlautmode_keys = nil, -- table
    keyboard_layer = 2,
    shiftmode = false,
    symbolmode = false,
    umlautmode = false,
    layout = nil, -- array

    height = nil,
    default_label_size = DEFAULT_LABEL_SIZE,
    bordersize = Size.border.default,
    padding = 0,
    key_padding = Size.padding.small,

    lang_to_keyboard_layout = {
        ar = "ar_keyboard",
        bg_BG = "bg_keyboard",
        bn = "bn_keyboard",
        cs = "cs_keyboard",
        da = "da_keyboard",
        de = "de_keyboard",
        el = "el_keyboard",
        en = "en_keyboard",
        es = "es_keyboard",
        fa = "fa_keyboard",
        fr = "fr_keyboard",
        he = "he_keyboard",
        hu = "hu_keyboard",
        ja = "ja_keyboard",
        ka = "ka_keyboard",
        ko_KR = "ko_KR_keyboard",
        ml = "ml_keyboard",
        nb_NO = "no_keyboard",
        pl = "pl_keyboard",
        pt_BR = "pt_keyboard",
        ro = "ro_keyboard",
        ru = "ru_keyboard",
        sk = "sk_keyboard",
        sr = "sr_keyboard",
        sv = "sv_keyboard",
        th = "th_keyboard",
        tr = "tr_keyboard",
        uk = "uk_keyboard",
        vi = "vi_keyboard",
        zh = "zh_keyboard",
        zh_CN = "zh_CN_keyboard",
    },

    lang_has_submenu = {
        ja = true,
        zh = true,
        zh_CN = true,
    },
}

function VirtualKeyboard:init()
    if self.uwrap_func then
        self.uwrap_func()
        self.uwrap_func = nil
    end
    local lang = self:getKeyboardLayout()
    local keyboard_layout = self.lang_to_keyboard_layout[lang] or self.lang_to_keyboard_layout["en"]
    local keyboard = require("ui/data/keyboardlayouts/" .. keyboard_layout)
    self.KEYS = keyboard.keys or {}
    self.shiftmode_keys = keyboard.shiftmode_keys or {}
    self.symbolmode_keys = keyboard.symbolmode_keys or {}
    self.utf8mode_keys = keyboard.utf8mode_keys or {}
    self.umlautmode_keys = keyboard.umlautmode_keys or {}
    local dictionary = G_reader_settings:readSetting(SWYPE_MVP_DICTIONARY_SETTING, "en")
    if dictionary ~= "en" and dictionary ~= "pl" then
        dictionary = "en"
    end
    self.swype_mvp_dictionary = dictionary
    self.width = Screen:getWidth()
    local keys_height = G_reader_settings:isTrue("keyboard_key_compact") and 48 or 64
    self.height = Screen:scaleBySize(keys_height * (#self.KEYS + 1))
    self.min_layer = keyboard.min_layer
    self.max_layer = keyboard.max_layer
    self:initLayer(self.keyboard_layer)
    self.tap_interval_override = time.ms(G_reader_settings:readSetting("ges_tap_interval_on_keyboard_ms", 0))
    if Device:hasKeys() then
        self.key_events.Close = { { "Back" } }
    end
    if keyboard.wrapInputBox then
        self.uwrap_func = keyboard.wrapInputBox(self.inputbox) or self.uwrap_func
    end
    if Device:hasDPad() and Device:hasKeyboard() then
        -- Use physical keyboard for most characters
        -- For special characters not available in physical keyboard
        -- Use arrow and Press keys to select in VirtualKeyboard
        for k, seq in pairs(self.extra_key_events) do
            if self:_isTextKeyWithoutModifier(seq) then
                self.key_events[k] = nil
            end
        end
    end
end

function VirtualKeyboard:_isTextKeyWithoutModifier(seq)
    for _, oneseq in ipairs(seq) do
        if #oneseq ~= 1 then -- has modifier key combination
            return false
        end
        if #oneseq[1] ~= 1 then -- not simple text key, like Home, End
            return false
        end
    end
    return true
end

function VirtualKeyboard:getKeyboardLayout()
    if G_reader_settings:isFalse("keyboard_remember_layout") and not keyboard_state.force_current_layout then
        local lang = G_reader_settings:readSetting("keyboard_layout_default")
            or G_reader_settings:readSetting("keyboard_layout", "en")
        G_reader_settings:saveSetting("keyboard_layout", lang)
    end
    return G_reader_settings:readSetting("keyboard_layout") or G_reader_settings:readSetting("language")
end

function VirtualKeyboard:setKeyboardLayout(layout)
    keyboard_state.force_current_layout = true
    local prev_keyboard_height = self.dimen and self.dimen.h
    G_reader_settings:saveSetting("keyboard_layout", layout)
    self:init()
    if prev_keyboard_height and self.dimen.h ~= prev_keyboard_height then
        self:_refresh(true, true)
        -- Keyboard height change: notify parent (InputDialog)
        if self.inputbox and self.inputbox.parent and self.inputbox.parent.onKeyboardHeightChanged then
            self.inputbox.parent:onKeyboardHeightChanged()
        end
    else
        self:_refresh(true)
    end
    keyboard_state.force_current_layout = false
end

function VirtualKeyboard:onClose()
    UIManager:close(self)
    return true
end

function VirtualKeyboard:_refresh(want_flash, fullscreen)
    local refresh_type = "ui"
    if want_flash then
        refresh_type = "flashui"
    end
    if fullscreen then
        UIManager:setDirty("all", refresh_type)
        return
    end
    UIManager:setDirty(self, function()
        return refresh_type, self.dimen
    end)
end

function VirtualKeyboard:_swypeScheduleWarmUp(delay)
    self.swype_mvp_warm_generation = (self.swype_mvp_warm_generation or 0) + 1
    local generation = self.swype_mvp_warm_generation
    local dictionary = self.swype_mvp_dictionary or "en"
    UIManager:scheduleIn(delay or 0.35, function()
        if self.swype_mvp_warm_generation ~= generation
                or not self.visible
                or self.swype_mvp_dictionary ~= dictionary then
            return
        end
        if self.swype_mvp_trace then
            self:_swypeScheduleWarmUp(0.5)
            return
        end

        swypeKeepOnlyBucketDictionary(dictionary)
        swypeOpenBucketDictionary(dictionary)
        swypeWarmScoring()
    end)
end

function VirtualKeyboard:onShow()
    self:_refresh(true)
    self.visible = true
    self:_swypeScheduleWarmUp()
    return true
end

function VirtualKeyboard:onCloseWidget()
    self.swype_mvp_warm_generation = (self.swype_mvp_warm_generation or 0) + 1
    self:_swypeCancelBucketPrefetch()
    self:_swypeCommitPendingContext()
    self:_swypeSaveContext()
    self:_refresh(true)
    self.visible = false
end

function VirtualKeyboard:lockVisibility(toggle)
    self.lock_visibility = toggle
end

function VirtualKeyboard:setVisibility(toggle)
    if self.lock_visibility then
        return
    end

    if toggle then
        UIManager:show(self)
    else
        self:onClose()
    end
end

function VirtualKeyboard:isVisible()
    return self.visible
end

function VirtualKeyboard:showKeyboard(ignore_first_hold_release)
    if not self:isVisible() then
        self.ignore_first_hold_release = ignore_first_hold_release
        self:setVisibility(true)
    end
end

function VirtualKeyboard:hideKeyboard()
    if self:isVisible() then
        self:setVisibility(false)
    end
end

function VirtualKeyboard:initLayer(layer)
    local function VKLayer(b1, b2, b3)
        local function boolnum(bool)
            return bool and 1 or 0
        end
        return 2 - boolnum(b1) + 2 * boolnum(b2) + 4 * boolnum(b3)
    end

    if layer then
        -- to be sure layer is selected properly
        layer = math.max(layer, self.min_layer)
        layer = math.min(layer, self.max_layer)
        self.keyboard_layer = layer
        -- fill the layer modes
        self.shiftmode  = (layer == 1 or layer == 3 or layer == 5 or layer == 7 or layer == 9 or layer == 11)
        self.symbolmode = (layer == 3 or layer == 4 or layer == 7 or layer == 8 or layer == 11 or layer == 12)
        self.umlautmode   = (layer == 5 or layer == 6 or layer == 7 or layer == 8)
    else -- or, without input parameter, restore layer from current layer modes
        self.keyboard_layer = VKLayer(self.shiftmode, self.symbolmode, self.umlautmode)
    end
    self:addKeys()
end

function VirtualKeyboard:addKeys()
    self:free() -- free previous keys' TextWidgets
    self.layout = {}
    self.swype_mvp_candidate_keys = {}
    local candidate_row_count = 1
    local row_count = #self.KEYS + candidate_row_count
    local base_key_width = math.floor((self.width - (#self.KEYS[1] + 1)*self.key_padding - 2*self.padding)/#self.KEYS[1])
    local base_key_height = math.floor((self.height - (row_count + 1)*self.key_padding - 2*self.padding)/row_count)
    local h_key_padding = HorizontalSpan:new{width = self.key_padding}
    local v_key_padding = VerticalSpan:new{width = self.key_padding}
    local vertical_group = VerticalGroup:new{ allow_mirroring = false }
    do
        local horizontal_group = HorizontalGroup:new{ allow_mirroring = false }
        local layout_horizontal = {}
        local candidates = self.swype_mvp_candidates or {}
        local slot_count = 4
        local candidate_width = math.floor((self.width - (slot_count + 1)*self.key_padding - 2*self.padding) / slot_count)
        for i = 1, slot_count do
            local candidate = i > 1 and candidates[i - 1] or nil
            local word = i == 1
                and self:_swypeDictionaryLabel()
                or (candidate and candidate.word or " ")
            local virtual_key = VirtualKey:new{
                key = word,
                label = word,
                keyboard = self,
                width = candidate_width,
                height = base_key_height,
            }
            virtual_key.is_swype_candidate = true
            virtual_key.swype_mvp_candidate_index = i
            virtual_key.swipe_callback = nil
            virtual_key.hold_callback = nil
            virtual_key.callback = function()
                if i == 1 then
                    self:_swypeToggleDictionary()
                else
                    local current_candidates = self.swype_mvp_candidates or {}
                    local current_candidate = current_candidates[i - 1]
                    if current_candidate then
                        self:_swypeSelectCandidate(current_candidate)
                    end
                end
            end
            table.insert(self.swype_mvp_candidate_keys, virtual_key)
            table.insert(horizontal_group, virtual_key)
            table.insert(layout_horizontal, virtual_key)
            if i ~= slot_count then
                table.insert(horizontal_group, h_key_padding)
            end
        end
        table.insert(vertical_group, horizontal_group)
        table.insert(self.layout, layout_horizontal)
        table.insert(vertical_group, v_key_padding)
    end
    for i = 1, #self.KEYS do
        local horizontal_group = HorizontalGroup:new{ allow_mirroring = false }
        local layout_horizontal = {}
        for j = 1, #self.KEYS[i] do
            local key
            local key_chars = self.KEYS[i][j][self.keyboard_layer]
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
            width_factor = width_factor or self.KEYS[i][j].width or self.KEYS[i].width or 1.0
            local key_width = math.floor((base_key_width + self.key_padding) * width_factor)
                            - self.key_padding
            local key_height = base_key_height
            label = label or self.KEYS[i][j].label or key
            if label == "" and self.shiftmode and (not self.release_shift or self.symbolmode) then
                key = label
                label = "" -- capslock symbol
            end
            local virtual_key = VirtualKey:new{
                key = key,
                key_chars = key_chars,
                icon = self.KEYS[i][j].icon,
                label = label,
                alt_label = alt_label,
                bold = self.KEYS[i][j].bold,
                keyboard = self,
                width = key_width,
                height = key_height,
            }
            if not virtual_key.key_chars and label ~= "" then
                virtual_key.swipe_callback = nil
            end
            table.insert(horizontal_group, virtual_key)
            table.insert(layout_horizontal, virtual_key)
            if j ~= #self.KEYS[i] then
                table.insert(horizontal_group, h_key_padding)
            end
        end
        table.insert(vertical_group, horizontal_group)
        table.insert(self.layout, layout_horizontal)
        if i ~= #self.KEYS then
            table.insert(vertical_group, v_key_padding)
        end
    end

    local keyboard_frame = FrameContainer:new{
        margin = 0,
        bordersize = Size.border.default,
        background = G_reader_settings:nilOrTrue("keyboard_key_border") and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        radius = 0,
        padding = self.padding,
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geom:new{
                w = self.width - 2*Size.border.default - 2*self.padding,
                h = self.height - 2*Size.border.default - 2*self.padding,
            },
            vertical_group,
        }
    }
    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        keyboard_frame,
    }
    -- Point our top-level dimen to the relevant widget, keyboard_frame
    keyboard_frame.dimen = keyboard_frame:getSize()
    self.dimen = keyboard_frame.dimen
    self.ges_events.SwypeWordPan = {
        GestureRange:new{
            ges = "pan",
            range = function() return self.dimen end,
            rate = 60,
        },
    }
    self.ges_events.SwypeWordPanRelease = {
        GestureRange:new{
            ges = "pan_release",
            range = function() return self.dimen end,
        },
    }
    self.ges_events.SwypeWordSwipe = {
        GestureRange:new{
            ges = "swipe",
            range = function() return self.dimen end,
        },
    }
    self.ges_events.SwypeWordMultiswipe = {
        GestureRange:new{
            ges = "multiswipe",
            range = function() return self.dimen end,
        },
    }
end

function VirtualKeyboard:isSwypeMvpEnabled()
    return G_reader_settings:nilOrTrue("keyboard_swype_mvp_enabled")
        and not self.symbolmode
        and not self.umlautmode
end

function VirtualKeyboard:_swypeKeyAt(pos)
    if not pos or not self.layout then
        return
    end
    for _, row in ipairs(self.layout) do
        for _, key in ipairs(row) do
            if key.dimen and key.dimen:contains(pos) then
                if key.is_swype_candidate then
                    return
                end
                local normalized = swypeNormalizeText(key.key or key.label)
                if #normalized == 1 then
                    return normalized, key
                end
                return nil, key
            end
        end
    end
end

function VirtualKeyboard:_swypeEndpointLetters(pos, exact_last)
    local candidates = {}
    local seen = {}
    if exact_last and #exact_last == 1 then
        table.insert(candidates, exact_last)
        seen[exact_last] = true
    end
    if not pos or not self.layout then
        return candidates
    end
    local nearby = {}
    for _, row in ipairs(self.layout) do
        for _, key in ipairs(row) do
            if key.dimen and not key.is_swype_candidate then
                local normalized = swypeNormalizeText(key.key or key.label)
                if #normalized == 1 and not seen[normalized] then
                    local center_x = key.dimen.x + key.dimen.w / 2
                    local center_y = key.dimen.y + key.dimen.h / 2
                    local dx = pos.x - center_x
                    local dy = pos.y - center_y
                    table.insert(nearby, {
                        letter = normalized,
                        distance = dx * dx + dy * dy,
                    })
                end
            end
        end
    end
    table.sort(nearby, function(left, right)
        return left.distance < right.distance
    end)
    for i = 1, math.min(2, #nearby) do
        table.insert(candidates, nearby[i].letter)
        seen[nearby[i].letter] = true
    end
    return candidates
end

function VirtualKeyboard:_swypeInvertPixelSet(pixel_set)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    for y, row in pairs(pixel_set or {}) do
        local run_start
        local previous_x
        local xs = {}
        for x in pairs(row) do
            table.insert(xs, x)
        end
        table.sort(xs)
        for _, current_x in ipairs(xs) do
            min_x = math.min(min_x, current_x)
            min_y = math.min(min_y, y)
            max_x = math.max(max_x, current_x)
            max_y = math.max(max_y, y)
            if not run_start then
                run_start = current_x
            elseif current_x ~= previous_x + 1 then
                Screen.bb:invertRect(run_start, y, previous_x - run_start + 1, 1)
                run_start = current_x
            end
            previous_x = current_x
        end
        if run_start then
            Screen.bb:invertRect(run_start, y, previous_x - run_start + 1, 1)
        end
    end
    if min_x == math.huge then
        return
    end
    return Geom:new{
        x = min_x,
        y = min_y,
        w = max_x - min_x + 1,
        h = max_y - min_y + 1,
    }
end

function VirtualKeyboard:_swypeDrawTraceSegment(previous, current)
    local trace = self.swype_mvp_trace
    if not trace or not current then
        return
    end
    trace.drawn_pixels = trace.drawn_pixels or {}
    local new_pixels = {}
    local radius = 1
    local start_x = previous and previous.x or current.x
    local start_y = previous and previous.y or current.y
    local dx = current.x - start_x
    local dy = current.y - start_y
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then
        steps = 1
    end
    for step = 0, steps do
        local center_x = math.floor(start_x + dx * step / steps + 0.5)
        local center_y = math.floor(start_y + dy * step / steps + 0.5)
        for offset_y = -radius, radius do
            local y = center_y + offset_y
            local row = trace.drawn_pixels[y]
            if not row then
                row = {}
                trace.drawn_pixels[y] = row
            end
            local new_row = new_pixels[y]
            if not new_row then
                new_row = {}
                new_pixels[y] = new_row
            end
            for offset_x = -radius, radius do
                local x = center_x + offset_x
                if not row[x] then
                    row[x] = true
                    new_row[x] = true
                end
            end
        end
    end
    local region = self:_swypeInvertPixelSet(new_pixels)
    if region then
        UIManager:setDirty(nil, "a2", region)
    end
end

function VirtualKeyboard:_swypeClearTracePixels(refresh_type)
    local trace = self.swype_mvp_trace
    if not trace or not trace.drawn_pixels then
        return
    end
    local region = self:_swypeInvertPixelSet(trace.drawn_pixels)
    trace.drawn_pixels = nil
    if region then
        UIManager:setDirty(nil, refresh_type or "ui", region)
    end
end

function VirtualKeyboard:_swypeCancelBucketPrefetch()
    self.swype_mvp_prefetch_generation = (self.swype_mvp_prefetch_generation or 0) + 1
    local controller = self.swype_mvp_bucket_prefetch
    if not controller then
        return
    end

    local cache = swype_mvp_bucket_cache[controller.dictionary] or {}
    local global_jobs = swype_mvp_bucket_prefetch_jobs[controller.dictionary] or {}
    for key, job in pairs(controller.jobs) do
        if not job.completed then
            job.cancelled = true
        end
        if not job.used then
            cache[key] = nil
        end
        if global_jobs[key] == job then
            global_jobs[key] = nil
        end
    end
    self.swype_mvp_bucket_prefetch = nil
end

function VirtualKeyboard:_swypeScheduleBucketPrefetch()
    local trace = self.swype_mvp_trace
    if not trace or #trace.letters < 2 then
        return
    end
    local dictionary = self.swype_mvp_dictionary or "en"
    local first = trace.letters[1]
    local controller = self.swype_mvp_bucket_prefetch
    if not controller or controller.dictionary ~= dictionary or controller.first ~= first then
        self:_swypeCancelBucketPrefetch()
        controller = {
            dictionary = dictionary,
            first = first,
            current_last = trace.letters[#trace.letters],
            jobs = {},
        }
        self.swype_mvp_bucket_prefetch = controller
        self.swype_mvp_prefetch_generation = (self.swype_mvp_prefetch_generation or 0) + 1
        controller.generation = self.swype_mvp_prefetch_generation
    else
        controller.current_last = trace.letters[#trace.letters]
    end
    if controller.scheduled then
        return
    end

    local function schedule_step(delay)
        controller.scheduled = true
        UIManager:scheduleIn(delay, function()
            controller.scheduled = false
            if self.swype_mvp_bucket_prefetch ~= controller
                    or self.swype_mvp_prefetch_generation ~= controller.generation
                    or not self.swype_mvp_trace then
                return
            end

            local cache = swype_mvp_bucket_cache[controller.dictionary] or {}
            local selected_key = controller.first .. (controller.current_last or "")
            local selected_job
            if not cache[selected_key] then
                selected_job = controller.jobs[selected_key]
            else
                selected_key = nil
            end
            if not selected_key or (selected_job and (selected_job.completed or selected_job.cancelled)) then
                selected_key = nil
                selected_job = nil
                for code = string.byte("a"), string.byte("z") do
                    local key = controller.first .. string.char(code)
                    local job = controller.jobs[key]
                    if not cache[key] and (not job or not job.completed) then
                        selected_key = key
                        selected_job = job
                        break
                    end
                end
            end

            if not selected_job and selected_key then
                selected_job = swypeStartBucketPrefetch(
                    controller.first, string.sub(selected_key, 2, 2), controller.dictionary)
                if selected_job then
                    controller.jobs[selected_key] = selected_job
                end
            end
            if selected_job and not selected_job.completed and not selected_job.cancelled then
                swypeAdvanceBucketPrefetch(selected_job,
                    SWYPE_MVP_PREFETCH_BATCH_SIZE, SWYPE_MVP_PREFETCH_WORK_MS)
            end

            local unfinished = false
            for code = string.byte("a"), string.byte("z") do
                local key = controller.first .. string.char(code)
                if not (swype_mvp_bucket_cache[controller.dictionary]
                        and swype_mvp_bucket_cache[controller.dictionary][key]) then
                    unfinished = true
                    break
                end
            end
            if unfinished then
                schedule_step(0.01)
            end
        end)
    end
    schedule_step(0.06)
end

function VirtualKeyboard:_swypeReset(keep_prefetch)
    local trace = self.swype_mvp_trace
    if trace then
        self:_swypeClearTracePixels("ui")
    end
    if not keep_prefetch then
        self:_swypeCancelBucketPrefetch()
    end
    self.swype_mvp_trace_generation = (self.swype_mvp_trace_generation or 0) + 1
    self.swype_mvp_trace = nil
    self.swype_mvp_active = nil
    self.swype_mvp_last_point_time = nil
end

function VirtualKeyboard:_swypeScheduleTraceFinalize()
    self.swype_mvp_trace_generation = (self.swype_mvp_trace_generation or 0) + 1
    local generation = self.swype_mvp_trace_generation
    UIManager:scheduleIn(0.4, function()
        if self.swype_mvp_trace_generation ~= generation
                or not self.swype_mvp_trace
                or not self.swype_mvp_last_point_time
                or time.now() - self.swype_mvp_last_point_time < time.ms(350) then
            return
        end
        self:_swypeFinalizeTrace()
    end)
end

function VirtualKeyboard:_swypeAddPoint(pos)
    if not pos or not pos.x or not pos.y then
        return
    end
    local now = time.now()
    if self.swype_mvp_trace and self.swype_mvp_last_point_time
            and now - self.swype_mvp_last_point_time > time.ms(500) then
        self:_swypeReset()
    end
    self.swype_mvp_last_point_time = now
    if not self.swype_mvp_trace then
        self.swype_mvp_trace = {
            letters = {},
            points = {},
            letter_points = {},
            last_letter = nil,
            last_center = nil,
        }
    end
    local point = {
        x = math.floor(pos.x),
        y = math.floor(pos.y),
    }
    local points = self.swype_mvp_trace.points
    local previous_point = points[#points]
    local point_added = not previous_point
        or math.abs(point.x - previous_point.x) >= 2
        or math.abs(point.y - previous_point.y) >= 2
    if point_added then
        table.insert(points, point)
        self:_swypeDrawTraceSegment(previous_point, point)
    end

    local letter, key = self:_swypeKeyAt(pos)
    if not letter then
        return
    end
    local center
    if key and key.dimen then
        center = {
            x = key.dimen.x + math.floor(key.dimen.w / 2),
            y = key.dimen.y + math.floor(key.dimen.h / 2),
        }
    end
    if letter ~= self.swype_mvp_trace.last_letter then
        if center and self.swype_mvp_trace.last_center then
            local dx = center.x - self.swype_mvp_trace.last_center.x
            local dy = center.y - self.swype_mvp_trace.last_center.y
            if math.sqrt(dx * dx + dy * dy) < math.max(8, math.floor((key.dimen.w or 40) * 0.45)) then
                self:_swypeScheduleTraceFinalize()
                return
            end
        end
        table.insert(self.swype_mvp_trace.letters, letter)
        table.insert(self.swype_mvp_trace.letter_points, point)
        self.swype_mvp_trace.last_letter = letter
        self.swype_mvp_trace.last_center = center or self.swype_mvp_trace.last_center
        self:_swypeScheduleBucketPrefetch()
    end
    if #self.swype_mvp_trace.letters >= 2 then
        self.swype_mvp_active = true
    end
    self:_swypeScheduleTraceFinalize()
end

function VirtualKeyboard:_swypeAddKeyCenter(key)
    if key and key.dimen then
        self:_swypeAddPoint(Geom:new{
            x = key.dimen.x + math.floor(key.dimen.w / 2),
            y = key.dimen.y + math.floor(key.dimen.h / 2),
            w = 1,
            h = 1,
        })
    end
end

function VirtualKeyboard:_swypePickWord(signature)
    local candidates = self:_swypePickCandidates(signature, 1)
    if candidates[1] then
        return candidates[1].word, candidates[1].spatial_score
    end
end

function VirtualKeyboard:_swypeScoreEntry(signature, entry, trace_chars, next_positions,
        trace_info, key_centers, allow_endpoint_mismatch)
    local candidate = entry.signature
    local score, endpoint_mismatch = swypeMatchScore(
        candidate,
        trace_chars,
        next_positions,
        allow_endpoint_mismatch,
        trace_info and trace_info.letter_points,
        trace_info and trace_info.endpoint_pos,
        key_centers)
    local endpoint_score = swypeShortWordEndpointScore(signature, candidate)
    if endpoint_score and (#candidate <= 3 or (entry.freq or 0) >= 6500) then
        score = math.min(score, math.max(endpoint_score, score - 1))
    end
    if math.abs(#signature - #candidate) <= SWYPE_MVP_EDIT_DISTANCE_MAX then
        local edit_score = swypeEditDistance(
            signature, candidate, SWYPE_MVP_EDIT_DISTANCE_MAX)
        if edit_score <= SWYPE_MVP_EDIT_DISTANCE_MAX then
            score = math.min(score, edit_score + math.floor(#signature / 2))
        end
    end
    local context_bonus = trace_info and self:_swypeContextBonus(
        trace_info.previous_word, entry.word) or 0
    return score, score * SWYPE_MVP_SCORE_UNIT - (entry.freq or 0) - context_bonus
end

function VirtualKeyboard:_swypeAddCandidate(results, seen, entry, spatial_score, ranked_score, limit)
    if seen[entry.word] then
        return
    end
    seen[entry.word] = true
    local candidate = {
        word = entry.word,
        signature = entry.signature,
        spatial_score = spatial_score,
        ranked_score = ranked_score,
    }
    local inserted = false
    for i = 1, #results do
        if ranked_score < results[i].ranked_score then
            table.insert(results, i, candidate)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(results, candidate)
    end
    while #results > limit do
        local removed = table.remove(results)
        if removed then
            seen[removed.word] = nil
        end
    end
end

function VirtualKeyboard:_swypePickCandidates(signature, limit, trace_info)
    limit = limit or 3
    local dictionary = self.swype_mvp_dictionary or "en"
    local has_bucket_dictionary = swypeOpenBucketDictionary(dictionary)
    local words, words_by_first
    if not has_bucket_dictionary then
        words, words_by_first = swypeLoadWords()
    end
    local trace_chars, next_positions = swypeBuildNextPositions(signature)
    local first = string.sub(signature, 1, 1)
    local last = string.sub(signature, -1)
    local max_spatial = math.max(6, #signature)
    local results, seen = {}, {}
    local key_centers = {}
    if trace_info and self.layout then
        for _, row in ipairs(self.layout) do
            for _, key in ipairs(row) do
                if key.dimen and not key.is_swype_candidate then
                    local normalized = swypeNormalizeText(key.key or key.label)
                    if #normalized == 1 and not key_centers[string.byte(normalized)] then
                        key_centers[string.byte(normalized)] = {
                            x = key.dimen.x + key.dimen.w / 2,
                            y = key.dimen.y + key.dimen.h / 2,
                            size = math.max(key.dimen.w, key.dimen.h),
                        }
                    end
                end
            end
        end
    end

    local function scan(entries, allow_endpoint_mismatch)
        for _, entry in ipairs(entries or {}) do
            if not entry.lang or entry.lang == dictionary then
                local spatial_score, ranked_score = self:_swypeScoreEntry(
                    signature,
                    entry,
                    trace_chars,
                    next_positions,
                    trace_info,
                    key_centers,
                    allow_endpoint_mismatch)
                if spatial_score <= max_spatial then
                    self:_swypeAddCandidate(results, seen, entry, spatial_score, ranked_score, limit)
                end
            end
        end
    end

    if has_bucket_dictionary then
        local bucket = swypeLoadBucket(first, last, dictionary)
        for length = 2, math.min(14, #signature) do
            scan(bucket and bucket.by_length[length])
        end
    else
        local indexed = swype_mvp_words_by_first_length_last[first]
        if indexed then
            for length = 2, math.min(14, #signature) do
                local by_last = indexed[length]
                if by_last then
                    scan(by_last[last])
                end
            end
        end
    end

    if #signature >= 3 and trace_info and trace_info.endpoint_pos then
        local endpoint_letters = self:_swypeEndpointLetters(trace_info.endpoint_pos, last)
        if #endpoint_letters > 1 then
            for i = 2, #endpoint_letters do
                local endpoint_last = endpoint_letters[i]
                if has_bucket_dictionary then
                    local bucket = swypeLoadBucket(first, endpoint_last, dictionary)
                    for length = 2, math.min(14, #signature) do
                        scan(bucket and bucket.by_length[length], true)
                    end
                else
                    local indexed = swype_mvp_words_by_first_length_last[first]
                    if indexed then
                        for length = 2, math.min(14, #signature) do
                            local by_last = indexed[length]
                            if by_last then
                                scan(by_last[endpoint_last], true)
                            end
                        end
                    end
                end
            end
        end
    end

    if #results == 0 and has_bucket_dictionary then
        local popular_entries = swypeLoadPopularWords(first, dictionary)
        if popular_entries then
            scan(popular_entries)
        else
            -- Keep compatibility with older dictionary packages.
            scan(swypeLoadFirstBuckets(first, dictionary))
        end
    elseif #results == 0 then
        scan(words_by_first[first] or words)
    end
    return results
end

function VirtualKeyboard:_swypeDeleteText(text)
    for _ = 1, #swypeSplitChars(text or "") do
        self.inputbox:delChar()
    end
end

function VirtualKeyboard:_swypeGetPreviousWord()
    if not self.inputbox or not self.inputbox.getText then
        return
    end
    local text = self.inputbox:getText() or ""
    local word = text:match("([^%s%p%d]+)%s*$")
    if word and #word > 0 then
        return string.lower(word)
    end
end

function VirtualKeyboard:_swypeGetContextCounts()
    if self.swype_mvp_context_counts then
        return self.swype_mvp_context_counts
    end
    local counts = G_reader_settings:readSetting(SWYPE_MVP_CONTEXT_SETTING, {})
    if type(counts) ~= "table" then
        counts = {}
    end
    self.swype_mvp_context_counts = counts
    return counts
end

function VirtualKeyboard:_swypeContextBonus(previous_word, word)
    if not previous_word or not word then
        return 0
    end
    local previous_counts = self:_swypeGetContextCounts()[previous_word]
    local count = previous_counts and previous_counts[word] or 0
    if count <= 0 then
        return 0
    end
    return math.min(3600, math.floor(600 * math.log(count + 1) / math.log(2)))
end

function VirtualKeyboard:_swypeLearnContext(previous_word, word)
    if not previous_word or not word or #previous_word == 0 or #word == 0 then
        return
    end
    local counts = self:_swypeGetContextCounts()
    counts[previous_word] = counts[previous_word] or {}
    local previous_counts = counts[previous_word]
    previous_counts[word] = math.min(255, (previous_counts[word] or 0) + 1)
    local entries = 0
    for _ in pairs(previous_counts) do
        entries = entries + 1
    end
    if entries > 24 then
        local least_word
        local least_count
        for candidate_word, candidate_count in pairs(previous_counts) do
            if not least_count or candidate_count < least_count then
                least_word = candidate_word
                least_count = candidate_count
            end
        end
        if least_word and least_word ~= word then
            previous_counts[least_word] = nil
        end
    end
    self.swype_mvp_context_dirty = true
end

function VirtualKeyboard:_swypeCommitPendingContext()
    local pending = self.swype_mvp_last_insert
    if not pending or pending.context_committed then
        return
    end
    self:_swypeLearnContext(pending.previous_word, pending.word)
    pending.context_committed = true
end

function VirtualKeyboard:_swypeSaveContext()
    if self.swype_mvp_context_dirty and self.swype_mvp_context_counts then
        G_reader_settings:saveSetting(SWYPE_MVP_CONTEXT_SETTING, self.swype_mvp_context_counts)
        self.swype_mvp_context_dirty = false
    end
end

function VirtualKeyboard:_swypeDictionaryLabel()
    return self.swype_mvp_dictionary == "en" and "EN" or "PL"
end

function VirtualKeyboard:_swypeToggleDictionary()
    self:_swypeCommitPendingContext()
    self:_swypeCancelBucketPrefetch()
    self.swype_mvp_dictionary = self.swype_mvp_dictionary == "en" and "pl" or "en"
    swypeKeepOnlyBucketDictionary(self.swype_mvp_dictionary)
    G_reader_settings:saveSetting(SWYPE_MVP_DICTIONARY_SETTING, self.swype_mvp_dictionary)
    logger.info("swype mvp dictionary selected", self.swype_mvp_dictionary)
    self:_swypeClearCandidateRow("ui")
    self:_swypeRefreshCandidateRow("flashui", 1)
    self:_swypeScheduleWarmUp(0.1)
end

function VirtualKeyboard:_swypeRefreshCandidateRow(refresh_type, only_index)
    refresh_type = refresh_type or "ui"
    if not self.swype_mvp_candidate_keys then
        self:addKeys()
    end

    local candidates = self.swype_mvp_candidates or {}
    for i, virtual_key in ipairs(self.swype_mvp_candidate_keys or {}) do
        if not only_index or i == only_index then
            local candidate = i > 1 and candidates[i - 1] or nil
            local word = i == 1
                and self:_swypeDictionaryLabel()
                or (candidate and candidate.word or " ")
            virtual_key.key = word
            virtual_key.label = word
            if virtual_key.swype_mvp_label_widget then
                virtual_key.swype_mvp_label_widget:setText(word)
            end
            if virtual_key[1] and virtual_key[1].dimen then
                UIManager:widgetRepaint(virtual_key[1], virtual_key[1].dimen.x, virtual_key[1].dimen.y)
                UIManager:setDirty(nil, refresh_type, virtual_key[1].dimen)
            end
        end
    end
end

function VirtualKeyboard:_swypeClearCandidateState(keep_debug)
    self.swype_mvp_candidates = nil
    self.swype_mvp_last_insert = nil
    if not keep_debug then
        self.swype_mvp_debug_signature = nil
    end
end

function VirtualKeyboard:_swypeClearCandidateRow(refresh_type)
    self:_swypeClearCandidateState()
    self:_swypeRefreshCandidateRow(refresh_type)
end

function VirtualKeyboard:_swypeRejectLastInsert()
    if self.swype_mvp_last_insert and self.swype_mvp_last_insert.text then
        logger.dbg("swype mvp rejected", self.swype_mvp_last_insert.signature)
        self:_swypeDeleteText(self.swype_mvp_last_insert.text)
        self:_swypeReset()
        self:_swypeClearCandidateState()
        self:_swypeRefreshCandidateRow()
        return true
    end
    if self.swype_mvp_candidates or self.swype_mvp_debug_signature then
        self:_swypeReset()
        self:_swypeClearCandidateRow()
        return true
    end
    return false
end

function VirtualKeyboard:_swypeSelectCandidate(candidate)
    if not candidate or not self.swype_mvp_last_insert then
        self:_swypeClearCandidateRow()
        return
    end
    local replacement = candidate.word .. " "
    if self.swype_mvp_last_insert and self.swype_mvp_last_insert.text then
        self:_swypeDeleteText(self.swype_mvp_last_insert.text)
    end
    logger.dbg("swype mvp selected", candidate.signature, "=>", candidate.word)
    self:_swypeLearnContext(self.swype_mvp_last_insert.previous_word, candidate.word)
    self.swype_mvp_last_insert.context_committed = true
    self.inputbox:addChars(replacement)
    self:_swypeClearCandidateState()
    self:_swypeRefreshCandidateRow()
end

function VirtualKeyboard:_swypeInsertBestAndShowCandidates(signature, candidates, previous_word)
    if not candidates or #candidates == 0 then
        logger.dbg("swype mvp no confident candidate", signature)
        self.swype_mvp_debug_signature = signature
        self:_swypeClearCandidateState(true)
        self:_swypeRefreshCandidateRow()
        return false
    end
    local inserted = candidates[1].word .. " "
    logger.dbg("swype mvp best", signature, "=>", candidates[1].word)
    self.inputbox:addChars(inserted)
    self.swype_mvp_candidates = candidates
    self.swype_mvp_debug_signature = signature
    self.swype_mvp_last_insert = {
        text = inserted,
        signature = signature,
        word = candidates[1].word,
        previous_word = previous_word,
    }
    self:_swypeRefreshCandidateRow()
end

function VirtualKeyboard:_swypeFinalizeSignature(signature, trace_info)
    if not signature or #signature == 0 then
        return false
    end
    if #signature < 2 then
        self.swype_mvp_debug_signature = signature
        self:_swypeRefreshCandidateRow()
        return true
    end
    local candidates = self:_swypePickCandidates(signature, 3, trace_info)
    self:_swypeInsertBestAndShowCandidates(
        signature, candidates, trace_info and trace_info.previous_word)
    return true
end

function VirtualKeyboard:_swypeFinalizeTrace()
    if not self.swype_mvp_trace then
        return false
    end
    local trace = self.swype_mvp_trace
    local signature = table.concat(trace.letters)
    local points = trace.points or {}
    local trace_info = {
        letter_points = trace.letter_points,
        endpoint_pos = points[#points],
        previous_word = self:_swypeGetPreviousWord(),
    }
    self:_swypeReset(true)
    local finalized = self:_swypeFinalizeSignature(signature, trace_info)
    self:_swypeCancelBucketPrefetch()
    return finalized
end

function VirtualKeyboard:onSwypeWordPan(_, ges)
    if not self:isSwypeMvpEnabled() then
        self:_swypeReset()
        return false
    end
    if ges and not self.swype_mvp_trace then
        self:_swypeCommitPendingContext()
        self:_swypeClearCandidateState()
        self:_swypeAddPoint(ges.start_pos)
    end
    self:_swypeAddPoint(ges and ges.pos)
    return true
end

function VirtualKeyboard:_onSwypeWordPathRelease(_, ges, source_key)
    if not self:isSwypeMvpEnabled() then
        self:_swypeReset()
        return false
    end
    self:_swypeCommitPendingContext()
    self:_swypeClearCandidateState()

    -- KOReader's swipe event uses pos as the start and end_pos as the lift point.
    -- Preserve any pan samples already collected for this same contact.
    if not self.swype_mvp_trace then
        local start_pos = ges and (ges.start_pos or ges.pos)
        if start_pos then
            self:_swypeAddPoint(start_pos)
        else
            self:_swypeAddKeyCenter(source_key)
        end
    end

    local end_pos = ges and (ges.end_pos or ges.pos)
    self:_swypeAddPoint(end_pos)
    if not self.swype_mvp_trace then
        self:_swypeAddKeyCenter(source_key)
    end
    return self:_swypeFinalizeTrace()
end

function VirtualKeyboard:onSwypeWordSwipe(_, ges, source_key)
    return self:_onSwypeWordPathRelease(_, ges, source_key)
end

function VirtualKeyboard:onSwypeWordMultiswipe(_, ges, source_key)
    return self:_onSwypeWordPathRelease(_, ges, source_key)
end

function VirtualKeyboard:onSwypeWordPanRelease(_, ges)
    if not self:isSwypeMvpEnabled() then
        self:_swypeReset()
        return false
    end
    if ges and not self.swype_mvp_trace then
        self:_swypeCommitPendingContext()
        self:_swypeClearCandidateState()
        self:_swypeAddPoint(ges.start_pos)
    end
    if not self.swype_mvp_trace then
        self:_swypeReset()
        return false
    end
    self:_swypeAddPoint(ges and ges.pos)
    return self:_swypeFinalizeTrace()
end

function VirtualKeyboard:setLayer(key)
    if key == "Shift" then
        self.shiftmode = not self.shiftmode
    elseif key == "Sym" or key == "ABC" then
        self.symbolmode = not self.symbolmode
    elseif key == "Äéß" then
        self.umlautmode = not self.umlautmode
    end
    self:initLayer()
    self:_refresh(false)
end

function VirtualKeyboard:addChar(key, keep_swype_candidates)
    self:_swypeCommitPendingContext()
    if not keep_swype_candidates and self.swype_mvp_candidates then
        self:_swypeClearCandidateRow()
    end
    logger.dbg("add char", key)
    self.inputbox:addChars(key)
end

function VirtualKeyboard:delChar()
    if self:_swypeRejectLastInsert() then
        return
    end
    logger.dbg("delete char")
    self.inputbox:delChar()
end

function VirtualKeyboard:delWord(left_to_cursor)
    logger.dbg("delete word")
    self.inputbox:delWord(left_to_cursor)
end

function VirtualKeyboard:delToStartOfLine()
    logger.dbg("delete to start of line")
    self.inputbox:delToStartOfLine()
end

function VirtualKeyboard:leftChar()
    self.inputbox:leftChar()
end

function VirtualKeyboard:rightChar()
    self.inputbox:rightChar()
end

function VirtualKeyboard:goToStartOfLine()
    self.inputbox:goToStartOfLine()
end

-- Some keyboard with intermediate state (ie. zh) may need to be notified
function VirtualKeyboard:onSwitchingKeyboardLayout()
    if self.inputbox.onSwitchingKeyboardLayout then self.inputbox:onSwitchingKeyboardLayout() end
end

function VirtualKeyboard:goToEndOfLine()
    self.inputbox:goToEndOfLine()
end

function VirtualKeyboard:upLine()
    self.inputbox:upLine()
end

function VirtualKeyboard:scrollUp()
    self.inputbox:scrollUp()
end

function VirtualKeyboard:downLine()
    self.inputbox:downLine()
end

function VirtualKeyboard:scrollDown()
    self.inputbox:scrollDown()
end

return VirtualKeyboard
