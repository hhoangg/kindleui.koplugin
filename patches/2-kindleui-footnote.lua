--[[
Kindle's footnote sheet, applied to KOReader's own footnote popup.

KOReader already has the hard parts. `FootnoteWidget` is a BottomContainer with
a ScrollHtmlWidget inside it, so the sheet already rises from the bottom edge and
already scrolls, and it already knows how to jump to the footnote's place in the
book -- `follow_callback`.

What it does not have is any way to SEE that. The jump is bound to
`onSwipeFollow`, and only to `direction == "west"` (footnotewidget.lua:431-439).
The capability is there; the affordance is not, and a gesture nothing on screen
mentions is a feature most people never learn exists.

Kindle's sheet says it out loud. Measured from the firmware's own window dump:

    A:FooterNotes    1236x612 +0+1033      37.1% of a 1236x1648 panel

    ---- thick rule ----------------------
    Footnote                            X
    [30] the note text, scrolling if long
    ...
    Go To Footnotes                     >

So this patch adds a title, a close button and that bottom row, and leaves
everything else upstream's.

WHY IT WRAPS `init` RATHER THAN REPLACING IT

Replacing `FootnoteWidget:init` would mean copying ~200 lines of CSS assembly,
font-size resolution and scroll plumbing into this file and owning them forever.
Instead this calls upstream's own init and then reaches into the widget tree it
built: the frame's child is a VerticalGroup whose first element is the top
border, so the title goes in at index 2 and the action row is appended.

THE ONE UGLY PART, AND WHY

Upstream fixes the sheet height at `Screen:getHeight() * 1/3` on its second line
and derives the scroll area from it further down. There is no seam between the
two. Adding ~190px of chrome to a 549px content area would give a 739px sheet --
45% of the screen where Kindle uses 37% -- so the content has to be told to be
smaller before that line runs, and the only way in is `Screen:getHeight` itself.

It is shadowed for exactly the duration of the wrapped call, restored in the
same breath, and restored again through pcall if init raises. Upstream reads it
once more, to size the whole-screen gesture range, so that range is put back by
hand afterwards -- the two callers are two lines apart and both are checked
against the file each time this is verified.

Verified against KOReader v2026.07.1.
]]

local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

-- Kindle's own sheet, as a fraction of the panel it was measured on.
local SHEET_RATIO = 612 / 1648
local SIDE_PAD    = Size.padding.large

--- The "Go To Footnotes >" row. A plain tappable strip, not a Button: Kindle
-- draws no border here, and on e-ink a bordered button in a sheet reads as a
-- second, competing frame.
--
-- It works at all because WidgetContainer:handleEvent propagates to children
-- before calling its own handler (widgetcontainer.lua:100-107). FootnoteWidget
-- registers TapClose over the WHOLE screen, so without that ordering a tap here
-- would simply close the sheet instead.
local ActionRow = InputContainer:extend{
    width = nil,
    text = nil,
    callback = nil,
}

function ActionRow:init()
    local face = Font:getFace("cfont", 20)
    local label = TextWidget:new{ text = self.text, face = face }
    local chevron = TextWidget:new{ text = "›", face = Font:getFace("cfont", 24) }
    local h = math.max(label:getSize().h, chevron:getSize().h) + 2 * SIDE_PAD

    self[1] = HorizontalGroup:new{
        HorizontalSpan:new{ width = SIDE_PAD },
        LeftContainer:new{
            dimen = Geom:new{ w = self.width - 3 * SIDE_PAD - chevron:getSize().w, h = h },
            label,
        },
        RightContainer:new{
            dimen = Geom:new{ w = chevron:getSize().w, h = h },
            chevron,
        },
        HorizontalSpan:new{ width = SIDE_PAD },
    }
    self.dimen = Geom:new{ w = self.width, h = h }
    self.ges_events = {
        TapAction = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
end

function ActionRow:getSize()
    return Geom:new{ w = self.width, h = self.dimen.h }
end

function ActionRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
end

function ActionRow:onTapAction()
    if self.callback then self.callback() end
    return true
end

local function patch()
    local ok, FootnoteWidget = pcall(require, "ui/widget/footnotewidget")
    if not ok or type(FootnoteWidget) ~= "table" then
        return false, "no FootnoteWidget"
    end
    if rawget(FootnoteWidget, "_kindleui_patched") then
        return true
    end
    local orig_init = rawget(FootnoteWidget, "init")
    if type(orig_init) ~= "function" then
        return false, "init is not a function"
    end

    FootnoteWidget.init = function(self)
        local screen_h = Screen:getHeight()
        local sheet_h = math.floor(screen_h * SHEET_RATIO)

        -- Chrome has to be measured before upstream sizes the scroll area, so
        -- the title bar is built first and only inserted afterwards.
        local titlebar = TitleBar:new{
            width = Screen:getWidth(),
            align = "left",
            title = _("Footnote"),
            with_bottom_line = false,
            close_callback = function() self:onClose() end,
            show_parent = self,
        }
        local action
        if self.follow_callback then
            action = ActionRow:new{
                width = Screen:getWidth(),
                text = _("Go To Footnotes"),
                callback = function()
                    -- Same order as onSwipeFollow: tell the reader the sheet's
                    -- height first, so it can restore the page under it, then
                    -- follow. (footnotewidget.lua:431-439)
                    if self.close_callback then self.close_callback(self.height) end
                    return self.follow_callback()
                end,
            }
        end
        local hairline_h = Size.line.thin
        local chrome_h = titlebar:getHeight() + hairline_h
            + (action and action:getSize().h or 0)

        -- See the header. Upstream computes floor(H * 1/3) with no seam after
        -- it, so H is what has to change.
        local want_content = math.max(sheet_h - chrome_h, math.floor(screen_h * 0.12))
        local real_getHeight = Screen.getHeight
        Screen.getHeight = function() return want_content * 3 end
        local init_ok, init_err = pcall(orig_init, self)
        Screen.getHeight = real_getHeight
        if not init_ok then
            error(init_err, 0)
        end

        -- Upstream sized its whole-screen gesture range from the same call, two
        -- lines below the one we were aiming at. Every ges_event shares that one
        -- Geom, so putting it back once fixes all of them.
        local tap = self.ges_events and self.ges_events.TapClose
        if tap and tap.range then
            tap.range.h = screen_h
        end

        local frame = self.container
        local node = frame and frame[1]
        if not node then
            logger.warn("kindleui: footnote sheet has no frame, leaving it alone")
            return
        end
        -- Short notes make upstream wrap the group in a CenterContainer to crop
        -- the blank area away. Kindle's sheet does not do that -- it keeps its
        -- height and lets the note sit at the top -- and the wrapper's own
        -- height maths would fight the row we are about to append, so it goes.
        if node.ignore == "height" and node[1] then
            node = node[1]
            frame[1] = node
        end

        -- VerticalGroup caches its per-child offsets the first time getSize()
        -- is called and paintTo() then indexes that cache by child number
        -- (verticalgroup.lua:15-30 and :48). Upstream has already measured this
        -- group, so every insert below leaves the cache one entry short and the
        -- next paint dies on a nil offset. resetLayout() drops the cache; it has
        -- to run after EVERY mutation, not once at the end, because the filler
        -- height is itself measured from a getSize() in between.
        local n_before = #node
        local decorated = pcall(function()
            table.insert(node, 2, titlebar)   -- right after the top border line
            node:resetLayout()

            if action then
                local used = node:getSize().h + hairline_h + action:getSize().h
                if sheet_h > used then
                    table.insert(node, VerticalSpan:new{ width = sheet_h - used })
                end
                table.insert(node, LineWidget:new{
                    dimen = Geom:new{ w = Screen:getWidth(), h = hairline_h },
                })
                table.insert(node, action)
                node:resetLayout()
            end
        end)

        if not decorated then
            -- Put the group back the way upstream built it. A plain KOReader
            -- footnote sheet is a small loss; a half-built one crashes the
            -- reader out to the Kindle home screen, which is how this patch
            -- failed the first time it ran.
            for i = #node, n_before + 1, -1 do
                table.remove(node, i)
            end
            for i, w in ipairs(node) do
                if w == titlebar then table.remove(node, i) break end
            end
            node:resetLayout()
            logger.warn("kindleui: footnote sheet chrome failed, using the plain popup")
        end

        -- close_callback is handed this to repaint the page underneath.
        self.height = node:getSize().h
    end

    FootnoteWidget._kindleui_patched = true
    return true
end

local ok, err = pcall(patch)
if ok and err ~= false then
    logger.info("kindleui: footnote sheet patch applied")
else
    logger.warn("kindleui: footnote sheet patch skipped:", tostring(err))
end
