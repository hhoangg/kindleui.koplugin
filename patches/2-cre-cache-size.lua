--[[
Give crengine a disk cache big enough for the library that is actually on here.

THE NUMBER

`credocument.lua:87` sets the rendered-document cache to **64 MB** and evicts the
least recently used entry when that is reached. That was a sane default for a
shelf of ordinary EPUBs. It is not one for long web novels: measured on this
device, a single book costs

    Phàm Nhân Tu Tiên 2   12.9 MB
    tam-thon-nhan-gian    10.3 MB
    vu-dong-can-khon       9.9 MB

because the cache holds the whole paginated document, and these have 1300-1700
HTML fragments each. Sixty-four megabytes holds five or six of them.

WHY THAT IS WORSE THAN IT SOUNDS

The cost of a miss is not small. Rendering one of these from scratch took **44
seconds** here, wall clock, measured from `opening file` to `Restoring user input
handling` in the log. With forty books and room for six, opening one evicts
another, so the same book pays that cost again the next time it is opened -- not
once, every time. The reader looks broken and the cache looks like it is working.

Disk is the cheap side of this trade: /mnt/us had 4.5 GB free with the whole
library on it, and the entire cache for forty books is a few hundred megabytes.

WHY A PATCH AND NOT A SETTING

There is no menu entry for it -- `cre_disk_cache_max_size` appears nowhere in
KOReader outside the line that reads it. Editing settings.reader.lua by hand does
not survive either: KOReader holds that file in memory and rewrites it on exit,
so an edit made while it is running is erased the next time it closes. Setting it
here happens at startup, before any document is opened and therefore before
`initCache` reads it.

NOT TOUCHED: `cre_storage_size_factor`

The neighbouring knob multiplies crengine's IN-MEMORY caches by 40. On a device
with 485 MB of RAM and swap already full, that is worth looking at -- but it
trades against render speed, and unlike the disk cache there is no measurement
here to justify a number. Left alone deliberately.
]]

local logger = require("logger")

local WANT_MB = 512

local ok, err = pcall(function()
    local current = G_reader_settings:readSetting("cre_disk_cache_max_size")
    if current and current >= WANT_MB then
        return -- already at least this generous; do not shrink someone's choice
    end
    G_reader_settings:saveSetting("cre_disk_cache_max_size", WANT_MB)
    logger.info("kindle-jb: cre disk cache set to", WANT_MB, "MB (was",
                tostring(current or 64), "MB)")
end)

if not ok then
    -- A smaller cache is slow. A patch that raises during startup is a reader
    -- that does not start.
    logger.warn("kindle-jb: could not set cre disk cache size:", tostring(err))
end
