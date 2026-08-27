# kindleui.koplugin

[![Licence: AGPL-3.0](https://img.shields.io/badge/licence-AGPL--3.0-blue)](./LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2026.07.1-6b7280)](https://github.com/koreader/koreader)
[![Tested on](https://img.shields.io/badge/tested%20on-Paperwhite%205-6b7280)](#known-limits)
[![Ko-fi](https://img.shields.io/badge/ko--fi-support-f97316)](https://ko-fi.com/hhoangg)

A Kindle-shaped reading UI for KOReader, built for a jailbroken Paperwhite 5.

KOReader's own chrome is capable but undivided: swiping down from the top of a
document opens *two* panels at once — `ReaderMenu:onSwipeShowMenu` fires
`ShowConfigMenu` for the bottom style strip and then `onShowMenu` for the top
menu bar (`readermenu.lua:481-490`) — so one gesture puts every setting the
reader has in front of you, split across opposite edges of the screen.

Kindle's firmware splits the same surface three ways, by where the gesture
starts and what it is *for*:

| Gesture | Panel | Concern |
|---|---|---|
| swipe down from the top edge | Control centre | the **device**: light, warmth, radio |
| tap the top edge | Reading toolbar | the **book**: font, contents, search |
| swipe up from the bottom edge | Reading toolbar + footer | **where you are** in it |

This plugin implements that split, plus a lock screen that draws the time, the
date, the Vietnamese lunar date and a quote over the screensaver wallpaper.

Proportions are not invented. Every screenshot the Kindle firmware writes is
paired with an `xwininfo` dump naming each window and giving its exact rect, so
the layout below is the firmware's own geometry, expressed as ratios of a
1236×1648 reference panel in `kindleui_geom.lua`:

```
QuickSettingsWindow  1236x1331 @ y=0      control centre
titleBar             1236x101  @ y=0      clock / battery strip
searchBar            1236x115  @ y=101    despite the name, the icon toolbar
appToolBar           1236x126  @ y=216    despite the name, the book title
footerBar            1236x311  @ y=1337   chapter + scrubber
```

## Install

Two directories, nothing to build:

```
kindleui.koplugin/                 ->  /mnt/us/koreader/plugins/
patches/2-kindleui-quiet-sync.lua  ->  /mnt/us/koreader/patches/
```

Restart KOReader — plugins load only at startup. Settings live under
**Menu → Taps and gestures → Kindle-style UI**.

## Screens

**Control centre** (`kindleui_controlcentre.lua`) — battery, clock,
four circular toggles in one row, brightness and warmth sliders. Labels read
the *state* for toggles (`On`/`Off`) and the *name* for actions.

**Wi-Fi, Dark Mode, Sync, All Settings** — and the list is short on purpose.
Kindle's own panel carries Airplane and Bluetooth as well, and neither survives
contact with KOReader. There is no Bluetooth API at all: not one reference in
`frontend/` or `plugins/`, on any platform, so the disc could only ever have
been decorative. Airplane mode is worse in a subtler way — KOReader has exactly
one radio and no notion of airplane mode, so the disc was really the Wi-Fi
toggle wearing an inverted caption, where *On* meant the radio was *off*. Two
names for one switch, pointing opposite ways. The row now holds only controls
that do what they say.

**Reading toolbar** (`kindleui_toolbar.lua`) — back/Home, `Aa`, contents,
notebook, search, overflow across the top; chapter title, position, time left
and a chapter-ticked scrubber across the bottom.

**Go To** (`kindleui_pagelist.lua`) — the chapter list, with the current chapter
in bold and a bar in the left margin. Swipe or pan inside the list to scroll.

**Page browser** (`kindleui_pagebrowser.lua`) — a 3×3 thumbnail grid with the
page number in a black badge over each card's top-left corner. Reuses
KOReader's own thumbnail pipeline (`readerthumbnail.lua:257`) rather than
re-rendering anything.

**Aa menu** (`kindleui_aamenu.lua`) — four tabs (Themes, Font, Layout, More),
one visible at a time, replacing `ConfigDialog`'s everything-at-once strip.
Font rows render in the font they name.

**Settings** (`kindleui_settings.lua`) — a flat list of eight, no section
headers, matching the firmware. Regroups KOReader's existing `menu_items`; no
item definition is touched.

**Lock screen** (`kindleui_lockscreen.lua`) — clock, date, lunar date, quote,
over the wallpaper. See below.

## The lock screen

**Text colour adapts to the wallpaper.** The widget samples `Screen.bb` under
its own rect — the framebuffer, not the image file, so it is right for cover
images and message backgrounds too — and picks black text with a white outline
on a light background, white text with a black outline on a dark one.

This is not decoration. A real wallpaper set spans mean luminance **2 to 251**;
a fixed colour provably fails at one end. Black text vanishes on a dark image,
white text vanishes on a light one, and the two failures are exact mirrors.
Override with `kindleui_lock_colour` = `auto` | `black` | `white`.

The outline is drawn as **8 offset passes plus the text**, because blitbuffer
has no blur primitive. Nothing paints a rectangle behind the text: the wallpaper
is never covered.

**Two refresh regions, deliberately.** The clock ticks; the date, lunar date and
quote change once a day. `clock_dimen` and `rest_dimen` are separate, so a
periodic wake refreshes only the clock's strip. `updateClock()` restores the
wallpaper pixels it saved before drawing, because what is underneath belongs to
the screensaver.

**Waking to tick the clock is off by default.** When enabled, the alarm goes
through `Device.wakeup_mgr:addTask`, which on Kindle does not touch the RTC
directly: `WakeupMgr` is built with a mock rtc (`kindle/powerd.lua:309`) and the
real alarm is a property set on Amazon's own powerd (`:253`) during
`readyToSuspend`, the only state in which Kindle accepts it. It can fire up to
**10 seconds early** because the device sits in a ready-to-suspend state for
that long (`:290-291`). Requires `liblipclua` from the Kindle firmware; without
it the clock simply shows the time it was drawn at, like any Kindle screensaver.

## The quiet-sync patch

`KOSync:onReaderReady` pulls progress on the next tick when auto-sync is on
([`kosync.koplugin/main.lua:190-194`](https://github.com/koreader/koreader/blob/master/plugins/kosync.koplugin/main.lua#L190-L194)):

```lua
self:getProgress(true, false)
```

The arguments are `ensure_networking` and `interactive`. The call says, in the
same breath, *the user did not ask for this* and *turn the radio on for it* — so
opening a book raises "Connecting to Wi-Fi…" and "Scanning for networks…" over
the page. Upstream gates its **own** messages on `interactive`; NetworkMgr never
receives the flag, so it speaks up regardless.

The patch cuts where the two arguments disagree: a call that is not interactive
does not get to force the radio on. If the radio is already up nothing changes.
Manual sync stays `interactive = true` and keeps its dialogs.

Cost: opening a book with Wi-Fi off pulls nothing at that moment. It arrives
when the network next comes up — `_onNetworkConnected` drains the queue. Pairs
well with **Network → Restore Wi-Fi connection on resume**, which brings the
radio back silently so you are usually online by the time you open a book.

## Optional companions

None of these are required; each degrades to "that feature is absent".

- **[bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin)** —
  the home screen. Without it, swipe-down works in the reader but not on the
  home screen: `BookshelfWidget` is `covers_fullscreen` and sits above the
  FileManager, so the plugin registers its touch zones directly on that widget
  when it appears. Bookshelf leaves the top 1/8 band free on purpose, so
  nothing is fought over.
- **[xtreader.koplugin](https://github.com/hhoangg/xtreader.koplugin)** —
  the Sync disc and the account row in Settings.
- **[readinginsights.koplugin](https://github.com/peterboda236/readinginsights.koplugin)** —
  the Reading Insights row in Settings.

## Known limits

- **Verified against KOReader v2026.07.1 only.** The plugin leans on internals —
  `readermenu.lua`, `uimanager.lua`, `wakeupmgr.lua`, `blitbuffer.lua`,
  `configdialog.lua`. Another release may move behaviour, not just line numbers.
- **Tested on a Paperwhite 5 only.** Measurements are ratios of the reference
  panel, so they should scale, but nothing else has run it. On a screen too
  short for a panel the code logs a warning and lets content define the height
  rather than clipping controls away.
- **Glyphs were verified against one font file.** All 35 codepoints in
  `kindleui_theme.lua` were checked by parsing the cmap of the `symbols.ttf` on
  the target device, which predates Nerd Fonts v3. A newer KOReader may ship a
  different file, and icons would fall back to tofu. Two codepoints from a first
  draft were already wrong this way.
- **KOReader has no theming layer.** Colour is hardcoded as `Blitbuffer.COLOR_*`
  across 61 widget files, so this plugin restyles the screens it owns and
  nothing else. Screens it does not own still look like KOReader.
- **No colour, no shadows, no animation.** Every boundary on e-ink has to be a
  real line, and selection is never a filled background — a fill repaints, and a
  repaint flashes.

## Credits

Full licence texts for everything below are in
[THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md).

- **Quote database** — copied verbatim from
  [simpleui.koplugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin)
  by doctorhetfield-cmd, MIT. Kept in its original `{ q, a, b }` shape so
  upstream changes can be diffed rather than re-transcribed. It is the only
  third-party code in this repository.
- **KOReader** — [koreader/koreader](https://github.com/koreader/koreader),
  AGPL-3.0. Nothing is copied; this is a plugin that calls its widgets, events
  and drawing primitives, and reuses its shipped icons and thumbnail pipeline
  rather than redrawing them.
- **bookshelf.koplugin** — [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin),
  AGPL-3.0. The optional home screen. No code from it is present; `main.lua`
  cites its line numbers to explain where this plugin's touch zones attach and
  why the two do not fight over the same gestures.
- **Lunar calendar** — Hồ Ngọc Đức's algorithm. His site at
  `informatik.uni-leipzig.de/~duc/amlich/` is gone, so the reference is the
  [archived rules page](https://web.archive.org/web/20250123093939/http://www.informatik.uni-leipzig.de/~duc/amlich/calrules.html).
  Computed
  against **UTC+7**. The implementation is this project's; only the method is
  Đức's. The Vietnamese calendar is not the Chinese one — it resolves new moons
  and solar terms against a different timezone, and the two differ by a day
  several times a year, occasionally including Tết itself. Validated against Tết
  Nguyên Đán 2026 (17 February 2026 = 1/1, năm Bính Ngọ) and a leap month
  (25 July 2025 = 1/6 nhuận, năm Ất Tỵ).
- **Layout proportions** — measured from the Kindle firmware's own `xwininfo`
  dumps, as described at the top of this file. Numbers observed from a device
  you own, not assets taken from it: no Amazon code, font, icon or image is
  redistributed here.

## Support

If this saved you some work, [ko-fi.com/hhoangg](https://ko-fi.com/hhoangg).
It is a side project run by one person, and it will stay free either way.

## Licence

**AGPL-3.0** — see [LICENSE](./LICENSE).

KOReader is AGPL-3.0 and a plugin is useless without it, so this carries the
same licence rather than a more permissive one. The MIT-licensed quote table
combines into that cleanly and keeps its own notice; the reverse would not work,
which is why it is the only thing taken that way.
