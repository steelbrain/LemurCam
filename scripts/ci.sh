#!/usr/bin/env bash
set -euo pipefail

# Local CI: SwiftLint, project generation, build, and tests.
#
# By default the build is signed with the team in project.yml. Without that
# team's certificates, build unsigned the way the GitHub workflow does
# (CODE_SIGNING_ALLOWED=NO): pass --unsigned, or set LEMURCAM_UNSIGNED=1.
# Unsigned is also the default when CI is set (as on GitHub Actions). Unsigned
# builds compile and run the unit tests, but the app they produce cannot
# install the camera extension or the audio driver.

usage() {
  cat <<EOF
Usage: scripts/ci.sh [--unsigned]

  --unsigned   Build and test with CODE_SIGNING_ALLOWED=NO (no signing identity
               or provisioning profile needed). Also enabled by
               LEMURCAM_UNSIGNED=1 or a non-empty CI other than "false"/"0".
EOF
}

UNSIGNED=0
if [[ "${LEMURCAM_UNSIGNED:-0}" == "1" ]]; then
  UNSIGNED=1
fi
case "${CI:-}" in
  ""|false|0) ;;
  *) UNSIGNED=1 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned) UNSIGNED=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# Run from the repo root no matter where the script is invoked from.
cd "$(dirname "$0")/.."

# .swiftlint.yml pins the SwiftLint version, and any other version makes the
# lint exit 2 with only a one-line warning. Check it before doing any work.
REQUIRED_SWIFTLINT="$(awk '$1 == "swiftlint_version:" { gsub(/["'\'']/, "", $2); print $2; exit }' .swiftlint.yml)"
if [[ -z "$REQUIRED_SWIFTLINT" ]]; then
  echo "error: could not read swiftlint_version from .swiftlint.yml." >&2
  exit 1
fi
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: SwiftLint ${REQUIRED_SWIFTLINT} is required (swiftlint_version in .swiftlint.yml), but swiftlint is not on PATH." >&2
  echo "See \"Building From Source\" in README.md for how to install it." >&2
  exit 1
fi
INSTALLED_SWIFTLINT="$(swiftlint version 2>/dev/null || echo unknown)"
if [[ "$INSTALLED_SWIFTLINT" != "$REQUIRED_SWIFTLINT" ]]; then
  echo "error: SwiftLint ${REQUIRED_SWIFTLINT} is required (swiftlint_version in .swiftlint.yml), but $(command -v swiftlint) is ${INSTALLED_SWIFTLINT}." >&2
  echo "Put SwiftLint ${REQUIRED_SWIFTLINT} first on PATH; see \"Building From Source\" in README.md." >&2
  exit 1
fi

if [[ "$UNSIGNED" -eq 1 ]]; then
  echo "==> Code signing disabled (CODE_SIGNING_ALLOWED=NO)."
  BUILD_ARGS=(CODE_SIGNING_ALLOWED=NO)
  TEST_ARGS=(-quiet CODE_SIGNING_ALLOWED=NO)
else
  BUILD_ARGS=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  TEST_ARGS=(-quiet)
fi

echo "==> [1/3] Linting..."
swiftlint lint --strict

echo "==> [2/3] Building app targets..."
xcodegen generate
xcodebuild build -scheme LemurCam -destination 'platform=macOS' "${BUILD_ARGS[@]}"

echo "==> [3/3] Running tests..."
xcodebuild test -scheme LemurCam -destination 'platform=macOS' "${TEST_ARGS[@]}"

echo "==> All CI checks passed."
