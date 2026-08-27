--[[
A card in the control centre for work that is still going on somewhere else.

WHAT THIS IS FOR

A long job -- uploading a library, say -- should not own the screen while it
runs. The reader starts it, goes back to their book, and pulls the control
centre down when they want to know how far it has got. That only works if the
panel can show something it does not itself own.

So this is a registry, the same shape as lib/bookshelf_placeholders.lua: with no
provider registered the panel is exactly as it was, and a plugin that wants a
card registers one. kindleui does not know what an upload is.

WHY A PROVIDER AND NOT A WIDGET

A provider is asked EVERY time the panel is built, and answers with plain data.
That matters because the panel is rebuilt on every toggle and on a timer while a
job runs -- a widget handed over once would have to be kept in step by whoever
handed it over, across rebuilds it cannot see. Plain data cannot go stale.
]]

local Blitbuffer = require("ffi/blitbuffer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Layout = require("kindleui_geom")

-- Local rather than shared with the control centre's copy, which is a local in
-- that file and not exported. Ten lines duplicated is a smaller cost than
-- reaching into another module's private, or than exporting one just to be
-- imported once -- and it is what stops this file having a dependency that
-- resolves only at run time, which `luajit -bl` cannot check.
local Tappable = InputContainer:extend{ on_tap = nil }

function Tappable:init()
    self.ges_events = {
        TapTaskCard = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
end

function Tappable:onTapTaskCard()
    if self.on_tap then self.on_tap() end
    return true
end

local TaskCard = {}

-- Reference pixels, measured against the same 1236x1648 panel the rest of the
-- control centre is laid out from.
local REF_PAD        = 22
local REF_BAR_H      = 22
local REF_CLOSE      = 52
local REF_GAP        = 12

local _provider = nil

--- Register what the card should show, or nil to remove it.
--
-- `fn()` returns nil when there is nothing to show, or:
--
--     { title      = "Uploading · 12 of 87 · 1.8 MB/s",
--       right      = "14%",              -- optional, right-aligned on the title row
--       progress   = 0.14,               -- 0..1, or nil for no bar
--       subtitle   = "87 books sent",    -- optional second line
--       running    = true,               -- decides what the close button MEANS
--       on_close   = function() end }
--
-- `running` is not decoration. The close button cancels work when a job is
-- running and merely clears a notice when it is not, and those must not be the
-- same tap with no warning -- so the card asks first when running is true.
function TaskCard.setProvider(fn)
    _provider = (type(fn) == "function") and fn or nil
end

function TaskCard.hasProvider()
    return _provider ~= nil
end

--- The current card data, or nil. Never raises: a provider having a bad day
--- must not take the control centre down with it.
function TaskCard.peek()
    if not _provider then return nil end
    local ok, data = pcall(_provider)
    if not ok then
        local ok_log, logger = pcall(require, "logger")
        if ok_log then logger.warn("kindleui: task card provider failed:", tostring(data)) end
        return nil
    end
    if type(data) ~= "table" or not data.title then return nil end
    return data
end

--- The card widget for `inner_w`, or nil when there is nothing to show.
--
-- `on_change` is called after the close button does something, so the panel can
-- rebuild itself -- the card cannot rebuild its own container.
function TaskCard.build(inner_w, faces, on_change)
    local data = TaskCard.peek()
    if not data then return nil end

    local pad   = Layout.y(REF_PAD)
    local gap   = Layout.y(REF_GAP)
    local close = Layout.y(REF_CLOSE)
    local content_w = inner_w - 2 * pad

    local rows = VerticalGroup:new{ align = "left" }

    -- Title row: title on the left, an optional figure and the close button on
    -- the right. The close button is sized to a comfortable touch target rather
    -- than to the glyph -- it is the one control here that throws work away.
    local title = TextWidget:new{
        text = data.title, face = faces.title, padding = 0,
        max_width = content_w - close - Layout.x(90),
    }
    local right_bits = HorizontalGroup:new{ align = "center" }
    if data.right then
        table.insert(right_bits, TextWidget:new{
            text = data.right, face = faces.sub, padding = 0,
        })
        table.insert(right_bits, HorizontalSpan:new{ width = gap })
    end
    table.insert(right_bits, Tappable:new{
        on_tap = function()
            if type(data.on_close) == "function" then data.on_close() end
            if type(on_change) == "function" then on_change() end
        end,
        CenterContainer:new{
            dimen = Geom:new{ w = close, h = close },
            TextWidget:new{ text = "\u{00D7}", face = faces.close, padding = 0 },
        },
    })

    local right_w = right_bits:getSize().w
    table.insert(rows, HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = content_w - right_w, h = close },
            RightContainer:new{
                dimen = Geom:new{ w = content_w - right_w, h = close },
                HorizontalGroup:new{ align = "center", title,
                    HorizontalSpan:new{ width = content_w - right_w - title:getSize().w } },
            },
        },
        right_bits,
    })

    if data.progress then
        local p = math.max(0, math.min(1, data.progress))
        local bar_h = Layout.y(REF_BAR_H)
        local border = Size.border.thick
        local fill_w = math.floor((content_w - 2 * border) * p)
        table.insert(rows, VerticalSpan:new{ width = gap })
        table.insert(rows, FrameContainer:new{
            bordersize = border,
            color = Blitbuffer.COLOR_BLACK,
            radius = math.floor(bar_h / 2),
            padding = 0,
            margin = 0,
            width = content_w,
            height = bar_h,
            -- A zero-width LineWidget raises, so an untouched bar draws nothing
            -- rather than a hairline at the left edge pretending to be progress.
            fill_w > 0 and LineWidget:new{
                dimen = Geom:new{ w = fill_w, h = bar_h - 2 * border },
                background = Blitbuffer.COLOR_BLACK,
            } or VerticalSpan:new{ width = bar_h - 2 * border },
        })
    end

    if data.subtitle then
        table.insert(rows, VerticalSpan:new{ width = gap })
        table.insert(rows, TextWidget:new{
            text = data.subtitle, face = faces.sub, padding = 0, max_width = content_w,
        })
    end

    return FrameContainer:new{
        bordersize = Size.border.thick,
        color = Blitbuffer.COLOR_BLACK,
        radius = Layout.y(10),
        background = Blitbuffer.COLOR_WHITE,
        margin = 0,
        padding = pad,
        width = inner_w,
        rows,
    }
end

--- True while the registered task wants the panel repainted on a timer.
function TaskCard.isLive()
    local data = TaskCard.peek()
    return data ~= nil and data.running == true
end

return TaskCard
