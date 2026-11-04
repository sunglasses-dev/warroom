#!/usr/bin/env bash
# tests/smoke.sh — end-to-end check on a throwaway board. Runs in CI and on your machine; touches nothing outside a temp dir.
#   1. a plain mention does not wake a seat; an "@SEAT ACTION:" line does, within a few seconds
#   2. a second waiter on a seat that is already held is refused
#   3. a registered job that dies wakes its owner once, and its row is dropped, also when several seats check at once
#   4. the idle guard names a silent seat once per silence, not once per prompt
#   5. install.sh refuses a settings file that is not valid JSON, or has a hook command that is not a string, and leaves it unchanged
#   6. a reopen request wakes the other seats; reopen.sh status exits 0 while they bank
#   7. wake grammar: only a first line "@SEAT ACTION:" from another author wakes (not prose, ACTIONABLE, a second line, the seat's own post)
#   8. a replaced board of the same length is read again from its start; a waiter missing its session id is refused
#   9. two arms of one seat at the same moment: exactly one wins, every round
#  10. a board that cannot be written makes post fail; a job's row is kept until its wake is on the board
#  11. the writer lock: one holder per file (also through aliases, which are refused), a crash releases it, wr_run children
#      hold no copy, subshell use is refused, every failure is visible, a board named like the waiter's marker survives
#  12. the job ledger: concurrent add of one label gives one row; a reused pid (wrong start time) counts as gone
#  13. merge-daemon (gh stubbed): a check that fails on the second look, or a required check that never appears, merges nothing
#  14-16. warroom.env is data: command text refused, the current folder ignored, shell and cpu-sentinel.py agree
#  17-20. install.sh: refuses command text in --dir, survives an interrupted write, re-points a moved clone, keeps config
#  21. every hook with a bad warroom.env exits 1 (shown, prompt goes through), never 2 (Claude Code blocks the prompt)
#  22-26. install.sh changes only entries it wrote (manifest), keeps matcher scopes, validates an existing config;
#         a key set twice is refused by both readers; two installers at once give one result
#  27-32. second review (waiter, cursor, guard, reopen): shared opt-out rows, one wake when a waiter is replaced, a board refilled in
#         place, the guard's job identity and its mark across board generations, reopen READY only with cards, quoted commands
#  33. a missing board is created without truncating (parallel first posts all survive); an uncreatable board is an error
#  34. a ledger write that fails leaves the ledger as it was and exits non-zero
#  35. pids.sh add refuses pid 0 and a pid whose start time cannot be read
#  36. cpu-sentinel reads the four-column ledger (job policy, owner alerted once); a row with a reused pid is ignored
#  37. cpu-sentinel --dry-run changes nothing; a failed alert post is retried until it lands, then not repeated
#  38. merge-daemon: an option without a value exits 2 (no spin); a dry run writes nothing on any outcome
#  39. merge-daemon readback: merged by this run / merged by another account / accepted but not merged / refused because already merged
#  40. leak-check: a bad denylist pattern or an unreadable file is an error (exit 2), run-state files in the tree are a hit
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
export WARROOM_DIR="$T/run" WARROOM_ENV="$T/none" SEATS="BOSS W1" WARROOM_POLL=1 WARROOM_MIN_GAP=0
B="$ROOT/bin"; fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
wait_exit() { for _ in $(seq 1 "$2"); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done; return 1; }

# 1. wake grammar
"$B/waiter.sh" W1 sid-w1 > "$T/w1.out" 2>/dev/null & WP=$!; sleep 2
"$B/board.sh" post BOSS "talking about @W1 in prose"
sleep 3; kill -0 $WP 2>/dev/null && ok "plain mention does not wake" || bad "plain mention woke the seat"
"$B/board.sh" post BOSS "@W1 ACTION: run the thing"
if wait_exit $WP 10 && grep -q "@W1 ACTION: run the thing" "$T/w1.out"; then ok "ACTION line wakes the seat"; else bad "ACTION line did not wake"; fi

# 2. one live waiter per seat
"$B/waiter.sh" W1 sid-a >/dev/null 2>&1 & A=$!; sleep 2
"$B/waiter.sh" W1 sid-b >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "second waiter on a held seat is refused" || bad "second waiter was not refused (rc $rc)"
kill $A 2>/dev/null

# 3. dead job wakes its owner once
sleep 30 & J=$!; "$B/pids.sh" add smoke-job $J BOSS >/dev/null; kill $J; wait $J 2>/dev/null
"$B/pids.sh" check >/dev/null; "$B/pids.sh" check >/dev/null
n=$(grep -c "@BOSS ACTION" "$("$B/board.sh" path)")
[ "$n" = 1 ] && ! grep -q smoke-job "$WARROOM_DIR/pids.tsv" && ok "dead job wakes its owner once, row dropped" || bad "dead job: $n wake lines"
# same, with several seats checking at the same moment (every waiter runs check on every poll)
sleep 30 & J=$!; "$B/pids.sh" add smoke-race $J W1 >/dev/null; kill $J; wait $J 2>/dev/null
for _ in 1 2 3 4; do "$B/pids.sh" check >/dev/null & done; wait
n=$(grep -c "job 'smoke-race'" "$("$B/board.sh" path)")
[ "$n" = 1 ] && ok "dead job wakes once with 4 checks at the same moment" || bad "concurrent check: $n wake lines"

# 4. guard once per silence
: > "$("$B/board.sh" path)"; printf '[%s · W1] hello\n' "$(date -d '-40 min' +%H:%M 2>/dev/null || date -v-40M +%H:%M)" > "$("$B/board.sh" path)"
for _ in 1 2 3; do echo '{}' | WARROOM_IDLE_MIN=30 bash "$ROOT/hooks/board-guard.sh"; sleep 1; done
n=$(grep -c "GUARD\] @W1 ACTION" "$("$B/board.sh" path)")
[ "$n" = 1 ] && ok "guard names a silent seat once per silence" || bad "guard posted $n times for one silence"

# 5. installer never overwrites unreadable settings
mkdir -p "$T/cfg" "$T/home"; printf '{"model": "x",}\n' > "$T/cfg/settings.json"; cp "$T/cfg/settings.json" "$T/orig"
HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" bash "$ROOT/install.sh" --dir "$T/home/run" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && cmp -s "$T/orig" "$T/cfg/settings.json" && ok "install refuses invalid settings, file unchanged" || bad "install on invalid settings: rc $rc"
mkdir -p "$T/i5b/cfg" "$T/i5b/home"; printf '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": ["bash", "x.sh"]}]}]}}\n' > "$T/i5b/cfg/settings.json"; cp "$T/i5b/cfg/settings.json" "$T/i5b/orig"
HOME="$T/i5b/home" CLAUDE_CONFIG_DIR="$T/i5b/cfg" bash "$ROOT/install.sh" --dir "$T/i5b/home/run" >"$T/i5b/out" 2>&1; rc=$?
[ $rc != 0 ] && cmp -s "$T/i5b/orig" "$T/i5b/cfg/settings.json" && ! grep -q Traceback "$T/i5b/out" && grep -q 'is not a string' "$T/i5b/out" && ok "install refuses a hook command that is not a string, cleanly" || bad "non-string command: rc $rc ($(grep -m1 -E 'Error|string' "$T/i5b/out"))"

# 6. a reopen request wakes the other seats, and status exits 0 while seats are still banking
: > "$("$B/board.sh" path)"; rm -f "$WARROOM_DIR"/.cursor-* "$WARROOM_DIR"/.lastwake-* "$WARROOM_DIR/.reopen-requested"
"$B/waiter.sh" W1 sid-w1r > "$T/w1r.out" 2>/dev/null & WP=$!; sleep 2
"$B/reopen.sh" arm >/dev/null
if wait_exit $WP 10 && grep -q "REOPEN REQUESTED" "$T/w1r.out"; then ok "reopen request wakes the other seats"; else bad "reopen request did not wake W1"; fi
"$B/reopen.sh" status >/dev/null; rc=$?
[ $rc = 0 ] && ok "reopen status exits 0" || bad "reopen status exited $rc"

# 7. wake grammar: first line of a post, "@SEAT ACTION:" or "@ALL ACTION:", author not the seat
: > "$("$B/board.sh" path)"
"$B/waiter.sh" W1 sid-g1 > "$T/g1.out" 2>/dev/null & WP=$!; sleep 2
"$B/board.sh" post BOSS "see @W1 ACTION: this is only quoted mid-line"
"$B/board.sh" post BOSS "the @W1 ACTIONABLE items are in the doc"
"$B/board.sh" post BOSS "status line one
@W1 ACTION: a second line is not a directive"
"$B/board.sh" post W1 "@W1 ACTION: my own post must not wake me"
sleep 4
kill -0 $WP 2>/dev/null && ok "mid-line, ACTIONABLE, second-line and own-post lines do not wake" || bad "grammar: a non-directive woke the seat: $(head -c 200 "$T/g1.out")"
"$B/board.sh" post BOSS "@W1 ACTION: the real one"
if wait_exit $WP 10 && grep -q "the real one" "$T/g1.out"; then ok "a first-line directive from another author wakes"; else bad "grammar: the real directive did not wake"; fi

# 8. a replaced board (same length, new file) is read from its start; a missing session id is refused
BF="$("$B/board.sh" path)"; printf '[00:00 · BOSS] old %s\n' 1 2 3 4 5 > "$BF"
"$B/waiter.sh" W1 sid-g2 > "$T/g2.out" 2>/dev/null & WP=$!; sleep 2
printf '[00:00 · BOSS] new %s\n' 1 2 3 4 > "$BF.new"; printf '[00:01 · BOSS] @W1 ACTION: after the swap\n' >> "$BF.new"; mv "$BF.new" "$BF"
if wait_exit $WP 10 && grep -q "after the swap" "$T/g2.out"; then ok "replaced board of the same length is read again"; else bad "rotation: directive in the replaced board was missed"; fi
"$B/waiter.sh" W1 >/dev/null 2>&1; r1=$?; "$B/waiter.sh" W1 unknown >/dev/null 2>&1; r2=$?
[ "$r1$r2" = 22 ] && ok "waiter without a real session id is refused" || bad "session id check: rc $r1 $r2"

# 9. seat claim: two arms at the same moment, five rounds, never both alive
race=0
for i in 1 2 3 4 5; do
  rm -f "$WARROOM_DIR/seats.tsv" "$WARROOM_DIR"/.cursor-*
  "$B/waiter.sh" BOSS "sid-r$i-a" >/dev/null 2>&1 & p1=$!
  "$B/waiter.sh" BOSS "sid-r$i-b" >/dev/null 2>&1 & p2=$!
  sleep 2; live=0; kill -0 $p1 2>/dev/null && live=$((live+1)); kill -0 $p2 2>/dev/null && live=$((live+1))
  [ $live = 1 ] || race=$((race+1))
  kill $p1 $p2 2>/dev/null; wait $p1 $p2 2>/dev/null
done
[ $race = 0 ] && ok "simultaneous arms of one seat: exactly one wins (5 rounds)" || bad "seat claim race: $race of 5 rounds did not have exactly one live"

# 10. an unwritable board is an error; a job row survives until its wake is on the board
(export WARROOM_DIR="$T/run2"; mkdir -p "$WARROOM_DIR/board.md"; "$B/board.sh" post BOSS "hello" >/dev/null 2>&1)
[ $? != 0 ] && ok "post to an unwritable board exits non-zero" || bad "post to an unwritable board reported success"
export WARROOM_DIR="$T/run2"; sleep 30 & J=$!; "$B/pids.sh" add keep-job $J BOSS >/dev/null; kill $J; wait $J 2>/dev/null
"$B/pids.sh" check >/dev/null 2>&1
grep -q '^keep-job' "$WARROOM_DIR/pids.tsv" && ok "job row kept while the wake could not be posted" || bad "job row was dropped without a wake"
rm -rf "$WARROOM_DIR/board.md"; : > "$WARROOM_DIR/board.md"
"$B/pids.sh" check >/dev/null 2>&1; "$B/pids.sh" check >/dev/null 2>&1
n=$(grep -c "job 'keep-job'" "$WARROOM_DIR/board.md")
[ "$n" = 1 ] && ! grep -q '^keep-job' "$WARROOM_DIR/pids.tsv" && ok "retry wakes once, then drops the row" || bad "retry: $n wake lines"
export WARROOM_DIR="$T/run"

# 11. the writer lock (docs/design/LOCK_AND_MERGE_GATE.md, Part A acceptance tests): flock on FILE.flock
LD="$T/lock"; mkdir -p "$LD"; C="$B/_common.sh"
# TRY FILE: an independent fresh process tries FILE's lock for 1 s and prints 0 (taken) or 1 (held elsewhere)
printf '%s\n' 'WARROOM_LOCK_WAIT=1; . "$WR_C"; wr_lock "$1" >/dev/null 2>&1; echo $?' > "$LD/try.sh"
export WR_C="$C" TRY="$LD/try.sh"
try() { bash "$TRY" "$1"; }
lk() { s=$1; shift; WARROOM_LOCK_WAIT=1 bash -c ". \"\$WR_C\"; $s" _ "$@" 2>&1; }   # run a snippet in a fresh shell
hold() { # hold FILE: a fresh process takes FILE's lock and keeps it (its sleeps run through wr_run); HP = its pid
  WARROOM_LOCK_WAIT=5 bash -c '. "$WR_C"; wr_lock "$1" || exit 1; : > "$1.held"; while :; do wr_run sleep 1; done' _ "$1" >/dev/null 2>&1 & HP=$!
  for _ in $(seq 1 50); do [ -e "$1.held" ] && return 0; sleep 0.1; done; return 1; }
unhold() { kill -9 "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; rm -f "$1.held"; }
ino() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

# stable_inode_contention_and_crash
: > "$LD/a"; hold "$LD/a"; i1=$(ino "$LD/a.flock"); r1=$(try "$LD/a"); unhold "$LD/a"; r2=$(try "$LD/a"); i2=$(ino "$LD/a.flock")
[ "$r1" = 1 ] && [ "$r2" = 0 ] && [ "$i1" = "$i2" ] && ok "lock: a held lock is not taken, a SIGKILLed holder releases it, the sidecar keeps its inode" || bad "lock: held try $r1, after SIGKILL $r2, inode $i1 then $i2"
! grep -nE 'wr_reclaim|\.lock/owner|mkdir[^;|]*\.lock' "$C" >/dev/null && ok "lock: no reclaim path and no .lock directory in the code" || bad "lock: an old reclaim or .lock directory path is still in _common.sh"
: > "$LD/seq"; pl=""
for k in 1 2 3 4 5 6 7 8; do
  WARROOM_LOCK_WAIT=30 bash -c '. "$WR_C"; for j in 1 2 3; do wr_lock "$1" || exit 1; echo s >> "$1"; sleep 0.05; echo e >> "$1"; wr_unlock "$1"; done' _ "$LD/seq" >/dev/null 2>&1 & pl="$pl $k:$!"
done
for p in $pl; do wait "${p#*:}"; done
want=$(for _ in $(seq 1 24); do printf se; done)
[ "$(tr -d '\n' < "$LD/seq")" = "$want" ] && ok "lock: 8 independent writers never overlap (24 sections, strictly s/e)" || bad "lock: writers overlapped or failed: $(tr -d '\n' < "$LD/seq" | head -c 60)"
# identity: one name per protected file
: > "$LD/r1"; ln -s r1 "$LD/al1"; hold "$LD/r1"
o=$(lk 'wr_lock "$1"; r=$?; [ -e /dev/fd/8 ] && echo "rc=$r fd8 open" || echo "rc=$r fd8 closed"' "$LD/al1"); unhold "$LD/r1"
case "$o" in *"is a symlink"*"rc=2 fd8 closed"*) ok "lock: a leaf symlink to a held file is refused (2) and opens nothing" ;; *) bad "lock: leaf alias: $o" ;; esac
: > "$LD/h1"; ln "$LD/h1" "$LD/h2"; : > "$LD/s1"; ln -s "$LD/elsewhere" "$LD/s1.flock"
o=$(lk 'wr_lock "$1"; echo "hard=$?"; wr_lock "$2"; echo "sidecar=$?"' "$LD/h1" "$LD/s1")
case "$o" in *"hard links"*"hard=2"*"is a symlink"*"sidecar=2"*) ok "lock: a hard-linked file and a symlinked sidecar are refused (2)" ;; *) bad "lock: aliases: $o" ;; esac
[ ! -e "$LD/elsewhere" ] && ok "lock: nothing was created through the sidecar symlink" || bad "lock: the sidecar symlink target was created"
mkdir "$LD/d"; ln -s d "$LD/dl"; : > "$LD/d/f"; hold "$LD/dl/f"; r=$(try "$LD/d/f"); unhold "$LD/dl/f"
[ "$r" = 1 ] && ok "lock: through a symlinked parent, a second process waits for the first (same key)" || bad "lock: symlinked parent gave two holders (try $r)"

# inherited_fd_lifetime: real wr_run, real nested callers
printf '%s\n' 'for f in 8 9; do [ -e /dev/fd/$f ] && echo "fd$f open"; done; echo "child ran"' > "$LD/fds.sh"
o=$(lk 'wr_lock "$1"; wr_lock "$2"; echo "-- via wr_run"; wr_run bash "$3"; echo "-- plain"; bash "$3"' "$LD/a" "$LD/r1" "$LD/fds.sh")
case "$o" in *"-- via wr_run"$'\n'"child ran"*"-- plain"$'\n'"fd8 open"$'\n'"fd9 open"*) ok "lock: a child started by wr_run holds neither lock descriptor (a plain child holds both)" ;; *) bad "lock: wr_run descriptors: $o" ;; esac
printf '%s\n' 'echo $$ > "$1"; kill -STOP $$' > "$LD/stopme.sh"
for mode in wr_run plain; do
  rm -f "$LD/cpid"; if [ $mode = wr_run ]; then run="wr_run bash"; else run="bash"; fi
  WARROOM_LOCK_WAIT=5 bash -c ". \"\$WR_C\"; wr_lock \"\$1\" || exit 1; $run \"\$2\" \"\$3\"" _ "$LD/a" "$LD/stopme.sh" "$LD/cpid" >/dev/null 2>&1 & PP=$!
  for _ in $(seq 1 50); do [ -s "$LD/cpid" ] && break; sleep 0.1; done; cp=$(cat "$LD/cpid" 2>/dev/null)
  kill -9 $PP 2>/dev/null; wait $PP 2>/dev/null; sleep 0.2
  if [ $mode = wr_run ]; then rw=$(try "$LD/a"); kill -0 "$cp" 2>/dev/null && aw=alive || aw=gone
  else rp=$(try "$LD/a"); fi
  kill -9 "$cp" 2>/dev/null; sleep 0.2
done
rf=$(try "$LD/a")
[ "$rw" = 0 ] && [ "$aw" = alive ] && [ "$rp" = 1 ] && [ "$rf" = 0 ] && ok "lock: holder killed while its stopped child runs: free with wr_run, held by a plain child until it ends" || bad "lock: release rule: wr_run $rw ($aw), plain $rp, after the child $rf"
# real callers in a copy of the tree, with board.sh replaced by a stub that reports the descriptors it got (and can stop)
TR="$LD/tree"; mkdir -p "$TR"; cp -R "$ROOT/bin" "$ROOT/hooks" "$TR/"
printf '%s\n' '#!/usr/bin/env bash' 'for f in 8 9; do [ -e /dev/fd/$f ] && echo "fd$f open"; done >> "$FDLOG"; echo "post $*" >> "$FDLOG"' '[ -z "${STUB_STOP:-}" ] || { echo $$ > "$STUB_STOP"; kill -STOP $$; }' 'exit 0' > "$TR/bin/board.sh"
R2="$LD/run2"; mkdir -p "$R2"; export FDLOG="$LD/fdlog"; : > "$FDLOG"
sleep 30 & sp=$!; WARROOM_DIR="$R2" "$TR/bin/pids.sh" add job1 $sp W1 >/dev/null; kill $sp; wait $sp 2>/dev/null
WARROOM_DIR="$R2" "$TR/bin/pids.sh" check >/dev/null 2>&1
grep -q "post GUARD" "$FDLOG" && ! grep -q "open" "$FDLOG" && ok "lock: pids.sh check posts a dead job through wr_run (the post holds no lock descriptor)" || bad "lock: pids.sh check nested post: $(tr '\n' ' ' < "$FDLOG")"
: > "$FDLOG"; printf '[00:00 · W1] hello\n' > "$R2/board.md"
WARROOM_DIR="$R2" WARROOM_IDLE_MIN=0 bash "$TR/hooks/board-guard.sh" </dev/null >/dev/null 2>&1
grep -q "post GUARD @W1 ACTION" "$FDLOG" && ! grep -q "open" "$FDLOG" && ok "lock: board-guard posts an idle seat through wr_run (no lock descriptor)" || bad "lock: board-guard nested post: $(tr '\n' ' ' < "$FDLOG")"
sleep 30 & sp=$!; WARROOM_DIR="$R2" "$TR/bin/pids.sh" add job2 $sp W1 >/dev/null; kill $sp; wait $sp 2>/dev/null; rm -f "$LD/spid"
WARROOM_DIR="$R2" STUB_STOP="$LD/spid" "$TR/bin/pids.sh" check >/dev/null 2>&1 & PP=$!
for _ in $(seq 1 50); do [ -s "$LD/spid" ] && break; sleep 0.1; done; cp=$(cat "$LD/spid" 2>/dev/null)
kill -9 $PP 2>/dev/null; wait $PP 2>/dev/null; sleep 0.2; r=$(try "$R2/pids.tsv"); kill -0 "$cp" 2>/dev/null && a=alive || a=gone; kill -9 "$cp" 2>/dev/null
[ "$r" = 0 ] && [ "$a" = alive ] && ok "lock: pids.sh check killed during its stopped post: the ledger is free while the post still runs" || bad "lock: ledger after a killed check: try $r, post $a"

# slot_ownership_and_failure_cleanup
o=$(lk 'wr_lock "$1" && wr_lock "$2"; wr_lock "$3"; echo "third=$?"; wr_unlock "$3"; printf "wrong="; wr_run bash "$TRY" "$1"; printf "wrong="; wr_run bash "$TRY" "$2"
  wr_lock "$1"; echo "same=$?"; wr_unlock "$1"; wr_lock "$3"; echo "reuse=$? s8=${_WR_SLOT8##*/} s9=${_WR_SLOT9##*/}"; printf "b="; wr_run bash "$TRY" "$2"; printf "a="; wr_run bash "$TRY" "$1"' "$LD/a" "$LD/r1" "$LD/seq" | tr '\n' ' ')
case "$o" in *"nesting limit"*"third=2 wrong=1 wrong=1 "*"already holding"*"same=2 reuse=0 s8=seq s9=r1 b=1 a=0"*) ok "lock: two slots, a third refused, a wrong-file unlock is a no-op, a same-key relock refused, out-of-order release then reacquire" ;; *) bad "lock: slots: $o" ;; esac
: > "$LD/d/g"; o=$(lk 'wr_lock "$1"; wr_lock "$2"; echo "samekey=$?"' "$LD/dl/g" "$LD/d/g")
case "$o" in *"samekey=2"*) ok "lock: a same-key relock through a symlinked parent is refused" ;; *) bad "lock: same key via parent: $o" ;; esac
hold "$LD/r1"; o=$(lk 'wr_lock "$1"; wr_lock "$2"; r=$?; [ -e /dev/fd/9 ] && f=open || f=closed; echo "second=$r s9=[$_WR_SLOT9] fd9=$f"' "$LD/a" "$LD/r1"); unhold "$LD/r1"
case "$o" in *"held by another writer"*"second=1 s9=[] fd9=closed"*) ok "lock: a failed second acquire leaves slot 9 empty and fd 9 closed" ;; *) bad "lock: failed second acquire: $o" ;; esac
o=$(lk 'chk() { for fn in wr_lock wr_unlock wr_run; do a=$1; [ $fn = wr_run ] && a=true; x=$($fn "$a" 2>/dev/null); r1=$?; ($fn "$a" 2>/dev/null); r2=$?; echo | $fn "$a" 2>/dev/null; r3=$?; printf "%s " "$fn=$r1$r2$r3"; done; }
  printf "none: "; chk "$1"; wr_lock "$2"; printf "held: "; chk "$2"; printf "still="; wr_run bash "$TRY" "$2"
  wr_unlock "$2"; printf "after: "; chk "$2"; printf "free="; wr_run bash "$TRY" "$2"; [ -e /dev/fd/8 ] && echo "fd8=open" || echo "fd8=closed"' "$LD/a" "$LD/r1" | tr '\n' ' ')
n2=$(printf '%s\n' "$o" | grep -o 'wr_[a-z]*=222' | wc -l | tr -d ' ')
[ "$n2" = 9 ] && case "$o" in *"still=1 "*"free=0 fd8=closed"*) true ;; *) false ;; esac && ok "lock: wr_lock, wr_unlock and wr_run in ( ), \$( ) and a pipeline return 2 in all three states and open nothing" || bad "lock: subshell refusal ($n2 of 9): $(printf '%s' "$o" | tr '\n' ' ')"
if [ "$(id -u)" != 0 ]; then
  mkdir "$LD/ro"; chmod 555 "$LD/ro"; o=$(lk 'wr_lock "$1"; echo "rc=$? s8=[$_WR_SLOT8] fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"' "$LD/ro/f"); chmod 755 "$LD/ro"
  case "$o" in *"could not open lock file"*"rc=1 s8=[] fd8=closed"*) ok "lock: an unwritable folder prints its own line, leaves the slot empty and fd 8 closed" ;; *) bad "lock: open failure: $o" ;; esac
fi
mkdir -p "$LD/py3" "$LD/nopy"; printf '#!/bin/sh\necho "stub helper says no" >&2\nexit 3\n' > "$LD/py3/python3"; chmod +x "$LD/py3/python3"
for t in dirname basename stat sed head cat; do p=$(command -v $t) && ln -s "$p" "$LD/nopy/$t"; done
o=$(lk 'PATH="$2:$PATH"; wr_lock "$1"; echo "rc=$? s8=[$_WR_SLOT8] fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"' "$LD/a" "$LD/py3")
case "$o" in *"lock helper failed"*"stub helper says no"*"exit 3"*"rc=1 s8=[] fd8=closed"*) ok "lock: a helper that exits 3 prints its own line and cleans up" ;; *) bad "lock: helper exit 3: $o" ;; esac
o=$(lk 'PATH="$2"; wr_lock "$1"; echo "rc=$? s8=[$_WR_SLOT8] fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"' "$LD/a" "$LD/nopy")
case "$o" in *"lock helper failed"*"exit 127"*"rc=1 s8=[] fd8=closed"*) ok "lock: python3 missing from PATH prints its own line and cleans up" ;; *) bad "lock: helper missing: $o" ;; esac

# caller_timeout_visibility: outer and nested lock failures, one caller at a time, no unlocked change
R3="$LD/run3"; mkdir -p "$R3"
sleep 30 & sp=$!; WARROOM_DIR="$R3" "$B/pids.sh" add job3 $sp W1 >/dev/null; kill $sp; wait $sp 2>/dev/null
cp "$R3/pids.tsv" "$LD/ledger.before"; hold "$R3/pids.tsv"
e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/pids.sh" add job4 $$ W1 2>&1 >/dev/null); r=$?; unhold "$R3/pids.tsv"
[ $r = 1 ] && case "$e" in *"could not lock the job ledger; nothing changed"*) true ;; *) false ;; esac && cmp -s "$R3/pids.tsv" "$LD/ledger.before" && ok "lock: pids.sh with the ledger busy says so, exits 1, ledger unchanged" || bad "lock: busy ledger: rc $r, '$e'"
hold "$R3/pids.tsv"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/waiter.sh" W1 sid-v 2>&1 >/dev/null & wp=$!; sleep 4; kill $wp 2>/dev/null; wait $wp 2>/dev/null); unhold "$R3/pids.tsv"
case "$e" in *"could not lock the job ledger"*) ok "lock: a busy ledger during the waiter's job check reaches the waiter's stderr" ;; *) bad "lock: waiter hid the ledger failure: '$e'" ;; esac
b0=$(cksum < "$R3/board.md"); hold "$R3/board.md"
e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/pids.sh" check 2>&1 >/dev/null); unhold "$R3/board.md"
grep -q "job3" "$R3/pids.tsv" && [ "$(cksum < "$R3/board.md")" = "$b0" ] && case "$e" in *"could not lock the board"*) true ;; *) false ;; esac && ok "lock: pids.sh check with the board busy keeps the row, shows the board error, board unchanged" || bad "lock: check with a busy board: '$e', row $(grep -c job3 "$R3/pids.tsv")"
printf '[00:00 · W1] hello\n' > "$R3/board.md"; b0=$(cksum < "$R3/board.md"); : > "$R3/.guard-W1"; hold "$R3/.guard-W1"
e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); r=$?; unhold "$R3/.guard-W1"
[ $r = 0 ] && [ "$(cksum < "$R3/board.md")" = "$b0" ] && case "$e" in *"board-guard: skipped W1 (mark busy)"*) true ;; *) false ;; esac && ok "lock: board-guard with the mark busy says so, exits 0, posts nothing" || bad "lock: busy mark: rc $r, '$e'"
hold "$R3/board.md"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); unhold "$R3/board.md"
[ ! -s "$R3/.guard-W1" ] && [ "$(cksum < "$R3/board.md")" = "$b0" ] && case "$e" in *"could not lock the board"*) true ;; *) false ;; esac && ok "lock: board-guard with the board busy shows the error and leaves the mark unchanged" || bad "lock: guard with a busy board: '$e', mark '$(cat "$R3/.guard-W1")'"
# the waiter's two arming locks, cursor then registry: each failure says so; a registry failure releases the cursor
: > "$R3/.cursor-W1"; hold "$R3/.cursor-W1"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/waiter.sh" W1 sid-c 2>&1 >/dev/null); r=$?; unhold "$R3/.cursor-W1"
[ $r = 1 ] && case "$e" in *"could not lock the cursor of seat W1"*) true ;; *) false ;; esac && ok "lock: waiter with its cursor busy says so and exits 1" || bad "lock: busy cursor: rc $r, '$e'"
hold "$R3/seats.tsv"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/waiter.sh" W1 sid-c 2>&1 >/dev/null); r=$?; c=$(try "$R3/.cursor-W1"); unhold "$R3/seats.tsv"
[ $r = 1 ] && [ "$c" = 0 ] && case "$e" in *"could not lock the seat registry"*) true ;; *) false ;; esac && ok "lock: waiter with the registry busy says so, exits 1 and releases its cursor" || bad "lock: busy registry: rc $r, cursor try $c, '$e'"
# bootstrap: a board with content stays byte-identical when 8 processes source _common.sh at once
printf 'line one\nline two\n' > "$R3/board.md"; b0=$(cksum < "$R3/board.md"); pl=""
for k in 1 2 3 4 5 6 7 8; do WARROOM_DIR="$R3" bash -c '. "$1"' _ "$C" >/dev/null 2>&1 & pl="$pl $!"; done; wait $pl 2>/dev/null
[ "$(cksum < "$R3/board.md")" = "$b0" ] && ok "lock: sourcing _common.sh never changes a board that has content" || bad "lock: bootstrap changed the board"

# FIX 1: a BOARD configured as the waiter's own marker name (.lastwake-W1) is never emptied by a wake
R4="$LD/run4"; mkdir -p "$R4"; printf '%s\n' "[00:00 · BOSS] forty-four bytes of board here." > "$R4/.lastwake-W1"; h0=$(head -c 44 "$R4/.lastwake-W1" | cksum)
WARROOM_DIR="$R4" BOARD=.lastwake-W1 "$B/waiter.sh" W1 sid-l > "$LD/w4.out" 2>&1 & wp=$!; sleep 2
WARROOM_DIR="$R4" BOARD=.lastwake-W1 "$B/board.sh" post BOSS "@W1 ACTION: wake on a board named like the marker"
wait_exit $wp 10; kill $wp 2>/dev/null
[ "$(head -c 44 "$R4/.lastwake-W1" | cksum)" = "$h0" ] && grep -q "wake on a board named like the marker" "$R4/.lastwake-W1" && grep -q "@W1 ACTION" "$LD/w4.out" && ok "lock: a wake on a board named .lastwake-SEAT leaves the board's bytes intact (touch, not truncate)" || bad "lock: marker-named board: $(wc -c < "$R4/.lastwake-W1") bytes, waiter: $(head -c 120 "$LD/w4.out")"
! grep -nE '(^|[;&|] *): > "\$LAST"' "$B/waiter.sh" >/dev/null && ok "lock: the waiter never truncates its wake timestamp" || bad "lock: waiter.sh still truncates \$LAST"

# lock_order_and_upgrade_boundary (lint only, not evidence of safety)
code="$B/board.sh $B/pids.sh $B/waiter.sh $B/reopen.sh $ROOT/hooks/board-guard.sh"
sub='\$\([^)]*wr_(lock|unlock|run)|(^|[^|])\| *wr_(lock|unlock|run)'
! grep -nE "$sub" $code >/dev/null && ok "lock lint: no lock call inside \$( ) or after a pipe" || bad "lock lint: a lock call runs in a subshell: $(grep -nE "$sub" $code | head -2)"
! grep -nE '(^|[^0-9&<>])[89]>|>&[89]|<&[89]' $code "$ROOT/tools/"*.sh >/dev/null && ok "lock lint: fds 8 and 9 are used only by _common.sh" || bad "lock lint: another script uses fd 8 or 9"
grep -q "stop every session, waiter and job using this run directory" "$ROOT/README.md" && ok "lock lint: the README carries the upgrade step" || bad "lock lint: README upgrade step missing"

# 8 simultaneous posts to a missing board through board.sh all land, no error (5 rounds)
n=0; ne=0
for r in 1 2 3 4 5; do
  R5="$LD/run5.$r"; pl=""
  for k in 1 2 3 4 5 6 7 8; do WARROOM_DIR="$R5" "$B/board.sh" post W1 "p$k" >/dev/null 2>>"$LD/e5" & pl="$pl $!"; done
  wait $pl 2>/dev/null; n=$(grep -c ' p[1-8]$' "$R5/board.md" 2>/dev/null); ne=$(wc -l < "$LD/e5" 2>/dev/null | tr -d ' ')
  [ "$n" = 8 ] && [ "${ne:-0}" = 0 ] || break
done
[ "$n" = 8 ] && [ "${ne:-0}" = 0 ] && ok "lock: 8 simultaneous board.sh posts to a missing board all land, no error (5 rounds)" || bad "lock: 8-way post: $n of 8 landed, $ne error line(s): $(head -1 "$LD/e5" 2>/dev/null)"

# 12. job ledger: one row per label under concurrent add; a reused pid counts as gone
: > "$("$B/board.sh" path)"; : > "$WARROOM_DIR/pids.tsv"
sleep 30 & J=$!; aps=""
for _ in 1 2 3 4; do "$B/pids.sh" add dup-job $J BOSS >/dev/null 2>&1 & aps="$aps $!"; done; wait $aps 2>/dev/null
n=$(grep -c '^dup-job' "$WARROOM_DIR/pids.tsv")
[ "$n" = 1 ] && ok "concurrent add of one label leaves one row" || bad "concurrent add: $n rows"
awk -F'\t' 'BEGIN{OFS="\t"} {$4="Thu Jan  1 00:00:00 1970"; print}' "$WARROOM_DIR/pids.tsv" > "$T/pids.mod" && cp "$T/pids.mod" "$WARROOM_DIR/pids.tsv"
"$B/pids.sh" check >/dev/null 2>&1
grep -q "job 'dup-job'" "$("$B/board.sh" path)" && ok "a pid with a different start time counts as gone" || bad "reused pid was treated as the same job"
kill $J 2>/dev/null; wait $J 2>/dev/null

# 13. merge-daemon with a stubbed gh
SD="$T/stub"; mkdir -p "$SD"; export GH_STUB_DIR="$SD"; SHA=$(printf 'a%.0s' $(seq 1 40))
cat > "$SD/gh" <<'STUB'
#!/usr/bin/env bash
d=$GH_STUB_DIR
case "$*" in
  *"pr merge"*) touch "$d/merged"; exit 0 ;;
  *mergeCommit*) echo "feedface"; exit 0 ;;
  *statusCheckRollup*)
    if [ -e "$d/merged" ]; then cat "$d/view.merged"; exit 0; fi
    n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
    if [ $n -le 1 ] || [ ! -e "$d/view.2" ]; then cat "$d/view.1"; else cat "$d/view.2"; fi ;;
esac
STUB
chmod +x "$SD/gh"
mk() { # mk STATE NAME CONCLUSION...
  python3 - "$SHA" "$@" <<'PY'
import json, sys
sha, state = sys.argv[1], sys.argv[2]; rest = sys.argv[3:]
checks = [{"__typename": "CheckRun", "name": rest[i], "status": "COMPLETED", "conclusion": rest[i+1]} for i in range(0, len(rest), 2)]
print(json.dumps({"state": state, "headRefOid": sha, "title": "a title", "statusCheckRollup": checks}))
PY
}
mk MERGED build SUCCESS > "$SD/view.merged"
runmd() { rm -f "$SD/merged" "$SD/count"; PATH="$SD:$PATH" "$B/merge-daemon.sh" 7 --head "$SHA" --poll 1 --timeout 3 "$@" >/dev/null 2>&1; }
mk OPEN build SUCCESS > "$SD/view.1"; mk OPEN build FAILURE > "$SD/view.2"
runmd --require build; rc=$?
[ $rc = 1 ] && [ ! -e "$SD/merged" ] && ok "merge-daemon: a check that fails on the confirming look merges nothing" || bad "merge-daemon merged or passed after a late failure (rc $rc)"
rm -f "$SD/view.2"; mk OPEN lint SUCCESS > "$SD/view.1"; runmd --require build; rc=$?
[ $rc = 1 ] && [ ! -e "$SD/merged" ] && ok "merge-daemon: a required check that never appears merges nothing" || bad "merge-daemon merged without the required check (rc $rc)"
mk OPEN build SUCCESS lint NEUTRAL > "$SD/view.1"; runmd --require build; rc=$?
[ $rc = 0 ] && [ -e "$SD/merged" ] && ok "merge-daemon: green on two looks with the required check merges, pinned" || bad "merge-daemon did not merge a green PR (rc $rc)"
runmd --head "${SHA%a}b"; rc=$?
[ $rc = 1 ] && [ ! -e "$SD/merged" ] && ok "merge-daemon: a branch that is not at the pinned head merges nothing" || bad "merge-daemon ignored the pinned head (rc $rc)"

# 14. config is data, never code: a $(...) in warroom.env is refused and does not run
printf 'WARROOM_DIR="$(touch %s/m-env)"\n' "$T" > "$T/bad.env"
WARROOM_ENV="$T/bad.env" "$B/board.sh" path >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && [ ! -e "$T/m-env" ] && ok "command text in warroom.env is refused, not run" || bad "bad warroom.env: rc $rc, ran=$([ -e "$T/m-env" ] && echo yes || echo no)"

# 15. a warroom.env in the current folder is ignored (only $WARROOM_ENV or ~/.warroom/warroom.env are read)
mkdir -p "$T/cwd" "$T/h8"; printf 'SEATS="EVIL"\nWARROOM_DIR="%s/cwd-run"\n' "$T" > "$T/cwd/warroom.env"
got=$(cd "$T/cwd" && env -u SEATS -u WARROOM_DIR -u WARROOM_ENV HOME="$T/h8" bash "$B/board.sh" path 2>&1)
[ "$got" = "$T/h8/warroom-run/board.md" ] && ok "warroom.env in the current folder is ignored" || bad "cwd config was read: $got"

# 16. the shell scripts and cpu-sentinel.py resolve the same config
printf 'SEATS="A1 B2"\nWARROOM_DIR="$HOME/run9"\nBOARD="b9.md"\n' > "$T/s9.env"
sh_cfg=$(env -u SEATS -u WARROOM_DIR HOME="$T/h8" WARROOM_ENV="$T/s9.env" bash -c '. "$1/_common.sh"; printf "SEATS=%s\nWARROOM_DIR=%s\nBOARD_FILE=%s\n" "$SEATS" "$WARROOM_DIR" "$BOARD_FILE"' _ "$B")
py_cfg=$(env -u SEATS -u WARROOM_DIR HOME="$T/h8" WARROOM_ENV="$T/s9.env" python3 "$B/cpu-sentinel.py" --config)
[ "$sh_cfg" = "$py_cfg" ] && ok "shell and cpu-sentinel.py read the same config" || bad "config differs: [$sh_cfg] vs [$py_cfg]"
mkdir -p "$T/p9"; cp "$T/s9.env" "$T/p9/\$(touch m-py)"
(cd "$T/p9" && WARROOM_ENV="$T/p9/\$(touch m-py)" python3 "$B/cpu-sentinel.py" --config >/dev/null 2>&1)
[ ! -e "$T/p9/m-py" ] && ok "cpu-sentinel.py never hands the config path to a shell" || bad "cpu-sentinel.py ran text from the config path"

# 17. install.sh refuses a --dir with command text and writes nothing
mkdir -p "$T/i10/cfg" "$T/i10/home"
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i10/home" CLAUDE_CONFIG_DIR="$T/i10/cfg" bash "$ROOT/install.sh" --dir "$T/i10/\$(touch $T/m-dir)" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && [ ! -e "$T/m-dir" ] && [ ! -e "$T/i10/home/.warroom" ] && [ ! -e "$T/i10/cfg/settings.json" ] \
  && ok "install refuses \$(...) in --dir and writes nothing" || bad "install --dir with command text: rc $rc"

# 18. an interrupted settings write leaves settings.json exactly as it was (the write goes to a temp file first)
mkdir -p "$T/i11/cfg" "$T/i11/home"
# bash counts ulimit -f in 1024-byte blocks: 8 = 8 KiB. The file fits under it; the file with the hooks added does not.
python3 -c 'import json,sys; json.dump({"model": "x", "pad": "p" * 7950}, open(sys.argv[1], "w"))' "$T/i11/cfg/settings.json"
cp "$T/i11/cfg/settings.json" "$T/i11/orig"
( ulimit -f 8; env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i11/home" CLAUDE_CONFIG_DIR="$T/i11/cfg" bash "$ROOT/install.sh" --dir "$T/i11/run" >/dev/null 2>&1 ); rc=$?
[ $rc != 0 ] && cmp -s "$T/i11/orig" "$T/i11/cfg/settings.json" && ok "interrupted settings write leaves the file intact, install fails" \
  || bad "interrupted write: rc $rc, file $(cmp -s "$T/i11/orig" "$T/i11/cfg/settings.json" && echo same || echo CHANGED)"

# 19. reinstall: an entry this installer wrote (listed in its manifest) from a clone that has moved is pointed here,
#     never doubled, and a second run changes nothing
mkdir -p "$T/i12/cfg" "$T/i12/home/.warroom"
printf '{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash /gone/clone/hooks/board-tail.sh"}]}]}}\n' > "$T/i12/cfg/settings.json"
python3 -c 'import json,os,sys; json.dump({"version": 1, "settings": {os.path.realpath(sys.argv[1]): [{"event": "UserPromptSubmit", "matcher": None, "command": "bash /gone/clone/hooks/board-tail.sh", "script": "board-tail.sh"}]}}, open(sys.argv[2], "w"))' "$T/i12/cfg/settings.json" "$T/i12/home/.warroom/installed-hooks.json"
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i12/home" CLAUDE_CONFIG_DIR="$T/i12/cfg" bash "$ROOT/install.sh" --dir "$T/i12/run" >/dev/null 2>&1
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i12/home" CLAUDE_CONFIG_DIR="$T/i12/cfg" bash "$ROOT/install.sh" >"$T/i12/out2" 2>&1
n=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["hooks"]; print(sum(len(g["hooks"]) for e in d.values() for g in e), sum("/gone/" in h["command"] for e in d.values() for g in e for h in g["hooks"]))' "$T/i12/cfg/settings.json")
nb=0; for f in "$T"/i12/cfg/settings.json.warroom-bak-*; do [ -e "$f" ] && nb=$((nb + 1)); done
[ "$n" = "4 0" ] && [ "$nb" = 1 ] && grep -q "nothing to change" "$T/i12/out2" && ok "moved clone (in the manifest) re-pointed, second run changes nothing" || bad "reinstall: entries/old '$n', backups $nb"

# 20. reinstall with other seats than the existing config is refused, not silently ignored
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i12/home" CLAUDE_CONFIG_DIR="$T/i12/cfg" bash "$ROOT/install.sh" --seats "X1 X2" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'SEATS="BOSS MANAGER W1 W2"' "$T/i12/home/.warroom/warroom.env" && ok "install refuses seats that differ from the existing config" || bad "install with other seats: rc $rc"

# 21. a hook never exits 2 on a bad config: Claude Code would block the prompt, in every session on the machine
hr=""; for h in board-guard board-tail waiter-check; do
  printf '{"session_id": "sid-h21"}' | WARROOM_ENV="$T/bad.env" bash "$ROOT/hooks/$h.sh" >/dev/null 2>&1; hr="$hr $h=$?"
done
[ "$hr" = " board-guard=1 board-tail=1 waiter-check=1" ] && [ ! -e "$T/m-env" ] && ok "hooks exit 1, not 2, on a bad warroom.env" || bad "hook exit codes on a bad config:$hr"

# 22. a hook entry the installer did not write is left alone, even when its file name matches and its path is gone
mkdir -p "$T/i22/cfg" "$T/i22/home"
printf '{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash /missing/other-tool/hooks/board-tail.sh"}]}]}}\n' > "$T/i22/cfg/settings.json"
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i22/home" CLAUDE_CONFIG_DIR="$T/i22/cfg" bash "$ROOT/install.sh" --dir "$T/i22/run" >"$T/i22/out" 2>&1; rc=$?
n=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["hooks"]; print(sum("/missing/other-tool/" in h["command"] for e in d.values() for g in e for h in g["hooks"]), sum(len(g["hooks"]) for e in d.values() for g in e))' "$T/i22/cfg/settings.json")
[ $rc = 0 ] && [ "$n" = "1 5" ] && grep -q "left alone" "$T/i22/out" && ok "an entry the installer did not write is kept as it was" || bad "foreign hook: rc $rc, kept/total '$n'"

# 23. our own entry under two matcher scopes (startup, resume) keeps both scopes
mkdir -p "$T/i23/cfg" "$T/i23/home"
python3 -c 'import json,shlex,sys; c="bash "+shlex.quote(sys.argv[2]+"/hooks/waiter-check.sh"); json.dump({"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": c}]}, {"matcher": "resume", "hooks": [{"type": "command", "command": c}]}]}}, open(sys.argv[1], "w"))' "$T/i23/cfg/settings.json" "$ROOT"
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i23/home" CLAUDE_CONFIG_DIR="$T/i23/cfg" bash "$ROOT/install.sh" --dir "$T/i23/run" >/dev/null 2>&1; rc=$?
m=$(python3 -c 'import json,sys; print(" ".join(sorted(g.get("matcher","-") for g in json.load(open(sys.argv[1]))["hooks"]["SessionStart"])))' "$T/i23/cfg/settings.json")
[ $rc = 0 ] && [ "$m" = "resume startup" ] && ok "two matcher scopes of one entry are both kept" || bad "matcher scopes after install: rc $rc, '$m'"

# 24. an existing warroom.env whose seats break the rules stops the install before anything is written
mkdir -p "$T/i24/cfg" "$T/i24/home/.warroom"; printf 'SEATS="ALL"\n' > "$T/i24/home/.warroom/warroom.env"
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i24/home" CLAUDE_CONFIG_DIR="$T/i24/cfg" bash "$ROOT/install.sh" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && [ ! -e "$T/i24/cfg/settings.json" ] && [ ! -e "$T/i24/home/warroom-run" ] && ok "install refuses an existing config with reserved seats" || bad "existing SEATS=ALL: rc $rc"

# 25. a key set twice in warroom.env is refused by the shell scripts and by cpu-sentinel.py alike
printf 'WARROOM_DIR="%s"\nWARROOM_DIR="%s"\n' "$T/dup-first" "$T/dup-last" > "$T/dup.env"
env -u SEATS -u WARROOM_DIR WARROOM_ENV="$T/dup.env" bash -c '. "$1/bin/_common.sh"' _ "$ROOT" >/dev/null 2>&1; r1=$?
env -u SEATS -u WARROOM_DIR WARROOM_ENV="$T/dup.env" python3 "$B/cpu-sentinel.py" --config >/dev/null 2>&1; r2=$?
[ $r1 != 0 ] && [ $r2 != 0 ] && [ ! -e "$T/dup-first" ] && [ ! -e "$T/dup-last" ] && ok "a key set twice is refused by both readers" || bad "duplicate key: shell rc $r1, sentinel rc $r2"

# 26. two installers at the same moment: both finish, the settings hold each entry once and the manifest lists them
mkdir -p "$T/i26/cfg" "$T/i26/home"; printf '{"model": "x"}\n' > "$T/i26/cfg/settings.json"
for i in 1 2; do env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i26/home" CLAUDE_CONFIG_DIR="$T/i26/cfg" bash "$ROOT/install.sh" --dir "$T/i26/run" >"$T/i26/o$i" 2>&1 & done; wait
n=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2])); print(d["model"], sum(len(g["hooks"]) for e in d["hooks"].values() for g in e), sum(len(v) for v in m["settings"].values()))' "$T/i26/cfg/settings.json" "$T/i26/home/.warroom/installed-hooks.json" 2>/dev/null)
[ "$n" = "x 4 4" ] && ok "two installers at once: one result, manifest matches" || bad "concurrent install: '$n' ($(cat "$T/i26/o1" "$T/i26/o2" | grep -i -m1 -E 'could not|changed|another'))"
# 27. two sessions opting out (NONE) keep both rows; a seat's own arm still replaces only that seat's row (FIX 5)
rm -f "$WARROOM_DIR/seats.tsv"
"$B/waiter.sh" NONE sid-n1 >/dev/null 2>&1; "$B/waiter.sh" NONE sid-n2 >/dev/null 2>&1; "$B/waiter.sh" NONE sid-n1 >/dev/null 2>&1
n=$(awk -F'\t' '$2=="NONE"' "$WARROOM_DIR/seats.tsv" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok "a second opt-out does not delete the first" || bad "NONE rows after three opt-outs by two sessions: $n"

# 28. a waiter replaced by a newer arm of the same session never delivers a second wake (FIX 3), 6 rounds
BF="$("$B/board.sh" path)"; dup=0
for i in 1 2 3 4 5 6; do
  : > "$BF"; rm -f "$WARROOM_DIR"/.cursor-* "$WARROOM_DIR"/.lastwake-* "$WARROOM_DIR/seats.tsv"
  "$B/waiter.sh" W1 "sid-d$i" > "$T/d_a.out" 2>/dev/null & pa=$!; sleep 2
  "$B/board.sh" post BOSS "@W1 ACTION: round $i"
  sleep 0.$((i * 2))                                   # a different distance from the wake each round
  "$B/waiter.sh" W1 "sid-d$i" > "$T/d_b.out" 2>/dev/null & pb=$!
  sleep 4; kill $pa $pb 2>/dev/null; wait $pa $pb 2>/dev/null
  w=$(cat "$T/d_a.out" "$T/d_b.out" | grep -c "WAKE -> W1"); [ "$w" = 1 ] || { dup=$((dup + 1)); echo "   round $i: $w wakes"; }
done
[ $dup = 0 ] && ok "replacing a waiter at the moment of a wake gives exactly one wake (6 rounds)" || bad "same-session replacement: $dup of 6 rounds did not give exactly one wake"

# 29. a board emptied in place and refilled (same file, same first line, longer) is read again; so is board.sh tail (FIX 4)
printf '[00:00 · BOSS] head\n[00:00 · BOSS] old 1\n[00:00 · BOSS] old 2\n[00:00 · BOSS] old 3\n[00:00 · BOSS] old 4\n[00:00 · BOSS] old 5\n' > "$BF"
rm -f "$WARROOM_DIR"/.cursor-* "$WARROOM_DIR"/.lastwake-* "$WARROOM_DIR/seats.tsv" "$WARROOM_DIR"/.anchor-*
"$B/board.sh" tail BOSS >/dev/null
"$B/waiter.sh" W1 sid-t1 > "$T/t1.out" 2>/dev/null & WP=$!; sleep 2
printf '[00:00 · BOSS] head\n[00:00 · BOSS] new 1\n[00:01 · BOSS] @W1 ACTION: after the refill\n[00:01 · BOSS] new 3\n[00:01 · BOSS] new 4\n[00:01 · BOSS] new 5\n[00:01 · BOSS] new 6\n[00:01 · BOSS] new 7\n' > "$BF"
if wait_exit $WP 10 && grep -q "after the refill" "$T/t1.out"; then ok "board emptied in place and refilled is read again by the waiter"; else bad "refill in place: the waiter missed the directive"; fi
c=$("$B/board.sh" tail BOSS | grep -c "after the refill")
[ "$c" = 1 ] && ok "board.sh tail reads a refilled board again" || bad "board.sh tail after a refill printed the directive $c times"

# 30. the idle guard: a reused pid does not count as a running job; a new silence after a replaced board is named again (FIX 12)
past=$(date -d '-40 min' +%H:%M 2>/dev/null || date -v-40M +%H:%M)
: > "$WARROOM_DIR/pids.tsv"; rm -f "$WARROOM_DIR"/.guard-*; printf '[%s · W1] hello\n' "$past" > "$BF"
sleep 60 & GJ=$!; "$B/pids.sh" add guard-job $GJ W1 >/dev/null
echo '{}' | WARROOM_IDLE_MIN=30 bash "$ROOT/hooks/board-guard.sh"
a=$(grep -c "GUARD\] @W1 ACTION" "$BF")
awk -F'\t' -v OFS='\t' '{ $4 = "Mon Jan  1 00:00:00 2001"; print }' "$WARROOM_DIR/pids.tsv" > "$WARROOM_DIR/pids.new" && mv "$WARROOM_DIR/pids.new" "$WARROOM_DIR/pids.tsv"
echo '{}' | WARROOM_IDLE_MIN=30 bash "$ROOT/hooks/board-guard.sh"
b=$(grep -c "GUARD\] @W1 ACTION" "$BF"); kill $GJ 2>/dev/null; wait $GJ 2>/dev/null
[ "$a$b" = 01 ] && ok "guard: a live job keeps the seat busy; a reused pid does not" || bad "guard with live job / reused pid: $a then $b lines"
: > "$WARROOM_DIR/pids.tsv"; rm -f "$WARROOM_DIR"/.guard-*; printf '[%s · W1] hello\n' "$past" > "$BF"
echo '{}' | WARROOM_IDLE_MIN=30 bash "$ROOT/hooks/board-guard.sh"
printf '[%s · W1] a different first post\n' "$past" > "$BF.new"; mv "$BF.new" "$BF"
echo '{}' | WARROOM_IDLE_MIN=30 bash "$ROOT/hooks/board-guard.sh"
n=$(grep -c "GUARD\] @W1 ACTION" "$BF")
[ "$n" = 1 ] && ok "guard names a silence again after the board was replaced (same line number)" || bad "guard after a replaced board: $n lines in the new board"

# 31. reopen build is READY only with banked seats and current cards; otherwise it refuses, or writes a marked draft (FIX 13)
: > "$BF"; rm -rf "$WARROOM_DIR/.reopen-requested" "$WARROOM_DIR/cards" "$WARROOM_DIR"/REOPEN_MESSAGES_*
"$B/reopen.sh" arm >/dev/null
"$B/reopen.sh" build >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && ! ls "$WARROOM_DIR"/REOPEN_MESSAGES_* >/dev/null 2>&1 && ! grep -q "REOPEN READY" "$BF" && ok "reopen build refuses when no seat has a card or has banked" || bad "reopen build without cards: rc $rc"
"$B/reopen.sh" build --force >/dev/null 2>&1
S=$(ls "$WARROOM_DIR"/REOPEN_MESSAGES_*.md 2>/dev/null | head -1)
[ -n "$S" ] && grep -q "INCOMPLETE DRAFT" "$S" && ! grep -q "Close every window" "$S" && grep -q "REOPEN DRAFT" "$BF" && ! grep -q "REOPEN READY" "$BF" \
  && ok "reopen build --force writes a draft that says not to close windows" || bad "reopen build --force sheet/board lines wrong"
sleep 1; mkdir -p "$WARROOM_DIR/cards"
for t in BOSS W1; do echo "card of $t" > "$WARROOM_DIR/cards/${t}_REOPEN_smoke.md"; "$B/board.sh" post "$t" "banked for reopen" >/dev/null; done
"$B/reopen.sh" build >/dev/null 2>&1; rc=$?
S=$(ls "$WARROOM_DIR"/REOPEN_MESSAGES_*.md 2>/dev/null | head -1)
[ $rc = 0 ] && grep -q "Close every window" "$S" && ! grep -q "INCOMPLETE" "$S" && grep -q "REOPEN READY" "$BF" \
  && ok "reopen build is READY once every seat has banked and has a current card" || bad "reopen build with cards and banks: rc $rc"
rm -f "$WARROOM_DIR/.reopen-requested"

# 32. no error text on the first arm; printed commands are shell-quoted when the install path has a space (RIDER 2)
rm -f "$WARROOM_DIR"/.cursor-* "$WARROOM_DIR/seats.tsv"
"$B/waiter.sh" W1 sid-q1 >/dev/null 2> "$T/q1.err" & WP=$!; sleep 2; kill $WP 2>/dev/null; wait $WP 2>/dev/null
[ "$(wc -l < "$T/q1.err" | tr -d ' ')" = 1 ] && grep -q '^armed W1' "$T/q1.err" && ok "first arm prints only the armed line on stderr" || bad "first arm stderr: $(head -c 200 "$T/q1.err")"
mkdir -p "$T/sp dir" && cp -R "$ROOT/bin" "$ROOT/hooks" "$T/sp dir/"
bn=$(printf '{"session_id": "s-q2"}' | bash "$T/sp dir/hooks/waiter-check.sh" 2>&1)
cd_=$(bash "$T/sp dir/bin/reopen.sh" card W1 2>/dev/null)
case "$bn" in *'sp\ dir/bin/waiter.sh'*) q1=1 ;; *) q1=0 ;; esac
case "$cd_" in *'sp\ dir/bin/waiter.sh'*) q2=1 ;; *) q2=0 ;; esac
[ "$q1$q2" = 11 ] && ok "banner and reopen card print a quoted waiter command for a path with a space" || bad "quoting: banner $q1, card $q2"

# 33. a missing board is created with >> (never truncates); an uncreatable one is an error, not silence
# Only the creation step is raced here (scripts source _common.sh, then append): going through board.sh post would also
# race the board lock, and that lock starves under 8-way contention on Ubuntu CI ("could not lock the board"); that is a separate lock problem, not board creation.
# The old window (test, then truncate) is microseconds wide and cannot be forced, so the file is also checked for the append form.
n=0
for r in 1 2 3 4 5; do
  RUN_BOARD="$T/r22.$r"; rm -rf "$RUN_BOARD"; pl=""
  for k in 1 2 3 4 5 6 7 8; do
    WARROOM_DIR="$RUN_BOARD" bash -c '. "$1"; printf "first %s\n" "$2" >> "$BOARD_FILE"' _ "$B/_common.sh" "$k" >/dev/null 2>&1 & pl="$pl $!"
  done
  wait $pl 2>/dev/null
  n=$(grep -c 'first' "$RUN_BOARD/board.md" 2>/dev/null); [ "$n" = 8 ] || break
done
[ "$n" = 8 ] && ok "eight first writers to a missing board all survive (5 rounds)" || bad "first writers to a missing board: only ${n:-0} of 8 lines survived"
grep -q ': >> "\$BOARD_FILE"' "$B/_common.sh" && ! grep -qE '(^|[;&] *): > "\$BOARD_FILE"' "$B/_common.sh" && ok "the board is created with an append, not a truncating redirect" || bad "_common.sh creates the board with a truncating redirect"
printf x > "$T/afile"; WARROOM_DIR="$T/afile/run" "$B/board.sh" path >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && ok "a board that cannot be created is an error" || bad "uncreatable board reported success"

# 34. a failed ledger write keeps the old ledger and fails (ulimit -f is in 1024-byte blocks: 4 = 4 KiB; the 8 KiB ledger
#     already exists, so only the copy the script writes runs over the limit)
RUN_LEDGER="$T/r23"; mkdir -p "$RUN_LEDGER"; sleep 30 & J=$!
python3 -c 'import sys; open(sys.argv[1], "w").write("".join("r%03d\t1\tBOSS\tx\n" % i for i in range(584)))' "$RUN_LEDGER/pids.tsv"; cp "$RUN_LEDGER/pids.tsv" "$T/r23.orig"
( ulimit -f 4; WARROOM_DIR="$RUN_LEDGER" "$B/pids.sh" add job23 $J BOSS >/dev/null 2>&1 ) 2>/dev/null; rc=$?
[ $rc != 0 ] && cmp -s "$T/r23.orig" "$RUN_LEDGER/pids.tsv" && [ -z "$(find "$RUN_LEDGER" -name '*tmp*')" ] && ok "failed ledger write: old ledger kept, exit non-zero, no temp file left" \
  || bad "ledger write failure: rc $rc, ledger $(cmp -s "$T/r23.orig" "$RUN_LEDGER/pids.tsv" && echo same || echo CHANGED)"
kill $J 2>/dev/null; wait $J 2>/dev/null

# 35. pid 0 and an unreadable start time are refused, nothing is registered
sleep 30 & J=$!; mkdir -p "$T/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/ps"; chmod +x "$T/fakebin/ps"
"$B/pids.sh" add z0 0 BOSS >/dev/null 2>&1; r0=$?; "$B/pids.sh" add z00 000 BOSS >/dev/null 2>&1; r00=$?
PATH="$T/fakebin:$PATH" "$B/pids.sh" add nops $J BOSS >/dev/null 2>&1; r1=$?
[ $r0 != 0 ] && [ $r00 != 0 ] && [ $r1 != 0 ] && ! grep -qE '^(z0|z00|nops)	' "$WARROOM_DIR/pids.tsv" && ok "pid 0 and an unreadable start time are refused, no row written" \
  || bad "pids add: pid0 rc $r0/$r00, no-ps rc $r1, rows $(grep -cE '^(z0|z00|nops)	' "$WARROOM_DIR/pids.tsv")"
kill $J 2>/dev/null; wait $J 2>/dev/null

# 36. the sentinel reads the four-column ledger: a registered hot process gets the job policy, its owner is alerted once
RUN_SENT="$T/r25"; mkdir -p "$RUN_SENT"; : > "$RUN_SENT/board.md"
bash -c 'while :; do :; done' & BL=$!; sleep 2
WARROOM_DIR="$RUN_SENT" "$B/pids.sh" add busy25 $BL W1 >/dev/null
for _ in 1 2 3 4 5 6 7; do WARROOM_DIR="$RUN_SENT" python3 -I "$B/cpu-sentinel.py" --hot 5 >/dev/null 2>&1; done
n=$(grep -c "@W1 ACTION: process $BL .*(job)" "$RUN_SENT/board.md")
[ "$n" = 1 ] && ok "sentinel: registered hot process is a job, its owner is alerted exactly once" || bad "sentinel job alert: $n lines for the owner"
# the same row with a start time that is not this process's: the row is ignored (no owner, no job alert)
awk -F'\t' 'BEGIN{OFS="\t"} {$4="Thu Jan  1 00:00:00 1970"; print}' "$RUN_SENT/pids.tsv" > "$T/r25.mod" && cp "$T/r25.mod" "$RUN_SENT/pids.tsv"
rm -rf "$RUN_SENT/sentinel"; : > "$RUN_SENT/board.md"
for _ in 1 2 3 4 5 6; do WARROOM_DIR="$RUN_SENT" python3 -I "$B/cpu-sentinel.py" --hot 5 >/dev/null 2>&1; done
n=$(grep -c "@W1 ACTION: process $BL " "$RUN_SENT/board.md")
[ "$n" = 0 ] && ok "sentinel: a ledger row whose pid started at another time is ignored" || bad "sentinel trusted a reused pid ($n alerts to the row's owner)"
kill $BL 2>/dev/null; wait $BL 2>/dev/null

# 37. --dry-run changes nothing; a failed post is retried, a delivered one is not repeated
RUN_DRY="$T/r26"; mkdir -p "$RUN_DRY/sentinel"; : > "$RUN_DRY/board.md"
bash -c 'while :; do :; done' & BL=$!; sleep 2
KEY="$BL:$(ps -o comm= -p $BL | sed 's/^ *//;s/ *$//')"
printf '{"strikes": {"%s": 2}, "alerted": []}\n' "$KEY" > "$RUN_DRY/sentinel/strikes.json"; cp "$RUN_DRY/sentinel/strikes.json" "$T/r26.strikes"
out=$(WARROOM_DIR="$RUN_DRY" python3 -I "$B/cpu-sentinel.py" --dry-run --hot 5 2>&1)
if printf '%s' "$out" | grep -q "would post to BOSS" && ! grep -q ACTION "$RUN_DRY/board.md" && cmp -s "$T/r26.strikes" "$RUN_DRY/sentinel/strikes.json" && [ ! -e "$RUN_DRY/sentinel/sentinel.log" ]; then
  ok "sentinel --dry-run: says what it would post, writes no board line, strike file or log"
else bad "sentinel --dry-run had effects or printed nothing: $(printf '%s' "$out" | head -c 160)"; fi
mkdir "$RUN_DRY/bd"                                    # a board that is a directory: the alert post fails
BOARD="$RUN_DRY/bd" WARROOM_DIR="$RUN_DRY" python3 -I "$B/cpu-sentinel.py" --hot 5 >/dev/null 2>&1
rmdir "$RUN_DRY/bd"; : > "$RUN_DRY/bd"                     # now the board can be written
for _ in 1 2; do BOARD="$RUN_DRY/bd" WARROOM_DIR="$RUN_DRY" python3 -I "$B/cpu-sentinel.py" --hot 5 >/dev/null 2>&1; done
n=$(grep -c "@BOSS ACTION: process $BL " "$RUN_DRY/bd")
[ "$n" = 1 ] && ok "sentinel: a failed alert post is retried on the next run, then not repeated" || bad "sentinel alert retry: $n lines"
kill $BL 2>/dev/null; wait $BL 2>/dev/null

# 38. merge-daemon: an option without a value exits 2 instead of spinning; a dry run writes nothing, pass or fail
"$B/merge-daemon.sh" 7 --head >/dev/null 2>&1 & MP=$!
if wait_exit $MP 5; then wait $MP; rc=$?; else kill $MP 2>/dev/null; wait $MP 2>/dev/null; rc=spin; fi
[ "$rc" = 2 ] && ok "merge-daemon: an option with no value exits 2" || bad "merge-daemon with a missing option value: $rc"
nrec() { ls "$WARROOM_DIR/receipts" 2>/dev/null | wc -l | tr -d ' '; }
nboard() { wc -l < "$("$B/board.sh" path)" | tr -d ' '; }
mk OPEN build FAILURE > "$SD/view.1"; rm -f "$SD/view.2" "$SD/merged" "$SD/count"; r0=$(nrec); b0=$(nboard)
PATH="$SD:$PATH" "$B/merge-daemon.sh" 7 --head "$SHA" --poll 1 --timeout 3 --require build --dry-run >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ "$(nrec)" = "$r0" ] && [ "$(nboard)" = "$b0" ] && ok "merge-daemon --dry-run: a failing PR ends FAIL and writes no receipt or board line" || bad "failed dry run: rc $rc, receipts $r0->$(nrec), board $b0->$(nboard)"
mk OPEN build SUCCESS > "$SD/view.1"; rm -f "$SD/merged" "$SD/count"
PATH="$SD:$PATH" "$B/merge-daemon.sh" 7 --head "$SHA" --poll 1 --timeout 3 --require build --dry-run >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ ! -e "$SD/merged" ] && [ "$(nrec)" = "$r0" ] && [ "$(nboard)" = "$b0" ] && ok "merge-daemon --dry-run: a green PR passes, merges nothing, writes nothing" || bad "green dry run: rc $rc, receipts $r0->$(nrec), board $b0->$(nboard)"

# 39. merge-daemon readback: four outcomes that must not be told apart by "merged" alone
S2="$T/stub2"; mkdir -p "$S2"; export GH_STUB_DIR="$S2"
cat > "$S2/gh" <<'STUB'
#!/usr/bin/env bash
d=$GH_STUB_DIR
case "$*" in
  *"pr merge"*) if [ -e "$d/refuse" ]; then touch "$d/ext"; echo "Pull request is already merged" >&2; exit 1; fi
                [ -e "$d/queued" ] || touch "$d/merged"; exit 0 ;;
  *"api user"*) cat "$d/me" 2>/dev/null; exit 0 ;;
  *mergeCommit*) printf 'feedface\t%s\n' "$(cat "$d/mergedby" 2>/dev/null)"; exit 0 ;;
  *statusCheckRollup*) if [ -e "$d/merged" ] || [ -e "$d/ext" ]; then cat "$d/view.merged"; else cat "$d/view.1"; fi ;;
esac
STUB
chmod +x "$S2/gh"; mk OPEN build SUCCESS > "$S2/view.1"; mk MERGED build SUCCESS > "$S2/view.merged"
outcome() { # outcome FLAGS... : run once on a clean stub, print the last POSTCONDITION line and the exit code
  rm -f "$S2/merged" "$S2/ext" "$S2/refuse" "$S2/queued" "$S2/me" "$S2/mergedby"; : > "$("$B/board.sh" path)"
  for f in "$@"; do case "$f" in me=*) echo "${f#me=}" > "$S2/me" ;; by=*) echo "${f#by=}" > "$S2/mergedby" ;; *) touch "$S2/$f" ;; esac; done
  PATH="$S2:$PATH" "$B/merge-daemon.sh" 7 --head "$SHA" --poll 1 --timeout 3 --require build >/dev/null 2>&1; echo "rc=$? $(grep POSTCONDITION "$("$B/board.sh" path)" | tail -1)"; }
o=$(outcome me=ownerlogin by=ownerlogin); case "$o" in "rc=0 "*"POSTCONDITION PASS"*"merged by this run (invocation"*) ok "merge readback: merged by this run's account is reported as such" ;; *) bad "own merge: $o" ;; esac
o=$(outcome me=ownerlogin by=otherlogin); case "$o" in "rc=1 "*"POSTCONDITION FAIL"*"NOT merged by this run's account"*) ok "merge readback: merged by another account is not a pass" ;; *) bad "other account: $o" ;; esac
o=$(outcome queued); case "$o" in "rc=1 "*"POSTCONDITION FAIL"*"still 'OPEN'"*) ok "merge readback: accepted but still open (queue/auto-merge) is not a pass" ;; *) bad "queued: $o" ;; esac
o=$(outcome refuse); case "$o" in "rc=1 "*"POSTCONDITION FAIL"*"already MERGED by someone else"*) ok "merge readback: refused because already merged is reported as another actor's merge" ;; *) bad "refused/ext: $o" ;; esac
o=$(outcome); case "$o" in "rc=0 "*"POSTCONDITION PASS"*"does not prove this run did it"*) ok "merge readback: an unreadable merging account passes with the limit stated" ;; *) bad "unreadable merger: $o" ;; esac
export GH_STUB_DIR="$SD"

# 40. leak-check: scan errors are errors, run-state files in the tree are hits
LK="$T/lk"; mkdir -p "$LK/tree"; printf 'nothing here\n' > "$LK/tree/a.txt"; printf '(unbalanced\n' > "$LK/bad.deny"
bash "$ROOT/tools/leak-check.sh" "$LK/tree" >/dev/null 2>&1; r0=$?
LEAKCHECK_DENYLIST="$LK/bad.deny" bash "$ROOT/tools/leak-check.sh" "$LK/tree" >/dev/null 2>&1; r1=$?
[ $r0 = 0 ] && [ $r1 = 2 ] && ok "leak-check: a clean tree passes, a malformed denylist pattern is an error (exit 2)" || bad "leak-check: clean rc $r0, bad pattern rc $r1"
if [ "$(id -u)" != 0 ]; then
  printf 'x\n' > "$LK/tree/locked.txt"; chmod 000 "$LK/tree/locked.txt"
  bash "$ROOT/tools/leak-check.sh" "$LK/tree" >/dev/null 2>&1; r2=$?; chmod 600 "$LK/tree/locked.txt"
  [ $r2 = 2 ] && ok "leak-check: an unreadable file is an error, not a clean result" || bad "leak-check on an unreadable file: rc $r2"
fi
: > "$LK/tree/pids.tsv"; bash "$ROOT/tools/leak-check.sh" "$LK/tree" >/dev/null 2>&1; r3=$?
[ $r3 = 1 ] && ok "leak-check: a run-state file inside the tree is a hit" || bad "leak-check on a tree holding pids.tsv: rc $r3"

[ $fail = 0 ] && echo "smoke: all passed" || echo "smoke: FAILED"
exit $fail
