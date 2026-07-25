# Recovery Power Tools Project Context

## Project Scope (Phase 1, restated 2026-07-13)

1. Recover deleted media files (photos, RAW, video) plus ZIP.
2. Only list files that are deleted.
3. Select some or all found files to recover.

All three are met. Phases 2-5 built on top of them.

## Current Repository State

- GitHub repo: `powellmichael/recovery-power-tools`
- Default branch: `main`
- Current working branch: `phase-6-enhancements` (no commits yet)
- Phase history: `ac8650a` phase 1 MVP → `75db2e0` phase 2 (external drives)
  → `6ee5e26` phase 3 (filter/sort/pause) → `4d197dc` phase 4 (NTFS)
  → `4e03218` phase 5 (PR #4, merged)

Phase 5 contents:

- `8b4843d` video preview and gallery thumbnails
- `f64395d` EXIF thumbnail JPEG truncation fix
- `6491097` recovery-history protection, EXIF display, duplicate flagging,
  NSTableView reentrancy fix
- `b76ae2d` file list export/import with drive verification
- `dbf152a` percent complete while scanning
- `e656892` multi-selection in list and gallery
- `11efa46` media category row alignment

**Nothing in phase 5 has been field-tested on a real drive.** It builds and
41 tests pass, but video playback, gallery video thumbnails, EXIF/GPS on real
photos, and the manifest round-trip have only been exercised synthetically.

## Architecture

SwiftUI macOS app (SwiftPM, macOS 14+, Swift 6 strict concurrency). Key pieces:

- `ScanSource` — read-only byte source over a regular file or a raw device.
  Raw devices are opened via `/usr/libexec/authopen` (standard macOS password
  prompt, fd passed back over a socket). All reads are `pread`-based and
  block-aligned for devices.
- `DeviceDiscovery` — lists external physical disks/partitions via `diskutil`,
  plus a guard that refuses to recover onto the disk being scanned.
- `FreeSpaceMap` — parses FAT32 (FAT table), exFAT (allocation bitmap +
  deleted directory entry sets) and dispatches to `NTFS`. Carving only free
  space is what makes "only deleted files" true. Unrecognized filesystems fall
  back to whole-device carving with a "may include live files" note.
- `NTFS` — boot sector, MFT records with update-sequence fixups, `$FILE_NAME`
  and `$DATA` attributes, data-run decoding, `$Bitmap` free space. Supplies
  original filenames, exact sizes, and fragmentation segments.
- `RecoveryScanner` — signature carver over `ScanSource` regions with chunked
  streaming, overlap carry, and per-format length parsers. Deleted directory
  entries are processed **first** as first-class results (name + exact size);
  carving then only adds anonymous extras it hasn't already claimed.
- `RecoveryManifest` — JSON export/import of scan results with per-entry
  fingerprint verification against the live drive.
- `RecoveryViewModel` / `ContentView` — drive picker, media filter, results
  list and gallery, preview pane, recovery, manifests.

## Supported Formats

Determinable-length signatures only (formats without reliable signatures are
deliberately excluded — they'd produce garbage hits):

- Images: JPEG, PNG, HEIC/HEIF, BMP, RAW (TIFF family: NEF/CR2/ARW/DNG/3FR via
  IFD walking; Fuji RAF via header offsets)
- Video: MP4/MOV/M4V/3GP/3G2 (ISO boxes), AVI (RIFF + AVIX), WMV/ASF (File
  Properties object), FLV (tag walking), WebM/MKV (EBML), MPEG-PS (pack walking)
- Containers: ZIP (local header → end-of-central-directory + comment)

JPEG length comes from walking the segment structure rather than scanning for
the first `FFD9`: an EXIF thumbnail is a whole JPEG nested in APP1, and a byte
scan stops at the thumbnail's end marker. Walking is preferred but not
required — a failed walk falls back to the old scan, because free space is full
of JPEGs with damaged headers and a strict parser would recover fewer files.

## Scan Modes

- **External drive (the real recovery path)**: pick a partition from the drive
  menu → authopen password prompt → FAT32/exFAT/NTFS free-space map → carve
  only unallocated space. Results are deleted data by definition.
- **File/folder**: carves through readable file bytes; used for disk images,
  test blobs. Folder scans skip live media/container files by extension. An
  orange warning appears when the chosen folder lives on an external drive,
  since folder scans can't see deleted data.

## Features

**Results and selection**

- List view and gallery view (4-column thumbnail grid), switchable.
- Filename filter, sortable Filename and Size columns, arrow-key navigation.
- Nothing is selected for recovery by default (bulk-export accidents).
- Three-way visibility: All / New / Recovered.
- Media types grouped into collapsible Images / Video / Archives categories;
  JPEG only by default. The sidebar controls scroll, so expanding a category
  grows downward instead of pushing the top of the sidebar out of view; the
  status block stays pinned to the bottom so scan progress is visible while
  scrolled.
- Multi-selection in both views: shift-click for a range, command-click for
  discontiguous picks. Ticking one checkbox inside a multi-row selection
  applies to the whole selection; a checkbox outside it affects only its own
  row. Right-click offers the same, with a mark count that excludes stale
  manifest entries. Shift ranges follow visible order, so a range under an
  active filter never sweeps in rows that aren't on screen. Selection is
  shared, so it survives switching between list and gallery.

**Preview**

- Image preview with click-to-open at full natural size.
- Video preview via `AVPlayerView` hosted in `NSViewRepresentable`. SwiftUI's
  `VideoPlayer` crashes in a bare SwiftPM executable — its Swift metadata
  can't resolve `AVPlayerView`'s ObjC superclass at runtime.
- Gallery thumbnails for video come from `AVAssetImageGenerator`'s first
  decodable frame, with a play badge. Capped at 256 MB per file.
- EXIF display from carved bytes before recovery: dimensions, capture date,
  camera, lens, exposure, and GPS coordinates linking to Apple Maps. Rows
  appear only when the file carries the field.

**Recovery**

- Recover selected files to a chosen folder, optionally as a named ZIP
  (`ditto -c -k --norsrc`).
- Pause/resume mid-scan; cancel.
- Recovery history persists across scans (volume serial + offset + length),
  so repeat scans show what was already recovered.
- Duplicate flagging: results are fingerprinted by SHA256 of their first 4 KB
  plus exact length. Repeats are badged and excluded from Select All, never
  hidden or dropped — a prefix hash is a heuristic, so it marks and does not
  decide.
- Percent complete and bytes scanned during a scan.

**File lists (manifests)**

- Export scan results to JSON so they can be recovered later without
  re-scanning. Exporting mid-scan records the list as partial.
- Import re-reads the drive and verifies each entry's fingerprint. Stale
  entries are shown with a reason (different volume, past end of device, data
  changed, unreadable) and can't be selected — recovering one would write
  whatever now occupies that offset.
- Recovery status travels with the list but stays labelled as the exporting
  machine's claim; nothing is merged into the local log on import.

## Data Safety

`recovered.json` (Application Support) is the only record that a deleted file
was already pulled off a drive, and it is irreplaceable. `RecoveryLog`
therefore distinguishes "no file yet" from "file I couldn't parse": a parse
failure marks the log unreadable, **blocks saving**, and surfaces the path and
reason in the sidebar, rather than resetting to empty and letting the next save
overwrite thousands of records. Writes are atomic. The log path is injectable
so tests never touch the real file.

## Tests

`swift test` — 41 tests across six files:

- `ScannerTests` — synthetic blob carving (JPEG, PNG, BMP, ZIP, MP4
  offsets/lengths), recovery byte fidelity, EXIF-thumbnail truncation,
  FAT32 free clusters, exFAT deleted entries, duplicate fingerprinting.
- `NTFSTests` — data-run decoding, synthetic volume end-to-end including
  fragmented recovery.
- `ExfatIntegrationTests` — builds a real exFAT image with `hdiutil`, writes a
  JPEG, deletes it, scans, expects the filename back.
- `ManifestTests` — JSON round-trip, verification of unchanged data, detection
  of overwritten data / volume mismatch / offsets past end of device, version
  rejection.
- `RecoveryLogTests` — round-trip, corrupt file blocks save and preserves
  bytes, existing array format still reads. Also holds `MultiSelectionTests`:
  checkbox-applies-to-selection, shift ranges in both directions, ranges
  respecting an active filter, command-click toggling.
- `MetadataTests` — EXIF GPS hemisphere signs, camera make/model dedup,
  absent-field handling, progress labels.

## Open UI Issues

None currently open.

Recently closed: media category rows rendered as a staircase because
`DisclosureGroup` children had no explicit leading alignment, so each row
centred itself and labels of different widths ("MP4 / MOV" vs "AVI") started
at different x positions.

## Known Limitations / Deliberate Deferrals

- **FAT32 filenames unavailable.** exFAT and NTFS both supply original names
  from deleted directory entries; FAT32 doesn't yet. It needs its own parser
  for the 8.3 + LFN `0xE5` format (~150 lines). Note that some FAT32
  implementations zero the high cluster word on delete, so files above 4 GB or
  fragmented ones may resolve poorly even with the name recovered.
- **Fragmented files recover only on NTFS** (via data runs). FAT32/exFAT
  carving assumes contiguous data.
- **No scan resume.** Importing a partial manifest gives results, not scan
  position. Resuming needs region index + offset, same-volume and
  same-free-map checks, matching selected kinds, and a 128 KB backup for the
  overlap window.
- **Recovery history has no timestamps for older entries.** The log stores
  bare keys, so only files recovered in the exporting session carry a date and
  destination in a manifest. Changing that is a log format migration.
- APFS free-space parsing not implemented — internal Mac SSDs fall back to
  whole-device carve, and TRIM makes recovery there unlikely anyway.
- exFAT: reads only the first root-directory cluster for the bitmap entry and
  assumes the bitmap file is contiguous (`ponytail:` comments mark both).
- Duplicate detection is a 4 KB prefix heuristic, not proof. It marks; it never
  hides or deletes.
- Manifests are a fast path, not a guarantee: mounting a drive writes to it,
  and TRIM lets an SSD zero deleted blocks with no filesystem activity at all.
- PSD, CRW, GIF, and obscure formats (3DM, ANI, ART…) skipped — no reliable
  length/signature.
- No ZIP preview.
- Length-finders re-read from the source per candidate (O(n²) worst case on
  signature-dense sources).
- Thumbnail cache is unbounded (no LRU eviction).
- Not sandboxed/signed; SwiftPM executable, not an Xcode project yet.

## Future Enhancements

### Split jpegSearchCap into a walk budget and a fallback budget (not started)

`jpegSearchCap` (RecoveryScanner.swift:29) is used for two unrelated jobs, and
one value has to serve both:

- **RecoveryScanner.swift:391** — how far the brute-force `FFD9` search scans.
  It reads every byte, so this is the expensive one: a false `FFD8FF` with no
  `FFD9` ahead of it burns the full 256 MB.
- **RecoveryScanner.swift:635** — the limit for `jpegLength`'s segment walk.
  Cheap, because it hops by each segment's declared length instead of reading
  every byte.

Because both paths `return nil` past `limit`, the cap is also **the largest
JPEG the app can recover** — an oversized file is dropped entirely, not
truncated. That is why the 16 MB fast-scan cap costs real recoveries: it sits
below DSLR JPEGs and panoramas.

Proposal: keep the walk generous (256 MB or `maxCarveSize`) and give the
fallback its own budget of 8-16 MB. The fallback only runs when a file is
damaged enough that its segment structure won't parse, and a damaged JPEG's
recoverable content is near the front anyway. Expected 16-32x bound on the
worst case with no change to the size ceiling for intact files.

Unmeasured — reasoned from the code only. Needs its own benchmark before
landing, unlike the marker gate, whose 5.6x was measured. Note also that the
pathological case may be rarer on real drives than a synthetic benchmark
suggests: long zero runs contain no `FF` bytes and so generate no false
headers at all. The bad combination is a false `FFD8FF` in random-looking
data followed by a long stretch with no `FFD9` — a used/blank boundary.

### Review state — marking files not to recover (design in progress)

Goal: mark files you don't want, so the working set shows only real
candidates. The driving case is files **already recovered by other means** —
something this app can't detect on its own.

Two separable pieces:

- **"Marked" visibility filter** (~10 lines): a fourth option in the All / New
  / Recovered picker showing only checkbox-selected items. Not a new screen —
  the same table and gallery, filtered. Satisfies "see only what I want to
  recover" with no new state. Worth doing first; it may be enough.
- **Durable review state**: "already recovered elsewhere" is a fact about a
  file, not a per-session preference. It should survive a rescan the way
  app-recovered files already do. The recovery checkbox can't carry it — it
  clears on rescan, and an unchecked box is ambiguous between "no" and
  "haven't looked yet".

Design calls to settle:

- Prefer **one mutually exclusive review state** (unreviewed / keep / skip)
  over a separate rejected flag beside the existing checkbox. Two independent
  booleans give four combinations, one of which ("marked for recovery *and*
  rejected") is nonsense the UI would have to keep explaining away.
- Persist per drive, keyed like the recovery log (volume serial + offset +
  length), but in a **separate file** — `recovered.json` is irreplaceable and
  was only just hardened; it shouldn't take on a second concern.
- Probably fold "recovered elsewhere" into the existing Recovered view with a
  different badge, rather than inventing a fourth filter, since from the user's
  point of view those files *are* recovered — just not by this tool.
- Select All should skip skipped items, as it already skips duplicates.

### Landing page (design in progress)

A launch screen replacing the current straight-to-scan layout: a category
sidebar (Hard Drives and Locations, SD Card Recovery, plus utility entries)
next to a grid of drive cards showing name, capacity bar and used/total size.
Design still being worked out; estimate below assumes the drive grid plus the
two recovery categories, not the utility tools.

Effort: roughly 1.5 days for the drive grid, sidebar shell, and routing into
the existing scan flow. `DeviceDiscovery.externalDevices()` already supplies
everything the cards need except capacity. The restructure is the real work —
`ContentView` has no landing route today, so it becomes a `NavigationSplitView`
where the scan controls stay reachable after a drive is chosen.

Two things to settle before building:

- **Capacity is only readable for mounted volumes** (`volumeAvailableCapacityKey`
  via `URL.resourceValues`, no prompt, needs a mount point added to
  `ExternalDevice`). An unmounted volume's used space can only come from
  parsing its filesystem off the raw device, which means one `authopen`
  password prompt per drive — a non-starter for a launch screen. Unmounted
  drives should read "Not mounted", never "0 bytes": a recovery tool claiming a
  drive is empty when it can't see inside is the wrong kind of wrong.
- **File Repair, iCloud and Other Tools are products, not screens.** Nothing
  behind them exists. Leave them out of the first pass rather than shipping
  dead entries — in a tool people reach for after losing data, a dead-end
  button is worse than an absent one.

SD Card Recovery is thin by comparison (~2 hours): the same scan flow filtered
to SD/removable devices, which `diskutil` reports via `BusProtocol`.

## Recommended Next Steps

1. **Field-test phase 5** — nothing in it has touched real hardware yet. On the
   NTFS drive: video playback, gallery video thumbnails, EXIF/GPS on real
   photos, and manifest export → replug → import to see how many entries
   survive a mount. That last number decides whether scan resume is worth
   building at all.
2. **Review state** — start with the "Marked" filter, then decide on durable
   skip marking after using it against a real scan (see Future Enhancements).
3. **Landing page** once the design settles (see Future Enhancements).
4. **FAT32 deleted directory entries** for original filenames — the last
   filesystem still showing "Not Available". Worth it only if FAT32 volumes
   (SD cards, older USB sticks) are actually in scope. Note this pairs with the
   landing page's SD Card Recovery category: SD cards are typically FAT32, so
   that category is thin without this parser.
5. **Scan resume** via a cursor in the manifest, if field testing shows
   manifests survive real-world use.
6. App icon, signing, Xcode project — only when distribution matters.

## Environment Notes

- **Always run a release build: `make run` (or `swift run -c release`).**
  `swift run` and `swift build` default to debug, and the carver is a tight
  per-byte loop — exactly the shape Swift's `-Onone` leaves unoptimized.
  Measured on 256 MB of high-entropy data: **31 MB/s debug vs 667 MB/s
  release, a ~21x difference.** An 18-hour scan that stalled at 69% was a
  debug build, not a slow algorithm. A `Makefile` wraps this so the fast path
  is the default one; `make test` stays in debug on purpose, to keep
  assertions and overflow checks on.
- Run with `make run`. `FileRecoveryApp.init()` calls
  `setActivationPolicy(.regular)` and `activate(ignoringOtherApps:)` because a
  bare SwiftPM executable launches as a background process that never
  activates — without it the window shows but receives no key events.
- Field-verified hardware: exFAT 1 TB Crucial NVMe (~991 GB free, 12,438
  deleted directory entries) and an NTFS drive with working filenames.
