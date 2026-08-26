# Third-party notices

This plugin is licensed under the GNU Affero General Public License v3.0 (see
[LICENSE](./LICENSE)). It contains material from the projects below, under their
own licences, reproduced here in full as those licences require.

---

## simpleui.koplugin

**What is used:** the quote database in
[`kindleui.koplugin/kindleui_quotes.lua`](./kindleui.koplugin/kindleui_quotes.lua).
The entries are copied verbatim and kept in their original `{ q, a, b }` shape so
that a future update upstream can be diffed against this file rather than
re-transcribed by hand. The selection logic around them is not upstream's.

**Source:** <https://github.com/doctorhetfield-cmd/simpleui.koplugin>

**Licence:** MIT

```
MIT License

Copyright (c) 2026 doctorhetfield-cmd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

MIT is compatible with the AGPL: MIT-licensed material may be combined into an
AGPL-licensed work, and the notice above travels with it. The reverse is not
true, which is why the quote table is the only thing taken this way.

---

## KOReader

**What is used:** nothing is copied. This is a plugin, loaded by KOReader at
runtime, and it calls KOReader's own widgets, events and drawing primitives. It
also reuses shipped assets rather than redrawing them — `IconWidget` resolves the
control centre's rotation glyph from `resources/icons/mdlight/rotation.90CW.svg`,
and the page browser drives KOReader's own thumbnail pipeline.

Because the plugin is a derivative work in the licensing sense — it is useless
without KOReader and combines with it at runtime — it carries KOReader's licence
rather than a more permissive one.

**Source:** <https://github.com/koreader/koreader>

**Licence:** AGPL-3.0. See [LICENSE](./LICENSE), which is the same text.

---

## Not used, only referenced

These are named in comments and in the README as *interoperability targets*. No
code from them is present in this repository; the file and line references exist
so a reader can check the claims about how the two plugins interact.

- **[bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin)**, AGPL-3.0.
  Optional home screen. `main.lua` cites `bookshelf_widget.lua` line numbers to
  explain where this plugin's touch zones attach and why they conflict with
  nothing.
- **[xtreader.koplugin](https://github.com/hhoangg/xtreader.koplugin)**, AGPL-3.0. Optional
  book and progress sync. `kindleui_settings.lua` reads its public `statusText`
  when it happens to be loaded, and cites its line numbers to say why that
  string is safe to render as two lines.
- **[readinginsights.koplugin](https://github.com/peterboda236/readinginsights.koplugin)**, GPL-3.0.
  Optional reading dashboard. Cited by line number in `kindleui_settings.lua`
  to explain why its menu id needs re-sorting.
- **KOSync** ([`kosync.koplugin`](https://github.com/koreader/koreader/tree/master/plugins/kosync.koplugin), in-tree in KOReader), AGPL-3.0. The quiet-sync
  userpatch wraps two of its functions at runtime; it copies none of them, which
  is the whole point of the patch's shape.

---

## Lunar calendar algorithm

The Vietnamese lunar date is computed with Hồ Ngọc Đức's algorithm, itself
derived from the astronomical formulae in Jean Meeus's *Astronomical Algorithms*.
The algorithm was published for free use at
`informatik.uni-leipzig.de/~duc/amlich/`. That site is now gone; the rules
page survives in the Internet Archive:
<https://web.archive.org/web/20250123093939/http://www.informatik.uni-leipzig.de/~duc/amlich/calrules.html>.

The implementation in
[`kindleui.koplugin/kindleui_lunar.lua`](./kindleui.koplugin/kindleui_lunar.lua)
is written for this project; only the method is Đức's.
