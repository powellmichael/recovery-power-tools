# Recovery Power Tools Project Context

## Project Scope (Phase 1, restated 2026-07-13)

1. Recover deleted media files (photos, RAW, video) plus ZIP.
2. Only list files that are deleted.
3. Select some or all found files to recover.

## Current Repository State

- GitHub repo: `powellmichael/recovery-power-tools`
- Default branch: `main`
- Current working branch: `phase-2`
- Phase 1 MVP commit: `ac8650a`

## Architecture

SwiftUI macOS app (SwiftPM, macOS 14+). Key pieces:

- `ScanSource` — read-only byte source over a regular file or a raw device.
  Raw devices are opened via `/usr/libexec/authopen` (standard macOS password
  prompt, fd passed back over a socket). All reads are `pread`-based and
  block-aligned for devices.
- `DeviceDiscovery` — lists external physical disks/partitions via `diskutil`,
  plus a guard that refuses to recover onto the disk being scanned.
- `FreeSpaceMap` — parses FAT32 (FAT table) and exFAT (allocation bitmap) into
  free byte regions. Carving only free space is what makes "only deleted
  files" true. Unrecognized filesystems fall back to whole-device carving with
  a "may include live files" note.
- `RecoveryScanner` — signature carver over `ScanSource` regions with chunked
  streaming, overlap carry, and per-format length parsers.
- `RecoveryViewModel` / `ContentView` — drive picker menu, file/folder picker,
  per-item recovery checkboxes, image preview, per-item recovery errors.
  Recovery runs off the main actor.

## Supported Formats

Determinable-length signatures only (formats without reliable signatures are
deliberately excluded — they'd produce garbage hits):

- Images: JPEG, PNG, HEIC/HEIF, BMP, RAW (TIFF family: NEF/CR2/ARW/DNG/3FR via
  IFD walking; Fuji RAF via header offsets)
- Video: MP4/MOV/M4V/3GP/3G2 (ISO boxes), AVI (RIFF + AVIX), WMV/ASF (File
  Properties object), FLV (tag walking), WebM/MKV (EBML), MPEG-PS (pack walking)
- Containers: ZIP (local header → end-of-central-directory + comment)

## Scan Modes

- **External drive (the real recovery path)**: pick a partition from the drive
  menu → authopen password prompt → FAT32/exFAT free-space map → carve only
  unallocated space. Results are deleted data by definition.
- **File/folder**: carves through readable file bytes; used for disk images,
  test blobs. Folder scans skip live media/container files by extension.

## Tests

`swift test` — Swift Testing target covering: synthetic blob carving (JPEG,
PNG, BMP, ZIP, MP4 offsets/lengths), recovery byte fidelity, FAT32 free-cluster
parsing on a synthetic image.

## Known Limitations / Deliberate Deferrals

- Fragmented deleted files don't recover (carving assumes contiguous data).
- APFS free-space parsing not implemented — internal Mac SSDs fall back to
  whole-device carve, and TRIM makes recovery there unlikely anyway.
- exFAT: reads only the first root-directory cluster for the bitmap entry and
  assumes the bitmap file is contiguous (`ponytail:` comments mark both).
- Original filenames unavailable from carved bytes. FAT/exFAT deleted
  directory entries could supply names + first clusters — best next step.
- JPEG carving ends at the first FFD9; embedded EXIF thumbnails can truncate
  some images. Fix: validate decode, continue searching on failure.
- PSD, CRW, GIF, and obscure formats (3DM, ANI, ART…) skipped — no reliable
  length/signature.
- No video/ZIP preview; image preview only.
- Length-finders re-read from the source per candidate (O(n²) worst case on
  signature-dense sources).
- Not sandboxed/signed; SwiftPM executable, not an Xcode project yet.

## Feature Backlog

(empty — NTFS support shipped in phase 4: $Bitmap free space, MFT deleted
entries with names/exact sizes, fragmented-file recovery via data runs)

## Recommended Next Steps

1. Parse FAT/exFAT deleted directory entries for original filenames and
   cluster hints (big UX win: real names in results).
2. Video preview via AVPlayer (preview file is already written to temp).
3. JPEG end-marker validation to fix thumbnail truncation.
4. Real-drive field test with a scratch USB stick: format, copy media, delete,
   scan, verify recovery.
5. App icon, signing, Xcode project — only when distribution matters.
