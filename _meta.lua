local _ = require("lib/bookshelf_i18n").gettext
return {
    -- KEEP `name`, equal to the .koplugin directory id ("bookshelf"). Do not
    -- remove again, even though current KOReader deprecates it (koreader#15096:
    -- nightly logs a harmless "name in _meta.lua is deprecated" WARN and keys
    -- enable/disable off the directory id instead).
    --
    -- Why it's load-bearing on stable releases (confirmed v2025.10, before the
    -- ~2026-04 directory-id normalisation): the PluginLoader loads a DISABLED
    -- plugin from its _meta.lua, NOT main.lua. The plugin-manager "enable" toggle
    -- then keys plugins_disabled by that loaded name. With no name in _meta, the
    -- loader falls back to a path match (e.g. "mnt/.../bookshelf"), so enabling
    -- clears the wrong key and never removes plugins_disabled["bookshelf"] (the
    -- directory-id key discovery actually checks) -- the plugin stays stuck
    -- disabled. (Disabling works regardless, because an ENABLED plugin loads
    -- main.lua, which does carry name = "bookshelf".) name in _meta restores the
    -- correct key for the disabled-load path; tests/_test_meta.lua guards it.
    -- Renamed from "bookshelf" with the fork: this must equal the .koplugin
    -- directory id, which is now "kindleui". The long note above is upstream's
    -- and still applies -- it is why this field is here at all.
    name = "kindleui",
    fullname = _("Kindle UI"),
    description = _([[Kindle's interface for KOReader: a home screen you pick a book from, a control centre from the top edge, a reading toolbar, a page browser, a settings page and a lock screen.

Forked from bookshelf.koplugin by AndyHazz, which is the home screen and the larger part of this.]]),
    -- Four parts, and every one of them numeric on purpose.
    --
    -- The updater compares versions with `tonumber(part) or 0` over
    -- dot-separated pieces (bookshelf_updater.lua:66), so anything non-numeric
    -- silently becomes ZERO: "4.3.5-kindleui.1" parses as [4,3,0,1] and reads
    -- as OLDER than upstream's 4.3.5, which would offer every user a downgrade.
    --
    -- So the fork's build number is a fourth numeric part. It says which
    -- upstream release this is built on, and sorts above it.
    version = "4.3.5.1",
}
