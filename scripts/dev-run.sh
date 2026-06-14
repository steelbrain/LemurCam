#!/usr/bin/env bash
set -euo pipefail

# Build LemurCam (Debug), install it into /Applications, and launch it there.
#
# LemurCam refuses to run from anywhere but /Applications (see
# terminateIfNotInApplications in App/AppDelegate.swift): the CMIO system
# extension, the SMAppService helper daemon, and the audio HAL driver all need
# an installed, correctly-located bundle. Xcode's Run button launches the
# product straight out of DerivedData, which trips that guard, so this is the
# supported way to run a locally-built app during development.
#
# Note: Xcode's debugger does not attach to the /Applications copy. To debug,
# run this script, then use Xcode's Debug > Attach to Process.
#
# If you changed code in Extension/ or relevant Shared/ files, bump
# CURRENT_PROJECT_VERSION in project.yml first, or macOS may keep the stale
# extension running ("Extension already up to date" instead of "Updating
# extension: vN -> vM").

SCHEME="LemurCam"
CONFIGURATION="Debug"
APP_NAME="LemurCam"
DEST_APP="/Applications/${APP_NAME}.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Repo-local DerivedData so the built product is at a deterministic path and is
# covered by scripts/dev-clean.sh (which purges build/). Isolated from Xcode's
# GUI DerivedData; the /Applications copy is the one that actually runs.
DERIVED_DATA="$REPO_ROOT/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

cd "$REPO_ROOT"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building ${SCHEME} (${CONFIGURATION})..."
xcodebuild build \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: build product not found at $BUILT_APP" >&2
  exit 1
fi

echo "==> Stopping any running ${APP_NAME}..."
# A running bundle can't be cleanly replaced; quit it and wait for it to exit.
pkill -x "$APP_NAME" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
  sleep 0.3
done

echo "==> Installing to ${DEST_APP}..."
if [[ -e "$DEST_APP" && ! -w "$DEST_APP" ]]; then
  echo "error: ${DEST_APP} exists but is not writable." >&2
  echo "       This is usually a stale root-owned copy from a prior sudo run." >&2
  echo "       Remove it and re-run:  sudo rm -rf '${DEST_APP}'" >&2
  exit 1
fi
# Replace any prior copy outright so no stale files survive, then copy with
# ditto, which preserves the existing code signature. Do NOT re-sign: that
# would re-derive the helper's dotted executable name and break its signing
# identity (see the Helper target notes in project.yml).
rm -rf "$DEST_APP"
ditto "$BUILT_APP" "$DEST_APP"

# Defensive: strip quarantine so Gatekeeper doesn't translocate the app to a
# random read-only path, which would itself defeat the /Applications guard.
# Locally-built apps usually aren't quarantined, so this is belt-and-suspenders.
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "==> Launching ${DEST_APP}..."
open "$DEST_APP"

echo "==> Done. Running from ${DEST_APP}."
