local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("^@(.+)/main%.lua$") or "."
local virtualkeyboard_module = "ui/widget/virtualkeyboard"
local replacement_path = plugin_dir .. "/virtualkeyboard.lua"

-- KOReader loads plugin main files before normal text dialogs are created.
-- Replace the module cache entry so future keyboard instances use the plugin
-- implementation without modifying KOReader's installed core files.
local ok, replacement = pcall(dofile, replacement_path)
if ok and replacement then
    package.loaded[virtualkeyboard_module] = replacement
    logger.info("Tapless: VirtualKeyboard plugin implementation loaded")

    -- InputText caches the keyboard class during its own module initialization.
    -- Re-run that binding so an early-loaded InputText also uses Tapless.
    local InputText = require("ui/widget/inputtext")
    InputText.initInputEvents()
    logger.info("Tapless: InputText keyboard binding refreshed")
else
    logger.err("Tapless: failed to load VirtualKeyboard implementation", replacement)
end

local Tapless = WidgetContainer:extend{
    name = "tapless",
    is_doc_only = false,
}

return Tapless
