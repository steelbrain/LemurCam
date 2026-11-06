#!/usr/bin/env bash
set -euo pipefail

# Enforce SwiftLint's unused_import analyzer rule, and only that one of the
# analyzer_rules in .swiftlint.yml, on the Swift files SwiftLint lints. Run by
# scripts/ci.sh and the GitHub workflow after the build.
#
# swiftlint analyze takes each file's compiler arguments from an xcodebuild log.
# It skips a file whose arguments are not in the log without reporting it, and
# an incremental build logs only the files it recompiles, so the log must be
# from a clean build of every target. To catch a log that is not, this checks
# that analyze covered as many files as swiftlint lint does.
#
# Arguments after the log go to swiftlint analyze (e.g. --reporter).

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/check-unused-imports.sh <xcodebuild log> [swiftlint analyze options]" >&2
  exit 2
fi
if [[ ! -s "$1" ]]; then
  echo "error: the xcodebuild log $1 is missing or empty." >&2
  exit 1
fi
BUILD_LOG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift

# Run from the repo root, where .swiftlint.yml's included paths resolve.
cd "$(dirname "$0")/.."

# The number of files SwiftLint lints, from lint's summary line. Lint violations
# are the lint step's to report; only the count matters here.
LINTED="$(swiftlint lint 2>&1 >/dev/null | sed -n 's/^Done linting!.* in \([0-9][0-9]*\) files*\.$/\1/p' || true)"
if [[ -z "$LINTED" ]]; then
  echo "error: could not read how many files swiftlint lint checks." >&2
  exit 1
fi

ANALYZE_OUTPUT="$(mktemp -t lemurcam-analyze)"
trap 'rm -f "$ANALYZE_OUTPUT"' EXIT
STATUS=0
swiftlint analyze --strict --only-rule unused_import --compiler-log-path "$BUILD_LOG" "$@" 2>&1 \
  | tee "$ANALYZE_OUTPUT" || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  exit "$STATUS"
fi

ANALYZED="$(sed -n 's/^Done analyzing!.* in \([0-9][0-9]*\) files*\.$/\1/p' "$ANALYZE_OUTPUT")"
if [[ "$ANALYZED" != "$LINTED" ]]; then
  echo "error: swiftlint analyze checked ${ANALYZED:-no} of the $LINTED files SwiftLint lints." >&2
  echo "The rest have no compiler arguments in $BUILD_LOG; it must be the log of a clean build of every target." >&2
  exit 1
fi
