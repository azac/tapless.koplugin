-- Tapless dictionary catalog, download and installation manager.
-- The manager is intentionally independent from the swipe-scoring code so
-- network and archive work can only start from an explicit user action.

local Archiver = require("ffi/archiver")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local NetworkMgr = require("ui/network/manager")
local sha2 = require("ffi/sha2")
local http = require("socket.http")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local util = require("util")
local Screen = require("device").screen

local source = debug.getinfo(1, "S").source
local plugin_source_dir = source:match("^@(.+)/dictionary_manager%.lua$") or "."
local DictionaryRegistry = dofile(plugin_source_dir .. "/dictionary_registry.lua")

local CATALOG_URL = "https://azac.github.io/tapless.dictionaries/catalog.json"
local RELEASE_BASE_URL = "https://github.com/azac/tapless.dictionaries/releases/download/v"
local MAX_PACKAGE_BYTES = 16 * 1024 * 1024
local MAX_UNCOMPRESSED_BYTES = 20 * 1024 * 1024
local MAX_CATALOG_BYTES = 256 * 1024
local REQUIRED_FILES = {
    ["manifest.tsv"] = true,
    ["words.buckets.tsv"] = true,
    ["words.buckets.idx"] = true,
    ["words.popular.tsv"] = true,
    ["words.popular.idx"] = true,
}
local OPTIONAL_FILES = {
    ["ATTRIBUTION.txt"] = true,
    ["LICENSE-wordfreq.txt"] = true,
    ["DATA-LICENSE.txt"] = true,
}
local Manager = {
    registry = DictionaryRegistry,
    catalog = nil,
    catalog_path = nil,
    plugin_dir = nil,
    keyboard = nil,
    personal_dictionary = nil,
    menu = nil,
    loading_message = nil,
    busy = false,
}

local function isSafeId(value)
    return DictionaryRegistry:isSafeId(value)
end

local function isSafeFilename(value)
    return type(value) == "string"
        and value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") ~= nil
end

local function exists(path)
    return path and lfs.attributes(path) ~= nil
end

local function isDirectory(path)
    return path and lfs.attributes(path, "mode") == "directory"
end

local function removeTree(path)
    if not path or not exists(path) then
        return true
    end
    if not isDirectory(path) then
        return os.remove(path) == true
    end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            if not removeTree(child) then
                return false
            end
        end
    end
    return lfs.rmdir(path) ~= nil
end

local function readFile(path, max_bytes)
    local file = io.open(path, "rb")
    if not file then
        return nil, "Cannot open file"
    end
    local data = file:read(max_bytes and (max_bytes + 1) or "*a")
    file:close()
    if max_bytes and data and #data > max_bytes then
        return nil, "File is too large"
    end
    return data
end

local function writeFile(path, data)
    local file = io.open(path, "wb")
    if not file then
        return nil, "Cannot write file"
    end
    local ok, err = file:write(data)
    file:close()
    if not ok then
        return nil, err or "Write error"
    end
    return true
end

local function hexDigest(value)
    if type(value) ~= "string" then
        return nil
    end
    if #value == 64 and value:match("^[0-9a-fA-F]+$") then
        return value:lower()
    end
    if #value == 32 then
        return (value:gsub(".", function(char)
            return string.format("%02x", string.byte(char))
        end))
    end
end

local function sha256File(path)
    local data, err = readFile(path)
    if not data then
        return nil, err
    end
    local ok, digest = pcall(sha2.sha256, data)
    if not ok then
        return nil, digest
    end
    digest = hexDigest(digest)
    if not digest then
        return nil, "Unsupported SHA-256 result"
    end
    return digest
end

local function validatePackageRecord(package)
    if type(package) ~= "table"
            or not isSafeId(package.id)
            or type(package.name) ~= "string"
            or package.name == ""
            or type(package.version) ~= "string"
            or package.version == ""
            or not isSafeFilename(package.archive)
            or type(package.sha256) ~= "string"
            or #package.sha256 ~= 64
            or not package.sha256:match("^[0-9a-fA-F]+$")
            or type(package.size) ~= "number"
            or package.size < 1
            or package.size > MAX_PACKAGE_BYTES then
        return nil
    end
    return {
        id = package.id,
        name = package.name,
        version = package.version,
        source_language = package.source_language,
        data_language = package.data_language,
        keyboard_layout = package.keyboard_layout,
        rows = tonumber(package.rows),
        archive = package.archive,
        size = math.floor(package.size),
        sha256 = package.sha256:lower(),
        notes = type(package.notes) == "string" and package.notes or "",
        download_url = type(package.download_url) == "string" and package.download_url or nil,
    }
end

local function validateCatalog(data)
    if type(data) ~= "table" or tonumber(data.format) ~= 1 or type(data.packages) ~= "table" then
        return nil, "Unsupported catalog format"
    end
    local packages = {}
    for _, package in ipairs(data.packages) do
        local valid = validatePackageRecord(package)
        if valid then
            packages[valid.id] = valid
        end
    end
    if not next(packages) then
        return nil, "Catalog contains no valid packages"
    end
    return {
        format = 1,
        dictionary_version = data.dictionary_version,
        packages = packages,
    }
end

local function localRoot()
    return DataStorage:getDataDir() .. "/tapless"
end

local function installedPath(id, plugin_dir)
    local descriptor = DictionaryRegistry:get(id, plugin_dir)
    if descriptor then
        return descriptor.path, descriptor.bundled
    end
end

function Manager:shortLabel(id)
    return DictionaryRegistry:shortLabel(id, self.plugin_dir)
end

function Manager:isDictionaryAvailable(id, plugin_dir)
    return DictionaryRegistry:isAvailable(id, plugin_dir or self.plugin_dir)
end

function Manager:listInstalled(plugin_dir)
    return DictionaryRegistry:list(plugin_dir or self.plugin_dir)
end

function Manager:_loadCachedCatalog()
    local data = readFile(self.catalog_path, MAX_CATALOG_BYTES)
    if not data then
        return nil
    end
    local ok, decoded = pcall(json.decode, data)
    if not ok then
        return nil
    end
    local catalog = validateCatalog(decoded)
    if catalog then
        self.catalog = catalog
    end
    return self.catalog
end

local function httpToFile(url, target)
    for redirect_count = 0, 5 do
        local file = io.open(target, "wb")
        if not file then
            return nil, "Cannot create temporary file"
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok, result, code, headers = pcall(function()
            return http.request{
                url = url,
                method = "GET",
                headers = { ["User-Agent"] = "Tapless-KOReader" },
                sink = ltn12.sink.file(file),
            }
        end)
        socketutil:reset_timeout()
        -- ltn12.sink.file closes the handle after the response; on an error
        -- it may still be open, so closing it must be idempotent.
        pcall(function() file:close() end)
        if not ok then
            os.remove(target)
            return nil, result
        end
        code = tonumber(code)
        if result and code and code >= 200 and code < 300 then
            return true
        end
        local location = headers and (headers.location or headers.Location)
        if code and code >= 300 and code < 400 and location and redirect_count < 5 then
            os.remove(target)
            url = location
        else
            os.remove(target)
            return nil, "Server returned HTTP " .. tostring(code or result)
        end
    end
    os.remove(target)
    return nil, "Too many redirects"
end

function Manager:_fetchCatalog()
    local temp_path = localRoot() .. "/catalog.json.part"
    util.makePath(localRoot())
    local ok, err = httpToFile(CATALOG_URL, temp_path)
    if not ok then
        return nil, err
    end
    local data, read_err = readFile(temp_path, MAX_CATALOG_BYTES)
    if not data then
        os.remove(temp_path)
        return nil, read_err
    end
    local decoded_ok, decoded = pcall(json.decode, data)
    local catalog, catalog_err
    if decoded_ok then
        catalog, catalog_err = validateCatalog(decoded)
    else
        catalog_err = decoded
    end
    if not catalog then
        os.remove(temp_path)
        return nil, catalog_err
    end
    local write_ok, write_err = writeFile(self.catalog_path, data)
    os.remove(temp_path)
    if not write_ok then
        return nil, write_err
    end
    self.catalog = catalog
    return catalog
end

function Manager:_closeLoading()
    if self.loading_message then
        UIManager:close(self.loading_message)
        self.loading_message = nil
    end
end

function Manager:_showLoading(text)
    self:_closeLoading()
    self.loading_message = InfoMessage:new{ text = text, timeout = 0 }
    UIManager:show(self.loading_message)
end

function Manager:_closeMenu()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

function Manager:_notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

function Manager:_select(id)
    if not self.keyboard or not self.keyboard._swypeSetDictionary then
        return
    end
    self:_closeMenu()
    if not self.keyboard:_swypeSetDictionary(id) then
        self:_notify("Cannot enable dictionary " .. id .. ".")
    end
end

function Manager:_uninstall(id, name)
    local path, bundled = installedPath(id, self.plugin_dir)
    if not path or bundled then
        self:_notify("This dictionary cannot be uninstalled.")
        return
    end
    UIManager:show(ConfirmBox:new{
        text = "Uninstall dictionary " .. (name or id) .. "?",
        ok_text = "Uninstall",
        ok_callback = function()
            if self.keyboard and self.keyboard.swype_mvp_dictionary == id then
                if not self.keyboard:_swypeSetDictionary("en") then
                    self:_notify("Cannot switch to EN before uninstalling.")
                    return
                end
            end
            local removed = removeTree(path)
            DictionaryRegistry:invalidate(id)
            if removed then
                self:_notify("Uninstalled dictionary: " .. (name or id))
            else
                self:_notify("Failed to uninstall dictionary: " .. (name or id))
            end
            self:showMenu()
        end,
    })
end

function Manager:_personalContext()
    local keyboard = self.keyboard
    return keyboard and (keyboard.swype_mvp_dictionary or "en") or "en",
        keyboard and keyboard.swype_mvp_normalization_profile or nil
end

function Manager:_removePersonalWord(word)
    local language, profile = self:_personalContext()
    UIManager:show(ConfirmBox:new{
        text = "Remove \"" .. word .. "\" from personal words?",
        ok_text = "Remove",
        ok_callback = function()
            local removed, err = self.personal_dictionary:remove(
                language, word, profile)
            if removed then
                self:_notify("Removed personal word: " .. word)
            else
                self:_notify("Failed to remove personal word:\n"
                    .. tostring(err or word))
            end
            self:showPersonalWords()
        end,
    })
end

function Manager:showPersonalWords()
    self:_closeMenu()
    if not self.personal_dictionary then
        self:_notify("Personal words are unavailable.")
        self:showMenu()
        return
    end
    local language, profile = self:_personalContext()
    local words = self.personal_dictionary:list(language, profile)
    local buttons = {}
    local action_width = Screen:scaleBySize(140)
    for _, word in ipairs(words) do
        table.insert(buttons, {
            {
                text = word,
                align = "left",
                enabled = false,
                callback = function() end,
            },
            {
                text = "Remove",
                width = action_width,
                callback = function() self:_removePersonalWord(word) end,
            },
        })
    end
    if #words == 0 then
        table.insert(buttons, {
            {
                text = "No personal words",
                enabled = false,
                callback = function() end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = "Back",
            callback = function() self:showMenu() end,
        },
    })
    self.menu = ButtonDialog:new{
        title = "Tapless: Personal words (" .. string.upper(language) .. ")",
        width_factor = 0.95,
        rows_per_page = 8,
        buttons = buttons,
    }
    UIManager:show(self.menu)
end

function Manager:_packageUrl(package)
    if package.download_url and package.download_url:match("^https://") then
        return package.download_url
    end
    return RELEASE_BASE_URL .. package.version .. "/" .. package.archive
end

local function validateArchivePath(path)
    return type(path) == "string"
        and path:match("^[A-Za-z0-9_.-]+$") ~= nil
        and (REQUIRED_FILES[path] or OPTIONAL_FILES[path])
end

function Manager:_extractAndValidate(package, zip_path, temp_dir)
    local reader = Archiver.Reader:new()
    local ok, err = pcall(function()
        reader:open(zip_path)
        local seen = {}
        for entry in reader:iterate() do
            local path = entry.path
            if not validateArchivePath(path) or seen[path] then
                error("Forbidden or duplicate file in ZIP: " .. tostring(path))
            end
            seen[path] = true
        end
        for filename in pairs(REQUIRED_FILES) do
            if not seen[filename] then
                error("Missing file in ZIP: " .. filename)
            end
        end
        -- Archiver.Reader on KOReader has no rewind method. Reopen the
        -- archive after the validation pass before extracting its entries.
        reader:close()
        reader = Archiver.Reader:new()
        reader:open(zip_path)
        util.makePath(temp_dir)
        for entry in reader:iterate() do
            reader:extractToPath(entry.path, temp_dir .. "/" .. entry.path)
        end
        reader:close()
    end)
    if not ok then
        pcall(function() reader:close() end)
        return nil, err
    end

    local extracted_bytes = 0
    for filename in pairs(REQUIRED_FILES) do
        local size = lfs.attributes(temp_dir .. "/" .. filename, "size") or 0
        extracted_bytes = extracted_bytes + size
    end
    for filename in pairs(OPTIONAL_FILES) do
        local size = lfs.attributes(temp_dir .. "/" .. filename, "size") or 0
        extracted_bytes = extracted_bytes + size
    end
    if extracted_bytes > MAX_UNCOMPRESSED_BYTES then
        return nil, "Extracted package exceeds size limit"
    end

    local manifest, manifest_err = DictionaryRegistry:parseManifest(
        temp_dir .. "/manifest.tsv")
    if not manifest then
        return nil, manifest_err
    end
    if manifest.id ~= package.id then
        return nil, "Manifest ID does not match package"
    end
    local checksums = {
        { "words.buckets.tsv", manifest.sha256_data },
        { "words.buckets.idx", manifest.sha256_index },
        { "words.popular.tsv", manifest.sha256_popular_data },
        { "words.popular.idx", manifest.sha256_popular_index },
    }
    for _, item in ipairs(checksums) do
        if item[2] then
            local digest, digest_err = sha256File(temp_dir .. "/" .. item[1])
            if not digest then
                return nil, digest_err
            end
            if digest ~= string.lower(item[2]) then
                return nil, "Checksum mismatch for file " .. item[1]
            end
        end
    end
    return true
end

function Manager:_installPackage(package, zip_path)
    local dictionaries_root = DictionaryRegistry:externalRoot()
    local install_root = localRoot() .. "/install"
    local temp_dir = install_root .. "/" .. package.id .. ".tmp"
    local destination = dictionaries_root .. "/" .. package.id
    local backup = dictionaries_root .. "/." .. package.id .. ".backup"
    removeTree(temp_dir)
    removeTree(backup)
    util.makePath(install_root)
    util.makePath(dictionaries_root)

    local ok, err = self:_extractAndValidate(package, zip_path, temp_dir)
    if not ok then
        removeTree(temp_dir)
        return nil, err
    end
    DictionaryRegistry:invalidate(package.id)
    if exists(destination) and not os.rename(destination, backup) then
        removeTree(temp_dir)
        return nil, "Cannot prepare replacement for existing dictionary"
    end
    if not os.rename(temp_dir, destination) then
        if exists(backup) then
            os.rename(backup, destination)
        end
        removeTree(temp_dir)
        return nil, "Cannot install dictionary"
    end
    removeTree(backup)
    return true
end

function Manager:_downloadAndInstall(package)
    if package.size > MAX_PACKAGE_BYTES then
        return nil, "Package exceeds size limit"
    end
    local download_root = localRoot() .. "/downloads"
    util.makePath(download_root)
    local zip_path = download_root .. "/" .. package.archive .. ".part"
    os.remove(zip_path)
    local ok, err = httpToFile(self:_packageUrl(package), zip_path)
    if not ok then
        return nil, err
    end
    local size = lfs.attributes(zip_path, "size")
    if not size or size ~= package.size then
        os.remove(zip_path)
        return nil, "Downloaded package size mismatch"
    end
    local digest, digest_err = sha256File(zip_path)
    if not digest then
        os.remove(zip_path)
        return nil, digest_err
    end
    if digest ~= package.sha256 then
        os.remove(zip_path)
        return nil, "Downloaded package checksum mismatch"
    end
    local installed, install_err = self:_installPackage(package, zip_path)
    os.remove(zip_path)
    return installed, install_err
end

function Manager:_download(package)
    if self.busy then
        return
    end
    self.busy = true
    self:_closeMenu()
    self:_showLoading("Downloading dictionary: " .. package.name .. "...")
    NetworkMgr:runWhenOnline(function()
        local ok, err = self:_downloadAndInstall(package)
        self.busy = false
        self:_closeLoading()
        if ok then
            self:_notify("Installed dictionary: " .. package.name)
            self:showMenu()
        else
            logger.warn("Tapless dictionary install failed", package.id, err)
            self:_notify("Failed to install dictionary:\n" .. tostring(err))
            self:showMenu()
        end
    end)
end

function Manager:_refreshCatalog()
    if self.busy then
        return
    end
    self.busy = true
    self:_closeMenu()
    self:_showLoading("Downloading dictionary catalog...")
    NetworkMgr:runWhenOnline(function()
        local catalog, err = self:_fetchCatalog()
        self.busy = false
        self:_closeLoading()
        if not catalog then
            self:_notify("Failed to download catalog:\n" .. tostring(err))
        end
        self:showMenu()
    end)
end

function Manager:showMenu()
    self:_closeMenu()
    local installed = {}
    for _, info in ipairs(self:listInstalled(self.plugin_dir)) do
        installed[info.id] = info
    end
    local packages = self.catalog and self.catalog.packages or {}
    local ids = {}
    for id in pairs(installed) do ids[id] = true end
    for id in pairs(packages) do ids[id] = true end
    local ordered = {}
    for id in pairs(ids) do table.insert(ordered, id) end
    table.sort(ordered, function(left, right)
        if left == "en" then return true end
        if right == "en" then return false end
        if left == "pl" then return true end
        if right == "pl" then return false end
        return left < right
    end)
    local buttons = {}
    local action_width = Screen:scaleBySize(140)
    if self.personal_dictionary then
        local language, profile = self:_personalContext()
        local personal_count = #self.personal_dictionary:list(language, profile)
        table.insert(buttons, {
            {
                text = "Personal words (" .. personal_count .. ")",
                callback = function() self:showPersonalWords() end,
            },
        })
    end
    for _, id in ipairs(ordered) do
        local info = installed[id]
        local package = packages[id]
        local name = package and package.name or (info and info.name or id)
        if info then
            local active = self.keyboard and self.keyboard.swype_mvp_dictionary == id
            table.insert(buttons, {
                {
                    text = active and "✓ " .. name or name,
                    align = "left",
                    callback = function() self:_select(id) end,
                },
                {
                    text = info.bundled and "Built-in" or "Uninstall",
                    width = action_width,
                    enabled = not info.bundled,
                    callback = function()
                        if info.bundled then
                            return
                        end
                        self:_uninstall(id, package and package.name or info.name)
                    end,
                },
            })
        elseif package then
            table.insert(buttons, {
                {
                    text = name,
                    align = "left",
                    enabled = false,
                    callback = function() end,
                },
                {
                    text = "Download",
                    width = action_width,
                    callback = function() self:_download(package) end,
                },
            })
        end
    end
    table.insert(buttons, {
        {
            text = "Refresh catalog",
            callback = function() self:_refreshCatalog() end,
        },
    })
    table.insert(buttons, {
        {
            text = "Close",
            callback = function() self:_closeMenu() end,
        },
    })
    self.menu = ButtonDialog:new{
        title = "Tapless: Dictionaries",
        width_factor = 0.95,
        rows_per_page = 8,
        buttons = buttons,
    }
    UIManager:show(self.menu)
end

function Manager:open(keyboard, plugin_dir, personal_dictionary)
    DictionaryRegistry:invalidate()
    self.keyboard = keyboard
    self.plugin_dir = plugin_dir or self.plugin_dir
    self.personal_dictionary = personal_dictionary or self.personal_dictionary
    self.catalog_path = localRoot() .. "/catalog.json"
    if not self.catalog then
        self:_loadCachedCatalog()
    end
    if self.catalog then
        self:showMenu()
    else
        self:_refreshCatalog()
    end
end

return Manager
