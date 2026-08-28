--[[
Kindle's three-way split, applied to KOReader.

THE PROBLEM THIS SOLVES

Swiping down from the top edge of a KOReader document does not open one panel.
It opens two. `ReaderMenu:onSwipeShowMenu` (readermenu.lua:481-490) fires
`ShowConfigMenu` — the bottom font/style strip — and *then* calls `onShowMenu`
for the top TouchMenu, so a single gesture lands you in front of every setting
the reader has, split across two widgets at opposite edges of the screen.

Kindle separates the same surface into three, by where the gesture starts and
what it is for:

    swipe down from the top   ->  control centre   (the DEVICE: light, radio)
    tap the top edge          ->  reading toolbar  (the BOOK: font, contents)
    swipe up from the bottom  ->  page browser     (WHERE you are in the book)

This plugin implements the first and third. The second is KOReader's existing
top menu, which stays reachable and is deliberately left alone for now.

HOW THE GESTURE IS TAKEN OVER, AND WHY NO PATCH IS NEEDED

`InputContainer:onGesture` (inputcontainer.lua:260-264) walks the touch zones in
dependency order and stops at the first whose handler returns true:

    for _, tzone in ipairs(self._ordered_touch_zones) do
        if tzone.gs_range:match(ev) and tzone.handler(ev) then
            return true
        end
    end

`overrides` adds a DepGraph edge putting our zone ahead of the named ones
(inputcontainer.lua:161-165), so returning true consumes the swipe before
upstream's handler is ever consulted. Nothing is monkey-patched and nothing is
copied, which matters because a userpatch at `early` priority fails SILENTLY
(userpatch.lua:94 only surfaces failures from `late` onward) — a reskin that
broke after an OTA would quietly revert with no visible sign.

Returning false falls through to upstream, so a swipe in the wrong direction
inside our band behaves exactly as it always did.

Naming a zone that does not exist in this context is harmless: `addNodeDep`
routes through `getOrCreateNode` (depgraph.lua), and `registerTouchZones` then
looks the phantom up in `self._zones`, gets nil, and `table.insert(t, nil)` is a
no-op under LuaJIT. So the same override list is safe in the file manager, where
the reader's zones were never registered.

AND WHY THAT IS NOT ENOUGH ON A REPLACED HOME SCREEN

All of the above puts our zones on `self.ui` -- ReaderUI or FileManager. A
gesture only ever reaches the topmost non-toast widget, plus widgets below it
listed in some parent's `active_widgets` or flagged `is_always_active`
(uimanager.lua:915-961). A third-party home screen -- bookshelf.koplugin's
`BookshelfWidget`, `covers_fullscreen = true` (bookshelf_widget.lua:188-192) --
is pushed onto the window stack ABOVE the FileManager, and the FileManager is
neither of those things. So on that home screen the FileManager, and with it
every zone we registered there, stops seeing gestures at all.

`_attachToHomeScreen` below puts the same band on that widget instead. See its
comment for why that beats the alternatives; the short version is that
`InputContainer:onGesture` tries `_ordered_touch_zones` before `ges_events`
(inputcontainer.lua:260-265), so a zone on the home screen outranks the home
screen's own handlers, and a band that lives on a widget can only fire while
that widget is the one being handed the gesture.
]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local KindleUI = WidgetContainer:extend({
    name = "kindleui",
    -- The control centre is device-level, so it belongs on the home screen too,
    -- not only over an open document.
    is_doc_only = false,
})

-- Upstream's own zones for the top band. Both must be claimed: the plain one is
-- the full-width top 1/8, the _ext one is a narrower but TALLER centre column
-- (top 1/5), and a swipe starting between 1/8 and 1/5 down the middle would
-- otherwise still reach the old two-panel handler.
-- Both the swipe AND the pan zones, because upstream routes them to the SAME
-- handler: readermenu.lua:135 and :160 each call `onSwipeShowMenu`. A slow,
-- deliberate pull from the top edge -- exactly the gesture a control centre
-- invites -- is classified as a pan, not a swipe, so claiming only "swipe" left
-- the stock two-panel handler owning the most natural version of the gesture.
-- That is why the first build looked like nothing had changed at all.
local TOP_OVERRIDES = {
    "readermenu_ext_swipe", "readermenu_swipe",
    "readermenu_ext_pan", "readermenu_pan",
    "rolling_swipe", "paging_swipe",
    "rolling_pan", "paging_pan",
}

-- Tapping the top edge currently opens the same two-panel pile as swiping it
-- (readermenu.lua:122 -> onTapShowMenu). Kindle puts the reading toolbar there
-- instead, so the tap zones have to be claimed as well as the drag ones.
local TOP_TAP_OVERRIDES = {
    "readermenu_ext_tap", "readermenu_tap",
    "tap_forward", "tap_backward",
    -- The FILE MANAGER has its own pair, registered separately
    -- (filemanagermenu.lua:82, :91) and pointing at the same onTapShowMenu.
    -- Without these, a tap on the top edge of the home screen still opened
    -- KOReader's stock menu -- so the shelf and the reader disagreed about
    -- what that edge does, which is the one thing an edge gesture must not do.
}

local BOTTOM_OVERRIDES = {
    "readerconfigmenu_ext_swipe", "readerconfigmenu_swipe",
    "readerconfigmenu_ext_pan", "readerconfigmenu_pan",
    "rolling_swipe", "paging_swipe",
    "rolling_pan", "paging_pan",
}

-- Widgets we are willing to graft the top band onto, keyed by the `name` the
-- widget declares for itself.
--
-- This is an allowlist and not a shape test on purpose. "Any fullscreen
-- InputContainer" would also match a fullscreen menu, a file dialog or a
-- confirmation box, and a control centre erupting over a confirmation box is a
-- worse bug than the one being fixed. A home screen is a specific thing and has
-- to be named as one.
--
-- `bookshelf` is bookshelf.koplugin's `BookshelfWidget` (bookshelf_widget.lua:189).
local HOME_SCREEN_WIDGETS = {
    bookshelf = true,
}

--- Reads a tap-zone rect from G_defaults so our bands stay congruent with
--- upstream's, including any the user has edited in Advanced settings.
-- These live in defaults.lua:59-62 as ratios of screen width/height.
local function zoneRatio(key, fallback)
    local v = G_defaults and G_defaults:readSetting(key)
    if type(v) == "table" and v.w and v.h then
        return { ratio_x = v.x, ratio_y = v.y, ratio_w = v.w, ratio_h = v.h }
    end
    return fallback
end

function KindleUI:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindleui_control_centre", {
        category = "none",
        event = "ShowKindleControlCentre",
        title = _("Control centre"),
        general = true,
    })
    Dispatcher:registerAction("kindleui_page_list", {
        category = "none",
        event = "ShowKindlePageList",
        title = _("Go to (Kindle-style)"),
        reader = true,
    })
    Dispatcher:registerAction("kindleui_toolbar", {
        category = "none",
        event = "ShowKindleToolbar",
        title = _("Reading toolbar"),
        reader = true,
    })
    Dispatcher:registerAction("kindleui_aa_menu", {
        category = "none",
        event = "ShowKindleAaMenu",
        title = _("Reading settings (Aa)"),
        reader = true,
    })
    Dispatcher:registerAction("kindleui_settings", {
        category = "none",
        event = "ShowKindleSettings",
        title = _("Settings (Kindle-style)"),
        general = true,
    })
end

function KindleUI:init()
    -- Diagnostic, deliberately at INFO: PluginLoader logs nothing on a
    -- SUCCESSFUL load, so silence in crash.log is ambiguous between "loaded and
    -- did nothing" and "never loaded". This line makes those two distinguishable.
    logger.info("kindleui: init, ui =", self.ui and (self.ui.document and "reader" or "filemanager") or "nil")
    self:onDispatcherRegisterActions()
    self:installLockScreenHook()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- In the file manager there is no onReaderReady, so this is the only chance
    -- to claim the top band. In the reader it runs again from onReaderReady,
    -- and re-registering an id simply replaces it (inputcontainer.lua:140-142).
    self:setupTouchZones()

    -- Once, here, and never from onReaderReady or onSetDimensions: registerWidget
    -- wraps `self.onCloseWidget` to unregister itself (hook_container.lua:57-62),
    -- so calling it twice would stack two wrappers on one plugin instance.
    --
    -- Guarded rather than assumed: event_hook is a plain field on the UIManager
    -- singleton (uimanager.lua:47), and the whole home-screen path is optional --
    -- if it is not there, the reader keeps working and the home screen keeps the
    -- behaviour it has today.
    if not self._input_hook_registered
       and UIManager.event_hook and UIManager.event_hook.registerWidget then
        UIManager.event_hook:registerWidget("InputEvent", self)
        self._input_hook_registered = true
    end
end

function KindleUI:onReaderReady()
    self:setupTouchZones()
end

--- Re-derives the pixel rects after a rotation.
-- InputContainer stores zones as absolute Geoms, so the ratios have to be
-- reapplied against the new screen size or the bands land in the wrong place.
-- This covers the home screen's copy of the band too: setupTouchZones detaches
-- it and clears the cache, and the next input frame re-grafts the new rects.
function KindleUI:onSetDimensions()
    self:setupTouchZones()
end

function KindleUI:isEnabled(key, default)
    local v = G_reader_settings:readSetting("kindleui_" .. key)
    if v == nil then return default end
    return v == true
end

--- Builds the control centre's two top-band zone definitions.
--
-- Split out of setupTouchZones because the same band now has to be registered in
-- two places -- on `self.ui`, and on whatever fullscreen home screen has covered
-- it -- and a band that silently drifted between the two would be a bug with no
-- symptom other than "sometimes it does not open".
--
-- `prefix` keeps the two sets of ids distinct. They live in different DepGraphs
-- so they could not actually collide, but the diagnostic at the end of
-- setupTouchZones prints ids and would be unreadable if they were the same.
--
-- Returns the rects too, so the toolbar's tap zones stay congruent with the
-- swipe band instead of recomputing the ratios and eventually disagreeing.
function KindleUI:_controlCentreZones(prefix, overrides)
    local top = zoneRatio("DTAP_ZONE_MENU",
                          { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1/8 })
    local top_ext = zoneRatio("DTAP_ZONE_MENU_EXT",
                          { ratio_x = 1/4, ratio_y = 0, ratio_w = 2/4, ratio_h = 1/5 })
    local function southHandler(ges)
        -- A swipe's `pos` is where the finger went DOWN, not where it lifted
        -- (gesturedetector.lua:942-951), which is what makes "from the top
        -- edge" mean what it says.
        logger.dbg("kindleui: top-band swipe, direction =", tostring(ges.direction))
        if ges.direction ~= "south" then return false end
        -- A `swipe` is terminal: the finger has already lifted by the time it is
        -- reported. A `pan` is not -- the finger is still down and will keep
        -- producing events, which is why the panel has to be told which of the
        -- two opened it.
        return self:onShowKindleControlCentre(ges.ges == "pan")
    end
    local zones = {}
    for _, ges in ipairs({ "swipe", "pan" }) do
        zones[#zones + 1] = { id = prefix .. "cc_" .. ges, ges = ges,
                              screen_zone = top, overrides = overrides,
                              handler = southHandler }
        zones[#zones + 1] = { id = prefix .. "cc_ext_" .. ges, ges = ges,
                              screen_zone = top_ext, overrides = overrides,
                              handler = southHandler }
    end
    return zones, top, top_ext
end

--- Stop the file manager's own top-edge tap from opening KOReader's menu.
--
-- Registered on `ui.menu`, NOT on `ui`, and that is the whole trick. Replacing
-- a zone by id only works within the graph it was registered on
-- (inputcontainer.lua:139-141), and FileManagerMenu is its OWN InputContainer
-- with its own `_zones` (filemanagermenu.lua:24, :80). Registering these ids on
-- the FileManager put them in a different graph entirely, where they replaced
-- nothing and the stock menu kept opening -- which is exactly what happened.
--
-- `overrides` cannot do this job either: it changes the order zones are tried
-- in, and the overridden zone still runs when the one ahead of it declines
-- (inputcontainer.lua:onGesture).
--
-- The handler DECLINES rather than swallowing. The band is the top 1/8 across
-- the full width, which on the home screen covers the head of the hero card, so
-- consuming the tap would trade a menu nobody wanted for a dead strip over the
-- book they are reading. Returning false lets the gesture fall through to
-- bookshelf's own ges_events, where the hero listens.
function KindleUI:_suppressStockMenuTap()
    local ui = self.ui
    if ui and ui.document then return end          -- reader has its own handling
    local menu = ui and ui.menu
    if not (menu and type(menu.registerTouchZones) == "function") then return end
    if not self:isEnabled("suppress_stock_menu", true) then return end

    local function declineTap() return false end
    local ok, err = pcall(menu.registerTouchZones, menu, {
        { id = "filemanager_tap", ges = "tap",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1/8 },
          handler = declineTap },
        { id = "filemanager_ext_tap", ges = "tap",
          screen_zone = { ratio_x = 1/4, ratio_y = 0, ratio_w = 2/4, ratio_h = 1/5 },
          handler = declineTap },
    })
    if not ok then
        logger.warn("kindleui: could not take over the file manager menu tap:", tostring(err))
    end
end

--- Takes the band back off a home screen we had grafted it onto.
--
-- Needed because that widget is not ours to rebuild. Turning the control centre
-- off in the menu, or a rotation that moves the band, rebuilds OUR zones -- but
-- the copy sitting in the shelf's own DepGraph would keep firing at the old rect
-- until the shelf itself was destroyed, because registerTouchZones only replaces
-- ids within the graph it is called on (inputcontainer.lua:140-142).
function KindleUI:_detachFromHomeScreen()
    local host, zones = self._home_host, self._home_zones
    self._home_host, self._home_seen = nil, nil
    if not (host and zones) then return end
    if type(host.unRegisterTouchZones) ~= "function" then return end
    -- pcall because `host` belongs to another plugin: a shelf caught mid-teardown
    -- must cost us the band, not the reader.
    local ok, err = pcall(host.unRegisterTouchZones, host, zones)
    if not ok then
        logger.warn("kindleui: home screen refused to release touch zones:", tostring(err))
    end
end

function KindleUI:setupTouchZones()
    if not Device:isTouchDevice() then return end
    local ui = self.ui
    if not (ui and ui.registerTouchZones) then return end

    -- Before _home_zones is replaced, so the detach passes the ids it registered.
    self:_detachFromHomeScreen()
    self._home_zones = nil

    local zones = {}

    -- Unconditional. This band was behind a setting; it is not any more,
    -- because with it off the top edge of the screen does nothing at all.
    do
        local cc_zones, top, top_ext = self:_controlCentreZones("kindleui_", TOP_OVERRIDES)
        for _, zone in ipairs(cc_zones) do
            zones[#zones + 1] = zone
        end

        -- Built here rather than at attach time because registerTouchZones
        -- resolves the ratios against the screen size it is CALLED with
        -- (inputcontainer.lua:138, 147-152), and onSetDimensions -> setupTouchZones
        -- is what re-derives them after a rotation.
        --
        -- No `overrides`: bookshelf.koplugin's shelf carries no touch zones at
        -- all, only raw ges_events (bookshelf_widget.lua:349-469), so there is
        -- nothing on that widget for the DepGraph to order us against.
        self._home_zones = self:_controlCentreZones("kindleui_home_", nil)

        -- Reader only: the toolbar is about the open book, so in the file
        -- manager a top-edge tap keeps its stock meaning. Reader-or-not is the
        -- only condition left; the switch that also guarded this is gone.
        if ui.document then
            local function tapHandler()
                return self:onShowKindleToolbar()
            end
            zones[#zones + 1] = { id = "kindleui_toolbar_tap", ges = "tap",
                                  screen_zone = top, overrides = TOP_TAP_OVERRIDES,
                                  handler = tapHandler }
            zones[#zones + 1] = { id = "kindleui_toolbar_ext_tap", ges = "tap",
                                  screen_zone = top_ext, overrides = TOP_TAP_OVERRIDES,
                                  handler = tapHandler }
        end
    end

    -- Reader only: the page browser needs a document to page through. As with
    -- the toolbar, that is now the only thing gating it.
    if ui.document then
        local bot = zoneRatio("DTAP_ZONE_CONFIG",
                              { ratio_x = 0, ratio_y = 7/8, ratio_w = 1, ratio_h = 1/8 })
        local bot_ext = zoneRatio("DTAP_ZONE_CONFIG_EXT",
                              { ratio_x = 1/4, ratio_y = 4/5, ratio_w = 2/4, ratio_h = 1/5 })
        -- Swipe up shows the reading TOOLBAR, not the chapter list. Kindle
        -- reserves the contents behind the toolbar's own list icon, and pulling
        -- up from the bottom reveals the book chrome instead. An earlier build
        -- had this opening Go To directly, which put a screen two levels deep
        -- one gesture away and left the toolbar unreachable from the bottom.
        local function northHandler(ges)
            if ges.direction ~= "north" then return false end
            return self:onShowKindleToolbar()
        end
        for _, ges in ipairs({ "swipe", "pan" }) do
            zones[#zones + 1] = { id = "kindleui_pages_" .. ges, ges = ges,
                                  screen_zone = bot, overrides = BOTTOM_OVERRIDES,
                                  handler = northHandler }
            zones[#zones + 1] = { id = "kindleui_pages_ext_" .. ges, ges = ges,
                                  screen_zone = bot_ext, overrides = BOTTOM_OVERRIDES,
                                  handler = northHandler }
        end
    end

    if #zones > 0 then
        ui:registerTouchZones(zones)
    end
    -- Outside that guard on purpose: this registers on a DIFFERENT object
    -- (ui.menu) and has nothing to do with whether we ended up with zones of
    -- our own. Inside it, turning the control centre off would silently bring
    -- KOReader's menu back.
    self:_suppressStockMenuTap()
    logger.info("kindleui: registered", #zones, "touch zones on",
                ui.document and "ReaderUI" or "FileManager")

    -- The ordering is the whole mechanism, so print it rather than trust it.
    -- DepGraph:serialize emits a node's deps before the node itself
    -- (depgraph.lua:180-198), and `overrides` makes us a dep of the zone we are
    -- displacing, so our ids MUST appear ahead of readermenu_swipe here. If they
    -- do not, the override edge was lost and no amount of reasoning about the
    -- graph will help.
    if ui.touch_zone_dg then
        local order = ui.touch_zone_dg:serialize()
        local swipes = {}
        for _, id in ipairs(order) do
            if tostring(id):find("swipe", 1, true) then
                swipes[#swipes + 1] = id
            end
        end
        logger.dbg("kindleui: swipe zone order:", table.concat(swipes, " > "))
    end
end

--- Grafts the top band onto a fullscreen home screen that has covered our host.
--
-- WHY THE BAND GOES ON THAT WIDGET AND NOT SOMEWHERE ELSE
--
-- Two other routes exist and both are worse.
--
-- Adding this plugin to `self.ui.active_widgets` would get us the gesture only
-- once the top widget has DECLINED it (uimanager.lua:941-947). Nothing stops a
-- plugin being appended there -- it is a plain array read at exactly two places,
-- uimanager.lua:918 and :941 -- but it means every swipe any dialog happens to
-- ignore is offered to us, so the gate against erupting over a confirmation box
-- would have to be written by hand and would be the only thing standing between
-- a user and a control centre over their "delete this book?" prompt. It also
-- does not work at all while bookshelf.koplugin parks a reader under its shelf:
-- there its own handleEvent converts a top-strip gesture into the file manager
-- menu and returns true (bookshelf_widget.lua:578-581), so the event never
-- reaches the walk down the stack.
--
-- Renaming our zones with a `filemanager_` prefix would get them picked up by
-- that plugin's own zone-forwarding allowlist (bookshelf_gesture_zones.lua:56-62,
-- called from bookshelf_widget.lua:568). That is a real, deliberate compatibility
-- path -- but it is theirs, it is matched by a string pattern we do not control,
-- and it too is dead in the parked-reader case, where the allowlist is
-- `^readermenu_` and a match converts to the menu instead of firing our handler.
--
-- Registering on the widget itself has neither problem. It sits at
-- bookshelf_widget.lua:564, ahead of both of those branches, and
-- InputContainer:onGesture tries `_ordered_touch_zones` before `ges_events`
-- (inputcontainer.lua:260-265), so we outrank the shelf's own swipe handlers
-- without patching anything. Best of all, the gate against unrelated modals is
-- structural rather than written: a zone that lives on a widget can only fire
-- while that widget is the one being handed the gesture, and a dialog on top is
-- handed it instead (uimanager.lua:915).
--
-- WHY AN InputEvent HOOK IS THE TRIGGER
--
-- Nothing announces that a widget has appeared. UIManager:show sends `Show` to
-- the widget alone (uimanager.lua:186), never a broadcast, and bookshelf.koplugin
-- emits no open or close event of its own. The hook is the in-tree idiom for
-- "look at the world once per input frame" (autoturn.koplugin/main.lua:87,
-- autosuspend.koplugin/main.lua:198) and it runs BEFORE the batch is dispatched
-- (uimanager.lua:1539-1547) -- so the finger-down that begins the very first
-- swipe after the shelf appears is already enough, and the user never has to
-- throw one gesture away to arm the next.
--
-- The `_home_seen` cache is what keeps this cheap: on every input frame except
-- the one where the topmost widget actually changed, it is one table compare.
function KindleUI:onInputEvent()
    if not self._home_zones then return end
    local top = UIManager:getTopmostVisibleWidget()
    if top == self._home_seen then return end
    self._home_seen = top
    -- getTopmostVisibleWidget only skips widgets flagged `invisible`
    -- (uimanager.lua:785-793); it says nothing about what the widget IS, so the
    -- caller has to look. Core does the same (readerfooter.lua:831), as do
    -- plugins that need to know what they are sitting under
    -- (autoturn.koplugin/main.lua:34-35 tests `top_wg.name`).
    if type(top) ~= "table" or not HOME_SCREEN_WIDGETS[top.name] then return end
    -- Two shape checks, because `name` alone is a promise anyone can make.
    -- covers_fullscreen tells the shelf apart from that plugin's own dialogs, and
    -- registerTouchZones is what makes it an InputContainer at all
    -- (inputcontainer.lua:137). Either missing means it is not the thing we
    -- expected, and the correct response is to leave it exactly as it is.
    if not top.covers_fullscreen or type(top.registerTouchZones) ~= "function" then
        return
    end
    local ok, err = pcall(top.registerTouchZones, top, self._home_zones)
    if not ok then
        logger.warn("kindleui: home screen refused touch zones:", tostring(err))
        return
    end
    -- Only on a genuinely new host. Every dialog that opens and closes over the
    -- shelf costs one re-attach -- harmless, registerTouchZones replaces ids in
    -- place (inputcontainer.lua:140-142) -- but logging each one would bury the
    -- one line that says whether this ever worked at all.
    if self._home_host ~= top then
        logger.info("kindleui: top band attached to home screen", tostring(top.name))
    end
    self._home_host = top
end

--- Opens one of this plugin's screens, at most one instance of it at a time.
--
-- Every screen is loaded through pcall so a module that is missing or broken
-- degrades to "the gesture did nothing" rather than taking the reader down with
-- it. Returning false on failure matters as much as the pcall: it lets the
-- touch zone fall through to whatever KOReader would have done, so a broken
-- screen costs you the reskin, not the function.
--
-- The shown-instance check is not defensive padding. A pan fires an event per
-- movement sample (readermenu.lua:150 routes pan to the same handler as swipe),
-- so a single slow pull would otherwise stack a dozen identical panels.
function KindleUI:_showScreen(key, module_name)
    self._screens = self._screens or {}
    local live = self._screens[key]
    if live and UIManager:isWidgetShown(live) then
        return true
    end
    local ok, Screen_ = pcall(require, module_name)
    if not ok or type(Screen_) ~= "table" then
        logger.warn("kindleui:", module_name, "failed to load:", tostring(Screen_))
        return false
    end
    local built, widget = pcall(function() return Screen_:new({ ui = self.ui }) end)
    if not built or not widget then
        logger.warn("kindleui:", module_name, "failed to build:", tostring(widget))
        return false
    end
    self._screens[key] = widget
    -- Ask for the refresh explicitly instead of relying on UIManager's fallback.
    --
    -- `UIManager:show` marks the widget dirty with a nil refreshtype
    -- (uimanager.lua:184), which paints it into the framebuffer but queues no
    -- refresh of its own. `_repaint` has a safety net for that -- if it painted
    -- anything and the refresh queue is empty, it adds a full-screen partial
    -- (uimanager.lua:1296). The net only works when the queue IS empty.
    --
    -- Opening a screen from the toolbar breaks that assumption twice over: the
    -- toolbar closes itself first, and the tap flash queues its own "fast"
    -- refresh over the icon. So the queue is already non-empty, the net never
    -- fires, and the only regions refreshed are the toolbar's and the icon's --
    -- neither of which covers the panel that just appeared. The panel is drawn,
    -- present in the window stack, and answers taps, while the display never
    -- shows it.
    --
    -- Naming the region also stops a panel that occupies a third of the screen
    -- from provoking a full-screen refresh.
    -- A widget that has not computed its band yet gets the old behaviour rather
    -- than a nil region, which setDirty would read as "refresh nothing".
    if widget.dimen then
        UIManager:show(widget, "ui", widget.dimen)
    else
        logger.warn("kindleui:", module_name, "has no dimen at show time")
        UIManager:show(widget)
    end
    logger.dbg("kindleui: showing", key)
    return true
end

function KindleUI:onShowKindleControlCentre(finger_still_down)
    if not self:_showScreen("control_centre", "kindleui_controlcentre") then
        return false
    end
    -- Opened mid-stroke: hold the panel inert until the finger lifts. Without
    -- this, a drag long enough to reach the sliders keeps feeding them `pan`
    -- events from the same stroke that opened the panel, and the brightness
    -- moves because the user swiped a bit far.
    local panel = self._screens and self._screens.control_centre
    if finger_still_down and panel and panel.armAfterOpen then
        panel:armAfterOpen()
    end
    -- Upstream cancels any pan-scroll the swipe started; without this the page
    -- creeps under the panel (readermenu.lua:486 does the same).
    if self.ui and self.ui.handleEvent then
        self.ui:handleEvent(Event:new("HandledAsSwipe"))
    end
    return true
end

--- Kindle's page-flip grid, which KOReader already has.
-- PageBrowserWidget draws the thumbnail grid and the chapter-ticked scrubber
-- (readerthumbnail.lua:102-108), so this routes rather than reimplements.
--- Kindle's Go To: the chapter list, not KOReader's thumbnail grid.
--
-- An earlier build routed this straight to `ShowPageBrowser`, because
-- PageBrowserWidget already existed and needed no new rendering code. It worked,
-- but what appeared was KOReader's own screen rather than the design that was
-- agreed, so the shortcut bought nothing worth having. If our own panel cannot
-- load we fall back to the stock grid, which is at least the right *kind* of
-- thing, and only then to the config strip.
function KindleUI:onShowKindlePageList()
    if not (self.ui and self.ui.document) then return false end
    if self:_showScreen("page_list", "kindleui_pagelist") then
        self.ui:handleEvent(Event:new("HandledAsSwipe"))
        return true
    end
    if self.ui:handleEvent(Event:new("ShowPageBrowser")) then
        self.ui:handleEvent(Event:new("HandledAsSwipe"))
        return true
    end
    return false
end

--- Kindle's page-thumbnail grid.
--
-- Falls back to KOReader's PageBrowserWidget, which works but lays out badly on
-- a long book: its chapter-name boxes along the bottom overflow and overlap each
-- other. A cramped screen still beats no screen, so it stays as the fallback.
function KindleUI:onShowKindlePageBrowser()
    if not (self.ui and self.ui.document) then return false end
    if self:_showScreen("page_browser", "kindleui_pagebrowser") then
        return true
    end
    return self.ui:handleEvent(Event:new("ShowPageBrowser")) or false
end

function KindleUI:onShowKindleToolbar()
    if not (self.ui and self.ui.document) then return false end
    return self:_showScreen("toolbar", "kindleui_toolbar")
end

function KindleUI:onShowKindleAaMenu()
    if not (self.ui and self.ui.document) then return false end
    return self:_showScreen("aa_menu", "kindleui_aamenu")
end

function KindleUI:onShowKindleSettings()
    if self:_showScreen("settings", "kindleui_settings") then
        return true
    end
    -- The stock menu is the escape hatch for everything not yet reskinned, so
    -- it is also the right thing to fall back to: losing the new settings page
    -- must not leave the reader with no way into its own settings.
    UIManager:sendEvent(Event:new("ShowMenu"))
    return true
end

--------------------------------------------------------------------------------
-- Lock screen: clock / date / lunar date / quote over the screensaver wallpaper.
--------------------------------------------------------------------------------

--- Minutes between clock refreshes while asleep. 0 disables the wake entirely.
function KindleUI:lockInterval()
    return tonumber(G_reader_settings:readSetting("kindleui_lock_interval")) or 0
end

--- Wraps Screensaver so our overlay rides on top of whatever it drew.
--
-- Deliberately NOT a copy of Screensaver:show. That function picks a wallpaper,
-- builds a message widget, wraps the lot in a ScreenSaverWidget and shows it
-- (screensaver.lua:661-668); reimplementing any of that would mean owning every
-- screensaver mode -- image, cover, message -- forever.
--
-- Riding on top works because of two facts that happen to line up. Our widget is
-- modal, and UIManager places a modal above the current top widget
-- (uimanager.lua:169-182), so it lands over the ScreenSaverWidget. And because
-- we paint AFTER it, `Screen.bb` already holds the composited wallpaper by the
-- time our paintTo samples it -- which is how the text colour adapts to a cover
-- image or a message background, not just to files in one folder.
--
-- Screensaver is a singleton module, so the wrap is installed once per session.
function KindleUI:installLockScreenHook()
    local ok, Screensaver = pcall(require, "ui/screensaver")
    if not ok or type(Screensaver) ~= "table" then return end
    if Screensaver._kindleui_wrapped then return end

    local orig_show, orig_close = Screensaver.show, Screensaver.close
    if type(orig_show) ~= "function" or type(orig_close) ~= "function" then return end

    local plugin = self

    Screensaver.show = function(sself, ...)
        local r = { orig_show(sself, ...) }
        -- Everything past this point is decoration. A failure here must cost the
        -- clock, never the screensaver -- a device that cannot show a lock screen
        -- is a device that looks broken.
        pcall(function() plugin:showLockOverlay() end)
        return unpack(r)
    end

    Screensaver.close = function(sself, ...)
        pcall(function() plugin:hideLockOverlay() end)
        return orig_close(sself, ...)
    end

    Screensaver._kindleui_wrapped = true
end

function KindleUI:showLockOverlay()
    local ok, LockScreen = pcall(require, "kindleui_lockscreen")
    if not ok or type(LockScreen) ~= "table" then
        logger.warn("kindleui: lock screen overlay failed to load:", tostring(LockScreen))
        return
    end
    -- Report the failure. Swallowing it silently -- which this did -- meant a
    -- lock screen that had stopped drawing entirely left NOTHING in the log to
    -- say why, and the fault took a round trip through the device to find.
    local built, widget = pcall(function() return LockScreen:new({}) end)
    if not built then
        logger.warn("kindleui: lock screen overlay failed to build:", tostring(widget))
        return
    end
    if not widget or not widget.dimen then
        logger.warn("kindleui: lock screen overlay built with no dimen")
        return
    end
    self._lock_widget = widget
    UIManager:show(widget, "ui", widget.dimen)
    self:armLockWake()
end

function KindleUI:hideLockOverlay()
    self:disarmLockWake()
    local w = self._lock_widget
    self._lock_widget = nil
    if w and UIManager:isWidgetShown(w) then
        UIManager:close(w)
    end
end

--- Books an RTC wake so the clock can tick while the device sleeps.
--
-- On Kindle this does NOT touch the RTC directly. WakeupMgr is created with a
-- mock rtc (kindle/powerd.lua:309) and the real alarm is a property set on
-- Amazon's own powerd -- `rtcWakeup`, seconds from now (kindle/powerd.lua:253),
-- which KOReader writes during readyToSuspend (:295-307) because that is the
-- only state in which Kindle accepts it. On resume, checkUnexpectedWakeup runs
-- our task if the alarm fired within 90 seconds (:271).
--
-- Two consequences worth knowing rather than discovering:
--   * the alarm can fire up to 10 seconds EARLY, because the device sits in
--     "Ready to suspend" for that long (:290-291). A 5 minute interval is really
--     4m50 or so. Nothing here depends on the precision.
--   * a wake costs a CPU spin-up plus a refresh, so the refresh is scoped to the
--     clock's own rect and never the whole screen.
function KindleUI:armLockWake()
    local minutes = self:lockInterval()
    if minutes <= 0 then return end
    local mgr = Device.wakeup_mgr
    if not (mgr and mgr.addTask) then
        -- No lipc handle means initWakeupMgr bailed early (kindle/powerd.lua:285)
        -- and there is nothing to schedule against. The clock still shows the
        -- time it was drawn at, which is what a Kindle screensaver does anyway.
        logger.dbg("kindleui: no wakeup_mgr, lock clock will not tick")
        return
    end
    -- One callback object, created once and reused, because removeTasks matches
    -- on `callback == v.callback` (wakeupmgr.lua:134). A fresh closure per arm
    -- would be a different value every time and could never be matched, leaving
    -- orphaned tasks to wake the device after the screensaver had gone.
    if not self._lock_wake_cb then
        self._lock_wake_cb = function() self:onLockWake() end
    end
    local ok = pcall(function()
        mgr:addTask(minutes * 60, self._lock_wake_cb)
    end)
    if not ok then logger.warn("kindleui: could not schedule lock wake") end
end

function KindleUI:disarmLockWake()
    local mgr = Device.wakeup_mgr
    if not (mgr and mgr.removeTasks) then return end
    -- Both arguments nil matches nothing at all -- the test is
    -- `epoch == v.epoch or callback == v.callback` (wakeupmgr.lua:134), and nil
    -- equals neither a number nor a function. So there is no point calling this
    -- before the callback exists.
    if not self._lock_wake_cb then return end
    pcall(function() mgr:removeTasks(nil, self._lock_wake_cb) end)
end

function KindleUI:onLockWake()
    local w = self._lock_widget
    -- Woken for a clock that is no longer on screen: stop, and do not re-arm.
    -- Otherwise a stale chain would keep waking the device for nothing.
    if not (w and UIManager:isWidgetShown(w)) then
        self._lock_widget = nil
        return
    end
    pcall(function() w:updateClock() end)
    self:armLockWake()
end

--- Menu for the screensaver overlay.
-- Every element is separately switchable because each one costs something
-- different: the clock costs a wake, the quote costs a sidecar-free table
-- lookup, the lunar date costs a page of arithmetic once a day.
function KindleUI:lockScreenMenu()
    local function toggle(key, label, help)
        return {
            text = label,
            help_text = help,
            checked_func = function() return self:isEnabled(key, true) end,
            callback = function()
                G_reader_settings:saveSetting("kindleui_" .. key,
                    not self:isEnabled(key, true))
            end,
        }
    end
    local function colour(value, label)
        return {
            text = label,
            checked_func = function()
                return (G_reader_settings:readSetting("kindleui_lock_colour") or "auto") == value
            end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("kindleui_lock_colour", value)
            end,
        }
    end
    -- The nine cells, named the way the settings list reads them rather than as
    -- a grid: nobody scanning a menu thinks in row-major order.
    local function place(value, label)
        return {
            text = label,
            checked_func = function()
                return (G_reader_settings:readSetting("kindleui_lock_pos") or "bottom-left") == value
            end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("kindleui_lock_pos", value)
            end,
        }
    end
    local function every(minutes, label)
        return {
            text = label,
            checked_func = function() return self:lockInterval() == minutes end,
            radio = true,
            callback = function()
                G_reader_settings:saveSetting("kindleui_lock_interval", minutes)
                -- Re-arm now rather than at the next sleep, so the choice is
                -- testable without putting the device down first.
                if self._lock_widget then
                    self:disarmLockWake()
                    self:armLockWake()
                end
            end,
        }
    end
    return {
        toggle("lock_clock", _("Clock")),
        toggle("lock_date", _("Date")),
        toggle("lock_lunar", _("Lunar date"),
               _("Vietnamese lunar calendar, computed against UTC+7. It differs from the Chinese one by a day several times a year.")),
        toggle("lock_quote", _("Quote of the day")),
        {
            text = _("Position"),
            help_text = _("Which ninth of the screen the clock, date and quote sit in. Bottom-left is what Kindle does."),
            sub_item_table = {
                place("top-left",      _("Top left")),
                place("top-center",    _("Top centre")),
                place("top-right",     _("Top right")),
                place("middle-left",   _("Middle left")),
                place("middle-center", _("Middle centre")),
                place("middle-right",  _("Middle right")),
                place("bottom-left",   _("Bottom left")),
                place("bottom-center", _("Bottom centre")),
                place("bottom-right",  _("Bottom right")),
            },
        },
        {
            text = _("Text colour"),
            separator = true,
            sub_item_table = {
                colour("auto", _("Automatic")),
                colour("black", _("Always black")),
                colour("white", _("Always white")),
            },
            help_text = _("Automatic reads the wallpaper's brightness under the text and picks the colour that will be legible. A fixed colour is fine until a wallpaper arrives from the other end of the range: black text vanishes on a dark image, white text vanishes on a light one."),
        },
        {
            text_func = function()
                local m = self:lockInterval()
                if m <= 0 then return _("Clock updates: never") end
                return T(_("Clock updates: every %1 min"), m)
            end,
            help_text = _("Waking the device to redraw the clock costs battery, so this is off by default. Only the clock's own strip is refreshed, never the whole screen. The alarm can fire up to 10 seconds early because the device sits in a ready-to-suspend state for that long."),
            sub_item_table = {
                every(0, _("Never")),
                every(5, _("Every 5 minutes")),
                every(10, _("Every 10 minutes")),
                every(15, _("Every 15 minutes")),
                every(30, _("Every 30 minutes")),
                every(60, _("Every hour")),
            },
        },
    }
end

function KindleUI:addToMainMenu(menu_items)
    menu_items.kindleui = {
        text = _("Kindle-style UI"),
        -- `id` so the settings page can name this group directly rather than
        -- hunting for it by title. Without one it is reachable only by
        -- whatever tab MenuSorter files it under.
        id = "kindleui",
        -- Still taps_and_gestures for KOReader's OWN menu, which has nowhere
        -- better to put a plugin. The settings page no longer inherits that
        -- placement: it names this id under "Appearance", where a lock screen
        -- belongs. Under the stock menu it was four levels down inside a group
        -- described as "Font, layout, page turns", which cost the owner ten
        -- minutes and left him unable to repeat the route.
        sorting_hint = "taps_and_gestures",
        sub_item_table = {
            -- The three gestures this fork is built on -- swipe down for the
            -- control centre, swipe up for Go to, tap the top for the reading
            -- toolbar -- used to be three switches here. They are not switches
            -- any more.
            --
            -- Turning one off did not return the reader to stock KOReader; it
            -- returned them to a Kindle with a third of its surface dead,
            -- because everything those gestures reach is only reachable that
            -- way. A setting whose off state is a broken device is not a
            -- choice, it is a trap, so the gestures are now simply part of
            -- what installing this fork means.
            {
                text = _("Top edge does not open KOReader's menu"),
                id = "kindleui_suppress_menu",
                help_text = _("On the home screen, a tap near the top edge opens KOReader's own menu. This turns that off, so the top of the screen belongs to the shelf and everything is reached from Settings instead.\n\nThe tap is declined rather than swallowed, so whatever is underneath -- the book on the hero card -- still answers it."),
                checked_func = function() return self:isEnabled("suppress_stock_menu", true) end,
                callback = function()
                    G_reader_settings:saveSetting("kindleui_suppress_stock_menu",
                        not self:isEnabled("suppress_stock_menu", true))
                    -- The zones live on the FileManager, which a settings
                    -- change does not rebuild, so they are re-registered here
                    -- or the toggle would mean nothing until the next launch.
                    self:setupTouchZones()
                end,
                separator = true,
            },
            {
                text = _("Lock screen"),
                -- `id` so the settings page can give this row an icon; it
                -- keys on ids, never on titles.
                id = "kindleui_lock_screen",
                separator = true,
                sub_item_table_func = function() return self:lockScreenMenu() end,
            },
            {
                text = _("Restart KOReader"),
                -- `id` so the settings page can give this row an icon; it
                -- keys on ids, never on titles.
                id = "kindleui_restart",
                separator = true,
                keep_menu_open = false,
                -- Asked for, because plugin work means restarting often and the
                -- alternative is exiting to the Kindle home screen and back.
                --
                -- Restart, not exit: KOReader's own `restart` event brings it
                -- back up, where `exit` leaves the reader on the firmware's
                -- home screen wondering what happened.
                callback = function()
                    local UIManager = require("ui/uimanager")
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Restart KOReader?\n\nThe book you are reading is closed properly first, so your place is kept."),
                        ok_text = _("Restart"),
                        ok_callback = function()
                            -- restartKOReader, not a signal and not an exit.
                            --
                            -- It quits with status 85, which the launcher
                            -- treats as "start me again" -- verified on this
                            -- device at koreader.sh:329, `while
                            -- [ "${RETURN_VALUE}" -eq 85 ]`. Quitting through
                            -- UIManager is also what closes the document and
                            -- flushes settings; killing the process does
                            -- neither, and loses the reading position.
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },
        },
    }
end

return KindleUI
