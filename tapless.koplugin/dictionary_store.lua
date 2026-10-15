local logger = require("logger")

local DictionaryStore = {}
DictionaryStore.__index = DictionaryStore

function DictionaryStore:new(plugin_dir, registry, dictionary_index, time_api)
    return setmetatable({
        plugin_dir = plugin_dir or ".",
        registry = assert(registry),
        dictionary_index = assert(dictionary_index),
        time = assert(time_api),
        packages = {},
        bucket_cache = {},
        first_bucket_cache = {},
        popular_cache = {},
        word_presence_cache = {},
        prefetch_jobs = {},
        native_descriptors = {},
    }, self)
end

function DictionaryStore:open(dictionary)
    dictionary = dictionary or "en"
    if self.packages[dictionary] ~= nil then
        return self.packages[dictionary]
    end

    local descriptor = self.registry:get(dictionary, self.plugin_dir)
    if not descriptor then
        self.packages[dictionary] = false
        logger.warn("swype mvp dictionary package missing", dictionary)
        return false
    end

    local data_file = io.open(descriptor.files.bucket_data, "rb")
    local index = self.dictionary_index:loadIndex(
        descriptor.files.bucket_index, 2)
    if not index or not data_file then
        if data_file then data_file:close() end
        self.packages[dictionary] = false
        logger.warn("swype mvp dictionary files unavailable", dictionary)
        return false
    end

    local popular_data_file = io.open(descriptor.files.popular_data, "rb")
    local popular_index = self.dictionary_index:loadIndex(
        descriptor.files.popular_index, 1)
    if not popular_index or not popular_data_file then
        if popular_data_file then popular_data_file:close() end
        popular_index = nil
        popular_data_file = nil
    end

    local package = {
        descriptor = descriptor,
        index = index,
        file = data_file,
        popular_index = popular_index,
        popular_file = popular_data_file,
    }
    self.packages[dictionary] = package
    logger.info("swype mvp bucket dictionary", descriptor.files.bucket_data,
        "language", descriptor.data_language)
    return package
end

function DictionaryStore:keepOnly(dictionary)
    for cached_dictionary, package in pairs(self.packages) do
        if cached_dictionary ~= dictionary then
            if package and package.file then
                package.file:close()
            end
            if package and package.popular_file then
                package.popular_file:close()
            end
            self.packages[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.bucket_cache) do
        if cached_dictionary ~= dictionary then
            self.bucket_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.first_bucket_cache) do
        if cached_dictionary ~= dictionary then
            self.first_bucket_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.popular_cache) do
        if cached_dictionary ~= dictionary then
            self.popular_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.word_presence_cache) do
        if cached_dictionary ~= dictionary then
            self.word_presence_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary, jobs in pairs(self.prefetch_jobs) do
        if cached_dictionary ~= dictionary then
            for _, job in pairs(jobs) do
                job.cancelled = true
            end
            self.prefetch_jobs[cached_dictionary] = nil
        end
    end
end

function DictionaryStore:invalidate(dictionary)
    self.native_generation = (self.native_generation or 0) + 1
    self.native_descriptors[dictionary] = nil
    local package = self.packages[dictionary]
    if package and package.file then
        package.file:close()
    end
    if package and package.popular_file then
        package.popular_file:close()
    end
    self.packages[dictionary] = nil
    self.bucket_cache[dictionary] = nil
    self.first_bucket_cache[dictionary] = nil
    self.popular_cache[dictionary] = nil
    self.word_presence_cache[dictionary] = nil
    local jobs = self.prefetch_jobs[dictionary]
    for _, job in pairs(jobs or {}) do
        job.cancelled = true
    end
    self.prefetch_jobs[dictionary] = nil
end

function DictionaryStore:containsWord(signature, word, dictionary)
    if type(signature) ~= "string" or not signature:match("^[a-z]+$")
            or type(word) ~= "string" then
        return false
    end
    dictionary = dictionary or "en"
    self.word_presence_cache[dictionary] =
        self.word_presence_cache[dictionary] or {}
    local cache = self.word_presence_cache[dictionary]
    if cache[word] ~= nil then
        return cache[word]
    end
    local bucket = self:loadBucket(
        string.sub(signature, 1, 1), string.sub(signature, -1), dictionary)
    for _, entry in ipairs(bucket and bucket.entries or {}) do
        if entry.word == word then
            cache[word] = true
            return true
        end
    end
    cache[word] = false
    return false
end

function DictionaryStore:discardPrefetch(controller)
    if not controller then
        return
    end
    local cache = self.bucket_cache[controller.dictionary] or {}
    local global_jobs = self.prefetch_jobs[controller.dictionary] or {}
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
end

function DictionaryStore:isBucketLoaded(dictionary, key)
    local cache = self.bucket_cache[dictionary]
    return cache and cache[key] ~= nil
end

function DictionaryStore:advancePrefetch(job, max_entries, max_work_ms)
    if not job or job.cancelled or job.completed then
        return not job or job.completed
    end
    local work_start = self.time.now()
    local parsed = 0
    while not max_entries or parsed < max_entries do
        local line = job.next_line and job.next_line()
        if not line then
            job.completed = true
            self.bucket_cache[job.dictionary][job.key] = job.bucket
            break
        end
        self.dictionary_index:addBucketLine(job.bucket, line)
        parsed = parsed + 1
        if max_work_ms and parsed % 16 == 0
                and self.time.now() - work_start >= self.time.ms(max_work_ms) then
            break
        end
    end
    return job.completed
end

function DictionaryStore:startPrefetch(first, last, dictionary)
    dictionary = dictionary or "en"
    self.bucket_cache[dictionary] = self.bucket_cache[dictionary] or {}
    local cache = self.bucket_cache[dictionary]
    local key = (first or "") .. (last or "")
    if cache[key] then
        return
    end
    self.prefetch_jobs[dictionary] = self.prefetch_jobs[dictionary] or {}
    local jobs = self.prefetch_jobs[dictionary]
    if jobs[key] then
        return jobs[key]
    end
    local package = self:open(dictionary)
    if not package then
        return
    end

    local job = {
        dictionary = dictionary,
        key = key,
        bucket = self.dictionary_index:newBucket(),
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

function DictionaryStore:loadBucket(first, last, dictionary)
    dictionary = dictionary or "en"
    self.bucket_cache[dictionary] = self.bucket_cache[dictionary] or {}
    local cache = self.bucket_cache[dictionary]
    local key = (first or "") .. (last or "")
    local jobs = self.prefetch_jobs[dictionary]
    local prefetch_job = jobs and jobs[key]
    if cache[key] then
        if prefetch_job then
            prefetch_job.used = true
        end
        return cache[key]
    end
    if prefetch_job and not prefetch_job.cancelled then
        prefetch_job.used = true
        while not self:advancePrefetch(prefetch_job) do end
        return prefetch_job.bucket
    end
    local package = self:open(dictionary)
    if not package then
        return
    end

    local meta = package.index[key]
    local bucket = self.dictionary_index:readBucket(package.file, meta)
    cache[key] = bucket
    return bucket
end

function DictionaryStore:loadFirstBuckets(first, dictionary)
    dictionary = dictionary or "en"
    self.first_bucket_cache[dictionary] = self.first_bucket_cache[dictionary] or {}
    local cache = self.first_bucket_cache[dictionary]
    if cache[first] then
        return cache[first]
    end
    local entries = {}
    for code = string.byte("a"), string.byte("z") do
        local bucket = self:loadBucket(first, string.char(code), dictionary)
        for _, entry in ipairs(bucket and bucket.entries or {}) do
            table.insert(entries, entry)
        end
    end
    cache[first] = entries
    return entries
end

function DictionaryStore:loadPopularWords(first, dictionary)
    dictionary = dictionary or "en"
    self.popular_cache[dictionary] = self.popular_cache[dictionary] or {}
    local cache = self.popular_cache[dictionary]
    if cache[first] then
        return cache[first]
    end

    local package = self:open(dictionary)
    if not package or not package.popular_index or not package.popular_file then
        return nil
    end
    local meta = package.popular_index[first]
    local bucket = self.dictionary_index:readBucket(package.popular_file, meta)
    cache[first] = bucket.entries
    return bucket.entries
end

-- The native reader owns its file handles and invalidates on this generation.
function DictionaryStore:nativePaths(dictionary)
    dictionary = dictionary or "en"
    if self.native_descriptors[dictionary] == nil then
        self.native_descriptors[dictionary] = self.registry:get(dictionary, self.plugin_dir) or false
    end
    return self.native_descriptors[dictionary] or nil
end

return DictionaryStore
