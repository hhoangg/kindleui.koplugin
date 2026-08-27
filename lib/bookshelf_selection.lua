-- lib/bookshelf_selection.lua
-- Bulk-edit selection state. Pure data, no UI deps.
-- Owned by BookshelfWidget; lives as long as the widget shell.
-- See docs/superpowers/specs/2026-05-18-bulk-edit-design.md §1.

local Selection = {}
Selection.__index = Selection

function Selection.new()
    return setmetatable({ _paths = {}, _count = 0, _active = false }, Selection)
end

function Selection:isActive()  return self._active end

function Selection:enterMode()
    self._active = true
end

function Selection:exitMode()
    local prev = self._count
    self._active = false
    self._paths = {}
    self._count = 0
    return prev
end

function Selection:add(filepath)
    if self._paths[filepath] then return false end
    self._paths[filepath] = true
    self._count = self._count + 1
    return true
end

function Selection:remove(filepath)
    if not self._paths[filepath] then return false end
    self._paths[filepath] = nil
    self._count = self._count - 1
    return true
end

function Selection:toggle(filepath)
    if self._paths[filepath] then
        self:remove(filepath)
        return false
    else
        self:add(filepath)
        return true
    end
end

function Selection:contains(filepath)
    return self._paths[filepath] == true
end

function Selection:addMany(paths)
    local added = 0
    for _, p in ipairs(paths) do
        if self:add(p) then added = added + 1 end
    end
    return added
end

function Selection:removeMany(paths)
    local removed = 0
    for _, p in ipairs(paths) do
        if self:remove(p) then removed = removed + 1 end
    end
    return removed
end

function Selection:count() return self._count end

function Selection:paths()
    local list = {}
    for p in pairs(self._paths) do list[#list + 1] = p end
    table.sort(list)
    return list
end

function Selection:clear()
    self._paths = {}
    self._count = 0
end

function Selection:stackState(stack_paths)
    if #stack_paths == 0 then return "none" end
    local hit = 0
    for _, p in ipairs(stack_paths) do
        if self._paths[p] then hit = hit + 1 end
    end
    if hit == 0 then return "none" end
    if hit == #stack_paths then return "all" end
    return "some"
end

function Selection:scrubMissing(predicate)
    local to_remove = {}
    for p in pairs(self._paths) do
        if not predicate(p) then
            to_remove[#to_remove + 1] = p
        end
    end
    for _, p in ipairs(to_remove) do
        self._paths[p] = nil
        self._count = self._count - 1
    end
    return #to_remove
end

return Selection
