-- tests/_test_settings_store_present.lua
-- Pure-Lua. Usage: luajit tests/_test_settings_store_present.lua
-- Verifies Store.wasPresent() reflects whether the settings file existed at load.
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        return nil   -- pretend the settings file does NOT exist
    end,
}
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/fake-koreader-settings" end,
}
package.loaded["luasettings"] = {
    open = function(path)
        return {
            readSetting  = function() end,
            saveSetting  = function() end,
            delSetting   = function() end,
            isTrue       = function() end,
            nilOrTrue    = function() end,
            flush        = function() end,
        }
    end,
}
package.loaded["logger"] = {
    dbg = function() end,
    warn = function() end,
    err  = function() end,
}
_G.G_reader_settings = {
    readSetting = function() end,
    saveSetting = function() end,
    delSetting  = function() end,
    flush       = function() end,
}
local Store = dofile("lib/bookshelf_settings_store.lua")
assert(type(Store.wasPresent) == "function", "wasPresent missing")
assert(Store.wasPresent() == false, "expected wasPresent=false when file absent")
print("PASS settings_store wasPresent")
