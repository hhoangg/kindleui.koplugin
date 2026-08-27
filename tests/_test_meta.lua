-- Guards _meta.lua's `name` field. It MUST be present and equal to the plugin
-- directory id, which in this fork is "kindleui" and upstream is "bookshelf".
-- Removing it (to silence the deprecation warning on current KOReader) broke
-- enable/disable on stable releases up to ~v2025.10, which still key
-- plugins_disabled by `name`: a disabled plugin could not be re-enabled. See the
-- comment in _meta.lua. This test stops a future "tidy-up" from reintroducing
-- the regression.
--
-- The id is read from the checkout rather than hardcoded, so this keeps guarding
-- the invariant that actually matters -- name == directory id -- without having
-- to be edited again the next time the plugin is renamed, and without conflicting
-- with upstream when its own copy of this file says "bookshelf".
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local t = dofile("tests/_helpers.lua").runner()

-- The id this fork installs as, and therefore the id KOReader keys
-- plugins_disabled by. It is stated here rather than derived from the working
-- directory: a development checkout is usually named after the repository
-- ("kindle-jb", "kindleui.koplugin", whatever git clone produced), so deriving
-- it would make the assertion silently vanish in exactly the checkout a
-- developer runs the tests in. README's install step is the contract this
-- mirrors -- the plugin folder must be named kindleui.koplugin.
local EXPECTED_ID = "kindleui"

-- When the checkout IS a .koplugin directory, cross-check the two agree, so a
-- rename of the folder without a matching edit here is caught rather than
-- papered over.
local function directoryId()
    local pwd = io.popen("pwd"):read("*l") or ""
    local leaf = pwd:match("([^/]+)$") or ""
    return leaf:match("^(.+)%.koplugin$")
end

t.test("_meta.lua declares name == the plugin directory id", function()
    local meta = dofile("_meta.lua")
    assert(type(meta) == "table", "_meta.lua must return a table")
    assert(type(meta.name) == "string" and meta.name ~= "",
        "_meta.lua must set a non-empty name (the .koplugin directory id) so "
        .. "enable/disable tracking keys consistently on older KOReader; got "
        .. tostring(meta.name))
    assert(meta.name == EXPECTED_ID,
        "_meta.lua must set name = \"" .. EXPECTED_ID .. "\" (the .koplugin "
        .. "directory id this fork installs as) so enable/disable tracking keys "
        .. "consistently on older KOReader; got " .. tostring(meta.name))
    local dir_id = directoryId()
    if dir_id then
        assert(dir_id == EXPECTED_ID,
            "this checkout is a .koplugin directory named " .. dir_id
            .. ", but the test expects " .. EXPECTED_ID
            .. "; update EXPECTED_ID and _meta.lua together")
    end
    assert(type(meta.version) == "string", "_meta.lua must carry a version string")
end)

t.done()
