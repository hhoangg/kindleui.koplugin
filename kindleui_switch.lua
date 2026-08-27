--[[
A switch, drawn rather than typed.

WHY NOT A GLYPH

The bundled symbols font has toggle-on and toggle-off, and the settings page
used them. Measured out of the font file, the glyph's ink box is 0.52 of the
face's line height -- so a switch the size Kindle draws (0.35 of a row) needs a
face whose line is 0.67 of a row, which is half again taller than the row's own
title. The mandatory column carries one face for every row, so that face also
sizes the value text: "Viettel_5G" would have rendered larger than the heading
above it.

The ratio is fixed by the font, so no amount of tuning reconciles those two.
Drawing it is the only way to have a switch at the size a switch should be and
values at the size text should be.

PROPORTIONS

Measured off the two design images the owner supplied, not chosen:

    aspect            width / height       = 2.05
    stroke            0.09 x height
    knob diameter     0.70 x height
    knob centre       0.566 x height from the pill's end

The first attempt derived the knob from the stroke -- radius = h/2 - stroke --
which made it 0.80 of the height and sat its centre 0.50 from the end. Both
wrong in the same direction: a knob too big, pressed against the rim, with no
air between the two. The gap is not slack; it is what makes the knob read as an
object inside the pill rather than a hole cut out of it.

Height is a ratio of the ROW so the switch stays proportionate if the row height
changes -- which is what went wrong with the glyph it replaced, sized by a font
metric that had nothing to do with the row.

CONTRAST, NOT COLOUR

On is a filled pill with a knob punched out of it; off is an outlined pill with
a filled knob. Both states carry the same visual weight, which matters more here
than it would in colour: the tick this replaced could only say "on", so an off
row and a row that was not a switch at all looked identical.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local Switch = Widget:extend{
    -- Row height this switch belongs to. Everything else derives from it.
    row_h = 100,
    on = false,
}

-- All measured; see the header.
local H_RATIO      = 0.35    -- switch height as a fraction of the row
local ASPECT       = 2.05    -- width / height
local STROKE_RATIO = 0.09    -- outline thickness
local KNOB_RATIO   = 0.70    -- knob diameter
local KNOB_INSET   = 0.566   -- knob centre, from the near end

function Switch:getSize()
    local h = math.floor(self.row_h * H_RATIO)
    return Geom:new{ w = math.floor(h * ASPECT), h = h }
end

function Switch:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h = size.w, size.h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }

    local r      = math.floor(h / 2)
    -- Floored at 2px: a one-pixel outline vanishes into e-ink's own dithering,
    -- and an off switch that reads as blank is the bug this widget exists to
    -- fix.
    local stroke = math.max(2, math.floor(h * STROKE_RATIO))
    local knob_r = math.floor(h * KNOB_RATIO / 2)
    local inset  = math.floor(h * KNOB_INSET)
    local knob_cy = y + math.floor(h / 2)
    local knob_cx = self.on and (x + w - inset) or (x + inset)

    if self.on then
        bb:paintRoundedRect(x, y, w, h, Blitbuffer.COLOR_BLACK, r)
        -- Punched out in white. paintCircle draws a ring when given a width, so
        -- a width equal to the radius is what fills it.
        bb:paintCircle(knob_cx, knob_cy, knob_r, Blitbuffer.COLOR_WHITE, knob_r)
    else
        bb:paintBorder(x, y, w, h, stroke, Blitbuffer.COLOR_BLACK, r)
        bb:paintCircle(knob_cx, knob_cy, knob_r, Blitbuffer.COLOR_BLACK, knob_r)
    end
end

return Switch
