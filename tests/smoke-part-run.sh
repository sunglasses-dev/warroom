#!/usr/bin/env bash
# tests/smoke-part-run.sh PART TRAILER_FILE: what one CI leg runs. Runs one part of tests/smoke.sh, shows its output, keeps the
# part's own exit status (a timeout is 124 and stays 124), and saves the trailer line the part printed (empty if it printed none)
# for the aggregator, tests/smoke-all.sh.
set -u
[ $# = 2 ] && [ -n "$1" ] || { echo "usage: smoke-part-run.sh PART TRAILER_FILE" >&2; exit 2; }
suite=${SMOKE_SUITE:-$(cd "$(dirname "$0")" && pwd)/smoke.sh}
log=$(mktemp) || exit 2
SMOKE_PART=$1 bash "$suite" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
mkdir -p "$(dirname "$2")"
grep -E '^smoke-part [a-z0-9]+: ran=[0-9]+ expected=[0-9]+ ok=[0-9]+ fail=[0-9]+$' "$log" | tail -n 1 > "$2"
rm -f "$log"
exit "$rc"
