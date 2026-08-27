--[[
Kindle's own proportions, measured rather than guessed.

Every screenshot the Kindle firmware writes is paired with an `xwininfo` dump
naming each window and giving its exact rect. On a Paperwhite 5 (1236x1648) the
relevant ones are:

    QuickSettingsWindow  1236x1331 @ y=0     the control centre
    titleBar             1236x101  @ y=0     clock / battery strip
    searchBar            1236x115  @ y=101   despite the name, the icon toolbar
    appToolBar           1236x126  @ y=216   despite the name, the book title
    footerBar            1236x311  @ y=1337  chapter + scrubber
    kppContextMenu        572x543  @ 628,223 the overflow menu

Stored as ratios of that reference panel so the layout survives a different
screen. Absolute pixel counts would be wrong everywhere except a PW5, and
Screen:scaleBySize is the wrong tool here: these are proportions of the display,
not of the DPI.
]]

local Device = require("device")
local Screen = Device.screen

local REF_W, REF_H = 1236, 1648

local Geom = {
    -- Vertical bands, as a fraction of screen height.
    PANEL     = 1331 / REF_H, -- control centre
    STATUS    =  101 / REF_H,
    TOOLBAR   =  115 / REF_H,
    BOOKBAR   =  126 / REF_H,
    FOOTER    =  311 / REF_H,
}

--- Height in pixels of a named band on this screen.
function Geom.h(band)
    return math.floor(Screen:getHeight() * band)
end

--- Scales a reference-pixel measurement to this screen's width.
-- Kindle's spacing was authored against a 1236px-wide panel; anything narrower
-- has to shrink with it or the control centre's five discs stop fitting.
function Geom.x(px)
    return math.floor(Screen:getWidth() * px / REF_W)
end

--- Scales a reference-pixel measurement to this screen's height.
function Geom.y(px)
    return math.floor(Screen:getHeight() * px / REF_H)
end

Geom.REF_W, Geom.REF_H = REF_W, REF_H

return Geom
