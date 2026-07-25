# Always build optimized. A debug build scans ~20x slower — the carver is a
# tight per-byte loop, which is exactly what Swift's -Onone leaves unoptimized.
# Measured on 256 MB of high-entropy data: 31 MB/s debug vs 667 MB/s release.
#
# `swift run` and `swift build` default to debug, so use these targets instead.

.PHONY: run build test clean

run:
	swift run -c release

build:
	swift build -c release

# Tests stay in debug: they're small fixtures, and debug keeps assertions
# and overflow checks on.
test:
	swift test

clean:
	swift package clean
