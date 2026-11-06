#!/usr/bin/env bash
set -euo pipefail

# Enforce SwiftLint's unused_import analyzer rule, and only that one of the
# analyzer_rules in .swiftlint.yml, on the Swift files SwiftLint lints. Run by
# scripts/ci.sh after the build, alongside the tests.
#
# swiftlint analyze takes each file's compiler arguments from an xcodebuild log.
# It skips a file whose arguments are not in the log without reporting it, and
# an incremental build logs only the files it recompiles, so the log must be
# from a clean build of every target. To catch a log that is not, this checks
# that analyze covered as many files as swiftlint lint does.
#
# Analyze takes about a second a file in one process, so the files are analyzed
# in runs of 20, each in a new process, several at a time: min(physical cores /
# 2, available memory / 2.5 GB), at least 1 and at most 2 on GitHub Actions.
# LEMURCAM_ANALYZE_JOBS overrides that count. Each process takes up to about
# 2 GB. SourceKit spends most of its time resolving file paths (realpath), and
# on macOS 27 those system calls stop scaling across processes when any
# ancestor was started through a #! line rather than as `bash <script>`: on a
# 16-core Mac, 8 processes took 342 s that way and 156 s without, while one
# process is as fast either way. So run this, and scripts/ci.sh, with bash.
#
# Arguments after the log go to swiftlint analyze (e.g. --reporter).

CHUNK_SIZE=20

# Internal: one run of analyze, started by xargs below as
# `bash check-unused-imports.sh --run <work directory> <run number>`. It reads
# the analyze options and the run's files from the work directory, then becomes
# swiftlint analyze, which writes the run's output there.
if [[ "${1:-}" == "--run" ]]; then
  OPTIONS=()
  while IFS= read -r -d '' option; do OPTIONS+=("$option"); done <"$2/options"
  RUN_FILES=()
  while IFS= read -r -d '' file; do RUN_FILES+=("$file"); done <"$2/$3.files"
  exec swiftlint analyze "${OPTIONS[@]}" "${RUN_FILES[@]}" >"$2/$3.out" 2>"$2/$3.err"
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: bash scripts/check-unused-imports.sh <xcodebuild log> [swiftlint analyze options]" >&2
  exit 2
fi
if [[ ! -s "$1" ]]; then
  echo "error: the xcodebuild log $1 is missing or empty." >&2
  exit 1
fi
BUILD_LOG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
ANALYZE_ARGS=("$@")

# Run from the repo root, where .swiftlint.yml's paths resolve.
cd "$(dirname "$0")/.."

# The number of files SwiftLint lints, from lint's summary line. Lint violations
# are the lint step's to report; only the count matters here.
LINTED="$(swiftlint lint 2>&1 >/dev/null | sed -n 's/^Done linting!.* in \([0-9][0-9]*\) files*\.$/\1/p' || true)"
if [[ -z "$LINTED" ]]; then
  echo "error: could not read how many files swiftlint lint checks." >&2
  exit 1
fi

# The Swift files under .swiftlint.yml's `included` paths (a block list), as
# absolute paths: given relative ones, analyze finds no compiler arguments and
# checks nothing. `excluded` is left to --force-exclude, which applies it the
# way lint does. A path this misses fails the coverage check below.
INCLUDED=()
while IFS= read -r path; do
  if [[ -e "$path" ]]; then INCLUDED+=("$PWD/$path"); fi
done < <(awk '
  /^[^[:space:]#]/ { listing = ($1 == "included:"); next }
  listing && /^[[:space:]]*-[[:space:]]/ {
    sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["'\'']/, ""); print
  }
' .swiftlint.yml)
if [[ ${#INCLUDED[@]} -eq 0 ]]; then
  echo "error: could not read the included paths from .swiftlint.yml." >&2
  exit 1
fi
FILES=()
while IFS= read -r -d '' file; do
  FILES+=("$file")
done < <(find "${INCLUDED[@]}" -type f -name '*.swift' -print0 | sort -z)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "error: found no Swift files under .swiftlint.yml's included paths." >&2
  exit 1
fi
CHUNKS=$(((${#FILES[@]} + CHUNK_SIZE - 1) / CHUNK_SIZE))

if [[ -n "${LEMURCAM_ANALYZE_JOBS:-}" ]]; then
  if [[ ! "$LEMURCAM_ANALYZE_JOBS" =~ ^[0-9]+$ ]]; then
    echo "error: LEMURCAM_ANALYZE_JOBS must be a number, not \"$LEMURCAM_ANALYZE_JOBS\"." >&2
    exit 2
  fi
  JOBS="$LEMURCAM_ANALYZE_JOBS"
else
  PHYSICAL_CORES="$(sysctl -n hw.physicalcpu)"
  PAGE_SIZE="$(sysctl -n hw.pagesize)"
  # Free, inactive and speculative pages: what macOS can hand out without paging.
  AVAILABLE_PAGES="$(vm_stat | awk '/^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); sum += $NF } END { print sum + 0 }')"
  AVAILABLE_MB=$((AVAILABLE_PAGES * PAGE_SIZE / 1024 / 1024))
  JOBS=$((PHYSICAL_CORES / 2))
  BY_MEMORY=$((AVAILABLE_MB / 2560))
  if [[ "$BY_MEMORY" -lt "$JOBS" ]]; then JOBS="$BY_MEMORY"; fi
  if [[ "${GITHUB_ACTIONS:-}" == "true" && "$JOBS" -gt 2 ]]; then JOBS=2; fi
fi
if [[ "$JOBS" -lt 1 ]]; then JOBS=1; fi
if [[ "$JOBS" -gt "$CHUNKS" ]]; then JOBS="$CHUNKS"; fi

WORK="$(mktemp -d -t lemurcam-analyze)"
XARGS_PID=""
cleanup() {
  # A second Ctrl-C or TERM must not cut this short.
  trap '' INT TERM
  # Stop the runs: pause xargs so it starts no more, stop the runs going (each
  # is an analyze process, xargs's child), then end xargs. The children come
  # from ps: macOS 27's pgrep and pkill ignore -P and match every process.
  if [[ -n "$XARGS_PID" ]]; then
    kill -STOP "$XARGS_PID" 2>/dev/null || true
    for pid in $(ps -Ao pid=,ppid= | awk -v parent="$XARGS_PID" '$2 == parent { print $1 }'); do
      kill -TERM "$pid" 2>/dev/null || true
    done
    kill -TERM "$XARGS_PID" 2>/dev/null || true
    kill -CONT "$XARGS_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The analyze options and each run's files, NUL-separated, for the runs to read.
printf '%s\0' --strict --force-exclude --only-rule unused_import --compiler-log-path "$BUILD_LOG" \
  ${ANALYZE_ARGS[@]+"${ANALYZE_ARGS[@]}"} >"$WORK/options"
for ((run = 0; run < CHUNKS; run++)); do
  printf '%s\0' "${FILES[@]:run * CHUNK_SIZE:CHUNK_SIZE}" >"$WORK/$run.files"
done

# xargs starts the next run whenever one of the JOBS slots frees up.
echo "Analyzing ${#FILES[@]} files for unused imports: $CHUNKS runs of up to $CHUNK_SIZE files, $JOBS at a time..."
# xargs exits non-zero if any run did: analyze exits 2 when it finds an unused
# import, and other codes when it fails.
seq 0 $((CHUNKS - 1)) | xargs -n 1 -P "$JOBS" bash "$PWD/scripts/check-unused-imports.sh" --run "$WORK" &
XARGS_PID=$!
XARGS_STATUS=0
wait "$XARGS_PID" || XARGS_STATUS=$?
XARGS_PID=""

UNFINISHED=0
ANALYZED=0
VIOLATIONS=0
for ((run = 0; run < CHUNKS; run++)); do
  if [[ ! -f "$WORK/$run.err" ]]; then
    echo "error: run $run of swiftlint analyze did not start." >&2
    UNFINISHED=1
    continue
  fi
  # The violations, in the reporter's format.
  cat "$WORK/$run.out"
  # Anything else analyze said, without its file lists, progress and summary lines.
  grep -v -e "^Analyzing " -e "^Done analyzing!" "$WORK/$run.err" >&2 || true
  SUMMARY="$(sed -n 's/^Done analyzing! Found \([0-9]*\) violations*, [0-9]* serious in \([0-9]*\) files*\.$/\1 \2/p' "$WORK/$run.err")"
  if [[ -z "$SUMMARY" ]]; then
    echo "error: run $run of swiftlint analyze ended before its summary." >&2
    UNFINISHED=1
    continue
  fi
  VIOLATIONS=$((VIOLATIONS + ${SUMMARY% *}))
  ANALYZED=$((ANALYZED + ${SUMMARY#* }))
done

echo "Done analyzing! Found $VIOLATIONS unused imports in $ANALYZED of $LINTED files, in ${SECONDS}s."
if [[ "$XARGS_STATUS" -ne 0 || "$UNFINISHED" -ne 0 ]]; then
  echo "error: swiftlint analyze failed; the unused imports, or its errors, are listed above." >&2
  exit 1
fi
if [[ "$ANALYZED" -ne "$LINTED" ]]; then
  echo "error: swiftlint analyze checked $ANALYZED of the $LINTED files SwiftLint lints." >&2
  echo "The rest have no compiler arguments in $BUILD_LOG; it must be the log of a clean build of every target." >&2
  exit 1
fi
