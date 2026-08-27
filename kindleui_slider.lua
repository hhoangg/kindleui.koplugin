--[[--
Kindle's horizontal slider, drawn by hand.

KOReader has no slider widget. There is no `horizontalslider.lua`; the closest
thing upstream is FrontLightWidget, which rolls its own control out of a
ProgressWidget plus a row of Buttons (frontlightwidget.lua:120 onwards). That
produces KOReader's look, not Kindle's, so this widget paints Kindle's shape
straight into the blitbuffer instead of composing existing widgets.

    Brightness
                             14
    −  ━━━━━━━━━━━━(O)──────────────────  +

Everything measured from a real Paperwhite 5 screenshot and expressed in the
reference pixels of kindleui_geom.lua's 1236x1648 panel, so it survives another screen:

  * the segment left of the knob is a thick bar, the segment right of it a thin
    line (8 and 3 reference px);
  * the knob is a white disc with a black ring, 50 reference px across;
  * the current value floats above the knob and travels with it;
  * `−` and `+` sit at the far ends and step by one.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
local REF_TRACK_THICK = 8   -- bar left of the knob
local REF_TRACK_THIN  = 3   -- line right of the knob
local REF_KNOB_D      = 50
local REF_KNOB_RING   = 5
local REF_LABEL_H     = 44
local REF_VALUE_H     = 32
local REF_GLYPH_H     = 52  -- the − and + at the ends
local REF_GAP         = 12  -- breathing room between label, value and track
local REF_SIDE_GAP    = 22  -- between a glyph and the end of the track

local Slider = InputContainer:extend{
    label = nil,                 -- e.g. "Brightness"
    label_right = nil,           -- optional text pinned to the right of the label line
    label_right_callback = nil,  -- tapping that text calls this
    min = 0,
    max = 100,
    value = 0,
    width = nil,
    callback = nil,              -- callback(new_value), fired on every change
}

function Slider:init()
    self.width = self.width or Screen:getWidth()
    self.value = self:_clamp(self.value)

    -- Font:getFace() re-applies Screen:scaleBySize to the size it is given
    -- (font.lua:276), and getFontSizeToFitHeight measures in real pixels, so
    -- feeding the latter's result to the former does not double-scale.
    local label_size = TextWidget:getFontSizeToFitHeight("cfont", Layout.y(REF_LABEL_H), 0)
    local value_size = TextWidget:getFontSizeToFitHeight("cfont", Layout.y(REF_VALUE_H), 0)
    local glyph_size = TextWidget:getFontSizeToFitHeight("cfont", Layout.y(REF_GLYPH_H), 0)

    self.label_widget = TextWidget:new{
        text = self.label or "",
        face = Font:getFace("cfont", label_size),
        padding = 0,
    }
    self.value_widget = TextWidget:new{
        text = tostring(self.value),
        face = Font:getFace("cfont", value_size),
        padding = 0,
    }
    -- U+2212 MINUS SIGN rather than a hyphen: it is the same width and weight
    -- as the plus, which a hyphen is not. Both live in NotoSans, our cfont.
    self.minus_widget = TextWidget:new{
        text = "\u{2212}",
        face = Font:getFace("cfont", glyph_size),
        padding = 0,
    }
    self.plus_widget = TextWidget:new{
        text = "+",
        face = Font:getFace("cfont", glyph_size),
        padding = 0,
    }
    if self.label_right then
        self.label_right_widget = TextWidget:new{
            text = self.label_right,
            face = Font:getFace("cfont", value_size),
            padding = 0,
        }
    end

    self.knob_d      = Layout.x(REF_KNOB_D)
    self.knob_r      = math.floor(self.knob_d / 2)
    self.knob_ring   = math.max(Size.line.thick, Layout.x(REF_KNOB_RING))
    self.track_thick = math.max(Size.line.thick, Layout.y(REF_TRACK_THICK))
    self.track_thin  = math.max(Size.line.medium, Layout.y(REF_TRACK_THIN))
    self.gap         = Layout.y(REF_GAP)
    self.side_gap    = Layout.x(REF_SIDE_GAP)

    self.label_h = self.label_widget:getSize().h
    if self.label_right_widget then
        self.label_h = math.max(self.label_h, self.label_right_widget:getSize().h)
    end
    self.value_h = self.value_widget:getSize().h
    -- The knob overhangs the track, so the row is as tall as whichever of the
    -- knob and the end glyphs is bigger.
    self.row_h = math.max(self.knob_d,
                          self.minus_widget:getSize().h,
                          self.plus_widget:getSize().h)
    self.height = self.label_h + self.gap + self.value_h + self.row_h + Size.padding.default

    if Device:isTouchDevice() then
        -- gesturerange.lua:29 documents this exact idiom: a widget's dimen only
        -- exists once it has been painted, so hand match() a function instead of
        -- a rect and let it resolve at gesture time.
        self.ges_events = {
            TapSlider = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return self.dimen end,
                },
            },
            PanSlider = {
                GestureRange:new{
                    ges = "pan",
                    range = function() return self.dimen end,
                    -- Same throttle FrontLightWidget uses (frontlightwidget.lua:34):
                    -- an e-ink panel cannot keep up with raw pan event rates.
                    rate = Screen.low_pan_rate and 3 or 30,
                },
            },
        }
    end
end

function Slider:_clamp(value)
    value = math.floor((tonumber(value) or self.min) + 0.5)
    if value < self.min then return self.min end
    if value > self.max then return self.max end
    return value
end

function Slider:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Slider:paintTo(bb, x, y)
    -- Recorded so UIManager:setDirty can be aimed at this row alone.
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }

    -- The knob moves, and we repaint only ourselves, so the previous frame has
    -- to be wiped first or the old knob is left stranded on the track.
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)

    self.label_widget:paintTo(bb, x, y + math.floor((self.label_h - self.label_widget:getSize().h) / 2))
    if self.label_right_widget then
        local right_size = self.label_right_widget:getSize()
        self._right_zone_x = x + self.width - right_size.w
        self.label_right_widget:paintTo(bb, self._right_zone_x,
            y + math.floor((self.label_h - right_size.h) / 2))
    end

    local minus_size = self.minus_widget:getSize()
    local plus_size = self.plus_widget:getSize()
    local row_y = y + self.label_h + self.gap + self.value_h
    local cy = row_y + math.floor(self.row_h / 2)

    self.minus_widget:paintTo(bb, x, cy - math.floor(minus_size.h / 2))
    self.plus_widget:paintTo(bb, x + self.width - plus_size.w, cy - math.floor(plus_size.h / 2))

    -- Tap zones for the steppers: the glyph plus half the gap that follows it,
    -- because a bare "−" is a small target on a 300dpi panel.
    self._minus_x2 = x + minus_size.w + math.floor(self.side_gap / 2)
    self._plus_x1 = x + self.width - plus_size.w - math.floor(self.side_gap / 2)

    local t0 = x + minus_size.w + self.side_gap
    local t1 = x + self.width - plus_size.w - self.side_gap
    self._track_x0, self._track_x1 = t0, t1

    local travel = t1 - t0 - self.knob_d
    if travel < 0 then travel = 0 end
    local span = self.max - self.min
    local frac = span > 0 and (self.value - self.min) / span or 0
    local cx = t0 + self.knob_r + math.floor(travel * frac + 0.5)

    -- blitbuffer.lua:1704 -> paintRect(x, y, w, h, value)
    if cx > t0 then
        bb:paintRect(t0, cy - math.floor(self.track_thick / 2), cx - t0,
            self.track_thick, Blitbuffer.COLOR_BLACK)
    end
    if t1 > cx then
        bb:paintRect(cx, cy - math.floor(self.track_thin / 2), t1 - cx,
            self.track_thin, Blitbuffer.COLOR_BLACK)
    end

    -- blitbuffer.lua:1948 -> paintCircle(center_x, center_y, r, c, w), where w is
    -- the ring width and defaults to r, i.e. a solid disc. So: fill white to hide
    -- the thick bar running under the knob, then stroke the ring on top.
    bb:paintCircle(cx, cy, self.knob_r, Blitbuffer.COLOR_WHITE, self.knob_r)
    bb:paintCircle(cx, cy, self.knob_r, Blitbuffer.COLOR_BLACK, self.knob_ring)

    local value_size = self.value_widget:getSize()
    local vx = cx - math.floor(value_size.w / 2)
    if vx < x then vx = x end
    if vx + value_size.w > x + self.width then vx = x + self.width - value_size.w end
    self.value_widget:paintTo(bb, vx, y + self.label_h + self.gap)
end

--- Maps a screen x coordinate onto a value, clamped to the track's travel.
function Slider:_valueFromX(pos_x)
    if not self._track_x0 then return self.value end
    local travel = self._track_x1 - self._track_x0 - self.knob_d
    if travel <= 0 then return self.value end
    local frac = (pos_x - (self._track_x0 + self.knob_r)) / travel
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return self.min + frac * (self.max - self.min)
end

function Slider:setValue(value)
    local new_value = self:_clamp(value)
    if new_value == self.value then return end
    self.value = new_value
    self.value_widget:setText(tostring(new_value))
    if self.callback then
        self.callback(new_value)
    end
    self:refresh()
end

--- Repaints this row and nothing else.
-- ReaderFooter does the same dance at readerfooter.lua:2382: paint the widget
-- first so its dimen is current, then hand that rect to setDirty with a nil
-- widget so nothing underneath is redrawn. "fast" (A2) rather than "ui" because
-- a full-flash on every pan event would make dragging unusable on e-ink.
function Slider:refresh()
    if not self.dimen then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "fast", self.dimen)
end

function Slider:onTapSlider(_, ges_ev)
    if not self.dimen then return false end
    local pos = ges_ev.pos
    if self.label_right_widget and self._right_zone_x
        and pos.x >= self._right_zone_x and pos.y < self.dimen.y + self.label_h then
        if self.label_right_callback then
            self.label_right_callback()
        end
        return true
    end
    -- Ignore taps that land on the label line rather than the control.
    if pos.y < self.dimen.y + self.label_h then return true end
    if pos.x <= (self._minus_x2 or 0) then
        self:setValue(self.value - 1)
    elseif pos.x >= (self._plus_x1 or math.huge) then
        self:setValue(self.value + 1)
    else
        self:setValue(self:_valueFromX(pos.x))
    end
    return true
end

--- Dragging the knob. ges_ev.pos is the live finger position for pan as well as
-- tap, which is why FrontLightWidget can alias one handler to the other
-- (frontlightwidget.lua:581).
function Slider:onPanSlider(_, ges_ev)
    if not self.dimen then return false end
    self:setValue(self:_valueFromX(ges_ev.pos.x))
    return true
end

function Slider:free()
    -- Our text widgets are not children in the array part, so
    -- WidgetContainer:free would never reach their glyph caches.
    self.label_widget:free()
    self.value_widget:free()
    self.minus_widget:free()
    self.plus_widget:free()
    if self.label_right_widget then
        self.label_right_widget:free()
    end
end

return Slider
