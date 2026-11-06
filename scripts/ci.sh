#!/usr/bin/env bash
set -euo pipefail

# Local CI, and what the GitHub workflow's build job runs: SwiftLint, project
# generation, a clean build, then the unused-import check (swiftlint analyze)
# and the tests side by side.
#
# Run it as `bash scripts/ci.sh`: on macOS 27, starting it through its #! line
# (`scripts/ci.sh`) makes the check's parallel processes about twice as slow.
# scripts/check-unused-imports.sh says more.
#
# By default the build is signed with the team in project.yml. Without that
# team's certificates, build unsigned the way the GitHub workflow does
# (CODE_SIGNING_ALLOWED=NO): pass --unsigned, or set LEMURCAM_UNSIGNED=1.
# Unsigned is also the default when CI is set (as on GitHub Actions). Unsigned
# builds compile and run the unit tests, but the app they produce cannot
# install the camera extension or the audio driver.

usage() {
  cat <<EOF
Usage: bash scripts/ci.sh [--unsigned]

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
# check and the tests both run on that build, at the same time.
BUILD_LOG="$(mktemp -t lemurcam-ci-build)"
ANALYZE_OUTPUT="$(mktemp -t lemurcam-ci-analyze)"
ANALYZE_PID=""
cleanup() {
  # A second Ctrl-C or TERM must not cut this short.
  trap '' INT TERM
  # Stop the check if CI ends before it does (Ctrl-C, or an error).
  if [[ -n "$ANALYZE_PID" ]]; then kill "$ANALYZE_PID" 2>/dev/null || true; fi
  rm -f "$BUILD_LOG" "$ANALYZE_OUTPUT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> [1/3] Linting..."
swiftlint lint --strict

echo "==> [2/3] Building app and test targets from clean..."
xcodegen generate
xcodebuild clean build-for-testing -scheme LemurCam -destination 'platform=macOS' "${BUILD_ARGS[@]}" \
  | tee "$BUILD_LOG"

echo "==> [3/3] Checking for unused imports while running the tests..."
# On GitHub, report unused imports as annotations on their lines.
ANALYZE_ARGS=()
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  ANALYZE_ARGS=(--reporter github-actions-logging)
fi
bash scripts/check-unused-imports.sh "$BUILD_LOG" ${ANALYZE_ARGS[@]+"${ANALYZE_ARGS[@]}"} >"$ANALYZE_OUTPUT" 2>&1 &
ANALYZE_PID=$!

TEST_STATUS=0
xcodebuild test-without-building -scheme LemurCam -destination 'platform=macOS' "${TEST_ARGS[@]}" \
  || TEST_STATUS=$?

ANALYZE_STATUS=0
wait "$ANALYZE_PID" || ANALYZE_STATUS=$?
ANALYZE_PID=""
echo "==> Unused-import check:"
cat "$ANALYZE_OUTPUT"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  echo "error: the tests failed (xcodebuild exited $TEST_STATUS)." >&2
fi
if [[ "$ANALYZE_STATUS" -ne 0 ]]; then
  echo "error: the unused-import check failed (exit $ANALYZE_STATUS); its output is above." >&2
fi
if [[ "$TEST_STATUS" -ne 0 || "$ANALYZE_STATUS" -ne 0 ]]; then
  exit 1
fi

echo "==> All CI checks passed."
