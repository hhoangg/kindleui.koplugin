-- tests/_test_placeholders.lua
-- Books the account holds that this device has not downloaded: the registry in
-- lib/bookshelf_placeholders.lua, and its one integration point, Repo.getAll.
--
-- The KOReader stub prelude below is lifted from _test_book_repository.lua,
-- which is the only way to exercise getAll outside KOReader: it needs lfs,
-- DocSettings, BookInfoManager, ReadHistory and the settings store all faked.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Hardcover's enrichment/ratings caches are SQLite-backed (v2.4.2+); install
-- the in-memory cache fake BEFORE any module that loads bookshelf_hardcover, so
-- buildBookMeta/getAll enrichment reads exercise the real cache paths.
local hccache = dofile("tests/_helpers.lua").install_hardcover_cache_fake()

-- Hardcover.enrichBook/applyMetadata only run when the plugin is live, i.e.
-- Hardcover.isAvailable() -- which pcall-requires the external plugin's API
-- module (absent in CI). Stub it (with a query fn, memoised true on first call)
-- BEFORE bookshelf_hardcover is first required, so the enrichment tests below
-- exercise the plugin-present path. Without this the availability gate (v3.8.8)
-- suppresses all enrichment and the description/cover assertions fail.
package.loaded["hardcover/lib/hardcover_api"] = { query = function() return nil end }

package.loaded["readhistory"] = { hist = {} }
package.loaded["readcollection"] = { coll = { favorites = {} }, default_collection_name = "favorites" }
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp, _with_cover)
        return _G._test_bim_data and _G._test_bim_data[fp] or nil
    end,
}
package.loaded["docsettings"] = {
    open = function(_self, fp)
        return setmetatable({}, { __index = function(_, k)
            if k == "readSetting" then return function(_, key)
                return _G._test_docsettings_data and _G._test_docsettings_data[fp]
                    and _G._test_docsettings_data[fp][key]
            end end
        end })
    end,
    -- enrichBook's use_cover path looks for a custom .sdr cover; none in tests,
    -- so it falls back to the cached download path.
    findCustomCoverFile = function() return nil end,
    -- KOReader resolves the sidecar wherever the "Book metadata location"
    -- setting puts it (alongside the book, a central dir, or by hash). A book
    -- has a sidecar iff we set up DocSettings data for it -- independent of any
    -- sibling .sdr the lfs stub reports. Models the "dir"/"hash" case (#117).
    hasSidecarFile = function(_self, fp)
        return _G._test_docsettings_data and _G._test_docsettings_data[fp] ~= nil or false
    end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, key)
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }

-- ISO language name lookup used by bookshelf_lang (required by the repo at
-- load). 3-letter code -> English name, with the real module's code fallback.
package.loaded["ui/data/isolanguage"] = {
    getLocalizedLanguage = function(_self, iso3)
        local N = { eng = "English", deu = "German", fra = "French",
                    jpn = "Japanese", spa = "Spanish", zho = "Chinese" }
        return N[iso3] or iso3
    end,
}

-- BookshelfSettings stub: reads from the same _test_settings table as
-- the G_reader_settings stub, but transparently re-prefixes keys with
-- "bookshelf_". Lets existing tests keep using bookshelf_X keys in
-- _test_settings while production code reads short keys via the store.
local _store_generation = 1
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default)
        local v = _G._test_settings and _G._test_settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save   = function(key, value)
        _G._test_settings = _G._test_settings or {}
        _G._test_settings["bookshelf_" .. key] = value
        _store_generation = _store_generation + 1
    end,
    delete = function(key)
        if _G._test_settings then _G._test_settings["bookshelf_" .. key] = nil end
        _store_generation = _store_generation + 1
    end,
    flush  = function() end,
    generation = function() return _store_generation end,
    isTrue = function(key)
        return _G._test_settings and _G._test_settings["bookshelf_" .. key] == true
    end,
    nilOrTrue = function(key)
        if not _G._test_settings then return true end
        local v = _G._test_settings["bookshelf_" .. key]
        return v == nil or v == true
    end,
}
_G.G_reader_settings = setmetatable({}, {
    __index = function(_, k)
        if k == "readSetting" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key]
            end
        end
        if k == "isTrue" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key] == true
            end
        end
        return nil
    end,
})


local Repo         = dofile("lib/bookshelf_book_repository.lua")
local Placeholders = require("lib/bookshelf_placeholders")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- One folder holding two real books, so a placeholder has something to sort
-- against rather than being the only thing on the shelf.
local lfs_stub = package.loaded["libs/libkoreader-lfs"]
local function stubLibrary()
    local LISTING = { ["/lib"] = { ".", "..", "beta.epub", "delta.epub" } }
    lfs_stub.dir = function(path)
        local files = LISTING[path] or {}
        local i = 0; return function() i = i + 1; return files[i] end
    end
    lfs_stub.attributes = function(fp, key)
        if fp:find("%.epub$") == nil and fp == "/lib" then
            if key == "mode" then return "directory" end
            return { mode = "directory", modification = 0, size = 0 }
        end
        if key == "mode" then return "file" end
        if key == "modification" then return 0 end
        if key == nil then return { mode = "file", modification = 0, size = 9 } end
    end
    _G._test_bim_data = {
        ["/lib/beta.epub"]  = { title = "Beta",  has_meta = true },
        ["/lib/delta.epub"] = { title = "Delta", has_meta = true },
    }
    _G._test_settings = { home_dir = "/lib" }
end

local function titlesOf(items)
    local out = {}
    for _i, it in ipairs(items or {}) do
        if it.kind ~= "folder" then out[#out + 1] = tostring(it.title) end
    end
    return out
end

local function reset()
    Placeholders.setProvider(nil)
    Repo.invalidateWalkCache()
    Repo.invalidateAllCache()
end

-- ============================================================================
-- The registry itself
-- ============================================================================

test("no provider registered: entriesFor is empty", function()
    reset()
    assert(Placeholders.hasProvider() == false)
    local e = Placeholders.entriesFor("/lib")
    assert(type(e) == "table" and #e == 0, "expected no entries, got " .. #e)
end)

test("entriesFor: shapes an entry the way lfs would", function()
    reset()
    Placeholders.setProvider(function() return { { id = "bok_1", name = "gamma.epub",
        title = "Gamma", authors = "Somebody", size = 4242 } } end)
    local e = Placeholders.entriesFor("/lib")
    assert(#e == 1, "expected 1 entry, got " .. #e)
    assert(e[1].attr.mode == "file", "must look like a file to the walk")
    assert(e[1].attr.size == 4242, "size carries through for the size column")
    assert(e[1].attr.modification == 0,
        "a placeholder has no date on this device; stamping it with now would "
        .. "sort it to the top of 'recently added' on every walk")
    assert(e[1].doc_props.display_title == "Gamma",
        "title must be pre-set: there is no BIM row to read it from")
end)

test("entriesFor: a filename with no extension still gets one", function()
    reset()
    Placeholders.setProvider(function() return { { id = "x", name = "no-dot-here" } } end)
    local e = Placeholders.entriesFor("/lib")
    assert(e[1].fp:find("%.epub$"), "expected an epub fallback, got " .. e[1].fp)
end)

test("entriesFor: a provider that throws does not take the listing down", function()
    reset()
    Placeholders.setProvider(function() error("catalogue on fire") end)
    local ok, e = pcall(Placeholders.entriesFor, "/lib")
    assert(ok, "entriesFor must swallow a provider error")
    assert(#e == 0, "expected no entries from a failed provider")
end)

test("entriesFor: a provider returning nonsense is ignored", function()
    reset()
    Placeholders.setProvider(function() return "not a table" end)
    assert(#Placeholders.entriesFor("/lib") == 0)
    Placeholders.setProvider(function() return { 42, {}, { name = "" } } end)
    assert(#Placeholders.entriesFor("/lib") == 0,
        "entries without a usable name must be dropped, not defaulted")
end)

test("isPlaceholderPath: true only for paths entriesFor built", function()
    reset()
    Placeholders.setProvider(function() return { { id = "bok_9", name = "a.epub" } } end)
    local fp = Placeholders.entriesFor("/lib")[1].fp
    assert(Placeholders.isPlaceholderPath(fp), "own path must be recognised")
    assert(not Placeholders.isPlaceholderPath("/lib/a.epub"), "a real path must not be")
    assert(not Placeholders.isPlaceholderPath(nil))
end)

test("the pseudo-path keeps the book in its own folder", function()
    reset()
    Placeholders.setProvider(function() return { { id = "bok_2", name = "x.epub" } } end)
    local fp = Placeholders.entriesFor("/lib/Tien hiep")[1].fp
    assert(fp:match("^(.*)/[^/]+$") == "/lib/Tien hiep",
        "dirname must still be the folder the book belongs to, got " .. fp)
end)

test("buildRecord: carries the provider's metadata and flags itself", function()
    reset()
    local rec = Placeholders.buildRecord({ fp = "/lib/a.xtph-bok_3.epub", ph = {
        id = "bok_3", name = "a.epub", title = "Alpha", authors = "Nhi Muoi",
        series = "S", series_index = 2, size = 77 } })
    assert(rec.is_placeholder == true, "the renderer keys on this")
    assert(rec.placeholder_id == "bok_3", "the tap handler needs the id back")
    assert(rec.title == "Alpha" and rec.author == "Nhi Muoi")
    assert(rec.series_num == 2 and rec.size == 77)
    assert(rec.cover_bb == nil, "there is no file to extract a cover from")
    assert(rec.page_count == nil and rec.percent == nil,
        "a placeholder must not claim progress in a book the user has not got")
end)

-- ============================================================================
-- The integration point
-- ============================================================================

test("getAll: unchanged when no provider is registered", function()
    reset(); stubLibrary()
    local items, total = Repo.getAll("/lib", 10, 0)
    local t = titlesOf(items)
    assert(total == 2, "expected 2 books, got " .. tostring(total))
    assert(table.concat(t, ",") == "Beta,Delta", "got " .. table.concat(t, ","))
end)

test("getAll: placeholders appear, flagged, sorted among the real books", function()
    reset(); stubLibrary()
    Placeholders.setProvider(function(path)
        if path ~= "/lib" then return {} end
        return {
            { id = "bok_a", name = "alpha.epub",   title = "Alpha" },
            { id = "bok_c", name = "charlie.epub", title = "Charlie" },
        }
    end)
    Repo.invalidateWalkCache(); Repo.invalidateAllCache()
    local items, total = Repo.getAll("/lib", 10, 0)
    local t = titlesOf(items)
    assert(total == 4, "expected 2 real + 2 placeholders, got " .. tostring(total))
    -- Interleaved, not appended: that is the whole reason they join the walk
    -- before the sort rather than being tacked onto a finished page.
    assert(table.concat(t, ",") == "Alpha,Beta,Charlie,Delta",
        "expected placeholders sorted among the real books, got " .. table.concat(t, ","))
    local flagged, real = 0, 0
    for _i, it in ipairs(items) do
        if it.is_placeholder then flagged = flagged + 1 else real = real + 1 end
    end
    assert(flagged == 2 and real == 2,
        "expected 2 flagged / 2 real, got " .. flagged .. " / " .. real)
end)

test("getAll: a placeholder is never mistaken for a real book", function()
    reset(); stubLibrary()
    Placeholders.setProvider(function() return { { id = "bok_z", name = "zulu.epub", title = "Zulu" } } end)
    Repo.invalidateWalkCache(); Repo.invalidateAllCache()
    local items = Repo.getAll("/lib", 10, 0)
    -- Assert it is present BEFORE looping: without this the loop below has
    -- nothing to check and the test passes whether or not placeholders work.
    local seen_zulu = false
    for _i, it in ipairs(items) do if it.title == "Zulu" then seen_zulu = true end end
    assert(seen_zulu, "Zulu must be in the listing at all")
    for _i, it in ipairs(items) do
        if it.title == "Zulu" then
            assert(it.is_placeholder, "Zulu must be flagged")
            assert(Placeholders.isPlaceholderPath(it.filepath),
                "its filepath must be recognisable as a placeholder, got " .. tostring(it.filepath))
        else
            assert(not it.is_placeholder, tostring(it.title) .. " must not be flagged")
        end
    end
end)

test("getAll: paginates across the combined total", function()
    reset(); stubLibrary()
    Placeholders.setProvider(function() return {
        { id = "1", name = "alpha.epub",   title = "Alpha" },
        { id = "2", name = "charlie.epub", title = "Charlie" },
    } end)
    Repo.invalidateWalkCache(); Repo.invalidateAllCache()
    local page1, total1 = Repo.getAll("/lib", 2, 0)
    local page2, total2 = Repo.getAll("/lib", 2, 2)
    assert(total1 == 4 and total2 == 4, "total must count placeholders on every page")
    assert(#page1 == 2 and #page2 == 2, "got " .. #page1 .. " and " .. #page2)
    local joined = table.concat(titlesOf(page1), ",") .. "|" .. table.concat(titlesOf(page2), ",")
    assert(joined == "Alpha,Beta|Charlie,Delta", "got " .. joined)
end)

test("getAll: a provider that throws leaves the real books listed", function()
    reset(); stubLibrary()
    Placeholders.setProvider(function() error("catalogue on fire") end)
    Repo.invalidateWalkCache(); Repo.invalidateAllCache()
    local items, total = Repo.getAll("/lib", 10, 0)
    assert(total == 2, "the real books must still be there, got " .. tostring(total))
    assert(table.concat(titlesOf(items), ",") == "Beta,Delta")
end)

test("getAll: placeholders are scoped to the folder they belong to", function()
    reset(); stubLibrary()
    Placeholders.setProvider(function(path)
        if path == "/somewhere-else" then
            return { { id = "bok_e", name = "elsewhere.epub", title = "Elsewhere" } }
        end
        return {}
    end)
    Repo.invalidateWalkCache(); Repo.invalidateAllCache()
    local _items, total = Repo.getAll("/lib", 10, 0)
    assert(total == 2, "a placeholder for another folder must not leak in, got " .. tostring(total))

    -- Control: point the same provider at /lib and the count must move. Without
    -- this the assertion above holds just as well when placeholders never work
    -- at all, which is the failure it is meant to catch.
    Placeholders.setProvider(function(path)
        if path == "/lib" then
            return { { id = "bok_e", name = "elsewhere.epub", title = "Elsewhere" } }
        end
        return {}
    end)
    Repo.invalidateWalkCache(); Repo.invalidateAllCache()
    local _items2, total2 = Repo.getAll("/lib", 10, 0)
    assert(total2 == 3, "the same entry aimed at /lib must appear, got " .. tostring(total2))
end)

reset()
io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
