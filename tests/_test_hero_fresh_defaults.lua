-- tests/_test_hero_fresh_defaults.lua
-- Usage: luajit tests/_test_hero_fresh_defaults.lua
local stored
_G.G_reader_settings = {
    readSetting = function(_, k) if k == "bookshelf_hero_regions" then return stored end end,
    saveSetting = function(_, k, v) if k == "bookshelf_hero_regions" then stored = v end end,
    delSetting  = function(_, k) if k == "bookshelf_hero_regions" then stored = nil end end,
    flush = function() end,
}
local Regions = dofile("lib/bookshelf_hero_regions.lua")

stored = { title = { font_size = 99 } }   -- pretend a customization exists
Regions.applyFreshInstallDefaults()
local r = Regions.read()

-- title: bundled Inter ExtraBold (portable bare filename), size 32, bold off
assert(r.title.font_face == "Inter-ExtraBold.ttf", "title -> Inter-ExtraBold.ttf (got " .. tostring(r.title.font_face) .. ")")
assert(r.title.font_size == 32, "title sized 32")
assert(r.title.bold == false, "title bold off")
assert(r.title.line_height == 0.05, "title tight leading preserved")
assert(r.title.template == "%title", "title template")

-- author: bundled Caveat, size 26, short author names
assert(r.author.font_face == "Caveat-Regular.ttf", "author -> Caveat-Regular.ttf")
assert(r.author.font_size == 26, "author sized 26")
assert(r.author.template == "%authors_short", "author uses short author names")

-- tags enabled, progress bar rounded, customised templates carried over
assert(r.tags.disabled == false, "tags enabled")
assert(r.progress.bar_style == "rounded", "progress bar rounded")
assert(r.status.template:find("%%time_12h"), "status template carried over")
assert(r.description.template:find("%%rating"), "description shows rating prefix")

-- regions not in FRESH_INSTALL fall through to DEFAULTS (rating stays off)
assert(r.rating.disabled == Regions.DEFAULTS.rating.disabled, "rating falls through to default")

-- stale customization was cleared (title size 99 gone)
assert(r.title.font_size ~= 99, "prior customization replaced")

print("PASS hero fresh defaults")
