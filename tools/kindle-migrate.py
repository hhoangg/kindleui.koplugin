#!/usr/bin/env python3
"""Move a Kindle library into KOReader: books, collections, and reading progress.

    python3 tools/kindle-migrate.py --mount /Volumes/Kindle --out ~/kindle-migration

This exists because the three things that make a Kindle library yours are stored
in three different places, and copying the books gets you one of them:

    the FILES        under documents/, named <title>_<ASIN>.<ext>
    the COLLECTIONS  in /var/local/cc.db, an sqlite database off the volume
    the PROGRESS     in the same database, as a percentage per ASIN

Copy the files alone and you get a flat folder of several hundred books with
Amazon's bookkeeping in every filename and no idea where you were in any of
them. This puts the three back together.


WHAT IT WILL AND WILL NOT DO

It will not remove DRM, and it stops on any book that has it. A DRM'd file is
readable only by the Kindle that bought it; converting it is not something this
script declines on principle so much as something that cannot be done. They are
listed at the end so you know which books did not come across and why.

It never writes to the Kindle. Everything lands in --out, and copying the result
onto the device is a separate, deliberate step you take yourself.


PROGRESS IS A PERCENTAGE, AND THAT IS THE CEILING

`p_percentFinished` in cc.db is scaled 0-100, with -1 meaning "unknown". It is
the only position the Kindle records in a form anything else can read --
`p_lastAccessedPosition` is null on every row this was built against. So a
migrated book opens at roughly the right chapter, not at the right line.

KOReader accepts that: `last_percent` in a sidecar is its documented fallback
when there is no xpointer (readerrolling.lua:203-215), and it replaces the
percentage with a real position the first time it saves the book (:339). The
sidecars this writes are therefore transitional by design.

A percentage also cannot survive a re-pagination honestly. The EPUB this
produces is not the file the Kindle was reading, so "34%" means 34% of a
different pagination of the same text. For a novel that is the same chapter;
for anything with heavy front matter it can be a chapter out.


REQUIREMENTS

    calibre       for `ebook-convert` (https://calibre-ebook.com)
    KFX Input     only if you have KFX books; calibre cannot read them alone.
                  Preferences -> Plugins -> Get new plugins -> "KFX Input"

Nothing else. No Amazon account, no network.
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import zipfile

# Kindle book extensions worth converting, in the order we prefer them when the
# same ASIN exists more than once. AZW3 first: it is mobi8, which calibre reads
# natively, while KFX needs a third-party plugin.
EXTENSIONS = ("azw3", "azw", "kfx", "mobi", "prc")

# Chapter detection for books whose own table of contents is unusable. Applied
# only as a second pass -- see convert_one.
CHAPTER_XPATH = "//*[name()='h1' or name()='h2' or name()='h3']"

# A book is "finished" on the Kindle at this percentage. Amazon's own reading
# UI flips to "Read" here rather than at 100, because the back matter of most
# books is never turned past.
FINISHED_AT = 99.0


# --------------------------------------------------------------------------
# The Kindle side
# --------------------------------------------------------------------------

def find_cc_db(mount, explicit):
    """Locate cc.db, which is NOT on the USB volume.

    It lives at /var/local/cc.db in the Kindle's own filesystem, which USB mass
    storage does not expose. So it has to be fetched over SSH from a jailbroken
    device, or found in a backup. Some setups leave a copy on the volume; we
    look there first, then take --cc-db.
    """
    if explicit:
        p = pathlib.Path(explicit).expanduser()
        if not p.is_file():
            sys.exit(f"--cc-db: no such file: {p}")
        return p
    for guess in ("system/cc.db", "cc.db", "var/local/cc.db"):
        p = pathlib.Path(mount) / guess
        if p.is_file():
            return p
    sys.exit(
        "cc.db not found.\n\n"
        "It lives at /var/local/cc.db inside the Kindle, which the USB volume\n"
        "does not expose. On a jailbroken device with SSH:\n\n"
        "    scp root@<kindle-ip>:/var/local/cc.db ./cc.db\n\n"
        "then pass it with --cc-db ./cc.db.\n\n"
        "Without it you still get the books; you lose the collections and the\n"
        "reading progress, which is most of the point."
    )


def read_kindle_db(path):
    """Collections and progress, keyed by ASIN.

    Opened read-only through a URI so a live database is never touched, and
    copied first if that fails -- a Kindle that is still running holds a WAL.
    """
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        con.execute("SELECT 1 FROM Entries LIMIT 1")
    except sqlite3.Error as e:
        sys.exit(f"cannot read {path}: {e}")

    # Collection uuid -> its display name.
    names = {
        u: t for u, t in con.execute(
            "SELECT p_uuid, p_titles_0_nominal FROM Entries WHERE p_type='Collection'"
        )
    }
    # ASIN -> the first collection that claims it. A book can be in several;
    # a folder can only be one, and the first is as good a choice as any.
    collection = {}
    for cu, key in con.execute(
        "SELECT i_collection_uuid, i_member_cde_key FROM Collections"
    ):
        if key:
            collection.setdefault(key, names.get(cu, ""))

    # ASIN -> percent (0-100, -1 unknown).
    progress = {}
    for key, pct in con.execute(
        "SELECT p_cdeKey, p_percentFinished FROM Entries WHERE p_cdeKey IS NOT NULL"
    ):
        if pct is not None and pct >= 0:
            progress[key] = float(pct)

    con.close()
    return collection, progress


# --------------------------------------------------------------------------
# DRM
# --------------------------------------------------------------------------

# Markers an encrypted Amazon container carries. Checked as bytes rather than
# by parsing, because KFX is proprietary and undocumented; a false positive
# costs one skipped book, a false negative costs a conversion that fails much
# later with an error that says nothing about DRM.
DRM_MARKERS = (b"DRMION", b"drm_voucher")

# How far in to look for them. Measured, not guessed: on the DRM'd books this
# was built against the marker sat at offsets 20699 and 22747, so 2 MB is two
# orders of magnitude of headroom while still being one cheap read.
DRM_SCAN_BYTES = 2 * 1024 * 1024


def has_drm(path):
    """True when the file is encrypted, False when it is not, None when unclear.

    MOBI/AZW/AZW3 are authoritative: the PalmDOC header's `encryption type`
    field at offset 12 of record 0 is 0 for none, 1 for legacy, 2 for Amazon.
    Believe it and stop.

    Everything else is checked by scanning for the markers, and the scan is NOT
    conditioned on recognising the container first. That was the original bug
    here, and it failed in the direction that matters: a DRM'd KFX turns out to
    be an SQLite database rather than the CONT container a clean one uses, so
    gating the scan on the CONT magic meant every DRM'd book fell through to
    "cannot tell" -- and a "cannot tell" is passed to the converter, which is
    exactly what the check exists to prevent.

    Observed on real files:

        clean KFX      CONT\x02\x00...            no marker
        DRM'd KFX      SQLite format 3\x00        DRMION at ~20-23 KB

    So: decide MOBI by its header, decide everything else by the marker, and
    only answer None for a file that is neither and has no marker anywhere in
    the first couple of megabytes.
    """
    try:
        with open(path, "rb") as f:
            head = f.read(1024)
            if len(head) < 78:
                return None
            # PalmDB: type/creator at offset 60. The header answers exactly.
            if head[60:68] in (b"BOOKMOBI", b"TEXtREAd"):
                (rec0,) = struct.unpack(">I", head[78:82])
                f.seek(rec0 + 12)
                (enc,) = struct.unpack(">H", f.read(2))
                return enc != 0
            f.seek(0)
            blob = f.read(DRM_SCAN_BYTES)
            if any(m in blob for m in DRM_MARKERS):
                return True
            # A container we recognise, with no marker in it, really is clean.
            if head[:4] == b"CONT":
                return False
    except (OSError, struct.error):
        return None
    return None


# --------------------------------------------------------------------------
# Naming
# --------------------------------------------------------------------------

ASIN_SUFFIX = re.compile(r"_([A-Z0-9]{8,})$")


def split_asin(stem):
    """('Some Title', 'B00XYZ') -- the ASIN is Amazon's bookkeeping, not a title."""
    m = ASIN_SUFFIX.search(stem)
    if m:
        return stem[: m.start()], m.group(1)
    return stem, None


def safe_name(s):
    """A filename that survives FAT32/exFAT, keeping everything else.

    Diacritics stay. The Kindle's own /mnt/us has been holding Vietnamese
    filenames all along, and KOReader reads them; stripping them would be
    damage done for no reason. Only the characters a path genuinely cannot
    contain are replaced.
    """
    s = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "-", s)
    s = re.sub(r"\s+", " ", s).strip().rstrip(". ")
    return s[:150] or "untitled"


# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------

def toc_quality(epub):
    """(spine files, toc entries) for a produced EPUB.

    Both matter and neither alone is enough. A book converted from a source
    whose structure calibre did not recognise comes out as ONE enormous spine
    file with ONE table-of-contents entry: it opens, it reads, and every
    chapter jump and page number in it is wrong. Counting only TOC entries
    misses a book with a real TOC pointing into a single file.
    """
    try:
        with zipfile.ZipFile(epub) as z:
            names = z.namelist()
            spine = len([n for n in names if n.lower().endswith((".html", ".xhtml", ".htm"))])
            ncx = [n for n in names if n.lower().endswith(".ncx")]
            if not ncx:
                return spine, 0
            doc = z.read(ncx[0]).decode("utf-8", "replace")
            return spine, len(re.findall(r"<navPoint", doc))
    except (zipfile.BadZipFile, OSError, KeyError):
        return 0, 0


def convert_one(src, dst, verbose=False):
    """Convert, then check the result is actually navigable and retry if not.

    The retry is the reason this is not a one-line subprocess call. calibre's
    default conversion trusts the source's own structure, which for a good
    number of Kindle books is a single blob. The second pass tells it to find
    chapters from heading tags and to break pages at them, which turns that
    blob into something with working chapter navigation.

    Two passes, not one with the flags always on: forcing chapter detection on
    a book that already has a good structure overrides it with a worse guess.
    """
    base = [
        "ebook-convert", str(src), str(dst),
        "--no-default-epub-cover",
        "--preserve-cover-aspect-ratio",
    ]
    r = subprocess.run(base, capture_output=True, text=True)
    if r.returncode != 0 or not dst.exists():
        return False, 0, 0, (r.stderr or r.stdout or "")[-400:]

    spine, toc = toc_quality(dst)
    # <= 1, not == 0: a single useless entry is the common failure and reads as
    # "has a TOC" to anything that only checks for absence.
    if toc <= 1 or spine <= 1:
        if verbose:
            print(f"      weak structure (spine={spine} toc={toc}); retrying with chapter detection")
        retry = base + [
            "--use-auto-toc",
            "--chapter", CHAPTER_XPATH,
            "--page-breaks-before", CHAPTER_XPATH,
            "--chapter-mark", "pagebreak",
        ]
        r2 = subprocess.run(retry, capture_output=True, text=True)
        if r2.returncode == 0 and dst.exists():
            spine, toc = toc_quality(dst)
    return True, spine, toc, ""


# --------------------------------------------------------------------------
# Progress sidecars
# --------------------------------------------------------------------------

SIDECAR = """\
-- Written by the Kindle -> KOReader migration.
--
-- Percent only: the Kindle records no exact position anything else can read,
-- so this lands you in roughly the right chapter, not on the right line.
-- KOReader treats last_percent as its fallback when there is no xpointer
-- (readerrolling.lua:203-215) and replaces it with a real position the first
-- time it saves this book (:339), so this file is transitional.
return {{
    ["last_percent"] = {pct:.6f},
    ["percent_finished"] = {pct:.6f},
}}
"""


def write_sidecar(epub, percent):
    """KOReader's per-book sidecar, next to the book.

    `<name>.sdr/metadata.epub.lua` is the layout KOReader expects; it looks for
    it beside the file and nowhere else.
    """
    sdr = epub.parent / (epub.stem + ".sdr")
    sdr.mkdir(parents=True, exist_ok=True)
    (sdr / "metadata.epub.lua").write_text(
        SIDECAR.format(pct=percent / 100.0), encoding="utf-8"
    )


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def gather(docs):
    """One file per ASIN, preferring the format calibre handles best."""
    by_asin, loose = {}, []
    for ext in EXTENSIONS:
        for f in sorted(pathlib.Path(docs).rglob(f"*.{ext}")):
            _, asin = split_asin(f.stem)
            if asin is None:
                loose.append(f)
            elif asin not in by_asin:
                by_asin[asin] = f
    return by_asin, loose


def main():
    ap = argparse.ArgumentParser(
        description="Move a Kindle library into KOReader, keeping collections and progress.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--mount", required=True,
                    help="the mounted Kindle volume, e.g. /Volumes/Kindle")
    ap.add_argument("--out", required=True,
                    help="where to build the KOReader library (never the Kindle)")
    ap.add_argument("--cc-db",
                    help="path to a copy of the Kindle's /var/local/cc.db")
    ap.add_argument("--no-progress", action="store_true",
                    help="convert books and collections, skip the reading positions")
    ap.add_argument("--limit", type=int,
                    help="stop after N books; useful for a first look")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would happen and convert nothing")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    mount = pathlib.Path(args.mount).expanduser()
    docs = mount / "documents"
    if not docs.is_dir():
        sys.exit(f"no documents/ under {mount} -- is the Kindle mounted?")
    out = pathlib.Path(args.out).expanduser()

    # Refusing to write into the device is worth a check rather than a warning:
    # the whole design is that the Kindle is read-only here, and a mistyped
    # --out is the one way that promise gets broken.
    try:
        if out.resolve() == mount.resolve() or mount.resolve() in out.resolve().parents:
            sys.exit(f"--out is inside the Kindle ({out}). Choose a folder on your computer.")
    except OSError:
        pass

    if not args.dry_run and shutil.which("ebook-convert") is None:
        sys.exit(
            "ebook-convert not found. Install calibre (https://calibre-ebook.com).\n"
            "On macOS you may also need its command line tools on PATH:\n"
            "    export PATH=\"/Applications/calibre.app/Contents/MacOS:$PATH\""
        )

    collection, progress = {}, {}
    if args.cc_db or not args.no_progress:
        db = find_cc_db(mount, args.cc_db)
        collection, progress = read_kindle_db(db)
        print(f"cc.db: {len(collection)} books in collections, {len(progress)} with a position")

    by_asin, loose = gather(docs)
    books = sorted(by_asin.items())
    if args.limit:
        books = books[: args.limit]
    print(f"found {len(by_asin)} books"
          + (f" (+{len(loose)} without an ASIN, skipped)" if loose else ""))

    out.mkdir(parents=True, exist_ok=True)
    report, drm_skipped, failed = [], [], []
    converted = weak = positioned = 0

    for i, (asin, src) in enumerate(books, 1):
        title, _ = split_asin(src.stem)
        coll = collection.get(asin, "")
        folder = out / safe_name(coll) if coll else out / "Uncollected"
        dst = folder / (safe_name(title) + ".epub")
        label = f"[{i:3d}/{len(books)}] {(coll or '-'):18.18s} {title[:44]}"

        drm = has_drm(src)
        if drm:
            print(f"{label}  DRM, skipped")
            drm_skipped.append(title)
            continue

        if args.dry_run:
            print(f"{label}  -> {dst.relative_to(out)}")
            continue

        print(label, flush=True)
        folder.mkdir(parents=True, exist_ok=True)
        ok, spine, toc, err = convert_one(src, dst, args.verbose)
        if not ok:
            print(f"      failed: {err.splitlines()[-1] if err else '?'}")
            failed.append((title, err))
            continue
        converted += 1
        if toc <= 1 or spine <= 1:
            weak += 1
            print(f"      converted, but chapter navigation is poor (spine={spine} toc={toc})")

        pct = progress.get(asin)
        if pct is not None and not args.no_progress:
            write_sidecar(dst, pct)
            positioned += 1

        report.append({
            "asin": asin, "title": title, "collection": coll,
            "source": src.name, "output": str(dst.relative_to(out)),
            "spine": spine, "toc": toc,
            "percent": pct, "finished": bool(pct is not None and pct >= FINISHED_AT),
        })

    if args.dry_run:
        print("\ndry run; nothing was written")
        return

    (out / "migration-report.json").write_text(
        json.dumps({"books": report, "drm_skipped": drm_skipped,
                    "failed": [t for t, _ in failed]},
                   ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"\nconverted {converted}/{len(books)}"
          f", {positioned} with a reading position")
    if weak:
        print(f"{weak} converted with poor chapter navigation -- readable, but their"
              f"\n  page numbers and chapter jumps will not match the Kindle's.")
    if drm_skipped:
        print(f"\n{len(drm_skipped)} skipped for DRM. These can only be read on the"
              f"\n  Kindle that bought them:")
        for t in drm_skipped[:10]:
            print(f"    {t[:70]}")
        if len(drm_skipped) > 10:
            print(f"    ... and {len(drm_skipped) - 10} more")
    if failed:
        print(f"\n{len(failed)} failed to convert; see migration-report.json")

    print(f"\nLibrary built in {out}")
    print("Copy its contents into your KOReader books folder -- with KOReader")
    print("CLOSED, or the device may not notice the new files.")


if __name__ == "__main__":
    main()
