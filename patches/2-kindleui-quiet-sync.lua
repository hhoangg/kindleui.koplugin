--[[
Progress sync stops hijacking the screen.

THE COMPLAINT

Open a book and a dialog appears: "Connecting to Wi-Fi…", then "Scanning for
networks…", over the page you were about to read. Nobody asked for it.

WHAT ACTUALLY HAPPENS

`KOSync:onReaderReady` fires a pull on the next tick whenever auto_sync is on
(kosync.koplugin/main.lua:190-194):

    self:getProgress(true, false)

The two arguments are `ensure_networking` and `interactive`. So the call says,
in the same breath, "the user did not ask for this" AND "turn the radio on for
it". `getProgress` honours the first by routing through
`NetworkMgr:willRerunWhenOnline` (main.lua:826), which with
`wifi_enable_action = "turn_on"` lands in `turnOnWifiAndWaitForConnection` --
and that function shows "Connecting to Wi-Fi…" (manager.lua:539) and
"Scanning for networks…" (manager.lua:1116) as plain InfoMessages.

Those two are NOT gated on `interactive`. Upstream gates its OWN messages on it
-- every `showSyncError` call site is wrapped in `if interactive then` -- but
NetworkMgr never received the flag, so it speaks up regardless. That asymmetry
is the bug: the caller's "this is background work" never reaches the layer that
decides whether to open a dialog.

THE FIX, AND WHY IT IS THIS ONE

Wrapping `onReaderReady` was the obvious move and it is wrong: that function
also calls `registerEvents()`, which reads `settings.auto_sync` to decide
whether to hook onResume/onNetworkConnected (main.lua:1094-1101). Suppressing
the pull by flipping that flag would silently unhook the very events that make
background sync work.

So the wrap goes on `getProgress`/`updateProgress` instead, at exactly the point
where the two arguments disagree: a call that is not interactive does not get to
force the radio on. It may still sync -- if the radio is already up, nothing
changes at all.

WHAT THIS COSTS

Open a book with Wi-Fi off and no progress is pulled at that moment. It arrives
when the network next comes up: `KOSync:_onNetworkConnected` (main.lua:1012-1020)
drains the queue and pulls, and the push side already had a queue for precisely
this case (KOSyncQueue). A manual pull from the menu is `interactive = true` and
keeps its dialogs, because there the user did ask and deserves to see progress.

Pairs with `auto_restore_wifi`, which brings the radio back silently on resume
-- so by the time a book is opened the device is usually online anyway, and the
pull happens immediately with no dialog at all.

Verified against KOReader v2026.07.1.
]]

local logger = require("logger")
local userpatch = require("userpatch")

-- `plugin` here is the plugin's MODULE table, not an instance: userpatch.lua:178
-- calls `patchfunc(plugin)` with the argument createPluginInstance received, and
-- the freshly built instance is the *return* value. Patching the module table is
-- what we want anyway, since the instance reaches these methods through its
-- metatable.
--
-- That table is re-dofile()d for every Reader and FileManager (userpatch.lua:165-167),
-- so this runs again each time with a pristine table -- which is why capturing
-- `orig` here can never wrap an already-wrapped function. The guard below is
-- only for the case of two patch funcs registered against the same table.
userpatch.registerPatchPluginFunc("kosync", function(plugin)
    local ok, err = pcall(function()
        if type(plugin) ~= "table" then return end
        if plugin._kindleui_quiet then return end

        -- Both take (ensure_networking, interactive, ...) as their first two
        -- arguments; updateProgress has a third, on_suspend, which is passed
        -- through untouched.
        for _, name in ipairs({ "getProgress", "updateProgress" }) do
            local orig = plugin[name]
            if type(orig) == "function" then
                plugin[name] = function(self, ensure_networking, interactive, ...)
                    if not interactive then
                        ensure_networking = false
                    end
                    return orig(self, ensure_networking, interactive, ...)
                end
            else
                logger.warn("kindleui: kosync." .. name .. " missing, quiet-sync patch partial")
            end
        end

        plugin._kindleui_quiet = true
        logger.dbg("kindleui: quiet-sync patch applied to kosync")
    end)
    if not ok then
        -- A failure here must not cost the reader its sync plugin.
        logger.warn("kindleui: quiet-sync patch failed, ignoring:", err)
    end
end)
