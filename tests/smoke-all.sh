#!/usr/bin/env bash
# tests/smoke-all.sh DIR OS...: the verdict of a matrix run of tests/smoke.sh. DIR holds one <os>-<part>.trailer file per leg
# (the line a part prints last, see tests/smoke-part-run.sh). SMOKE_LEGS_RESULT is what GitHub reports for the matrix job.
# Passes only if EVERY part (base, m1, m2) of EVERY OS named left a trailer saying it ran every call the manifest gives it,
# printed at least the manifest's floor of ok lines, and failed nothing. A leg that never ran is a failure, not a skip.
set -u
dir=${1:-}; [ -n "$dir" ] || { echo "usage: smoke-all.sh DIR OS..." >&2; exit 2; }
shift
mf=${SMOKE_MANIFEST:-$(cd "$(dirname "$0")" && pwd)/smoke-parts.txt}
rc=0
no() { echo "FAIL $*"; rc=1; }
[ "${SMOKE_LEGS_RESULT:-}" = success ] || no "the matrix job result is '${SMOKE_LEGS_RESULT:-unset}', not success"
[ $# -gt 0 ] || no "no OS named: nothing was checked"
[ -r "$mf" ] || { no "the manifest $mf is missing"; exit 1; }
re='^smoke-part ([a-z0-9]+): ran=([0-9]+) expected=([0-9]+) ok=([0-9]+) fail=([0-9]+)$'
for os in "$@"; do
  for p in base m1 m2; do
    want=$(grep -cE "^$p (mut|fx) " "$mf"); floor=$(awk -v p="$p" '$1 == "floor" && $2 == p {print $3}' "$mf")
    [ "$want" -gt 0 ] || { no "$os $p: the manifest gives this part no calls"; continue; }
    f="$dir/$os-$p.trailer"
    [ -s "$f" ] || { no "$os $p: no trailer (the leg did not run, or printed none)"; continue; }
    [ $(( $(wc -l < "$f") )) = 1 ] || { no "$os $p: the trailer file is not exactly one line"; continue; }
    line=$(cat "$f")
    [[ $line =~ $re ]] || { no "$os $p: the trailer line is not in the expected form: $line"; continue; }
    [ "${BASH_REMATCH[1]}" = "$p" ] || { no "$os $p: the trailer is for part ${BASH_REMATCH[1]}"; continue; }
    ran=${BASH_REMATCH[2]}; exp=${BASH_REMATCH[3]}; okn=${BASH_REMATCH[4]}; bad=${BASH_REMATCH[5]}
    [ "$exp" = "$want" ] || no "$os $p: the leg expected $exp calls, the manifest gives it $want"
    [ "$ran" = "$exp" ] || no "$os $p: ran $ran of $exp calls"
    [ "$okn" -ge "${floor:-0}" ] || no "$os $p: printed $okn ok lines, the manifest floor is ${floor:-0}"
    [ "$bad" = 0 ] || no "$os $p: $bad failed"
    [ "$rc" = 0 ] && echo "ok   $os $p: ran $ran of $exp, $okn ok lines (floor ${floor:-0}), no failures"
  done
done
[ "$rc" = 0 ] && echo "smoke-all: every part of every OS ran completely" || echo "smoke-all: FAILED"
exit $rc
