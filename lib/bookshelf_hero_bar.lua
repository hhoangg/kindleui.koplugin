-- bookshelf_hero_bar.lua
-- Progress-bar backend chooser. When bookends is installed we route paint
-- through its OverlayWidget.paintProgressBar primitive (seven styles).
-- Without bookends we fall back to KOReader's stock ProgressWidget
-- (bordered / solid only).
--
-- All callers see a single `:new{ width, height, percentage, style }`
-- constructor and a paintable widget with `getSize / paintTo / free`.
--
-- Earlier version of this module tried to require bookends's BarWidget
-- directly. That doesn't work — BarWidget is `local` inside
-- bookends_overlay_widget.lua and never exported on the OverlayWidget
-- table. paintProgressBar IS exported, so we build our own thin wrapper
-- around it. The pattern matches what bookends's own BarWidget does
-- internally (bookends_overlay_widget.lua:223-227), so any future bar
-- style added to paintProgressBar lights up here automatically.

local Geom   = require("ui/geometry")
local Widget = require("ui/widget/widget")

local HeroBar = {}

-- pcall-load bookends's overlay-widget module. Plugin paths put each
-- koplugin's directory on package.path so the require resolves even
-- though bookends is is_doc_only (its main.lua doesn't run in FM
-- context, but module-level files are still requireable). Returns the
-- paintProgressBar function or nil.
local function loadBookendsPaint()
    local ok, mod = pcall(require, "bookends_overlay_widget")
    if not ok or type(mod) ~= "table" or type(mod.paintProgressBar) ~= "function" then
        return nil
    end
    return mod.paintProgressBar
end

-- Styles excluded from bookshelf's hero strip even when bookends supports
-- them. Radial / radial_hollow are circular dials and look out of place
-- in a horizontal strip context. Anything not listed here flows through
-- automatically as bookends adds new styles.
HeroBar.EXCLUDED_STYLES = {
    radial        = true,
    radial_hollow = true,
}

-- Snapshot of bookends's BAR_STYLES at the time this version of bookshelf
-- shipped. Used as a fallback when the installed bookends version is too
-- old to export OverlayWidget.BAR_STYLES (anything pre-v2.x). Bookends
-- versions that DO export the table get read directly — new styles
-- bookends adds in the future show up here without a bookshelf change.
HeroBar.BOOKENDS_FALLBACK = {
    "bordered", "solid", "rounded", "metro", "wavy",
    "radial", "radial_hollow", "pacman",
}

HeroBar.FALLBACK_STYLES = { "bordered", "solid" }

-- Returns the cycle-list applicable for the active backend. When bookends
-- is installed and exports BAR_STYLES, use that (so any future novelty
-- style auto-appears); otherwise the local snapshot. Either way, filter
-- through EXCLUDED_STYLES.
function HeroBar.availableStyles()
    if not loadBookendsPaint() then return HeroBar.FALLBACK_STYLES end
    local all
    local ok, mod = pcall(require, "bookends_overlay_widget")
    if ok and type(mod) == "table" and type(mod.BAR_STYLES) == "table" then
        all = mod.BAR_STYLES
    else
        all = HeroBar.BOOKENDS_FALLBACK
    end
    local out = {}
    for _, s in ipairs(all) do
        if not HeroBar.EXCLUDED_STYLES[s] then
            out[#out + 1] = s
        end
    end
    return out
end

-- Paintable widget that delegates to bookends's paintProgressBar.
-- Extends Widget rather than a bare metatable so KOReader's standard
-- event-propagation walk (WidgetContainer:propagateEvent → child:handleEvent
-- on every descendant) finds a `handleEvent` method on us. The earlier
-- bare-metatable version crashed the first event broadcast (Show /
-- Resume etc) because `bar:handleEvent` was nil.
--
-- Bookends's own BarWidget is similarly bare — but inside bookends it's
-- only ever rendered via manual paintTo calls in OverlayWidget's
-- framework, never as a child of a WidgetContainer that propagates
-- events. Bookshelf places this widget inside a HorizontalGroup, which
-- IS a WidgetContainer.
local BookendsBar = Widget:extend{
    width    = 0,
    height   = 0,
    fraction = 0,
    ticks    = nil,
    style    = "bordered",
    colors   = nil,
    paint    = nil,  -- bookends's paintProgressBar function
}

function BookendsBar:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ticks = self.ticks or {}
end

function BookendsBar:getSize() return self.dimen end

function BookendsBar:paintTo(bb, x, y)
    -- Stash dimen with screen coords so any parent that walks our dimen
    -- after paint sees the right values.
    self.dimen.x, self.dimen.y = x, y
    self.paint(bb, x, y, self.width, self.height,
        self.fraction, self.ticks, self.style, nil, false, self.colors)
end

function BookendsBar:free() end -- nothing to release; pure painter

-- new{ width, height, percentage, style, colors } -> a paintable widget.
-- `style` is the user's saved choice; we silently downgrade to whatever
-- the active backend supports (paintProgressBar tolerates unknown
-- styles by rendering bordered). `colors` is the bookends paintProgressBar
-- color table ({ fill = ..., bg = ... } at minimum); when bookends isn't
-- installed the fallback ProgressWidget ignores it.
function HeroBar:new(o)
    o = o or {}
    local width      = o.width or 0
    local height     = math.max(1, o.height or 5)
    local percentage = math.max(0, math.min(1, o.percentage or 0))
    local style      = o.style or "bordered"
    local colors     = o.colors

    local paint = loadBookendsPaint()
    if paint then
        return BookendsBar:new{
            width    = width,
            height   = height,
            fraction = percentage,
            ticks    = {},
            style    = style,
            colors   = colors,
            paint    = paint,
        }
    end

    -- Fallback: KOReader ProgressWidget. Only bordered / solid are
    -- meaningful; saved styles like wavy render as the default look.
    -- ProgressWidget doesn't expose per-instance fill/bg overrides, so
    -- user color picks have no effect along this path — acceptable as
    -- the fallback only triggers when bookends isn't installed, and the
    -- user can install bookends to unlock themed bars.
    local ProgressWidget = require("ui/widget/progresswidget")
    return ProgressWidget:new{
        width      = width,
        height     = height,
        percentage = percentage,
        margin_h   = 0,
        margin_v   = 0,
    }
end

return HeroBar
