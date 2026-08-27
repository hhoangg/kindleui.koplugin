-- tests/_test_bookshelf_selection.lua
-- Pure-Lua unit tests for bookshelf_selection.lua.
-- Run from the plugin root: `lua tests/_test_bookshelf_selection.lua`

package.path = "./?.lua;./?/init.lua;" .. package.path

local Selection = dofile("lib/bookshelf_selection.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("PASS " .. name)
    else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "values differ") .. " — expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

test("new selection is inactive and empty", function()
    local s = Selection.new()
    assertEq(s:isActive(), false)
    assertEq(s:count(), 0)
end)

test("enterMode sets active; exitMode clears and deactivates", function()
    local s = Selection.new()
    s:enterMode()
    assertEq(s:isActive(), true)
    s:add("/a.epub")
    s:add("/b.epub")
    assertEq(s:count(), 2)
    local prev = s:exitMode()
    assertEq(prev, 2)
    assertEq(s:isActive(), false)
    assertEq(s:count(), 0)
end)

test("add/remove/toggle/contains", function()
    local s = Selection.new()
    assertEq(s:add("/a.epub"), true)
    assertEq(s:add("/a.epub"), false)  -- already present
    assertEq(s:contains("/a.epub"), true)
    assertEq(s:remove("/a.epub"), true)
    assertEq(s:remove("/a.epub"), false)
    assertEq(s:toggle("/b.epub"), true)
    assertEq(s:contains("/b.epub"), true)
    assertEq(s:toggle("/b.epub"), false)
    assertEq(s:contains("/b.epub"), false)
end)

test("addMany / removeMany return counts of effective changes", function()
    local s = Selection.new()
    assertEq(s:addMany({"/a", "/b", "/c", "/a"}), 3)  -- duplicate counted once
    assertEq(s:count(), 3)
    assertEq(s:removeMany({"/b", "/z"}), 1)  -- /z not present
    assertEq(s:count(), 2)
end)

test("paths returns sorted copy; mutating it does not affect state", function()
    local s = Selection.new()
    s:addMany({"/c", "/a", "/b"})
    local p = s:paths()
    assertEq(p[1], "/a")
    assertEq(p[2], "/b")
    assertEq(p[3], "/c")
    table.remove(p)
    assertEq(s:count(), 3)
end)

test("clear empties paths; mode unchanged", function()
    local s = Selection.new()
    s:enterMode()
    s:addMany({"/a", "/b"})
    s:clear()
    assertEq(s:count(), 0)
    assertEq(s:isActive(), true)
end)

test("stackState returns all/some/none", function()
    local s = Selection.new()
    s:addMany({"/a", "/b"})
    assertEq(s:stackState({"/a", "/b", "/c"}), "some")
    s:add("/c")
    assertEq(s:stackState({"/a", "/b", "/c"}), "all")
    s:clear()
    assertEq(s:stackState({"/a", "/b"}), "none")
    assertEq(s:stackState({}), "none")  -- empty stack is "none"
end)

test("scrubMissing removes paths failing predicate; returns count removed", function()
    local s = Selection.new()
    s:addMany({"/a", "/b", "/c"})
    local keep = { ["/a"] = true, ["/c"] = true }
    local removed = s:scrubMissing(function(p) return keep[p] == true end)
    assertEq(removed, 1)
    assertEq(s:count(), 2)
    assertEq(s:contains("/b"), false)
end)

test("scrubMissing handles full removal", function()
    local s = Selection.new()
    s:addMany({"/a", "/b", "/c", "/d"})
    local removed = s:scrubMissing(function() return false end)
    assertEq(removed, 4)
    assertEq(s:count(), 0)
    assertEq(s:contains("/a"), false)
    assertEq(s:contains("/d"), false)
end)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
