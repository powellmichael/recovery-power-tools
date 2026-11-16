# Always build optimized. A debug build scans ~20x slower — the carver is a
# tight per-byte loop, which is exactly what Swift's -Onone leaves unoptimized.
# Measured on 256 MB of high-entropy data: 31 MB/s debug vs 667 MB/s release.
#
# `swift run` and `swift build` default to debug, so use these targets instead.

.PHONY: run build test clean app notarize license-keys

run:
	swift run -c release FileRecovery

build:
	swift build -c release

# Tests stay in debug: they're small fixtures, and debug keeps assertions
# and overflow checks on.
test:
	swift test

# Builds dist/Recovery Power Tools.app. Ad-hoc signed unless SIGN_IDENTITY
# names a Developer ID, e.g.
#   make app SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" VERSION=1.0.0
app:
	BUNDLE_ID="$(BUNDLE_ID)" VERSION="$(VERSION)" BUILD="$(BUILD)" \
	SIGN_IDENTITY="$(SIGN_IDENTITY)" PURCHASE_URL="$(PURCHASE_URL)" Scripts/make-app.sh

# Needs a Developer ID build and NOTARY_PROFILE; see Scripts/notarize.sh.
notarize:
	NOTARY_PROFILE="$(NOTARY_PROFILE)" Scripts/notarize.sh

# One-time: creates the licence signing key outside the repository and saves
# its public half where `make app` picks it up.
license-keys:
	swift run -c release LicenseTool keygen > license-public.key
	@echo "Public key saved to license-public.key (safe to commit)."

clean:
	swift package clean
	rm -rf dist
