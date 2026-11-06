#!/usr/bin/env bash
set -euo pipefail

# Local CI: SwiftLint, project generation, a clean build, the unused-import
# analysis (swiftlint analyze), and tests.
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

# The unused-import check (swiftlint analyze) reads each Swift file's compiler
# arguments from the build's log, and an incremental build logs only the files
# it recompiles. So the build starts clean, its log goes to this file, and the
# tests run on that build.
BUILD_LOG="$(mktemp -t lemurcam-ci-build)"
trap 'rm -f "$BUILD_LOG"' EXIT

echo "==> [1/4] Linting..."
swiftlint lint --strict

echo "==> [2/4] Building app and test targets from clean..."
xcodegen generate
xcodebuild clean build-for-testing -scheme LemurCam -destination 'platform=macOS' "${BUILD_ARGS[@]}" \
  | tee "$BUILD_LOG"

echo "==> [3/4] Checking for unused imports..."
scripts/check-unused-imports.sh "$BUILD_LOG"

echo "==> [4/4] Running tests..."
xcodebuild test-without-building -scheme LemurCam -destination 'platform=macOS' "${TEST_ARGS[@]}"

echo "==> All CI checks passed."
