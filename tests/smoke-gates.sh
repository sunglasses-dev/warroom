#!/usr/bin/env bash
# tests/smoke-gates.sh: the part split of tests/smoke.sh may never pass by running less. Each case below builds ONE way it could and
# asserts that the gate says FAIL (and, where the case needs it, why). Takes about a minute; runs in the `checks` CI job.
#   G1 a part exits 0 although a fixture failed       G6  a fixture's assert lines are gone (fewer ok lines than the floor)
#   G2 a trailer is missing, empty or garbled         G7  SMOKE_PART=typo runs nothing
#   G3 a part skips a call it owns                    G8  a part is missing from the matrix, from `needs`, or never ran
#   G4 a call in smoke.sh is not in the manifest      G9  the supervisor's timeout (124) is swallowed
#   G5 a call is listed twice, or in two parts        G10 a part is run without sourcing tests/smoke-lib.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
MF=$ROOT/tests/smoke-parts.txt

# mk_tree DIR: a copy of the files the gate runs on. bin and hooks are COPIED, never linked: a case that reaches the mutant
# section runs sed -i on its tree, and through a link that would rewrite the real scripts
mk_tree() {
  mkdir -p "$1/tests" "$1/.github/workflows"
  cp "$ROOT"/tests/smoke.sh "$ROOT"/tests/smoke-lib.sh "$ROOT"/tests/smoke-parts.txt "$ROOT"/tests/smoke-all.sh "$ROOT"/tests/smoke-part-run.sh "$ROOT"/tests/supervise.py "$1/tests/"
  cp "$ROOT/.github/workflows/ci.yml" "$1/.github/workflows/"
  cp -R "$ROOT/bin" "$1/bin"; cp -R "$ROOT/hooks" "$1/hooks"
}
# good_trailers DIR OS...: the trailer files of a matrix run in which every part ran every call it owns, with exactly the floor of ok lines
good_trailers() {
  local d=$1 os p e f; shift; mkdir -p "$d"
  for os; do for p in base m1 m2; do
    e=$(grep -cE "^$p (mut|fx) " "$MF"); f=$(awk -v p="$p" '$1 == "floor" && $2 == p {print $3}' "$MF")
    echo "smoke-part $p: ran=$e expected=$e ok=$f fail=0" > "$d/$os-$p.trailer"
  done; done
}
# must_fail NAME PATTERN CMD...: CMD exits non-zero AND its output says PATTERN (so it failed for the reason the case is about)
must_fail() {
  local name=$1 pat=$2 out rc; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -Eq -- "$pat"; then ok "$name: refused (rc $rc, says: $(printf '%s\n' "$out" | grep -E -- "$pat" | head -1 | cut -c1-110))"
  else bad "$name: rc $rc, the gate did not say '$pat': $(printf '%s' "$out" | tail -3 | tr '\n' '|' | cut -c1-240)"; fi
}
must_pass() { local name=$1 out rc; shift; out=$("$@" 2>&1); rc=$?; [ "$rc" = 0 ] && ok "$name" || bad "$name: rc $rc: $(printf '%s' "$out" | tail -3 | tr '\n' '|' | cut -c1-240)"; }

# The control: the aggregator accepts a run that is complete, on one OS and on two.
good_trailers "$W/good" os1 os2
export SMOKE_LEGS_RESULT=success
must_pass "control: smoke-all accepts a complete run on two OSes" bash "$ROOT/tests/smoke-all.sh" "$W/good" os1 os2

# --- a tiny suite that uses the real tests/smoke-lib.sh with a two-call manifest: real claims, real counting, real trailer ---
# tiny_suite DIR NAME BODY FLOOR: DIR/NAME.sh runs BODY (shell text calling pa_run_fx) as part m1 of a manifest that gives m1 fx_a and fx_b
tiny_suite() {
  local d=$1 n=$2 body=$3 floor=$4
  mkdir -p "$d"
  printf '%s\n' '# tiny manifest' 'controls 0' "floor m1 $floor" 'm1 fx - fx_a' 'm1 fx - fx_b' > "$d/$n.parts"
  cat > "$d/$n.sh" <<SUITE
set -u
ROOT="$ROOT"; B="\$ROOT/bin"; T=\$(mktemp -d); trap 'rm -rf "\$T"' EXIT; fail=0
ok()  { echo "ok   \$1"; echo >> "\$T/.n.ok"; }
bad() { echo "FAIL \$1"; fail=1; echo >> "\$T/.n.bad"; }
. "\$ROOT/tests/smoke-lib.sh"
export SMOKE_PART=m1 SMOKE_MANIFEST="$d/$n.parts"
smoke_begin "\$0" || exit 1
fx_a() { ok "a asserted"; ok "a asserted again"; }
fx_b() { PA_WHY="b broke"; return 1; }
fx_b_good() { ok "b asserted"; }
$body
smoke_finish || fail=1
exit \$fail
SUITE
}
tiny_run() { bash "$1"; }

# G1: a failed fixture fails the part (the suite's own status), and the trailer says so even if a wrapper dropped that status
tiny_suite "$W/t" g1 'pa_run_fx fx_a "fixture a"
pa_run_fx fx_b "fixture b"' 2
must_fail "G1 a failed fixture fails the part" 'fail=1' tiny_run "$W/t/g1.sh"
good_trailers "$W/g1" os1; echo "smoke-part m1: ran=$(grep -cE '^m1 (mut|fx) ' "$MF") expected=$(grep -cE '^m1 (mut|fx) ' "$MF") ok=999 fail=1" > "$W/g1/os1-m1.trailer"
must_fail "G1 smoke-all rejects a trailer with fail=1 although the part's status was lost" 'm1: 1 failed' bash "$ROOT/tests/smoke-all.sh" "$W/g1" os1

# G3: a part that owns two calls and makes one is refused, in the part and in the aggregator
tiny_suite "$W/t" g3 'pa_run_fx fx_a "fixture a"
if [ -n "${NEVER_SET:-}" ]; then
pa_run_fx fx_b "fixture b"
fi' 2
must_fail "G3 a part that skips a call it owns" 'ran 1 of the 2 calls' tiny_run "$W/t/g3.sh"
good_trailers "$W/g3" os1; sed -i.bak 's/ran=[0-9]*/ran=1/' "$W/g3/os1-m1.trailer"; rm -f "$W/g3/os1-m1.trailer.bak"
must_fail "G3 smoke-all rejects ran < expected" 'm1: ran 1 of' bash "$ROOT/tests/smoke-all.sh" "$W/g3" os1

# G6: a fixture whose assert lines were removed leaves fewer ok lines than the floor
tiny_suite "$W/t" g6 'fx_a() { :; }
fx_b() { ok "b asserted"; }
pa_run_fx fx_a "fixture a"
pa_run_fx fx_b "fixture b"' 99
must_fail "G6 ok lines below the floor" 'floor is 99' tiny_run "$W/t/g6.sh"
good_trailers "$W/g6" os1; fl=$(awk '$1 == "floor" && $2 == "m2" {print $3}' "$MF"); sed -i.bak "s/ok=[0-9]*/ok=$((fl - 1))/" "$W/g6/os1-m2.trailer"; rm -f "$W/g6/os1-m2.trailer.bak"
must_fail "G6 smoke-all rejects ok below the manifest floor" 'm2: printed' bash "$ROOT/tests/smoke-all.sh" "$W/g6" os1

# G2: a trailer that is missing, empty, for another part, or not in the form
good_trailers "$W/g2a" os1; rm "$W/g2a/os1-m1.trailer"
must_fail "G2 a missing trailer" 'os1 m1: no trailer' bash "$ROOT/tests/smoke-all.sh" "$W/g2a" os1
good_trailers "$W/g2b" os1; : > "$W/g2b/os1-m2.trailer"
must_fail "G2 an empty trailer" 'os1 m2: no trailer' bash "$ROOT/tests/smoke-all.sh" "$W/g2b" os1
good_trailers "$W/g2c" os1; sed -i.bak 's/^smoke-part base/smoke-part m1/' "$W/g2c/os1-base.trailer"; rm -f "$W/g2c/os1-base.trailer.bak"
must_fail "G2 a trailer for another part" 'the trailer is for part m1' bash "$ROOT/tests/smoke-all.sh" "$W/g2c" os1
good_trailers "$W/g2d" os1; echo "smoke: all passed" > "$W/g2d/os1-base.trailer"
must_fail "G2 a line that is not a trailer" 'not in the expected form' bash "$ROOT/tests/smoke-all.sh" "$W/g2d" os1

# G4: a call written in smoke.sh that the manifest does not list; G5: a call listed twice, in two parts, or in none
mk_tree "$W/g4"; printf '%s\n' 'pa_mut zzzmutant fx_r1' >> "$W/g4/tests/smoke.sh"
must_fail "G4 a mutant in smoke.sh missing from the manifest" 'only in the file' env SMOKE_PART=base bash "$W/g4/tests/smoke.sh"
mk_tree "$W/g5a"; l=$(grep -E '^m1 mut ' "$MF" | head -1); printf '%s\n' "$l" >> "$W/g5a/tests/smoke-parts.txt"
must_fail "G5 a call listed twice" 'lists a call twice' env SMOKE_PART=m1 bash "$W/g5a/tests/smoke.sh"
mk_tree "$W/g5b"; printf '%s\n' "$(printf '%s' "$l" | sed 's/^m1 /m2 /')" >> "$W/g5b/tests/smoke-parts.txt"
must_fail "G5 a call listed in two parts" 'lists a call twice' env SMOKE_PART=m2 bash "$W/g5b/tests/smoke.sh"
mk_tree "$W/g5c"; grep -vxF "$l" "$MF" > "$W/g5c/tests/smoke-parts.txt"
must_fail "G5 a call listed in no part" 'only in the file' env SMOKE_PART=m1 bash "$W/g5c/tests/smoke.sh"
mk_tree "$W/g5d"; printf '%s\n' 'm3 mut nosuch fx_r1' >> "$W/g5d/tests/smoke-parts.txt"
must_fail "G5 a row for a part no job runs" 'not a row' env SMOKE_PART=m1 bash "$W/g5d/tests/smoke.sh"

# G7: a typo in the part name must not run nothing and pass
must_fail "G7 SMOKE_PART=typo" 'unknown SMOKE_PART' env SMOKE_PART=m11 bash "$ROOT/tests/smoke.sh"

# G8: the workflow runs every part on every OS and the aggregator waits for the matrix; a leg that never ran is a failure
ci_check() { # ci_check FILE: the matrix lists exactly the parts smoke.sh knows, and smoke-all needs the matrix job
  local f=$1 want got
  want=$(sed -n 's/^SMOKE_PARTS_ALLOWED="\(.*\)"$/\1/p' "$ROOT/tests/smoke-lib.sh")
  got=$(sed -n 's/^ *part: \[\(.*\)\] *$/\1/p' "$f" | tr -d ',' | tr -s ' ')
  [ "$got" = "$want" ] || { echo "FAIL the matrix runs parts '$got', smoke.sh knows '$want'"; return 1; }
  awk '/^  smoke-all:/ {on = 1; next} on && /^  [a-z]/ {on = 0} on && /needs:/ {print}' "$f" | grep -q 'smoke' || { echo "FAIL smoke-all does not need the smoke matrix job"; return 1; }
  awk '/^  smoke-all:/ {on = 1; next} on && /^  [a-z]/ {on = 0} on && /always\(\)/ {f = 1} END {exit !f}' "$f" || { echo "FAIL smoke-all can be skipped when a leg fails"; return 1; }
  grep -q 'smoke-all.sh' "$f" || { echo "FAIL smoke-all does not run tests/smoke-all.sh"; return 1; }
}
must_pass "G8 control: ci.yml matches the parts and the aggregator needs the matrix" ci_check "$ROOT/.github/workflows/ci.yml"
sed 's/part: \[base, m1, m2\]/part: [base, m1]/' "$ROOT/.github/workflows/ci.yml" > "$W/ci_noparts.yml"
must_fail "G8 a part missing from the matrix" 'the matrix runs parts' ci_check "$W/ci_noparts.yml"
sed 's/needs: \[plan, smoke\]/needs: [plan]/' "$ROOT/.github/workflows/ci.yml" > "$W/ci_noneeds.yml"
must_fail "G8 smoke-all without needs on the matrix" 'does not need the smoke matrix' ci_check "$W/ci_noneeds.yml"
sed 's/if: \${{ always() }}/if: success()/' "$ROOT/.github/workflows/ci.yml" > "$W/ci_skippable.yml"
must_fail "G8 smoke-all skipped when a leg fails" 'can be skipped' ci_check "$W/ci_skippable.yml"
good_trailers "$W/g8" os1; rm "$W/g8/os1-m2.trailer"
must_fail "G8 a part job that never ran" 'os1 m2: no trailer' bash "$ROOT/tests/smoke-all.sh" "$W/g8" os1 os2
good_trailers "$W/g8b" os1
must_fail "G8 an OS whose legs never ran" 'os2 base: no trailer' bash "$ROOT/tests/smoke-all.sh" "$W/g8b" os1 os2
must_fail "G8 the matrix job itself failed" 'matrix job result is' env SMOKE_LEGS_RESULT=failure bash "$ROOT/tests/smoke-all.sh" "$W/good" os1 os2

# G9: the supervisor's timeout stays 124 through the CI wrapper, and leaves no trailer for smoke-all to accept
mkdir -p "$W/g9"
cat > "$W/g9/sleeper.sh" <<SUITE
[ -n "\${SMOKE_INNER:-}" ] || exec python3 -I "$ROOT/tests/supervise.py" -- bash "\$0" "\$@"
sleep 30
SUITE
rc=0; SMOKE_TIMEOUT=2 SMOKE_SUITE="$W/g9/sleeper.sh" bash "$ROOT/tests/smoke-part-run.sh" m1 "$W/g9/m1.trailer" >/dev/null 2>&1 || rc=$?
[ "$rc" = 124 ] && [ ! -s "$W/g9/m1.trailer" ] && ok "G9 a timeout stays 124 through the wrapper and leaves no trailer" || bad "G9 the wrapper returned $rc (want 124) or wrote a trailer"
mkdir -p "$W/g9b"; cp "$W/g9/m1.trailer" "$W/g9b/os1-m1.trailer"; : > "$W/g9b/os1-base.trailer"; : > "$W/g9b/os1-m2.trailer"
must_fail "G9 smoke-all rejects the empty trailers a timed-out run leaves" 'no trailer' bash "$ROOT/tests/smoke-all.sh" "$W/g9b" os1

# G10: a part run without sourcing tests/smoke-lib.sh must fail loudly, never pass empty
mk_tree "$W/g10a"; grep -v '^\. "\$ROOT/tests/smoke-lib.sh"$' "$ROOT/tests/smoke.sh" > "$W/g10a/tests/smoke.sh"
must_fail "G10 the lib is not sourced" 'did not define what the sections call' env SMOKE_PART=m1 bash "$W/g10a/tests/smoke.sh"
mk_tree "$W/g10b"; : > "$W/g10b/tests/smoke-lib.sh"
must_fail "G10 the lib is empty" 'did not define what the sections call' env SMOKE_PART=m1 bash "$W/g10b/tests/smoke.sh"
mk_tree "$W/g10c"; rm "$W/g10c/tests/smoke-lib.sh"
must_fail "G10 the lib is missing" 'smoke-lib.sh is missing' env SMOKE_PART=m1 bash "$W/g10c/tests/smoke.sh"
# the same with the guards deleted too: the run may take its time, but it must not end in a clean trailer or status 0
mk_tree "$W/g10d"; grep -vE '^\. "\$ROOT/tests/smoke-lib.sh"$|^\[ "\$\{SMOKE_LIB_SOURCED|^smoke_begin ' "$ROOT/tests/smoke.sh" > "$W/g10d/tests/smoke.sh"
out=$(SMOKE_PART=m1 SMOKE_TIMEOUT=60 bash "$W/g10d/tests/smoke.sh" 2>&1); rc=$?
if [ "$rc" != 0 ] && ! printf '%s\n' "$out" | grep -q '^smoke-part m1: .* fail=0$'; then ok "G10 even with the guards deleted, a run without the lib ends with status $rc and no clean trailer"
else bad "G10 a run without the lib and without the guards ended with status $rc: $(printf '%s' "$out" | tail -2 | tr '\n' '|' | cut -c1-200)"; fi

[ $fail = 0 ] && echo "smoke-gates: every case refused" || echo "smoke-gates: FAILED"
exit $fail
