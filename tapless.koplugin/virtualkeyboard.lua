local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("^@(.+)/[^/]+%.lua$") or "."
local VirtualKeyboard = require("ui/widget/virtualkeyboard")

if VirtualKeyboard._tapless_adapter_installed then
    return VirtualKeyboard
end

local function findUpvalue(fn, wanted)
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then
            break
        end
        if name == wanted then
            return value
        end
    end
end

local VirtualKey = assert(findUpvalue(VirtualKeyboard.addKeys, "VirtualKey"),
    "Tapless: incompatible KOReader VirtualKeyboard.addKeys")
local CandidateRow = dofile(plugin_dir .. "/candidate_row.lua")
local DictionaryManager = dofile(plugin_dir .. "/dictionary_manager.lua")
local DictionaryRegistry = DictionaryManager.registry
local DictionaryIndex = dofile(plugin_dir .. "/dictionary_index.lua")
local DictionaryStore = dofile(plugin_dir .. "/dictionary_store.lua")
    :new(plugin_dir, DictionaryRegistry, DictionaryIndex, time)
local InputSession = dofile(plugin_dir .. "/input_session.lua")
local Normalization = dofile(plugin_dir .. "/normalization.lua"):new(plugin_dir)
local PersonalDictionary = dofile(plugin_dir .. "/personal_dictionary.lua")
    :new(Normalization, DictionaryIndex)
local KeyboardGeometry = dofile(plugin_dir .. "/keyboard_geometry.lua")
    :new(Normalization)
local PrefetchController = dofile(plugin_dir .. "/prefetch_controller.lua")
local Scoring = dofile(plugin_dir .. "/scoring.lua"):new(Normalization)
local GeometryReranker = dofile(plugin_dir .. "/geometry_reranker.lua"):new()
local ShapeChannel = dofile(plugin_dir .. "/shape_channel.lua")
    :new(DictionaryStore, GeometryReranker, PersonalDictionary)
local TraceCollector = dofile(plugin_dir .. "/trace_collector.lua")
local GestureController = dofile(plugin_dir .. "/gesture_controller.lua")
    :new(TraceCollector, UIManager, time, Geom)
local TraceRenderer = dofile(plugin_dir .. "/trace_renderer.lua")
    :new(Screen, UIManager, Geom)
local ContextModel = dofile(plugin_dir .. "/context_model.lua")
    :new(G_reader_settings, "keyboard_swype_mvp_context_counts")
local TextCase = dofile(plugin_dir .. "/text_case.lua"):new(Normalization)
local InputController = dofile(plugin_dir .. "/input_controller.lua")
    :new(ContextModel, Normalization, logger, TextCase,
        PersonalDictionary, DictionaryStore, UIManager)
local DictionaryController = dofile(plugin_dir .. "/dictionary_controller.lua")
    :new{
        plugin_dir = plugin_dir,
        manager = DictionaryManager,
        registry = DictionaryRegistry,
        store = DictionaryStore,
        scoring = Scoring,
        ui_manager = UIManager,
        settings = G_reader_settings,
        logger = logger,
        setting_key = "keyboard_swype_mvp_dictionary",
        default_profile = Normalization.DEFAULT_PROFILE,
    }

dofile(plugin_dir .. "/key_adapter.lua")
    :new(Normalization, GestureRange):install(VirtualKey)

local KeyboardUI = dofile(plugin_dir .. "/keyboard_ui.lua"):new{
    candidate_row = CandidateRow,
    dictionary_manager = DictionaryManager,
    personal_dictionary = PersonalDictionary,
    plugin_dir = plugin_dir,
    horizontal_group = HorizontalGroup,
    virtual_key = VirtualKey,
    ui_manager = UIManager,
    gesture_range = GestureRange,
    screen = Screen,
}
local RecognitionEngine = dofile(plugin_dir .. "/recognition_engine.lua")
    :new(DictionaryStore, Scoring, GeometryReranker, PersonalDictionary, ShapeChannel)

-- Apply the tested refresh ordering for every gesture, independently of diagnostics.
GestureController.refresh_batch = dofile(plugin_dir .. "/refresh_batch.lua"):new(UIManager)

-- Diagnostic mode is explicitly enabled by a removable file, for at most
-- 30 gestures. The usual keyboard does not load or wrap the profiler.
local profile_flag = io.open(plugin_dir .. "/profile.enabled", "r")
if profile_flag then
    profile_flag:close()
    local C = require("ffi").C
    dofile(plugin_dir .. "/latency_profiler.lua"):new{
        time = { now = time.monotonic, ms = time.ms }, ui = UIManager,
        path = "/tmp/tapless-latency-profile.tsv",
        event_now = function()
            local detector = Device.input and Device.input.gesture_detector
            local clock = detector and detector:getClockSource()
            if clock == C.CLOCK_MONOTONIC then return time.monotonic(), "monotonic" end
            if clock == C.CLOCK_REALTIME then return time.realtime(), "realtime" end
            if clock == C.CLOCK_BOOTTIME then return time.boottime(), "boottime" end
        end,
    }:install{
        gesture_controller = GestureController, trace_collector = TraceCollector,
        trace_renderer = TraceRenderer, keyboard_geometry = KeyboardGeometry,
        input_controller = InputController, keyboard_ui = KeyboardUI,
        dictionary_store = DictionaryStore, engine = RecognitionEngine,
        shape_channel = ShapeChannel, screen = Screen,
    }
end

return dofile(plugin_dir .. "/koreader_adapter.lua"):new{
    input_session = InputSession,
    prefetch_controller = PrefetchController,
    dictionary_store = DictionaryStore,
    dictionary_controller = DictionaryController,
    input_controller = InputController,
    keyboard_geometry = KeyboardGeometry,
    keyboard_ui = KeyboardUI,
    recognition_engine = RecognitionEngine,
    gesture_controller = GestureController,
    trace_renderer = TraceRenderer,
    virtual_key = VirtualKey,
    ui_manager = UIManager,
    settings = G_reader_settings,
    screen = Screen,
    blitbuffer = Blitbuffer,
    bottom_container = BottomContainer,
    center_container = CenterContainer,
    frame_container = FrameContainer,
    geometry = Geom,
    horizontal_group = HorizontalGroup,
    horizontal_span = HorizontalSpan,
    vertical_group = VerticalGroup,
    vertical_span = VerticalSpan,
    size = Size,
    prefetch_batch_size = 96,
    prefetch_work_ms = 3,
}:install(VirtualKeyboard)
