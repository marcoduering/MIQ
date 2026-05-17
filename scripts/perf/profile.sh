#!/usr/bin/env bash
#
# On-demand MIQCore performance profile against a real-file corpus.
#
# Runs the `corpusProfile` test (release build) over every entry in
# scripts/perf/testcases.txt, prints a per-stage table with the delta vs
# scripts/perf/baseline.json, and writes machine-readable scripts/perf/results.json.
#
#   ./scripts/perf/profile.sh                  # profile + compare to baseline
#   ./scripts/perf/profile.sh --update-baseline # promote this run to the baseline
#   ./scripts/perf/profile.sh --threshold 1.30  # flag regressions > 30% (default 20%)
#
# testcases.txt is gitignored and maintainer-specific (see testcases.txt.example).
# Timings are machine-dependent: compare trends on the same host, not absolute
# numbers across machines. Build artifacts go to /tmp (never the repo CWD).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERF_DIR="$ROOT_DIR/scripts/perf"

CORPUS="$PERF_DIR/testcases.txt"
BASELINE="$PERF_DIR/baseline.json"
RESULTS="$PERF_DIR/results.json"
THRESHOLD="1.20"
UPDATE_BASELINE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    --threshold) THRESHOLD="${2:?--threshold needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CORPUS" ]]; then
  echo "error: $CORPUS not found." >&2
  echo "Copy scripts/perf/testcases.txt.example to testcases.txt and edit the paths." >&2
  exit 1
fi

SCRATCH="${TMPDIR:-/tmp}/miq-perf-build"

env \
  MIQ_PERF_CORPUS="$CORPUS" \
  MIQ_PERF_BASELINE="$BASELINE" \
  MIQ_PERF_JSON="$RESULTS" \
  MIQ_PERF_THRESHOLD="$THRESHOLD" \
  MIQ_PERF_UPDATE_BASELINE="$UPDATE_BASELINE" \
  swift test -c release \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SCRATCH" \
    --filter corpusProfile \
  2>&1 | grep -vE '^(Building|Compiling|Build complete|Test Suite|Test Case|Executed 0|􀟈|􀄵|􁁛|     )' || true

echo
if [[ "$UPDATE_BASELINE" == "1" ]]; then
  echo "Baseline promoted → scripts/perf/baseline.json (commit it)."
else
  echo "Results → scripts/perf/results.json (gitignored). Re-run with --update-baseline to promote."
fi
