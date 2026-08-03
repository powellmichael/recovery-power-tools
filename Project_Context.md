# Recovery Power Tools Project Context

## Project Scope (Phase 1, restated 2026-07-13)

1. Recover deleted media files (photos, RAW, video) plus ZIP.
2. Only list files that are deleted.
3. Select some or all found files to recover.

All three are met. Phases 2-7 built on top of them.

## Current Repository State

- GitHub repo: `powellmichael/recovery-power-tools`
- Default branch: `main`
- Current working branch: `phase-7-improvements`
- Phase history: `ac8650a` phase 1 MVP → `75db2e0` phase 2 (external drives)
  → `6ee5e26` phase 3 (filter/sort/pause) → `4d197dc` phase 4 (NTFS)
  → `4e03218` phase 5 (PR #4) → `e0ebfb5` phase 6 (PR #5)

Phase 7 (performance and completion feedback), unmerged:

- `7c8a11e` remove the quadratic scan and selection paths, stop leaking
  full-size previews, add the release-build Makefile
- `4b38a3d` cache the filtered list; drop two copies from the read path
- `30e9ae1` require a real JPEG marker after SOI before carving
- `4824b3c` elapsed scan time next to the status label
- `82711b6` dock bounce and scan-summary bar on completion
- `a684b95` / `ef8e7c7` power assertions so App Nap can't throttle a scan
  or a recovery

**Field-tested on real hardware.** Two complete 842 GB scans of an exFAT
1 TB PNY NVMe, plus the phase 5/6 features exercised against real photos and
video. 89 tests pass and the release build is clean. See "Measured
Performance" for what those scans showed.

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

Before any of that, the byte after `FFD8FF` must be a legal post-SOI marker
(`C0`-`CF`, `DA`-`DD`, `E0`-`EF`, `FE` — 37 of 256 values). This is a cost
filter, not a correctness one: a false `FFD8FF` otherwise sends the carver into
the fallback, which scans forward up to `jpegSearchCap` before giving up. The
table is deliberately generous — the whole SOF and APP range rather than just
the common APP0/APP1 — so an unusual first segment still carves. `sniffKind`
stays permissive by contrast: it runs once per deleted directory entry rather
than per byte, and there the filesystem has already said a file started there.

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
- Four-way visibility: All / New / Marked / Recovered. "Marked" shows only
  checkbox-selected rows; "Recovered" includes recovered-elsewhere, because
  from the user's point of view those files are recovered too.
- Media types grouped into collapsible Images / Video / Archives categories.
  **Nothing is checked by default, and an empty selection means every type**
  (`effectiveKinds`) — but see "Measured Performance": empty is also the
  slowest possible setting, because it enables MPEG. The sidebar controls
  scroll, so expanding a category
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
  so repeat scans show what was already recovered. The Recovered chip also
  shows the all-time count for the volume, so an off-type scan reads as
  "0 of 2,248 ever on this drive" rather than looking like lost history.
- Durable review marks (skipped / recovered-elsewhere) in a separate
  `review.json`, keyed like the recovery log so a judgement survives a rescan.
  Select All skips them, as it already skips duplicates.
- Duplicate flagging: results are fingerprinted by SHA256 of their first 4 KB
  plus exact length. Repeats are badged and excluded from Select All, never
  hidden or dropped — a prefix hash is a heuristic, so it marks and does not
  decide.
- After a recovery finishes, a prompt offers to uncheck just the files that
  run wrote, leaving any other checked files queued.
- **Fast scan** drops the brute-force end-marker fallback and caps the forward
  search hard. Structurally intact files are unaffected; badly damaged ones may
  be missed or truncated.

**Scan progress and completion**

- Percent complete, bytes scanned, and elapsed time during a scan. Paused time
  is excluded from the timer, and the total survives completion so a finished
  scan still reports how long it took.
- On completion the dock icon bounces (`requestUserAttention`, skipped when the
  app is already frontmost) and a summary bar appears above the results with
  duration and counts. The counts are buttons that jump to the matching view —
  the reason this is an inline bar and not a modal. A scan runs for over an
  hour, so the user is usually away when it ends; a dialog would sit unread and
  then block the results underneath. Counts are a frozen snapshot of that scan,
  not live totals.
- A power assertion (`beginActivity(.userInitiated)`) is held for the duration
  of a scan and, separately, of a recovery. Without it macOS App Nap throttles
  the process once the app stops being frontmost — locking the screen during an
  842 GB scan measurably cost throughput. The scan's assertion is tied to the
  scan clock so the two cannot drift apart.

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

`review.json` holds durable review marks under the same rules and the same
guard. It is deliberately a separate file: `recovered.json` is irreplaceable
and shouldn't take on a second concern.

Full-size preview carves are written to a temp directory and cleared when the
next preview starts and at launch. Thumbnails use their own directory so the
purge can't race their detached writes.

## Tests

`swift test` — 89 tests across six files (debug on purpose; see Environment
Notes):

- `ScannerTests` (18) — synthetic blob carving (JPEG, PNG, BMP, ZIP, MP4
  offsets/lengths), recovery byte fidelity, EXIF-thumbnail truncation, FAT32
  free clusters, exFAT deleted entries, duplicate fingerprinting, fast-scan
  behaviour, the signature-starter table, the overlap invariant across a chunk
  boundary, and the JPEG post-SOI marker gate.
- `NTFSTests` (2) — data-run decoding, synthetic volume end-to-end including
  fragmented recovery.
- `ExfatIntegrationTests` (1) — builds a real exFAT image with `hdiutil`,
  writes a JPEG, deletes it, scans, expects the filename back.
- `ManifestTests` (8) — JSON round-trip, verification of unchanged data,
  detection of overwritten data / volume mismatch / offsets past end of device,
  version rejection.
- `MetadataTests` (9) — EXIF GPS hemisphere signs, camera make/model dedup,
  absent-field handling, progress labels.
- `RecoveryLogTests` (51) — the log guards, plus most view-model behaviour:
  `ReviewLogTests`, `MultiSelectionTests`, `ReviewMarkFilteringTests`,
  `RecoveredAcrossSessionsTests`, `EffectiveKindsTests`,
  `RecoveryCompletePromptTests`, `FilteredCacheTests`, `ScanTimerTests`,
  `ScanSummaryTests`, `ScanActivityTests`, `RecoveryActivityTests`.

Two of these were verified by deliberately breaking the code they cover and
confirming the right tests failed: the filtered-cache invalidations and the
recovery power-assertion release. A cache or an assertion that silently stops
working is exactly the kind of thing a passing test can hide.

## Open UI Issues

None currently open.

Confirmed rendering correctly on real runs: the elapsed-time label beside the
status label, the dock bounce, and the scan-summary bar with its filter
buttons.

Earlier fix, kept for context: media category rows rendered as a staircase
because `DisclosureGroup` children had no explicit leading alignment, so each
row centred itself and labels of different widths ("MP4 / MOV" vs "AVI")
started at different x positions.

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
- Length-finders re-read from the source per candidate. The O(n²) *overlap*
  check is gone (one comparison against the furthest end so far), but the
  re-reads remain.
- Thumbnail cache is unbounded (no LRU eviction).
- The scan hands each found item to the main actor individually. Whether that
  throttles a large scan is untested — see Future Enhancements.
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

### Per-item main-actor hop during a scan (unmeasured)

`itemFound` does `await MainActor.run { ... }` once per file found — 150,149
crossings on a real scan. Each waits for the main actor, which is re-rendering
a table whose backing array keeps growing, so the cost per crossing may rise
with the result count. That would make the scan's throughput a function of how
much it has already found.

Suspected after a scan whose second half ran 2.6x slower than its first, but
**that scan also had the machine locked for an hour**, and App Nap alone
plausibly explains it. The power assertion has since removed that variable. Do
not act on this without measuring first: time a scan with the callback stubbed
out, or note the percentage at lock and unlock to see whether rate still decays.

If real, the fix is to batch across the boundary — accumulate in the scan task
and hand over a few times a second rather than per item.

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

1. **Decide the default media selection.** Empty-means-all is currently the
   slowest possible setting because it enables MPEG (see Measured
   Performance). Either optimise the `0x00` path, drop MPEG from the implicit
   "all", or flag it in the UI as the expensive one. Right now the
   least-informed choice is the slowest, which is backwards.
2. **Verify the App Nap fix** on the next long scan by noting the percentage
   at lock and at unlock. A single end-of-scan average cannot separate the
   locked stretch, so the current evidence is consistent with the fix working
   but does not prove it.
3. **Sample-check result quality.** Selecting video alongside JPEG cut results
   from 150,149 to 65,965 on the same drive. The theory is that videos now
   claim their own byte ranges and suppress JPEGs carved out of their
   interiors, plus the marker gate rejecting false headers — i.e. the removed
   items were junk. Unverified: it needs eyes on recovered files.
4. **Exercise Select All and a bulk recovery** at ~200k results. Those paths
   are O(items + selection) now, but that has never been run at this scale.
5. **Landing page** once the design settles (see Future Enhancements).
6. **FAT32 deleted directory entries** for original filenames — the last
   filesystem still showing "Not Available". Worth it only if FAT32 volumes
   (SD cards, older USB sticks) are actually in scope. Note this pairs with the
   landing page's SD Card Recovery category: SD cards are typically FAT32, so
   that category is thin without this parser.
7. **Scan resume** via a cursor in the manifest, if field testing shows
   manifests survive real-world use.
8. App icon, signing, Xcode project — only when distribution matters.

## Measured Performance

All synthetic figures are 256 MB, release build, on a local file — not a raw
device through `authopen`. Treat them as ratios, not predictions.

**Build mode dominates everything else.** `swift run` and `swift build`
default to debug, and the carver is a tight per-byte loop — exactly what
`-Onone` leaves unoptimized. The same code measures ~31 MB/s debug against
765 MB/s release. An 18-hour scan that stalled at 69% was a debug build, not a
slow algorithm. `make run` exists so the fast path is the default one.

**Media selection matters more than expected**, on data shaped like real free
space (~50% zero runs):

| selection | rate |
|---|---|
| JPEG only | 802 MB/s |
| Video only | 759 MB/s |
| JPEG + video | 679 MB/s |
| Everything except MPEG | 394 MB/s |
| Everything (the current default) | 73 MB/s |

MPEG alone costs 5.4x. Its signature starts `0x00`, and `0x00` is roughly half
of all bytes in free space, so `detect()` is called on ~128M bytes per 256 MB
instead of a few hundred thousand. Everything else combined only costs ~2x.

One combined pass also beats two separate passes by 1.74x — adding a media
type is far cheaper than re-reading the whole drive — and it is more correct:
video containers hold embedded JPEG (preview atoms, thumbnails, MJPEG frames),
and only a combined scan can skip past a video wholesale instead of carving
junk out of its interior.

**Field results**, exFAT 1 TB PNY NVMe, 842 GB of free space, fast scan:

| media types | time | rate | found |
|---|---|---|---|
| JPEG only | 2h 47m | 84 MB/s | 150,149 |
| JPEG + PNG + MP4/MOV + WebM/MKV | 1h 26m | 163 MB/s | 65,965 |

Adding three media types roughly **halved** the time, which contradicts the
synthetic table above. The likely reason is that the synthetic data contains no
real videos to skip: on a video-heavy drive, identifying a video lets the
carver jump `index` past gigabytes at once, while a JPEG-only scan walks every
one of those bytes. Both runs had the machine locked for ~35% of their
duration.

The pre-phase-7 equivalent of that first scan would have taken ~26 hours.

## Environment Notes

- **Always run a release build: `make run` (or `swift run -c release`)** — see
  Measured Performance for why it is ~25x. `make test` stays in debug on
  purpose, to keep assertions and overflow checks on.
- `FileRecoveryApp.init()` calls
  `setActivationPolicy(.regular)` and `activate(ignoringOtherApps:)` because a
  bare SwiftPM executable launches as a background process that never
  activates — without it the window shows but receives no key events.
- Field-verified hardware: exFAT 1 TB Crucial NVMe (~991 GB free, 12,438
  deleted directory entries), exFAT 1 TB PNY NVMe (842 GB free, 2,054 deleted
  directory entries; nothing recovered from it yet), and an NTFS drive with
  working filenames.
- Benchmark data must be checked, not assumed. A xorshift64 low-byte stream
  looks random but never emits `FFD9`, which silently turned a scan benchmark
  into a worst-case one and produced a throughput figure ~15x too low. Use
  splitmix64 and assert the signature counts in the generated data.
