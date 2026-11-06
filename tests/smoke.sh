#!/usr/bin/env bash
# tests/smoke.sh — end-to-end check on a throwaway board. Runs in CI and on your machine; touches nothing outside a temp dir.
#   1. a plain mention does not wake a seat; an "@SEAT ACTION:" line does, within a few seconds
#   2. a second waiter on a seat that is already held is refused
#   3. a registered job that dies wakes its owner once, and its row is dropped, also when several seats check at once
#   4. the idle guard names a silent seat once per silence, not once per prompt
#   7. wake grammar: only a first line "@SEAT ACTION:" from another author wakes (not prose, ACTIONABLE, a second line, the seat's own post)
#   8. a replaced board of the same length is read again from its start; a waiter missing its session id is refused
#   9. two arms of one seat at the same moment: exactly one wins, every round
#  10. a board that cannot be written makes post fail; a job's row is kept until its wake is on the board
#  11. the writer lock: one holder per file (also through aliases, which are refused), a crash releases it, wr_run children
#      hold no copy, subshell use is refused, every failure is visible, a board named like the waiter's marker is refused
#  12. the job ledger: concurrent add of one label gives one row; a reused pid (wrong start time) counts as gone
#  14-15. warroom.env is data: command text refused, the current folder ignored
#  17. docs/INSTALL.md: its hook block is valid JSON with the four entries, the quoted path works with a space in the clone path,
#      the parse command in the page accepts a good file and refuses a bad one, the page stays short
#  18-20. (unused numbers: the installer was removed)
#  21. every hook with a bad warroom.env exits 1 (shown, prompt goes through), never 2 (Claude Code blocks the prompt)
#  25. a key set twice in warroom.env is refused
#  27-32. second review (waiter, cursor, guard): shared opt-out rows, one wake when a waiter is replaced, a board refilled in
#         place, the guard's job identity and its mark across board generations, quoted commands
#  33. a missing board is created without truncating (parallel first posts all survive); an uncreatable board is an error
#  34. a ledger write that fails leaves the ledger as it was and exits non-zero
#  35. pids.sh add refuses pid 0 and a pid whose start time cannot be read
#  39. leak-check: a bad denylist pattern or an unreadable file is an error (exit 2), run-state files in the tree are a hit
#  40. process identity: ps failing is "unknown" (row kept, seat not taken, guard silent, hook says so), never "dead"; a
#      reused pid holds no seat
#  41-43. position integrity (a rewrite anywhere in the part already read is noticed), every state write checked (fault
#         injection with a python3 shim that refuses the rename), the board bootstrap under a forced race (with a wrong-code control)
#  44. the sample board, replayed through real waiters, wakes W1, W2 and BOSS by exactly their own handoffs
#  45-50. destinations: the run folder, board and config file are resolved from metadata and checked before anything is made
#         (settings names, the config folder, reserved state names, aliases, absolute paths, readonly values), seat arguments
#         that become paths, python3 required, hook exit codes
#  51. links and hard links at state leaves are refused, the link target is never created or written, and the temp is cleaned up
#  52. temps and write failures (PATH-shim faults for mktemp, awk, cksum, rm and python3): nothing half-written is left as a state file
#  53. exclusive create: the raw noclobber create has one winner among racers; wr_create accepts a loser only after the recheck
#  54. guard mark restore: a failed post puts the old mark (or "-") back; a restore that itself fails keeps the new mark and says so
#  55. injected poll filter/checksum failures keep the waiter alive and its position unchanged until retry delivers; arm and tail checksum failures exit without advancing their saved state, and empty-board tail succeeds.
#  59. selected fixtures fail on deliberately mutated copies of bin/ and hooks/ and pass on the pristine copy; the failing assertion is printed.
#      touchlast, legacytemp, mvreplace, oldrollback, restorerm and nofiltercheck are the six B write/filter mutants.
#  60. read gate (report mode): tests/read-gate.py checks its own fixtures and mutants, then lists every read in bin/ and hooks/ whose
#      failure can reach a state change. It prints the inventory and never fails on it yet; a tool error (unparsable script, empty
#      discovery) or a failed self-test does fail.
# Some hosts (a Node-based CI runner, for one) start every child with SIGPIPE ignored, and bash cannot restore a signal that was
# ignored when it started, so `trap '' PIPE` changes nothing there and the closed-pipe tests mean something else. Seats run in
# terminals, where SIGPIPE is at its default. When the probe sees otherwise, the suite restarts itself once through python3,
# which can put the default back.
if [ -z "${SMOKE_SIGPIPE_RESET:-}" ] && command -v python3 >/dev/null 2>&1 && [ "$(bash -c 'yes 2>/dev/null|head -c1>/dev/null; echo ${PIPESTATUS[0]}')" != 141 ]; then
  echo "smoke: the host ignores SIGPIPE; restarting with the default"
  export SMOKE_SIGPIPE_RESET=1
  exec python3 -I -c 'import os,signal,sys; signal.signal(signal.SIGPIPE,signal.SIG_DFL); os.execv(sys.argv[1],sys.argv[1:])' /usr/bin/env bash "$0" "$@"
fi
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
export WARROOM_DIR="$T/run" WARROOM_ENV="$T/none" SEATS="BOSS W1" WARROOM_POLL=1 WARROOM_MIN_GAP=0
B="$ROOT/bin"; fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
wait_exit() { for _ in $(seq 1 "$2"); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done; return 1; }
# the tests below that close a pipe early only mean something when SIGPIPE is at its default (see the restart at the top)
[ "$(bash -c 'yes 2>/dev/null|head -c1>/dev/null; echo ${PIPESTATUS[0]}')" = 141 ] && ok "SIGPIPE is at its default" || bad "SIGPIPE is not at its default; the PIPE tests would be meaningless"

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
# (was: board.md as a directory; a directory board is now refused before the run starts, so the board is a read-only file)
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$T/run2"; : > "$T/run2/board.md"; chmod 444 "$T/run2/board.md"
  (export WARROOM_DIR="$T/run2"; "$B/board.sh" post BOSS "hello" >/dev/null 2>&1)
  [ $? != 0 ] && ok "post to an unwritable board exits non-zero" || bad "post to an unwritable board reported success"
  export WARROOM_DIR="$T/run2"; sleep 30 & J=$!; "$B/pids.sh" add keep-job $J BOSS >/dev/null; kill $J; wait $J 2>/dev/null
  "$B/pids.sh" check >/dev/null 2>&1
  grep -q '^keep-job' "$WARROOM_DIR/pids.tsv" && ok "job row kept while the wake could not be posted" || bad "job row was dropped without a wake"
  chmod 644 "$WARROOM_DIR/board.md"
  "$B/pids.sh" check >/dev/null 2>&1; "$B/pids.sh" check >/dev/null 2>&1
  n=$(grep -c "job 'keep-job'" "$WARROOM_DIR/board.md")
  [ "$n" = 1 ] && ! grep -q '^keep-job' "$WARROOM_DIR/pids.tsv" && ok "retry wakes once, then drops the row" || bad "retry: $n wake lines"
else
  echo "skip unwritable board, job row kept, retry wakes once (running as root: a read-only file stays writable)"
fi
export WARROOM_DIR="$T/run"

# 11. the writer lock: flock on FILE.flock
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
  WARROOM_LOCK_WAIT=5 bash -c ". \"\$WR_C\"; wr_lock \"\$1\" || exit 1; $run \"\$2\" \"\$3\"; exit \$?" _ "$LD/a" "$LD/stopme.sh" "$LD/cpid" >/dev/null 2>&1 & PP=$!
  for _ in $(seq 1 50); do [ -s "$LD/cpid" ] && break; sleep 0.1; done; cp=$(cat "$LD/cpid" 2>/dev/null)
  [ -n "$cp" ] && [ "$cp" != "$PP" ] && pc=forked || pc="not forked (child $cp, holder $PP)"
  kill -9 $PP 2>/dev/null; wait $PP 2>/dev/null; sleep 0.2
  if [ $mode = wr_run ]; then rw=$(try "$LD/a"); kill -0 "$cp" 2>/dev/null && aw=alive || aw=gone
  else rp=$(try "$LD/a"); fi
  kill -9 "$cp" 2>/dev/null; sleep 0.2
done
rf=$(try "$LD/a")
[ "$rw" = 0 ] && [ "$aw" = alive ] && [ "$rp" = 1 ] && [ "$rf" = 0 ] && [ "$pc" = forked ] && ok "lock: holder killed while its stopped child runs: free with wr_run, held by a plain child until it ends" || bad "lock: release rule: wr_run $rw ($aw), plain $rp, after the child $rf, $pc"
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
mkdir -p "$LD/py3" "$LD/nopy"; printf '#!/bin/sh\ncase "$*" in *fcntl*) echo "stub helper says no" >&2; exit 3 ;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$LD/py3/python3"; chmod +x "$LD/py3/python3"
for t in dirname basename stat sed head cat; do p=$(command -v $t) && ln -s "$p" "$LD/nopy/$t"; done
o=$(lk 'PATH="$2:$PATH"; wr_lock "$1"; echo "rc=$? s8=[$_WR_SLOT8] fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"' "$LD/a" "$LD/py3")
case "$o" in *"lock helper failed"*"stub helper says no"*"exit 3"*"rc=1 s8=[] fd8=closed"*) ok "lock: a helper that exits 3 prints its own line and cleans up" ;; *) bad "lock: helper exit 3: $o" ;; esac
o=$(lk 'PATH="$2"; wr_lock "$1"; echo "rc=$? s8=[$_WR_SLOT8] fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"' "$LD/a" "$LD/nopy")
case "$o" in *"could not open lock file"*"cannot be examined"*"rc=1 s8=[] fd8=closed"*) ok "lock: python3 missing from PATH prints its own line, opens nothing and leaves the slot empty" ;; *) bad "lock: helper missing: $o" ;; esac

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
printf '[00:00 · W1] hello\n' > "$R3/board.md"; b0=$(cksum < "$R3/board.md"); printf -- '-\n' > "$R3/.guard-W1"; hold "$R3/.guard-W1"
e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); r=$?; unhold "$R3/.guard-W1"
[ $r = 0 ] && [ "$(cksum < "$R3/board.md")" = "$b0" ] && case "$e" in *"board-guard: skipped W1 (mark busy)"*) true ;; *) false ;; esac && ok "lock: board-guard with the mark busy says so, exits 0, posts nothing" || bad "lock: busy mark: rc $r, '$e'"
hold "$R3/board.md"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); unhold "$R3/board.md"
[ "$(cat "$R3/.guard-W1")" = "-" ] && [ "$(cksum < "$R3/board.md")" = "$b0" ] && case "$e" in *"could not lock the board"*) true ;; *) false ;; esac && ok "lock: board-guard with the board busy shows the error and restores the mark (no old mark: '-', never unlinked)" || bad "lock: guard with a busy board: '$e', mark '$(cat "$R3/.guard-W1")'"
# the waiter's two arming locks, cursor then registry: each failure says so; a registry failure releases the cursor
: > "$R3/.cursor-W1"; hold "$R3/.cursor-W1"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/waiter.sh" W1 sid-c 2>&1 >/dev/null); r=$?; unhold "$R3/.cursor-W1"
[ $r = 1 ] && case "$e" in *"could not lock the cursor of seat W1"*) true ;; *) false ;; esac && ok "lock: waiter with its cursor busy says so and exits 1" || bad "lock: busy cursor: rc $r, '$e'"
hold "$R3/seats.tsv"; e=$(WARROOM_DIR="$R3" WARROOM_LOCK_WAIT=1 "$B/waiter.sh" W1 sid-c 2>&1 >/dev/null); r=$?; c=$(try "$R3/.cursor-W1"); unhold "$R3/seats.tsv"
[ $r = 1 ] && [ "$c" = 0 ] && case "$e" in *"could not lock the seat registry"*) true ;; *) false ;; esac && ok "lock: waiter with the registry busy says so, exits 1 and releases its cursor" || bad "lock: busy registry: rc $r, cursor try $c, '$e'"
# bootstrap: a board with content stays byte-identical when 8 processes source _common.sh at once
printf 'line one\nline two\n' > "$R3/board.md"; b0=$(cksum < "$R3/board.md"); pl=""
for k in 1 2 3 4 5 6 7 8; do WARROOM_DIR="$R3" bash -c '. "$1"' _ "$C" >/dev/null 2>&1 & pl="$pl $!"; done; wait $pl 2>/dev/null
[ "$(cksum < "$R3/board.md")" = "$b0" ] && ok "lock: sourcing _common.sh never changes a board that has content" || bad "lock: bootstrap changed the board"

# a BOARD configured as the waiter's own marker name (.lastwake-W1) is refused before anything runs (was: the wake left its bytes intact)
R4="$LD/run4"; mkdir -p "$R4"; printf '%s\n' "[00:00 · BOSS] forty-four bytes of board here." > "$R4/.lastwake-W1"; cp "$R4/.lastwake-W1" "$LD/w4.orig"
WARROOM_DIR="$R4" BOARD=.lastwake-W1 "$B/waiter.sh" W1 sid-l > "$LD/w4.out" 2>&1; r1=$?
WARROOM_DIR="$R4" BOARD=.lastwake-W1 "$B/board.sh" post BOSS "@W1 ACTION: post on a board named like the marker" > "$LD/p4.out" 2>&1; r2=$?
cmp -s "$R4/.lastwake-W1" "$LD/w4.orig" && [ $r1 = 2 ] && [ $r2 = 2 ] && grep -q "at a name this tool writes" "$LD/w4.out" && grep -q "at a name this tool writes" "$LD/p4.out" && ok "lock: a board named .lastwake-SEAT is refused by the waiter and by post (exit 2), and the whole file is byte-identical" || bad "lock: marker-named board: rc $r1/$r2, $(wc -c < "$R4/.lastwake-W1") bytes, waiter: $(head -c 120 "$LD/w4.out")"
! grep -nE '(^|[;&|] *): > "\$LAST"' "$B/waiter.sh" >/dev/null && ok "lock: the waiter never truncates its wake timestamp" || bad "lock: waiter.sh still truncates \$LAST"

# lock_order_and_upgrade_boundary (lint only, not evidence of safety)
code="$B/board.sh $B/pids.sh $B/waiter.sh $ROOT/hooks/board-guard.sh"
sub='\$\([^)]*wr_(lock|unlock|run)|(^|[^|])\| *wr_(lock|unlock|run)'
! grep -nE "$sub" $code >/dev/null && ok "lock lint: no lock call inside \$( ) or after a pipe" || bad "lock lint: a lock call runs in a subshell: $(grep -nE "$sub" $code | head -2)"
_fdl=$(grep -nE '(^|[^0-9&<>])[89]>|>&[89]|<&[89]' $code "$ROOT/tools/"*.sh)
[ -z "$_fdl" ] && [ "$(grep -c '^ *wr_unlock "\$CUR"; echo "\[WAITER ERROR\] ' "$B/waiter.sh")" = 4 ] && ok "lock lint: fds 8 and 9 are used only by _common.sh; the 4 terminal delivery-error branches of waiter.sh release the cursor lock through wr_unlock" || bad "lock lint: another script uses fd 8 or 9: $_fdl"
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

# 14. config is data, never code: a $(...) in warroom.env is refused and does not run
printf 'WARROOM_DIR="$(touch %s/m-env)"\n' "$T" > "$T/bad.env"
WARROOM_ENV="$T/bad.env" "$B/board.sh" path >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && [ ! -e "$T/m-env" ] && ok "command text in warroom.env is refused, not run" || bad "bad warroom.env: rc $rc, ran=$([ -e "$T/m-env" ] && echo yes || echo no)"

# 15. a warroom.env in the current folder is ignored (only $WARROOM_ENV or ~/.warroom/warroom.env are read)
mkdir -p "$T/cwd" "$T/h8"; printf 'SEATS="EVIL"\nWARROOM_DIR="%s/cwd-run"\n' "$T" > "$T/cwd/warroom.env"
got=$(cd "$T/cwd" && env -u SEATS -u WARROOM_DIR -u WARROOM_ENV HOME="$T/h8" bash "$B/board.sh" path 2>&1)
[ "$got" = "$T/h8/warroom-run/board.md" ] && ok "warroom.env in the current folder is ignored" || bad "cwd config was read: $got"

# 17. docs/INSTALL.md is the install: its hook block parses, holds the four entries, and its quoted path works when the clone path has a space
D="$ROOT/docs/INSTALL.md"; CLX="$T/sp ace/wr"; mkdir -p "$CLX" "$T/i17"; cp -R "$ROOT/bin" "$ROOT/hooks" "$CLX/"
sed -n '/^```json$/,/^```$/p' "$D" | sed '1d;$d' | sed "s#/ABSOLUTE/PATH/TO/warroom#$CLX#g" > "$T/i17/settings.json"
cmds=$(python3 - "$T/i17/settings.json" <<'PY'
import json, shlex, sys, os
d = json.load(open(sys.argv[1])); h = d["hooks"]; out = []
for ev in ("SessionStart", "UserPromptSubmit"):
    for g in h[ev]:
        for e in g["hooks"]:
            a = shlex.split(e["command"])
            ok = e["type"] == "command" and len(a) == 2 and a[0] == "bash" and os.path.isfile(a[1]) and a[1].endswith(".sh")
            out.append(ev + ":" + os.path.basename(a[1]) + (":ok" if ok else ":BAD"))
print(" ".join(out))
PY
)
[ "$cmds" = "SessionStart:waiter-check.sh:ok UserPromptSubmit:waiter-check.sh:ok UserPromptSubmit:board-tail.sh:ok UserPromptSubmit:board-guard.sh:ok" ] \
  && ok "INSTALL.md hook block: valid JSON, the four entries, each a quoted existing script" || bad "INSTALL.md hook block: $cmds"
cmd1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$T/i17/settings.json")
hout=$(printf '{"session_id": "sid-i17"}' | sh -c "$cmd1" 2>&1)
case "$hout" in *"[WAITER NOT ARMED]"*) ok "the printed SessionStart command runs from a clone path with a space" ;; *) bad "INSTALL.md SessionStart command output: $hout" ;; esac
pc=$(grep '^python3 -I -S -c' "$D"); printf '{"a": 1}\n' > "$T/i17/good.json"; printf '{"a": \n' > "$T/i17/broken.json"
f="$T/i17/good.json" sh -c "$pc" >/dev/null 2>&1; g=$?; f="$T/i17/broken.json" sh -c "$pc" >/dev/null 2>&1; br=$?
[ -n "$pc" ] && [ $g = 0 ] && [ $br != 0 ] && [ "$(wc -l < "$D" | tr -d ' ')" -le 60 ] && ok "INSTALL.md parse command: accepts a good file, refuses a broken one; the page is at most 60 lines" || bad "INSTALL.md parse command: good rc $g, broken rc $br"

# (17, re-read against the destination checks) line 3 carries the PATH requirement for python3 once, and names the refusals it makes true
l3=$(sed -n 3p "$D"); np=$(cat "$ROOT/README.md" "$ROOT/SECURITY.md" "$ROOT"/docs/*.md | grep -c 'python3 must be on the PATH your Claude Code hooks run with')
want3='Five steps, run from the clone. You need git, bash, python3 and Claude Code, signed in; python3 must be on the PATH your Claude Code hooks run with. There is no settings installer: you add the hook entries by hand after saving a copy. Prefer paths outside the config folder; a run folder that is the config folder itself (compared by its physical path) and a run folder or board named like a settings file are refused, while dedicated subfolders remain allowed.'
case "$l3" in "$want3") [ "$np" = 1 ] && [ "$(wc -l < "$D" | tr -d ' ')" = 60 ] && ok "INSTALL.md line 3 is exactly the ruled line (python3 PATH said once in the docs) and the page is exactly 60 lines" || bad "python3 PATH sentence appears $np times, or the page is not 60 lines" ;; *) bad "INSTALL.md line 3 is not the ruled line: $l3" ;; esac

# 21. a hook never exits 2 on a bad config: Claude Code would block the prompt, in every session on the machine
hr=""; for h in board-guard board-tail waiter-check; do
  printf '{"session_id": "sid-h21"}' | WARROOM_ENV="$T/bad.env" bash "$ROOT/hooks/$h.sh" >/dev/null 2>&1; hr="$hr $h=$?"
done
[ "$hr" = " board-guard=1 board-tail=1 waiter-check=1" ] && [ ! -e "$T/m-env" ] && ok "hooks exit 1, not 2, on a bad warroom.env" || bad "hook exit codes on a bad config:$hr"

# 25. a key set twice in warroom.env is refused
printf 'WARROOM_DIR="%s"\nWARROOM_DIR="%s"\n' "$T/dup-first" "$T/dup-last" > "$T/dup.env"
env -u SEATS -u WARROOM_DIR WARROOM_ENV="$T/dup.env" bash -c '. "$1/bin/_common.sh"' _ "$ROOT" >/dev/null 2>&1; r1=$?
[ $r1 != 0 ] && [ ! -e "$T/dup-first" ] && [ ! -e "$T/dup-last" ] && ok "a key set twice is refused" || bad "duplicate key: shell rc $r1"

# 27. two sessions opting out (NONE) keep both rows; a seat's own arm still replaces only that seat's row
rm -f "$WARROOM_DIR/seats.tsv"
"$B/waiter.sh" NONE sid-n1 >/dev/null 2>&1; "$B/waiter.sh" NONE sid-n2 >/dev/null 2>&1; "$B/waiter.sh" NONE sid-n1 >/dev/null 2>&1
n=$(awk -F'\t' '$2=="NONE"' "$WARROOM_DIR/seats.tsv" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok "a second opt-out does not delete the first" || bad "NONE rows after three opt-outs by two sessions: $n"

# 28. a waiter replaced by a newer arm of the same session never delivers a second wake, 6 rounds
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

# 29. a board emptied in place and refilled (same file, same first line, longer) is read again; so is board.sh tail
printf '[00:00 · BOSS] head\n[00:00 · BOSS] old 1\n[00:00 · BOSS] old 2\n[00:00 · BOSS] old 3\n[00:00 · BOSS] old 4\n[00:00 · BOSS] old 5\n' > "$BF"
rm -f "$WARROOM_DIR"/.cursor-* "$WARROOM_DIR"/.lastwake-* "$WARROOM_DIR/seats.tsv" "$WARROOM_DIR"/.anchor-*
"$B/board.sh" tail BOSS >/dev/null
"$B/waiter.sh" W1 sid-t1 > "$T/t1.out" 2>/dev/null & WP=$!; sleep 2
printf '[00:00 · BOSS] head\n[00:00 · BOSS] new 1\n[00:01 · BOSS] @W1 ACTION: after the refill\n[00:01 · BOSS] new 3\n[00:01 · BOSS] new 4\n[00:01 · BOSS] new 5\n[00:01 · BOSS] new 6\n[00:01 · BOSS] new 7\n' > "$BF"
if wait_exit $WP 10 && grep -q "after the refill" "$T/t1.out"; then ok "board emptied in place and refilled is read again by the waiter"; else bad "refill in place: the waiter missed the directive"; fi
c=$("$B/board.sh" tail BOSS | grep -c "after the refill")
[ "$c" = 1 ] && ok "board.sh tail reads a refilled board again" || bad "board.sh tail after a refill printed the directive $c times"

# 30. the idle guard: a reused pid does not count as a running job; a new silence after a replaced board is named again
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

# 32. no error text on the first arm; printed commands are shell-quoted when the install path has a space
rm -f "$WARROOM_DIR"/.cursor-* "$WARROOM_DIR/seats.tsv"
"$B/waiter.sh" W1 sid-q1 >/dev/null 2> "$T/q1.err" & WP=$!; sleep 2; kill $WP 2>/dev/null; wait $WP 2>/dev/null
[ "$(wc -l < "$T/q1.err" | tr -d ' ')" = 1 ] && grep -q '^armed W1' "$T/q1.err" && ok "first arm prints only the armed line on stderr" || bad "first arm stderr: $(head -c 200 "$T/q1.err")"
mkdir -p "$T/sp dir" && cp -R "$ROOT/bin" "$ROOT/hooks" "$T/sp dir/"
bn=$(printf '{"session_id": "s-q2"}' | bash "$T/sp dir/hooks/waiter-check.sh" 2>&1)
case "$bn" in *'sp\ dir/bin/waiter.sh'*) q1=1 ;; *) q1=0 ;; esac
[ "$q1" = 1 ] && ok "the banner prints a quoted waiter command for a path with a space" || bad "quoting: banner $q1"

printf 'sid-tail\tW1\n' > "$WARROOM_DIR/seats.tsv"; rm -f "$WARROOM_DIR"/.anchor-*; printf '[00:00 · BOSS] @W1 ACTION: x\n' > "$BF"
bt=$(printf '{"session_id": "sid-tail"}' | bash "$T/sp dir/hooks/board-tail.sh" 2>&1)
case "$bt" in *'sp\ dir/bin/board.sh tail W1'*) ok "the board-tail hook prints a quoted board.sh command for a path with a space" ;; *) bad "board-tail command not quoted: $bt" ;; esac

# 33. a missing board is created with the exclusive create wr_create (never truncates); an uncreatable one is an error, not silence
# Only the creation step is raced here (scripts source _common.sh, then append): going through board.sh post would also
# race the board lock, and that lock starves under 8-way contention on Ubuntu CI ("could not lock the board"); that is a separate lock problem, not board creation.
# The old window (test, then truncate) is microseconds wide and cannot be forced, so the file is also checked for the exclusive form.
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
grep -q 'wr_create "\$BOARD_FILE"' "$B/_common.sh" && ! grep -qE '(^|[;&] *): >>? *"\$BOARD_FILE"' "$B/_common.sh" && ok "the board is created with the exclusive create, not a truncating redirect" || bad "_common.sh creates the board with a redirect"
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

# 39. leak-check: scan errors are errors, run-state files in the tree are hits
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
rm -f "$LK/tree/pids.tsv"; : > "$LK/tree/board.md.flock"; bash "$ROOT/tools/leak-check.sh" "$LK/tree" >/dev/null 2>&1; r4=$?
[ $r4 = 1 ] && ok "leak-check: a lock sidecar (board.md.flock) inside the tree is a hit" || bad "leak-check on a tree holding board.md.flock: rc $r4"
git -C "$ROOT" check-ignore -q board.md.flock && ok "a lock sidecar is ignored by git" || bad ".gitignore does not cover *.flock"

# 40. process identity: alive, dead or unknown. A pid whose start time cannot be read (ps failed) is "unknown", never "dead";
#     a seat, a strike count and an opt-out belong to one process (pid + start time), so a reused pid inherits none of them
RI="$T/r40"; mkdir -p "$RI" "$T/fakebin"; : > "$RI/board.md"; printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/ps"; chmod +x "$T/fakebin/ps"
lst() { ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; }
sleep 60 & IJ=$!; WARROOM_DIR="$RI" "$B/pids.sh" add id-job $IJ W1 >/dev/null
e=$(WARROOM_DIR="$RI" PATH="$T/fakebin:$PATH" "$B/pids.sh" check 2>&1 >/dev/null); rc=$?
[ $rc = 3 ] && grep -q '^id-job' "$RI/pids.tsv" && ! grep -q "id-job" "$RI/board.md" && case "$e" in *"cannot read the start time of pid $IJ"*) true ;; *) false ;; esac \
  && ok "identity: ps failing keeps a live job's row, posts no wake, says so, exits 3" \
  || bad "identity: unreadable start time: rc $rc, rows $(grep -c '^id-job' "$RI/pids.tsv"), wakes $(grep -c id-job "$RI/board.md")"
past=$(date -d '-40 min' +%H:%M 2>/dev/null || date -v-40M +%H:%M); printf '[%s · W1] hello\n' "$past" > "$RI/board.md"
echo '{}' | WARROOM_DIR="$RI" WARROOM_IDLE_MIN=30 PATH="$T/fakebin:$PATH" bash "$ROOT/hooks/board-guard.sh" 2>/dev/null
[ "$(grep -c "GUARD\] @W1 ACTION" "$RI/board.md")" = 0 ] && ok "identity: the guard does not call a seat idle when its job's identity is unknown" \
  || bad "identity: guard named W1 idle while its job could not be checked"
kill $IJ; wait $IJ 2>/dev/null; : > "$RI/board.md"; WARROOM_DIR="$RI" "$B/pids.sh" check >/dev/null 2>&1
n=$(grep -c "job 'id-job'" "$RI/board.md")
[ "$n" = 1 ] && ! grep -q '^id-job' "$RI/pids.tsv" && ok "identity: the job that really ended wakes its owner once" || bad "identity: dead job after unknown: $n wakes"
# seats: a stale row whose pid now belongs to an unrelated live process (other start time) does not hold the seat
sleep 60 & SL=$!; now=$(date +%Y-%m-%dT%H:%M:%S); TB="$(printf '\t')"
printf 'sid-old%sW1%s%s%s%s%sMon Jan  1 00:00:00 2001\n' "$TB" "$TB" "$SL" "$TB" "$now" "$TB" > "$RI/seats.tsv"
WARROOM_DIR="$RI" "$B/waiter.sh" W1 sid-new >/dev/null 2> "$T/r40.arm" & WP=$!; sleep 2
grep -q '^armed W1' "$T/r40.arm" && ok "identity: a stale seat row whose pid was reused does not block the seat" || bad "identity: reused pid blocked W1: $(head -c 160 "$T/r40.arm")"
kill $WP 2>/dev/null; wait $WP 2>/dev/null
printf 'sid-old%sW1%s%s%s%s%s%s\n' "$TB" "$TB" "$SL" "$TB" "$now" "$TB" "$(lst $SL)" > "$RI/seats.tsv"
WARROOM_DIR="$RI" "$B/waiter.sh" W1 sid-new >/dev/null 2>&1 & WP=$!; wait_exit $WP 5 && { wait $WP; r1=$?; } || { kill $WP; r1=spin; }
# ps that fails only for the HOLDER's pid (the arming waiter must still read its own start time)
mkdir -p "$T/psholder"; REALPS=$(command -v ps); printf '#!/bin/sh\ncase "$*" in *"-p $HOLDER_PID") exit 1 ;; esac\nexec %s "$@"\n' "$REALPS" > "$T/psholder/ps"; chmod +x "$T/psholder/ps"
HOLDER_PID=$SL WARROOM_DIR="$RI" PATH="$T/psholder:$PATH" "$B/waiter.sh" W1 sid-new >/dev/null 2> "$T/r40.unk" & WP=$!; wait_exit $WP 5 && { wait $WP; r2=$?; } || { kill $WP; r2=spin; }
[ "$r1" = 1 ] && [ "$r2" = 1 ] && grep -q "cannot be read" "$T/r40.unk" && ok "identity: the seat's own waiter holds it; an unreadable holder is refused, not taken" \
  || bad "identity: holder with matching start rc $r1, unreadable holder rc $r2"
printf 's-id%sW1%s%s%s%s%sMon Jan  1 00:00:00 2001\n' "$TB" "$TB" "$SL" "$TB" "$now" "$TB" > "$RI/seats.tsv"
bn1=$(printf '{"session_id": "s-id"}' | WARROOM_DIR="$RI" bash "$ROOT/hooks/waiter-check.sh" 2>&1)
printf 's-id%sW1%s%s%s%s%s%s\n' "$TB" "$TB" "$SL" "$TB" "$now" "$TB" "$(lst $SL)" > "$RI/seats.tsv"
bn2=$(printf '{"session_id": "s-id"}' | WARROOM_DIR="$RI" bash "$ROOT/hooks/waiter-check.sh" 2>&1)
bn3=$(printf '{"session_id": "s-id"}' | WARROOM_DIR="$RI" PATH="$T/fakebin:$PATH" bash "$ROOT/hooks/waiter-check.sh" 2>&1)
case "$bn1" in "[WAITER ENDED]"*) a=1 ;; *) a=0 ;; esac; case "$bn3" in "[WAITER UNCHECKED]"*) c=1 ;; *) c=0 ;; esac
[ "$a" = 1 ] && [ -z "$bn2" ] && [ "$c" = 1 ] && ok "identity: the hook warns on a reused waiter pid, is silent for the live one, says when it cannot tell" \
  || bad "identity: hook banners: reused '$(printf '%s' "$bn1" | head -c 40)' live '$(printf '%s' "$bn2" | head -c 40)' unknown '$(printf '%s' "$bn3" | head -c 40)'"
kill $SL 2>/dev/null; wait $SL 2>/dev/null
# 41. position integrity: a rewrite anywhere in the part already read is noticed (same file, same first line, same line at
#     the reader's position, a new line in the middle); the waiter, board.sh tail and the board-tail hook all see it
R8="$T/pos-rewrite"; mkdir -p "$R8"; BF8="$R8/board.md"
printf '[00:00 · BOSS] head\n[00:00 · BOSS] old 1\n[00:00 · BOSS] old 2\n[00:00 · BOSS] old 3\n[00:00 · BOSS] old 4\n[00:00 · BOSS] last consumed\n' > "$BF8"
WARROOM_DIR="$R8" "$B/board.sh" tail W1 >/dev/null
WARROOM_DIR="$R8" "$B/waiter.sh" W1 sid-i1 > "$T/i1.out" 2>/dev/null & WP=$!; sleep 2
ino0=$(ls -i "$BF8" | cut -d' ' -f1)
printf '[00:00 · BOSS] head\n[00:00 · BOSS] old 1\n[00:01 · BOSS] @W1 ACTION: interior refill\n[00:00 · BOSS] old 3\n[00:00 · BOSS] old 4\n[00:00 · BOSS] last consumed\n[00:02 · BOSS] added after\n' > "$BF8"
[ "$(ls -i "$BF8" | cut -d' ' -f1)" = "$ino0" ] && ok "refill fixture: same file, same first line, same line at the old position" || bad "refill fixture: the board changed inode"
if wait_exit $WP 8 && grep -q "interior refill" "$T/i1.out"; then ok "an interior rewrite of the part already read is noticed by the waiter"; else bad "interior rewrite: the waiter stayed asleep"; fi
kill $WP 2>/dev/null; wait $WP 2>/dev/null
h=$(printf '{"session_id":"sid-i1"}' | WARROOM_DIR="$R8" bash "$ROOT/hooks/board-tail.sh" 2>/dev/null)
case "$h" in *"interior refill"*) ok "the board-tail hook shows the interior rewrite" ;; *) bad "interior rewrite: the board-tail hook showed '$h'" ;; esac
c=$(WARROOM_DIR="$R8" "$B/board.sh" tail W1 | grep -c "interior refill")
[ "$c" = 1 ] && ok "board.sh tail reads an interior rewrite again" || bad "interior rewrite: board.sh tail printed the directive $c times"
c=$(WARROOM_DIR="$R8" "$B/board.sh" tail W1 | grep -c "interior refill")
[ "$c" = 0 ] && ok "board.sh tail does not print it a second time" || bad "board.sh tail repeated the directive"
# a cursor written by an older version (checksum of the last line only) is accepted once; a wrong one is not
printf '[00:00 · BOSS] a\n[00:00 · BOSS] b\n' > "$R8/b2.md"
g=$(WARROOM_DIR="$R8" BOARD=b2.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_generation "$BOARD_FILE"; wr_linesum "$BOARD_FILE" 2' _ "$B" | tr '\n' ' ')
printf '%s 2 %s %s\n' "${g%% *}" "$(date +%s)" "${g##* }" > "$R8/.old-cur"; printf '%s 2 %s 12345\n' "${g%% *}" "$(date +%s)" > "$R8/.bad-cur"
r1=$(WARROOM_DIR="$R8" BOARD=b2.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2/.old-cur" "$BOARD_FILE" 99999; wr_cursor_get "$2/.bad-cur" "$BOARD_FILE" 99999' _ "$B" "$R8" | tr '\n' ' ')
[ "$r1" = "2 0 " ] && ok "an older cursor (last-line checksum) is accepted once; a wrong one reads from the start" || bad "older cursor: got '$r1'"

# 42. every state write is checked. Fault injection: a stub python3 in front of PATH fails the os.replace of wr_replace whose
#     target ends in a name listed in the file $FAILMV_FILE (the file can appear while a waiter runs); every other python3 call
#     (locks, hook JSON) goes to the real one. Control: without the file the same run works.
SH41="$T/shim41"; mkdir -p "$SH41"; REALPY=$(command -v python3)
cat > "$SH41/python3" <<SHIM
#!/bin/sh
case "\$*" in *os.replace*) [ -f "\${FAILMV_FILE:-/nonexistent}" ] && for p in \$(cat "\$FAILMV_FILE"); do case "\$*" in *\$p) echo "shim: replace refused" >&2; exit 1 ;; esac; done ;; esac
exec $REALPY "\$@"
SHIM
chmod +x "$SH41/python3"; export FAILMV_FILE="$T/failmv"; rm -f "$FAILMV_FILE"
R9="$T/pos-savefail"; mkdir -p "$R9"; printf '[00:00 · BOSS] one\n[00:00 · BOSS] two\n' > "$R9/board.md"
printf 'other-sid\tBOSS\t1\t00:00\n' > "$R9/seats.tsv"
# 41a. the registry rename fails: exit 1, message, no "armed", registry as it was, no temp file
printf 'seats.tsv\n' > "$FAILMV_FILE"; s0=$(cksum < "$R9/seats.tsv")
WARROOM_DIR="$R9" PATH="$SH41:$PATH" "$B/waiter.sh" W1 sid-f1 > /dev/null 2> "$T/f1.err" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; e=$(cat "$T/f1.err")
[ $r = 1 ] && case "$e" in *"could not update the seat registry"*) true ;; *) false ;; esac && ! printf '%s\n' "$e" | grep -q '^armed ' \
  && [ "$(cksum < "$R9/seats.tsv")" = "$s0" ] && [ -z "$(find "$R9" -name '*tmp*')" ] && ok "arm: a failed registry write says so, exits 1, keeps the registry, leaves no temp file" || bad "arm with a failed registry write: rc $r, '$e'"
# 41b. the position cannot be saved: same, and the registry gets no row for the new session
rm -f "$FAILMV_FILE"; WARROOM_DIR="$R9" "$B/waiter.sh" W1 sid-f2 > /dev/null 2> "$T/f2.err" & WP=$!; sleep 2; kill $WP 2>/dev/null; wait $WP 2>/dev/null
grep -q "armed W1" "$T/f2.err" && ok "fault control: without the fault the same arm succeeds" || bad "fault control: the arm failed without a fault: $(cat "$T/f2.err")"
printf '.cursor-W1\n' > "$FAILMV_FILE"; c0=$(cksum < "$R9/.cursor-W1"); s0=$(cksum < "$R9/seats.tsv")
WARROOM_DIR="$R9" PATH="$SH41:$PATH" "$B/waiter.sh" W1 sid-f3 > /dev/null 2> "$T/f3.err" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; e=$(cat "$T/f3.err")
[ $r = 1 ] && case "$e" in *"could not save the position of seat W1"*) true ;; *) false ;; esac && [ "$(cksum < "$R9/.cursor-W1")" = "$c0" ] \
  && [ "$(cksum < "$R9/seats.tsv")" = "$s0" ] && ! grep -q sid-f3 "$R9/seats.tsv" && [ -z "$(find "$R9" -name '*tmp*')" ] && ok "arm: a failed position write says so, exits 1, keeps the cursor and the registry" || bad "arm with a failed position write: rc $r, '$e'"
# 41c. a wake whose position cannot be saved is not reported as delivered: exit 1, the header and lines were printed first, the cursor
#      is kept, the fresh gap marker stays (nothing is unlinked to undo a failure), and the next arm delivers them again
rm -f "$FAILMV_FILE" "$R9/.lastwake-W1"; WARROOM_DIR="$R9" PATH="$SH41:$PATH" "$B/waiter.sh" W1 sid-f4 > "$T/f4.out" 2> "$T/f4.err" & WP=$!; sleep 2
c0=$(cksum < "$R9/.cursor-W1"); printf '.cursor-W1\n' > "$FAILMV_FILE"
WARROOM_DIR="$R9" "$B/board.sh" post BOSS "@W1 ACTION: delivery fault line" >/dev/null
wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && grep -q "delivery fault line" "$T/f4.out" && grep -q "printed but not marked" "$T/f4.err" && grep -q '^\[WAKE' "$T/f4.out" && [ "$(cksum < "$R9/.cursor-W1")" = "$c0" ] && [ -e "$R9/.lastwake-W1" ] \
  && ok "wake: a position that cannot be saved is not a delivery (exit 1; header and lines printed first, cursor kept, the fresh gap marker kept and not unlinked)" || bad "wake with a failed position write: rc $r, out '$(cat "$T/f4.out")', err '$(cat "$T/f4.err")'"
rm -f "$FAILMV_FILE"; WARROOM_DIR="$R9" "$B/waiter.sh" W1 sid-f5 > "$T/f5.out" 2>/dev/null & WP=$!
if wait_exit $WP 8 && grep -q "delivery fault line" "$T/f5.out"; then ok "wake: after the fault is gone the same line is delivered again, once"; else bad "wake after a failed save: the line was lost"; fi
kill $WP 2>/dev/null; wait $WP 2>/dev/null
# 41d. board.sh tail: when the anchor cannot be saved the lines were printed but are NOT marked as read: exit 1, the anchor is
#      kept, a message says so, and afterwards the same lines come again (at-least-once, never lost)
WARROOM_DIR="$R9" "$B/board.sh" tail BOSS >/dev/null; WARROOM_DIR="$R9" "$B/board.sh" post W1 "new for the tail" >/dev/null
printf '.anchor-BOSS\n' > "$FAILMV_FILE"; a0=$(cksum < "$R9/.anchor-BOSS")
o=$(WARROOM_DIR="$R9" PATH="$SH41:$PATH" "$B/board.sh" tail BOSS 2>"$T/tail.err"); r=$?
[ $r = 1 ] && case "$o" in *"new for the tail"*) true ;; *) false ;; esac && grep -q "NOT marked as read" "$T/tail.err" && [ "$(cksum < "$R9/.anchor-BOSS")" = "$a0" ] && [ -z "$(find "$R9" -name '*tmp*' -o -name '*.chunk.*' -o -name '*.snap.*')" ] \
  && ok "tail: an anchor that cannot be saved prints the lines, says they are not marked as read, exits 1, keeps the anchor" || bad "tail with a failed anchor write: rc $r, out '$o'"
rm -f "$FAILMV_FILE"; o=$(WARROOM_DIR="$R9" "$B/board.sh" tail BOSS)
case "$o" in *"new for the tail"*) ok "tail: after the fault the same lines are printed again" ;; *) bad "tail after a failed save lost the lines: '$o'" ;; esac
# 41e. board-guard: a mark that cannot be saved means no post (nothing repeats at every prompt); control: it posts once
RGD="$T/guard-markfail"; mkdir -p "$RGD"; printf '[00:00 · W1] working\n' > "$RGD/board.md"; printf '.guard-W1\n' > "$FAILMV_FILE"; b0=$(cksum < "$RGD/board.md")
e=$(WARROOM_DIR="$RGD" PATH="$SH41:$PATH" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); r=$?
[ $r = 0 ] && [ "$(cksum < "$RGD/board.md")" = "$b0" ] && [ ! -e "$RGD/.guard-W1" ] && case "$e" in *"could not save the mark"*) true ;; *) false ;; esac && ok "guard: a mark that cannot be saved posts nothing, says so, exits 0" || bad "guard with a failed mark write: rc $r, '$e'"
rm -f "$FAILMV_FILE"; for _ in 1 2; do WARROOM_DIR="$RGD" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null >/dev/null 2>&1; done
[ "$(grep -c '@W1 ACTION: no board post' "$RGD/board.md")" = 1 ] && ok "guard control: without the fault it posts once per silence" || bad "guard control: $(grep -c '@W1 ACTION: no board post' "$RGD/board.md") posts"

# 42b. state-write order and arm identity.
#   (1) the gap marker cannot be written: the wake is not a delivery, the position is untouched, the next arm replays the line
DA="$T/wfixa"; mkdir -p "$DA"; printf '[00:00 · BOSS] one\n' > "$DA/board.md"
WARROOM_DIR="$DA" "$B/waiter.sh" W1 sid-t1 > "$T/t1.out" 2> "$T/t1.err" & WP=$!; sleep 2
c0=$(cksum < "$DA/.cursor-W1"); ln -s "$T/no-such-dir/marker" "$DA/.lastwake-W1"
WARROOM_DIR="$DA" "$B/board.sh" post BOSS "@W1 ACTION: marker fault line" >/dev/null
wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && grep -q "marker fault line" "$T/t1.out" && grep -q "printed but not marked" "$T/t1.err" && grep -q "gap marker" "$T/t1.err" && grep -q '^\[WAKE' "$T/t1.out" && [ "$(cksum < "$DA/.cursor-W1")" = "$c0" ] \
  && ok "wake: a gap marker that cannot be written is not a delivery (exit 1, header and lines printed first, position untouched)" || bad "wake with a failed gap marker: rc $r, out '$(cat "$T/t1.out")', err '$(cat "$T/t1.err")'"
rm -f "$DA/.lastwake-W1"; WARROOM_DIR="$DA" "$B/waiter.sh" W1 sid-t2 > "$T/t2.out" 2>/dev/null & WP=$!
if wait_exit $WP 8 && grep -q "marker fault line" "$T/t2.out"; then ok "wake: after the marker fault is gone the same line is delivered again"; else bad "wake after a failed marker write: the line was lost"; fi
kill $WP 2>/dev/null; wait $WP 2>/dev/null
#   (2) board.sh tail: the anchor moves only after the lines were written out
DB="$T/wfixb"; mkdir -p "$DB"; printf '[00:00 · BOSS] one\n' > "$DB/board.md"
WARROOM_DIR="$DB" "$B/board.sh" tail W1 >/dev/null; WARROOM_DIR="$DB" "$B/board.sh" post BOSS "line after the anchor" >/dev/null
a0=$(cksum < "$DB/.anchor-W1"); WARROOM_DIR="$DB" "$B/board.sh" tail W1 >&- 2> "$T/cat.err"; r=$?
[ $r = 1 ] && [ "$(cksum < "$DB/.anchor-W1")" = "$a0" ] && grep -q "could not write the lines" "$T/cat.err" && [ -z "$(find "$DB" -name '*tmp*' -o -name '*.chunk.*' -o -name '*.snap.*')" ] \
  && ok "tail: output that cannot be written exits 1 and leaves the anchor where it was" || bad "tail with closed output: rc $r, err '$(cat "$T/cat.err")'"
o=$(WARROOM_DIR="$DB" "$B/board.sh" tail W1); case "$o" in *"line after the anchor"*) ok "tail: the lines whose output failed come again" ;; *) bad "tail lost the lines after a failed output: '$o'" ;; esac
#   (3) a waiter that cannot read its own start time does not arm and writes no row
SHPS="$T/shim-ps"; mkdir -p "$SHPS"; printf '#!/bin/sh\nexit 1\n' > "$SHPS/ps"; chmod +x "$SHPS/ps"
DC="$T/wfixc"; mkdir -p "$DC"; printf '[00:00 · BOSS] one\n' > "$DC/board.md"; printf 'other-sid\tBOSS\t1\t00:00\n' > "$DC/seats.tsv"; s0=$(cksum < "$DC/seats.tsv")
WARROOM_DIR="$DC" PATH="$SHPS:$PATH" "$B/waiter.sh" W1 sid-p1 > /dev/null 2> "$T/p1.err" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && grep -q "cannot read the start time of this waiter" "$T/p1.err" && ! grep -q '^armed ' "$T/p1.err" && [ "$(cksum < "$DC/seats.tsv")" = "$s0" ] && [ ! -e "$DC/.cursor-W1" ] \
  && ok "arm: a start time that cannot be read means no arm, exit 1, no registry row, no position" || bad "arm with an unreadable start time: rc $r, '$(cat "$T/p1.err")'"
#   (4) a row with an empty start time is "cannot tell", never "alive"; only an old four-column row is judged by its pid
DD="$T/wfixd"; mkdir -p "$DD"; printf '[00:00 · BOSS] one\n' > "$DD/board.md"; sleep 60 & J=$!; sleep 0 & DEAD=$!; wait $DEAD 2>/dev/null
printf 'sid-e1\tW1\t%s\t00:00\t\nsid-e2\tBOSS\t%s\t00:00\nsid-e3\tW1\t%s\t00:00\t\n' "$J" "$J" "$DEAD" > "$DD/seats.tsv"; s0=$(cksum < "$DD/seats.tsv")
h1=$(printf '{"session_id": "sid-e1"}' | WARROOM_DIR="$DD" bash "$ROOT/hooks/waiter-check.sh" 2>&1)
h2=$(printf '{"session_id": "sid-e2"}' | WARROOM_DIR="$DD" bash "$ROOT/hooks/waiter-check.sh" 2>&1)
h3=$(printf '{"session_id": "sid-e3"}' | WARROOM_DIR="$DD" bash "$ROOT/hooks/waiter-check.sh" 2>&1)
case "$h1" in *"[WAITER UNCHECKED]"*) ok "hook: a live pid with an empty start time is reported as unchecked, not silent" ;; *) bad "hook on an empty-start row: '$h1'" ;; esac
[ -z "$h2" ] && ok "hook: an old four-column row with a live pid stays silent (pid judged alone)" || bad "hook on a four-column row: '$h2'"
case "$h3" in *"[WAITER ENDED]"*) ok "hook: an empty-start row whose pid is gone is reported as ended" ;; *) bad "hook on a dead empty-start row: '$h3'" ;; esac
WARROOM_DIR="$DD" "$B/waiter.sh" W1 sid-e4 > /dev/null 2> "$T/e4.err" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && grep -q "REFUSED" "$T/e4.err" && grep -q "not recorded" "$T/e4.err" && [ "$(cksum < "$DD/seats.tsv")" = "$s0" ] \
  && ok "arm: a seat held by a live pid with an empty start time is refused as unknown, registry untouched" || bad "arm against an empty-start holder: rc $r, '$(cat "$T/e4.err")'"
WARROOM_DIR="$DD" "$B/waiter.sh" BOSS sid-e5 > /dev/null 2> "$T/e5.err" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && grep -q "held by another live session" "$T/e5.err" && ok "arm: an old four-column row with a live pid still holds its seat" || bad "arm against a four-column holder: rc $r, '$(cat "$T/e5.err")'"
kill $J 2>/dev/null; wait $J 2>/dev/null
#   (5) pids.sh done and check: a ledger rename that fails keeps the ledger byte for byte and leaves no temp file
DE="$T/wfixe"; mkdir -p "$DE"; printf '[00:00 · BOSS] one\n' > "$DE/board.md"; sleep 60 & J=$!; sleep 60 & J2=$!
WARROOM_DIR="$DE" "$B/pids.sh" add keepjob "$J" BOSS >/dev/null; WARROOM_DIR="$DE" "$B/pids.sh" add deadjob "$J2" BOSS >/dev/null; cp "$DE/pids.tsv" "$T/wfixe.orig"
printf 'pids.tsv\n' > "$FAILMV_FILE"
WARROOM_DIR="$DE" PATH="$SH41:$PATH" "$B/pids.sh" "done" keepjob > /dev/null 2> "$T/d1.err"; r=$?
[ $r = 1 ] && grep -q "keepjob NOT removed" "$T/d1.err" && cmp -s "$T/wfixe.orig" "$DE/pids.tsv" && [ -z "$(find "$DE" -name '*tmp*')" ] \
  && ok "pids done: a failed ledger rename exits 1, says the row was not removed, keeps the ledger, leaves no temp file" || bad "pids done with a failed rename: rc $r, '$(cat "$T/d1.err")'"
kill $J2 2>/dev/null; wait $J2 2>/dev/null
WARROOM_DIR="$DE" PATH="$SH41:$PATH" "$B/pids.sh" check > /dev/null 2> "$T/c1.err"; r=$?
[ $r = 1 ] && grep -q "could not write the ledger" "$T/c1.err" && cmp -s "$T/wfixe.orig" "$DE/pids.tsv" && [ -z "$(find "$DE" -name '*tmp*')" ] \
  && ok "pids check: a failed ledger rename exits 1, keeps the ledger (a wake may repeat), leaves no temp file" || bad "pids check with a failed rename: rc $r, '$(cat "$T/c1.err")'"
rm -f "$FAILMV_FILE"
WARROOM_DIR="$DE" "$B/pids.sh" check > /dev/null 2>&1; r=$?
[ $r = 0 ] && ! grep -q '^deadjob' "$DE/pids.tsv" && grep -q '^keepjob' "$DE/pids.tsv" && ok "pids check control: without the fault the dead job is dropped and the live one kept" || bad "pids check control: rc $r, ledger '$(cat "$DE/pids.tsv")'"
WARROOM_DIR="$DE" "$B/pids.sh" "done" keepjob >/dev/null 2>&1; ! grep -q '^keepjob' "$DE/pids.tsv" && ok "pids done control: without the fault the row is removed" || bad "pids done control"
kill $J 2>/dev/null; wait $J 2>/dev/null

# 43. bootstrap: another writer wins the race between "board missing?" and "create it". Forced by a stub mkdir that plants a
#     first line at the moment the creating script makes the board's folder. The shipped code keeps that line; the old
#     truncating form (control, a mutated copy of bin/) loses it, so the fixture does discriminate.
SH42="$T/shim42"; mkdir -p "$SH42"; REALMKDIR=$(command -v mkdir)
cat > "$SH42/mkdir" <<SHIM
#!/bin/sh
if [ "\$1" = -p ] && [ "\$2" = "\$RACE_DIR" ] && [ ! -e "\$RACE_DIR/board.md" ]; then $REALMKDIR -p "\$2"; printf 'first writer line\n' >> "\$RACE_DIR/board.md"; fi
exec $REALMKDIR "\$@"
SHIM
chmod +x "$SH42/mkdir"
RACE="$T/race-ship"; WARROOM_DIR="$T/race-run1" BOARD="$RACE/board.md" RACE_DIR="$RACE" PATH="$SH42:$PATH" bash -c '. "$1"' _ "$C" >/dev/null 2>&1
[ "$(cat "$RACE/board.md" 2>/dev/null)" = "first writer line" ] && ok "bootstrap: a line written between the check and the create survives (forced race)" || bad "bootstrap race: the board holds '$(cat "$RACE/board.md" 2>/dev/null)'"
MUT="$T/mut42"; mkdir -p "$MUT"; cp -R "$B" "$MUT/bin"; sed 's/^    wr_create "\$BOARD_FILE" ||/  : > "$BOARD_FILE" ||/' "$B/_common.sh" > "$MUT/bin/_common.sh.new"; mv "$MUT/bin/_common.sh.new" "$MUT/bin/_common.sh"
RACE="$T/race-mut"; WARROOM_DIR="$T/race-run2" BOARD="$RACE/board.md" RACE_DIR="$RACE" PATH="$SH42:$PATH" bash -c '. "$1"' _ "$MUT/bin/_common.sh" >/dev/null 2>&1
[ -z "$(cat "$RACE/board.md" 2>/dev/null)" ] && ok "bootstrap control: the old truncating create loses that line, so the fixture catches it" || bad "bootstrap control: the old form did not lose the line; the fixture is blind"
unset FAILMV_FILE

# 44. the sample board teaches the real grammar: replayed through real waiters, W1, W2 and BOSS are each woken by exactly the
#     handoffs addressed to them (W1 once, W2 twice in one wake, BOSS once); an unstamped continuation line wakes nobody
RS="$T/sample"; mkdir -p "$RS"; SB="$ROOT/examples/4-seat/sample-board.md"; res=""
for s in W1 W2 BOSS; do
  : > "$RS/board.md"; rm -f "$RS"/.cursor-* "$RS"/.lastwake-* "$RS/seats.tsv"
  SEATS="BOSS MANAGER W1 W2" WARROOM_DIR="$RS" "$B/waiter.sh" "$s" "sid-s-$s" > "$RS/$s.out" 2>/dev/null & WP=$!; sleep 2
  cat "$SB" >> "$RS/board.md"; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null
  res="$res $s=$(grep -c "ACTION" "$RS/$s.out")/$(grep -c "@$s ACTION" "$RS/$s.out")"
done
[ "$res" = " W1=1/1 W2=2/2 BOSS=1/1" ] && ok "sample board: W1, W2 and BOSS are woken by exactly their own handoffs" || bad "sample board replay: '$res' (want W1=1/1 W2=2/2 BOSS=1/1)"
! grep -qE '^@(W1|W2|BOSS|MANAGER|ALL) ACTION' "$SB" && ok "sample board: no handoff line is an unstamped continuation" || bad "sample board: a handoff line has no stamp"

# 45-50. Where things go (destinations): the run folder W, the board B and the config file C are resolved from metadata
# before anything is created. Every case is a function of a fixture dir under $T, run against the tree in PB (bin/) and PHK
# (hooks/); section 59 runs the same functions against mutated copies. HOME and CLAUDE_CONFIG_DIR are fixture folders: no
# case reads or touches a real settings file.
PB="$B"; PHK="$ROOT/hooks"; PA_IN='{"session_id": "sid-pa"}'; PA_WHY=""; PA_SKIP=""; PA_NOTE=""
pa_setup() { PAW=$(cd -P "$(mktemp -d "$T/paw.XXXXXX")" && pwd -P); PAH="$PAW/h"; PAC="$PAW/cfg"; mkdir -p "$PAH" "$PAC" "$PAW/cwd"; }
pa_snap() { find "$PAW" -print 2>/dev/null | LC_ALL=C sort; }
pa_mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
pa_run() { ( cd "${PA_CWD:-$PAW/cwd}" && env HOME="$PAH" CLAUDE_CONFIG_DIR="$PAC" PYTHONDONTWRITEBYTECODE=1 WARROOM_ENV="$PAW/none.env" SEATS="BOSS W1" WARROOM_POLL=1 WARROOM_MIN_GAP=0 "$@" ); }
pa_exec() { PA_OUT=$(printf '%s' "$PA_IN" | pa_run "$@" 2>&1); PA_RC=$?; }
pa_pass() { pa_exec "$@"; [ "$PA_RC" = 0 ] || { PA_WHY="rc $PA_RC (want 0): $* -> $(printf '%s' "$PA_OUT" | head -c 160)"; return 1; }; }
# (pa_run sets PYTHONDONTWRITEBYTECODE=1: the Apple /usr/bin/python3 stub otherwise writes a bytecode cache under $HOME/Library,
# which is the interpreter creating a file, not a script of ours)
# pa_want PATTERN RC [ENV=VAL...] CMD [ARGS]: the run ends with RC, says PATTERN, and creates nothing under $PAW
pa_want() {
  _pat=$1; _wrc=$2; shift 2
  pa_snap > "$PAW.b"; pa_exec "$@"; pa_snap > "$PAW.a"
  [ "$PA_RC" = "$_wrc" ] || { PA_WHY="rc $PA_RC (want $_wrc): $* -> $(printf '%s' "$PA_OUT" | head -c 160)"; return 1; }
  printf '%s\n' "$PA_OUT" | grep -Eq -- "$_pat" || { PA_WHY="no '$_pat' in: $(printf '%s' "$PA_OUT" | head -c 160) ($*)"; return 1; }
  cmp -s "$PAW.b" "$PAW.a" || { PA_WHY="created: $(diff "$PAW.b" "$PAW.a" | grep '^[<>]' | head -3 | tr '\n' ' ') ($*)"; return 1; }
  return 0
}
pa_cfgbytes() { printf 'SEATS=BOSS W1\n' > "$1"; }

# 45. resolver: lexical gate, nearest existing ancestor, physical identity (R1-R5)
fx_r1() { # the config folder, spelled four lexical ways and through a symlink, is refused
  pa_setup; ln -s "$PAC" "$PAW/lnk-cfg"
  for w in "$PAC" "$PAC/" "$PAC/x/.." "$PAC/." "$PAW/lnk-cfg" "$PAW/lnk-cfg/"; do
    pa_want 'config folder|component' 2 WARROOM_DIR="$w" "$PB/board.sh" path || return 1
  done
}
fx_r2() { # an absent nested run folder is made only after the checks; the board is exactly under it (physical spelling)
  pa_setup
  pa_pass WARROOM_DIR="$PAW/fresh/a/b" "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAW/fresh/a/b/board.md" ] && [ -f "$PAW/fresh/a/b/board.md" ] || { PA_WHY="board path '$PA_OUT'"; return 1; }
  mkdir "$PAW/real"; ln -s "$PAW/real" "$PAW/lnk"
  pa_pass WARROOM_DIR="$PAW/lnk/f2/g" "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAW/lnk/f2/g/board.md" ] && [ -f "$PAW/real/f2/g/board.md" ] || { PA_WHY="symlinked spelling: '$PA_OUT'"; return 1; }
}
fx_r3() { # a refused board leaves a fresh run folder AND the board's parents uncreated (checks come before the bootstrap)
  pa_setup
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/w3" BOARD="$PAW/fresh2/x/settings.json" "$PB/board.sh" path || return 1
  [ ! -e "$PAW/w3" ] && [ ! -e "$PAW/fresh2" ] || { PA_WHY="w3 or fresh2 was created"; return 1; }
}
fx_r4() { # a parent that cannot be searched is refused, nothing created (skipped as root)
  if [ "$(id -u)" = 0 ]; then PA_SKIP="running as root: mode 000 does not block root"; return 0; fi
  pa_setup; mkdir "$PAW/r4"; chmod 000 "$PAW/r4"
  if ( cd "$PAW/r4" ) 2>/dev/null; then chmod 755 "$PAW/r4"; PA_SKIP="the folder stayed accessible (an ACL or a privileged user)"; return 0; fi
  pa_want 'cannot be resolved' 2 WARROOM_DIR="$PAW/r4/w" "$PB/board.sh" path; _r=$?; chmod 755 "$PAW/r4"; return $_r
}
fx_r5() { # a board with a trailing /, an existing folder, a folder symlink, or a folder above the run folder
  pa_setup; mkdir -p "$PAW/r5/d" "$PAW/r5/t"; ln -s "$PAW/r5/d" "$PAW/r5/dl"
  pa_want 'board|BOARD' 2 WARROOM_DIR="$PAW/r5" BOARD="$PAW/r5/b/" "$PB/board.sh" path || return 1
  pa_want 'board|BOARD' 2 WARROOM_DIR="$PAW/r5" BOARD=d "$PB/board.sh" path || return 1
  pa_want 'board|BOARD' 2 WARROOM_DIR="$PAW/r5" BOARD=dl "$PB/board.sh" path || return 1
  pa_want 'above the run folder' 2 WARROOM_DIR="$PAW/a/w" BOARD="$PAW/a" "$PB/board.sh" path || return 1
  [ ! -e "$PAW/a" ] || { PA_WHY="$PAW/a was created"; return 1; }
}

# 46. an absolute run folder; the board goes under it; the validated values cannot be reassigned (R6, R7)
fx_r6() {
  pa_setup; mkdir -p "$PAW/p1" "$PAW/p2"
  pa_want 'WARROOM_DIR must be an absolute path' 2 WARROOM_DIR=run "$PB/board.sh" path || return 1
  pa_want 'WARROOM_ENV must be an absolute path' 2 WARROOM_ENV=rel.env WARROOM_DIR="$PAW/r6" "$PB/board.sh" path || return 1
  for b in ./board.md ../x a/./b; do
    pa_want 'BOARD must not contain \. or \.\. components; write board\.md' 2 WARROOM_DIR="$PAW/r6" BOARD="$b" "$PB/board.sh" path || return 1
  done
  PA_CWD="$PAW/p1" pa_pass WARROOM_DIR="$PAW/r6" BOARD=board.md "$PB/board.sh" path || return 1; _a=$PA_OUT
  PA_CWD="$PAW/p2" pa_pass WARROOM_DIR="$PAW/r6" BOARD=board.md "$PB/board.sh" path || return 1
  [ "$_a" = "$PA_OUT" ] && [ "$_a" = "$PAW/r6/board.md" ] && [ ! -e "$PAW/p1/board.md" ] && [ ! -e "$PAW/p2/board.md" ] || { PA_WHY="board path from p1 '$_a', p2 '$PA_OUT'"; return 1; }
}
fx_r7a() { # W cannot be reassigned by a script that sourced _common.sh
  pa_setup; pa_exec WARROOM_DIR="$PAW/r7" bash -c '. "$1"; W=/elsewhere; echo "w=$W"' _ "$PB/_common.sh"
  case "$PA_OUT" in *"W: readonly variable"*) case "$PA_OUT" in *elsewhere*) ;; *) return 0 ;; esac ;; esac; PA_WHY="W was assignable: $PA_OUT"; return 1
}
fx_r7b() { # BOARD_FILE cannot be reassigned either
  pa_setup; pa_exec WARROOM_DIR="$PAW/r7" bash -c '. "$1"; BOARD_FILE=/elsewhere; echo "b=$BOARD_FILE"' _ "$PB/_common.sh"
  case "$PA_OUT" in *"BOARD_FILE: readonly variable"*) case "$PA_OUT" in *elsewhere*) ;; *) return 0 ;; esac ;; esac; PA_WHY="BOARD_FILE was assignable: $PA_OUT"; return 1
}
fx_r7c() { # a child started with BOARD=settings.json re-validates and is refused
  pa_setup; pa_pass WARROOM_DIR="$PAW/r7" "$PB/board.sh" path || return 1
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/r7" bash -c 'BOARD=settings.json "$1" path' _ "$PB/board.sh"
}

fx_r8() { # a HOME with a trailing / (or HOME=/) is the same HOME: the default config path and ~/ values add no second /
  pa_setup
  pa_pass HOME="$PAH/" WARROOM_DIR="$PAW/r8a" bash -c 'unset WARROOM_ENV; exec "$@"' _ "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAW/r8a/board.md" ] || { PA_WHY="HOME with a trailing /: board '$PA_OUT'"; return 1; }
  pa_pass HOME=/ WARROOM_DIR="$PAW/r8b" bash -c 'unset WARROOM_ENV; exec "$@"' _ "$PB/board.sh" path || return 1
  printf 'WARROOM_DIR=~/sub\n' > "$PAW/r8.env"
  pa_pass HOME="$PAH/" WARROOM_ENV="$PAW/r8.env" bash -c 'unset WARROOM_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAH/sub/board.md" ] || { PA_WHY="a home-relative value under HOME with a trailing /: board '$PA_OUT'"; return 1; }
  # a bare ~ stays HOME as written (line 23 of _config.sh): HOME with a trailing / still gives HOME/board.md, HOME=/ is refused
  printf 'WARROOM_DIR=~\n' > "$PAW/r8c.env"
  pa_pass HOME="$PAH/" WARROOM_ENV="$PAW/r8c.env" bash -c 'unset WARROOM_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
  [ "$PA_OUT" = "$PAH/board.md" ] || { PA_WHY="a bare ~ with HOME ending in /: board '$PA_OUT'"; return 1; }
  pa_want 'names no folder or file' 2 HOME=/ WARROOM_ENV="$PAW/r8c.env" bash -c 'unset WARROOM_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
}

# 47. settings names, reserved state names, the board's own aliases (N1-N5)
fx_n1() {
  pa_setup; mkdir -p "$PAW/n1b"; printf 'keep' > "$PAW/n1b/settings.json"; _k=$(cksum < "$PAW/n1b/settings.json")
  _sl=settings.l; _sl="${_sl}ocal.json"
  for n in settings.json Settings.JSON "$_sl" MANAGED-settings.json .Claude.json; do
    pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1a" BOARD="$n" "$PB/board.sh" post BOSS hello || return 1
  done
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1b" BOARD=settings.json "$PB/board.sh" post BOSS hello || return 1
  [ "$(cksum < "$PAW/n1b/settings.json")" = "$_k" ] || { PA_WHY="an existing settings.json changed"; return 1; }
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1c/SETTINGS.json" "$PB/board.sh" path || return 1
  pa_want 'settings file' 2 WARROOM_DIR="$PAW/n1a" BOARD=Settings.JSON "$PB/waiter.sh" W1 sid-n1 || return 1
  for h in waiter-check board-tail board-guard; do
    pa_want 'settings file' 1 WARROOM_DIR="$PAW/n1a" BOARD=settings.json "$PHK/$h.sh" || return 1
  done
  pa_want 'cannot locate the Claude Code config folder' 2 CLAUDE_CONFIG_DIR=cfg WARROOM_DIR="$PAW/n1d" "$PB/board.sh" path || return 1
  pa_want 'cannot locate' 2 WARROOM_DIR="$PAW/n1d" bash -c 'unset HOME CLAUDE_CONFIG_DIR; exec "$@"' _ "$PB/board.sh" path || return 1
  pa_want 'cannot locate' 2 WARROOM_DIR="$PAW/n1d" bash -c 'unset CLAUDE_CONFIG_DIR; exec env HOME=rel "$@"' _ "$PB/board.sh" path || return 1
  pa_want 'cannot locate' 2 WARROOM_DIR="$PAW/n1d" HOME= bash -c 'unset CLAUDE_CONFIG_DIR; exec "$@"' _ "$PB/board.sh" path
}
fx_n2() {
  pa_setup; W="$PAW/n2/w"
  for n in seats.tsv pids.tsv .cursor-W1 .lastwake-W1 .anchor-W1 .guard-W1 .poll-W1.123 .snap-W1.123 .wrtmp.abcd1234 x.flock b.tmp.123 b.chunk.123 .LASTWAKE-W1 SEATS.TSV \
           seats.tsv/board.md sub/.anchor-W1/b.md .wrtmp.q/b.md "$W/.cursor-W1/b.md"; do
    pa_want 'name this tool writes|ends in \.flock' 2 WARROOM_DIR="$W" BOARD="$n" "$PB/board.sh" path || return 1
  done
  mkdir -p "$PAW/n2e"; printf 'x' > "$PAW/n2e/seats.tsv"; _k=$(cksum < "$PAW/n2e/seats.tsv")
  pa_want 'name this tool writes' 2 WARROOM_DIR="$PAW/n2e" BOARD=seats.tsv "$PB/board.sh" path || return 1
  [ "$(cksum < "$PAW/n2e/seats.tsv")" = "$_k" ] || { PA_WHY="an existing seats.tsv changed"; return 1; }
  for n in board.tmp.md x.tmp.d/b.md sub/board.md; do   # not reserved: board.tmp.md, a folder named x.tmp.d, a plain subfolder
    pa_pass WARROOM_DIR="$PAW/n2c" BOARD="$n" "$PB/board.sh" path || return 1; rm -rf "${PAW:?}/n2c"
  done
}
fx_n3() {
  pa_setup; W="$PAW/n3/w"; mkdir -p "$W"; pa_cfgbytes "$PAW/n3/c.env"; _k=$(cksum < "$PAW/n3/c.env")
  pa_want 'config file' 2 WARROOM_ENV="$PAW/n3/c.env" WARROOM_DIR="$W" BOARD="$PAW/n3/c.env" "$PB/board.sh" path || return 1
  [ "$(cksum < "$PAW/n3/c.env")" = "$_k" ] || { PA_WHY="the config file changed"; return 1; }
  printf 'row\n' > "$W/pids.tsv"; ln "$W/pids.tsv" "$W/b.md"
  pa_want 'same file as a state entry' 2 WARROOM_DIR="$W" BOARD=b.md "$PB/board.sh" path || return 1
  ln -s "$W" "$PAW/link-to-W"
  pa_want 'name this tool writes' 2 WARROOM_DIR="$W" BOARD="$PAW/link-to-W/seats.tsv" "$PB/board.sh" path
}
fx_n4() { # controls: a plain subfolder board; an external board (its lock file appears beside it, as documented)
  pa_setup
  pa_pass WARROOM_DIR="$PAW/n4" BOARD=sub/board.md "$PB/board.sh" path || return 1
  pa_pass WARROOM_DIR="$PAW/n4" BOARD="$PAW/ext/board.md" "$PB/board.sh" post BOSS hi || return 1
  [ -f "$PAW/ext/board.md.flock" ] && grep -q hi "$PAW/ext/board.md" || { PA_WHY="no ext/board.md.flock after the post"; return 1; }
}
fx_n5() { # a fullwidth lookalike of settings.json is not folded: accepted (a stated limit); the filesystem's own answer is recorded
  pa_setup; mkdir -p "$PAW/n5"; : > "$PAW/n5/settings.json"; _fw=$(printf '\357\275\223ettings.json')
  pa_pass WARROOM_DIR="$PAW/n5" BOARD="$_fw" "$PB/board.sh" path || return 1
  [ -f "$PAW/n5/$_fw" ] || { PA_WHY="lookalike board not created"; return 1; }
  if [ "$PAW/n5/$_fw" -ef "$PAW/n5/settings.json" ]; then PA_NOTE="observed: the filesystem treats the lookalike as the same file"; else PA_NOTE="observed: the filesystem makes a distinct entry for the lookalike"; fi
}

# 48. the config file at a name this tool writes (N6)
fx_n6a() { # absent and existing, at each derived slot of the run folder
  pa_setup; W="$PAW/n6"
  for slot in .anchor-W1 seats.tsv pids.tsv .guard-W1 .lastwake-W1 .cursor-W1 .anchor-W9 board.md.flock .wrtmp.q1; do
    pa_want 'name this tool writes|lock file|ends in \.flock' 2 WARROOM_ENV="$W/$slot" WARROOM_DIR="$W" "$PB/board.sh" path || return 1   # absent
    mkdir -p "$W"; pa_cfgbytes "$W/$slot"; _k=$(cksum < "$W/$slot"); _m=$(pa_mt "$W/$slot")
    pa_want 'name this tool writes|lock file|ends in \.flock' 2 WARROOM_ENV="$W/$slot" WARROOM_DIR="$W" "$PB/board.sh" path || return 1   # existing
    [ "$(cksum < "$W/$slot")" = "$_k" ] && [ "$(pa_mt "$W/$slot")" = "$_m" ] || { PA_WHY="config at $slot changed"; return 1; }
    rm -rf "${W:?}"
  done
}
fx_n6b() { # under a nested reserved component, and the control at a plain name
  pa_setup; W="$PAW/n6"
  pa_want 'name this tool writes' 2 WARROOM_ENV="$W/.cursor-W1/sub/warroom.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  mkdir -p "$W/.cursor-W1/sub"; pa_cfgbytes "$W/.cursor-W1/sub/warroom.env"
  pa_want 'name this tool writes' 2 WARROOM_ENV="$W/.cursor-W1/sub/warroom.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  rm -rf "${W:?}"; mkdir -p "$W"; pa_cfgbytes "$W/warroom.env"
  pa_pass WARROOM_ENV="$W/warroom.env" WARROOM_DIR="$W" "$PB/board.sh" path
}
fx_n6c() { # the same file under another name: a hard link to a state entry or to the board's lock file; a dangling link to a slot
  pa_setup; W="$PAW/n6"; mkdir -p "$W"
  pa_cfgbytes "$W/.anchor-W1"; ln "$W/.anchor-W1" "$PAW/hl-anchor.env"
  pa_want 'same file as a state entry|name this tool writes' 2 WARROOM_ENV="$PAW/hl-anchor.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  pa_cfgbytes "$W/board.md.flock"; ln "$W/board.md.flock" "$PAW/hl-flock.env"
  pa_want 'lock file' 2 WARROOM_ENV="$PAW/hl-flock.env" WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  rm -f "${W:?}/.anchor-W1"; ln -s "$W/.anchor-W1" "$PAW/dangling.env"
  pa_want 'name this tool writes' 2 WARROOM_ENV="$PAW/dangling.env" WARROOM_DIR="$W" "$PB/board.sh" path
}
fx_n6d() { # a config path whose links loop is refused; a dangling link elsewhere stays allowed
  pa_setup; ln -s "$PAW/loop2" "$PAW/loop1"; ln -s "$PAW/loop1" "$PAW/loop2"
  pa_want 'config path loops' 2 WARROOM_ENV="$PAW/loop1" WARROOM_DIR="$PAW/n6d" "$PB/board.sh" path || return 1
  ln -s "$PAW/nowhere.env" "$PAW/dangling-ok.env"
  pa_pass WARROOM_ENV="$PAW/dangling-ok.env" WARROOM_DIR="$PAW/n6d" "$PB/board.sh" path
}

# 49. seat arguments that become paths (S1, S2)
fx_s1() {
  pa_setup; W="$PAW/s1"
  pa_exec WARROOM_DIR="$W" "$PB/board.sh" tail ../x
  [ "$PA_RC" = 2 ] && [ "$(find "$W" -print | LC_ALL=C sort | tr '\n' ' ')" = "$W $W/board.md " ] || { PA_WHY="fresh run: rc $PA_RC, new entries: $(find "$W" -print | LC_ALL=C sort | tr '\n' ' ')"; return 1; }
  for a in ../x W1/x "" w1 ZZ NONE; do
    pa_want 'unknown seat|usage' 2 WARROOM_DIR="$W" "$PB/board.sh" tail "$a" || return 1
  done
  pa_want 'usage' 2 WARROOM_DIR="$W" "$PB/board.sh" tail || return 1
  pa_want 'unknown seat' 2 WARROOM_DIR="$W" "$PB/waiter.sh" ../x sid-s1 || return 1
}
fx_s2() { # a registry row is data: a seat outside SEATS is not trusted by the read hooks
  pa_setup; W="$PAW/s2"; pa_pass WARROOM_DIR="$W" "$PB/board.sh" path || return 1
  printf '[00:00 · BOSS] hello\n' >> "$W/board.md"; printf 'sid-pa\t../x\t99999\tx\tstart\n' > "$W/seats.tsv"
  pa_want 'unknown seat in registry' 0 WARROOM_DIR="$W" "$PHK/waiter-check.sh" || return 1
  pa_want '^$' 0 WARROOM_DIR="$W" "$PHK/board-tail.sh" || return 1
  printf 'sid-pa\tW1\t99999\tx\tstart\n' > "$W/seats.tsv"
  pa_pass WARROOM_DIR="$W" "$PHK/board-tail.sh" || return 1
  case "$PA_OUT" in *"[BOARD]"*) return 0 ;; esac; PA_WHY="control (registry seat W1) printed '$PA_OUT'"; return 1
}

# 50. python3 is required; hook exits (P1, P2, H1)
fx_p1() {
  pa_setup; mkdir -p "$PAW/nopy" "$PAW/brokenpy"
  for t in dirname bash; do ln -s "$(command -v $t)" "$PAW/nopy/$t"; done
  for t in dirname bash; do ln -s "$(command -v $t)" "$PAW/brokenpy/$t"; done
  printf '#!/bin/sh\nexit 1\n' > "$PAW/brokenpy/python3"; chmod +x "$PAW/brokenpy/python3"
  for d in nopy brokenpy; do
    pa_want 'python3 is required' 2 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PB/board.sh" path || return 1
    pa_want 'python3 is required' 2 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PB/waiter.sh" W1 sid-p1 || return 1
    pa_want 'python3 is required' 2 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PB/pids.sh" check || return 1
    for h in waiter-check board-tail board-guard; do
      pa_want 'python3 is required' 1 PATH="$PAW/$d" WARROOM_DIR="$PAW/p1" "$PHK/$h.sh" || return 1
    done
  done
}
fx_p2() { # python3 passes the startup check and fails only the hook's JSON parse: exit 1 with a message, never a silent 0
  pa_setup; mkdir -p "$PAW/shim"; _py=$(command -v python3); pa_pass WARROOM_DIR="$PAW/p2" "$PB/board.sh" path || return 1
  printf '#!/bin/sh\ncase "$*" in *json*) echo "shim: json failed" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$_py" > "$PAW/shim/python3"; chmod +x "$PAW/shim/python3"
  for h in waiter-check board-tail; do
    pa_want 'could not read the hook input' 1 PATH="$PAW/shim:$PATH" WARROOM_DIR="$PAW/p2" "$PHK/$h.sh" || return 1
  done
  PA_IN='not json'; for h in waiter-check board-tail; do pa_want 'could not read the hook input' 1 WARROOM_DIR="$PAW/p2" "$PHK/$h.sh" || { PA_IN='{"session_id": "sid-pa"}'; return 1; }; done
  PA_IN='{"session_id": "sid-pa"}'
}
fx_p3() { # a json.py planted in the folder the hook runs from is never imported: the hooks start python3 isolated
  pa_setup; mkdir -p "$PAW/plant"; printf 'open("PWNED", "w").write("ran")\ndef load(f):\n    return {"session_id": "sid-pa"}\n' > "$PAW/plant/json.py"
  PA_CWD="$PAW/plant"
  for h in waiter-check board-tail; do
    pa_pass WARROOM_DIR="$PAW/p3" "$PHK/$h.sh" || { PA_CWD=""; return 1; }
    [ ! -e "$PAW/plant/PWNED" ] || { PA_WHY="$h imported the json.py from its working folder"; PA_CWD=""; return 1; }
  done
  PA_CWD=""
}
fx_h1() { # a bad warroom.env: every hook exits 1, never 2, and the message names the line
  pa_setup; printf 'SEATS=$(touch x)\n' > "$PAW/bad.env"
  for h in waiter-check board-tail board-guard; do
    pa_want 'warroom\.env line 1' 1 WARROOM_ENV="$PAW/bad.env" WARROOM_DIR="$PAW/h1" "$PHK/$h.sh" || return 1
  done
}
pa_run_fx() { # pa_run_fx FIXTURE "what it shows": ok, a printed skip, or FAIL with the assert that fired
  PA_WHY=""; PA_SKIP=""; PA_NOTE=""
  if "$1"; then if [ -n "$PA_SKIP" ]; then echo "skip $2 ($PA_SKIP)"; else ok "$2${PA_NOTE:+ [$PA_NOTE]}"; fi; else bad "$2: $PA_WHY"; fi
}
_TP=$(cd -P "$T" && pwd -P); pa_setup; case "$PAH$PAC" in "$_TP"/*"$_TP"/*) ok "destinations: the fixture HOME and CLAUDE_CONFIG_DIR are under the temp dir" ;; *) bad "destinations: fixture HOME/CLAUDE_CONFIG_DIR are not under $T" ;; esac
pa_setup; if [ -x /usr/bin/python3 ]; then pa_run /usr/bin/python3 -c 'import json, os, re' >/dev/null 2>&1; [ ! -e "$PAH/Library" ] && ok "interpreter: the system python3, run the way every fixture runs it, leaves nothing under the fixture HOME" || bad "interpreter: the system python3 created $(find "$PAH" -print | head -3 | tr '\n' ' ')"; fi
pa_run_fx fx_r1 "resolver: the config folder is refused however it is spelled (trailing /, /./, /x/.., a symlink to it)"
pa_run_fx fx_r2 "resolver: an absent nested run folder is made after the checks, and the board is exactly under it (also through a symlink spelling)"
pa_run_fx fx_r3 "resolver: a refused board leaves a fresh run folder and the board's parents uncreated"
pa_run_fx fx_r4 "resolver: a parent that cannot be searched is refused and nothing is created"
pa_run_fx fx_r5 "resolver: a board with a trailing /, an existing folder, a folder symlink, or a folder above the run folder is refused"
pa_run_fx fx_r6 "absolute paths: a relative WARROOM_DIR or WARROOM_ENV, and BOARD with ./ ../ or /./, are refused; a relative BOARD gives one path from any cwd"
pa_run_fx fx_r7a "readonly: a script that sourced _common.sh cannot reassign W"
pa_run_fx fx_r7b "readonly: a script that sourced _common.sh cannot reassign BOARD_FILE"
pa_run_fx fx_r7c "readonly: a child started with BOARD=settings.json re-validates and is refused"
pa_run_fx fx_r8 "HOME: a trailing / (or HOME=/) is accepted; the default config path and a ~/ value in warroom.env add no second /"
pa_run_fx fx_n1 "settings names: the four Claude Code settings file names (any case) are refused for W and B by post, waiter and the hooks; an unlocatable config folder is refused"
pa_run_fx fx_n2 "reserved names: all 12 families, nested and mixed case, are refused for the board; board.tmp.md, x.tmp.d/ and a plain subfolder are not"
pa_run_fx fx_n3 "aliases: the board as the config file, as a hard link of a state entry, or reached through a symlinked run folder, is refused"
pa_run_fx fx_n4 "controls: a subfolder board and an external board work (the external board's lock file appears beside it)"
pa_run_fx fx_n5 "limit: a fullwidth lookalike of settings.json is not folded (accepted, as the docs state)"
pa_run_fx fx_n6a "config at a state slot: absent or existing at each slot of the run folder is refused before bootstrap, bytes and mtime unchanged"
pa_run_fx fx_n6b "config at a state slot: under a nested reserved component is refused; warroom.env at a plain name works"
pa_run_fx fx_n6c "config at a state slot: a hard link to a state entry or the board's lock file, or a dangling link to a slot, is refused"
pa_run_fx fx_n6d "config at a state slot: a looping config link is refused; a dangling link elsewhere is allowed"
pa_run_fx fx_s1 "seat arguments: board.sh tail with ../x, W1/x, empty, omitted, w1, ZZ and NONE exits 2 and creates no per-seat file; so does waiter.sh ../x"
pa_run_fx fx_s2 "seat arguments: a registry row with a seat outside SEATS is not trusted by waiter-check (says so, exit 0) or board-tail (silent, exit 0)"
pa_run_fx fx_p1 "python3: missing or broken, every bin/ script exits 2 and every hook exits 1 with 'python3 is required' before anything is created"
pa_run_fx fx_p2 "python3: a failing JSON parse makes both read hooks exit 1 with a message, never a silent 0"
pa_run_fx fx_p3 "python3: a json.py planted in the hook's working folder is not imported (both read hooks start python3 with -I -S)"
pa_run_fx fx_h1 "hooks: a bad warroom.env exits 1 (never 2) and names the line"

SH51="$T/shim51"; mkdir -p "$SH51"; REALPY=$(command -v python3)
PS_OK=1; [ -n "$(ps -o lstart= -p $$ 2>/dev/null)" ] || PS_OK=0   # sections 51-55 and their mutants arm waiters, which need ps to read a start time; without it they are skipped, printed as skips

# 51. links and hard links at state leaves (PR B). A protected state file that is a link, or has a second name, is refused: the
#     link target is never created or written, and the temp that was made is removed. Cleanup success and failure are separate cases.
L51="$T/l51"; mkdir -p "$L51/tgt"
l51_base() { rm -rf "$L51/w" "$L51/tgt"; mkdir -p "$L51/w" "$L51/tgt"; printf '[00:00 · BOSS] one\n' > "$L51/w/board.md"; }
l51_clean() { [ ! -e "$L51/tgt/$1" ] && [ -L "$L51/w/$1" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ]; }
# L1: a dangling link at each protected file; the arm / add / guard is refused, the link still points at nothing, no temp is left
if [ "$PS_OK" = 1 ]; then
l51_base; ln -s "$L51/tgt/seats.tsv" "$L51/w/seats.tsv"
WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-l1 >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && l51_clean seats.tsv && ok "links: a dangling link at the seat registry is refused by the arm (exit 1), nothing created behind it, no temp left" || bad "links: registry link: rc $r, '$(cat "$L51/e")'"
l51_base; ln -s "$L51/tgt/pids.tsv" "$L51/w/pids.tsv"; WARROOM_DIR="$L51/w" "$B/pids.sh" add l1job $$ W1 >/dev/null 2>"$L51/e"; r=$?
[ $r = 1 ] && l51_clean pids.tsv && ok "links: a dangling link at the job ledger is refused by pids.sh add (exit 1), nothing created behind it" || bad "links: ledger link: rc $r, '$(cat "$L51/e")'"
l51_base; ln -s "$L51/tgt/.cursor-W1" "$L51/w/.cursor-W1"
WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-l1c >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && l51_clean .cursor-W1 && ok "links: a dangling link at the cursor is refused by the arm (exit 1), nothing created behind it" || bad "links: cursor link: rc $r, '$(cat "$L51/e")'"
else echo "skip links: dangling link at the registry, ledger, cursor (ps cannot read process start times here, so a waiter cannot arm)"; fi
l51_base; printf '[00:00 · W1] working\n' > "$L51/w/board.md"; ln -s "$L51/tgt/.guard-W1" "$L51/w/.guard-W1"; b0=$(cksum < "$L51/w/board.md")
e=$(WARROOM_DIR="$L51/w" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); r=$?
[ $r = 0 ] && l51_clean .guard-W1 && [ "$(cksum < "$L51/w/board.md")" = "$b0" ] && ok "links: a dangling link at the guard mark is refused (exit 0, no post, nothing created behind it)" || bad "links: guard mark link: rc $r, '$e'"
if [ "$PS_OK" = 1 ]; then
# L1 delivery: a dangling link at the gap marker; the wake is not a delivery (exit 1), the position stays, the target is not created
l51_base; WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-l1d > "$L51/o" 2>"$L51/e" & WP=$!; sleep 2; ln -s "$L51/tgt/.lastwake-W1" "$L51/w/.lastwake-W1"; c0=$(cksum < "$L51/w/.cursor-W1")
WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: link marker line" >/dev/null; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && l51_clean .lastwake-W1 && [ "$(cksum < "$L51/w/.cursor-W1")" = "$c0" ] && grep -q "link marker line" "$L51/o" && grep -q "printed but not marked" "$L51/e" \
  && ok "links: a dangling link at the gap marker is refused at the delivery (exit 1, position kept, nothing created behind it)" || bad "links: marker link: rc $r, '$(cat "$L51/e")'"
else echo "skip links: dangling link at the gap marker (ps cannot read process start times here, so a waiter cannot arm)"; fi
# L1b: wr_replace called directly on a symlinked FINAL (wr_lock would refuse first in the full path): refused, target absent, the recorded temp removed
l51_base; ln -s "$L51/tgt/final" "$L51/w/final"
e=$(WARROOM_DIR="$L51/w" bash -c '. "$1/_common.sh"; wr_temp "$2/final" || exit 9; t=$_WR_TMP; echo data > "$t"; wr_replace "$t" "$2/final"; echo "rc=$?"; [ -e "$t" ] && echo "TEMP-LEFT"' _ "$B" "$L51/w" 2>&1)
case "$e" in *"refusing to replace"*"rc=1"*) true ;; *) false ;; esac && l51_clean final && case "$e" in *TEMP-LEFT*) false ;; *) true ;; esac && ok "links: wr_replace on a symlinked file is refused (rc 1), the link target stays absent, the temp is removed" || bad "links: wr_replace on a link: '$e'"
if [ "$PS_OK" = 1 ]; then
# L2: the gap marker is a hard link to another file; the delivery reaches the marker step (stderr), exits 1, and that file is byte, time and link-count equal
l51_base; printf 'outside file\n' > "$L51/out"; ln "$L51/out" "$L51/w/.lastwake-W1"; sleep 1; o0=$(cksum < "$L51/out"); m0=$(stat -c %Y "$L51/out" 2>/dev/null || stat -f %m "$L51/out")
WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-l2 > "$L51/o" 2>"$L51/e" & WP=$!; sleep 2; WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: hard link marker line" >/dev/null
wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
m1=$(stat -c %Y "$L51/out" 2>/dev/null || stat -f %m "$L51/out"); n1=$(stat -c %h "$L51/out" 2>/dev/null || stat -f %l "$L51/out")
[ $r = 1 ] && grep -q "printed but not marked" "$L51/e" && [ "$(cksum < "$L51/out")" = "$o0" ] && [ "$m1" = "$m0" ] && [ "$n1" = 2 ] \
  && ok "links: a gap marker with a second name is refused at the delivery (exit 1); the other name keeps its bytes, time and link count" || bad "links: marker hard link: rc $r, mtime $m0->$m1, links $n1, '$(cat "$L51/e")'"
# L3: FINAL becomes a directory AFTER the precheck (a python3 shim does it right before the real os.replace): exit 1, the directory stays empty
# (an "mv" replace would move the temp INTO it)
SH51="$T/shim51"; mkdir -p "$SH51"; REALPY=$(command -v python3)
cat > "$SH51/python3" <<SHIM
#!/bin/sh
case "\$*" in *os.replace*.cursor-W1) for a in "\$@"; do f=\$a; done; rm -f "\$f"; mkdir "\$f" ;; esac
exec $REALPY "\$@"
SHIM
chmod +x "$SH51/python3"; l51_base
WARROOM_DIR="$L51/w" PATH="$SH51:$PATH" "$B/waiter.sh" W1 sid-l3 >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && [ -d "$L51/w/.cursor-W1" ] && [ -z "$(ls -A "$L51/w/.cursor-W1")" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && ok "links: a file turned into a directory after the precheck is not written into (exit 1, the directory stays empty, no temp left)" || bad "links: directory swap: rc $r, '$(cat "$L51/e")', content '$(ls -A "$L51/w/.cursor-W1" 2>&1)'"
else echo "skip links: gap marker hard link, directory swap (ps cannot read process start times here, so a waiter cannot arm)"; fi

# 52. temps and write failures (PR B). Faults are PATH shims that read $FAULT55/<tool> and fail every matching call while the file exists:
#     mktemp "all" | "first" (no temp in the folder yet = the snapshot) | "second" (one exists = the chunk); awk "all" | "filter"
#     (only the wake filter); cksum "all" | a byte count (only the call whose input has that size); rm (cleanup of a .wrtmp.* temp).
FAULT55="$T/fault55"; mkdir -p "$FAULT55"; SH55="$T/shim55"; mkdir -p "$SH55"
for tool in mktemp awk cksum rm; do
  real=$(command -v $tool)
  case $tool in
  mktemp) cond='d=$(dirname "$1"); have=$(ls -A "$d" 2>/dev/null | grep -c "^[.]wrtmp[.]"); { [ "$k" = all ] || { [ "$k" = first ] \&\& [ "$have" = 0 ]; } || { [ "$k" = second ] \&\& [ "$have" != 0 ]; }; } \&\& { echo "shim: mktemp refused" >\&2; exit 1; }' ;;
  awk)    cond='{ [ "$k" = all ] || { [ "$k" = filter ] \&\& [ "$1" = -v ] \&\& case "$2" in seat=*) true ;; *) false ;; esac; }; } \&\& { echo "shim: awk refused" >\&2; exit 1; }' ;;
  rm)     cond='case "$*" in *.wrtmp.*) echo "shim: rm refused" >\&2; exit 1 ;; esac' ;;
  cksum)  cond='in="$f.in.$$"; cat > "$in"; sz=$(wc -c < "$in" | tr -d " "); if [ "$k" = all ] || [ "$k" = "$sz" ]; then rm -f "$in"; echo "shim: cksum refused" >\&2; exit 1; fi; "'$real'" < "$in"; r=$?; rm -f "$in"; exit $r' ;;
  esac
  cond=$(printf '%s' "$cond" | sed 's/\\&/\&/g')
  printf '#!/bin/sh\nf="%s/%s"\nif [ -f "$f" ]; then k=$(cat "$f"); %s\nfi\nexec %s "$@"\n' "$FAULT55" "$tool" "$cond" "$real" > "$SH55/$tool"; chmod +x "$SH55/$tool"
done
fault_set() { rm -f "$FAULT55/$1" "$FAULT55/$1.cnt"; printf '%s\n' "$2" > "$FAULT55/$1"; }
fault_clear() { rm -f "$FAULT55"/*; }
l52_base() { rm -rf "$L51/w"; mkdir -p "$L51/w"; printf '[00:00 · BOSS] one\n[00:00 · BOSS] two\n' > "$L51/w/board.md"; printf 'other-sid\tBOSS\t1\t00:00\n' > "$L51/w/seats.tsv"; }
l52_dir() { ls -A "$L51/w" | tr '\n' ' '; }
if [ "$PS_OK" = 1 ]; then
# L4: legacy same-PID temp names are planted (links and a hard link) and the waiter is exec'd in the SAME pid: nothing planted is written through or removed
l51_base; printf 'victim\n' > "$L51/victim"; v0=$(cksum < "$L51/victim"); printf 'seats\n' > "$L51/hl"; ln "$L51/hl" "$L51/w/.hardtmp"; mkdir "$L51/w/.wrtmp.PLANTED"
WARROOM_DIR="$L51/w" bash -c 'ln -s "$1/victim" "$2/.cursor-W1.tmp.$$"; ln -s "$1/victim" "$2/seats.tsv.tmp.$$"; ln -s "$1/victim" "$2/.anchor-W1.tmp.$$"; exec "$3/waiter.sh" W1 sid-l4' _ "$L51" "$L51/w" "$B" >/dev/null 2>"$L51/e" & WP=$!; sleep 2
kill -0 $WP 2>/dev/null && armed=1 || armed=0; kill $WP 2>/dev/null; wait $WP 2>/dev/null
n=$(find "$L51/w" -maxdepth 1 -name '*.tmp.*' -type l | wc -l | tr -d ' ')
[ $armed = 1 ] && [ "$(cksum < "$L51/victim")" = "$v0" ] && [ "$n" = 3 ] && [ -d "$L51/w/.wrtmp.PLANTED" ] && [ "$(cksum < "$L51/hl")" = "$(printf 'seats\n' | cksum)" ] \
  && ok "temps: planted same-PID link names and a planted .wrtmp directory are never written through or removed (the temp name is random and exclusive)" || bad "temps: planted temps: armed $armed, links $n, victim '$(cat "$L51/victim")', '$(cat "$L51/e")'"
# L6a: mktemp fails: the arm exits 1 with a message, writes to no empty name, the registry is byte-equal
l52_base; s0=$(cksum < "$L51/w/seats.tsv"); fault_set mktemp all
WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/waiter.sh" W1 sid-l6a >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; fault_clear
{ [ $r = 1 ] && [ "$(cksum < "$L51/w/seats.tsv")" = "$s0" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && grep -q "not armed" "$L51/e"; } && ok "temps: mktemp failing stops the arm (exit 1, 'not armed'), the registry is byte-equal, nothing is written under an empty temp name" || bad "temps: mktemp fault: rc $r, '$(cat "$L51/e")'"
# L6b: the registry rewrite (awk) fails: exit 1, registry byte-equal, the temp is removed
l52_base; s0=$(cksum < "$L51/w/seats.tsv"); fault_set awk all
WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/waiter.sh" W1 sid-l6b >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; fault_clear
[ $r = 1 ] && [ "$(cksum < "$L51/w/seats.tsv")" = "$s0" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && grep -q "not armed" "$L51/e" && ok "temps: a failed registry rewrite exits 1, 'not armed', the registry is byte-equal, the temp is removed" || bad "temps: awk fault: rc $r, '$(cat "$L51/e")', dir $(l52_dir)"
# L6c: the replace fails AND the cleanup fails: reported with the retained temp's path, the registry is intact (python3 shim from section 42 + rm shim)
export FAILMV_FILE="$T/failmv"; l52_base; s0=$(cksum < "$L51/w/seats.tsv"); printf 'seats.tsv\n' > "$FAILMV_FILE"; fault_set rm all
WARROOM_DIR="$L51/w" PATH="$SH41:$SH55:$PATH" "$B/waiter.sh" W1 sid-l6c >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; fault_clear; rm -f "$FAILMV_FILE"; unset FAILMV_FILE
tp=$(sed -n 's/.*could not remove the temporary file \(.*\); it is left in place.*/\1/p' "$L51/e" | head -1)
[ $r = 1 ] && [ "$(cksum < "$L51/w/seats.tsv")" = "$s0" ] && [ -n "$tp" ] && [ -e "$tp" ] && ok "temps: a failed cleanup is reported with the retained temp's path; the registry is intact (exit 1)" || bad "temps: cleanup fault: rc $r, temp '$tp', '$(cat "$L51/e")'"
# the other writes, each alone: ledger (pids.sh add), then the snapshot and chunk temps of a delivery poll
l52_base; : > "$L51/w/pids.tsv"; p0=$(cksum < "$L51/w/pids.tsv"); fault_set awk all
e=$(WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/pids.sh" add l6job $$ W1 2>&1 >/dev/null); r=$?; fault_clear
[ $r = 1 ] && [ "$(cksum < "$L51/w/pids.tsv")" = "$p0" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && case "$e" in *"NOT registered"*) true ;; *) false ;; esac && ok "temps: a failed ledger write says NOT registered, exits 1, keeps the ledger, leaves no temp" || bad "temps: ledger fault: rc $r, '$e'"
for which in 1 2; do
  name=$([ $which = 1 ] && echo snapshot || echo chunk)
  l52_base; rm -f "$L51/w/seats.tsv"; WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/waiter.sh" W1 sid-l6s$which > "$L51/o" 2>"$L51/e" & WP=$!; sleep 2; c0=$(cksum < "$L51/w/.cursor-W1")
  fault_set mktemp "$([ $which = 1 ] && echo first || echo second)"; WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: $name fault line" >/dev/null; sleep 3
  alive=0; kill -0 $WP 2>/dev/null && alive=1; mid=$(cksum < "$L51/w/.cursor-W1"); grep -q "nothing consumed" "$L51/e" && said=1 || said=0; fault_clear
  wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null
  [ $alive = 1 ] && [ "$mid" = "$c0" ] && [ $said = 1 ] && grep -q "$name fault line" "$L51/o" && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] \
    && ok "temps: a failed $name temp consumes nothing (waiter stays up, position kept, message), and the line is delivered on the next good poll" || bad "temps: $name fault: alive $alive said $said same-pos $([ "$mid" = "$c0" ] && echo y || echo n), out '$(cat "$L51/o")', err '$(cat "$L51/e")'"
done
else echo "skip temps: planted temps, mktemp / awk / cleanup / ledger / snapshot / chunk faults (ps cannot read process start times here, so a waiter cannot arm)"; fi

# 53. exclusive create (PR B): the RAW noclobber create has exactly one winner among racers; wr_create's losers may succeed after the recheck
l51_base; : > "$L51/w/.race"; rm -f "$L51/w/.race"
for i in 1 2 3 4 5 6 7 8; do ( set -C; : > "$L51/w/.race" ) 2>/dev/null && echo win >> "$L51/wins.$i" & done; wait
n=$(ls "$L51"/wins.* 2>/dev/null | wc -l | tr -d ' '); rm -f "$L51"/wins.*
[ "$n" = 1 ] && ok "create: 8 racing raw noclobber creates, exactly one succeeds" || bad "create: $n of 8 raw creates succeeded"
rm -f "$L51/w/.race"; for i in 1 2 3 4 5 6 7 8; do ( WARROOM_DIR="$L51/w" bash -c '. "$1/_common.sh"; wr_create "$2/.race"; echo $? > "$2/rc.$3"' _ "$B" "$L51/w" $i ) & done; wait
bad_rc=$(cat "$L51"/w/rc.* | grep -vc '^0$'); [ "$bad_rc" = 0 ] && wr_leaf=$(find "$L51/w" -name .race -type f -size 0 -links 1 | wc -l | tr -d ' ') && [ "$wr_leaf" = 1 ] && ok "create: 8 racing wr_create calls all report a usable file (losers recheck), one empty one-name file results" || bad "create: wr_create race: $bad_rc failed, leaf $wr_leaf"
l51_base; ln -s "$L51/tgt/x" "$L51/w/.dang"; ( set -C; : > "$L51/w/.dang" ) 2>/dev/null; r1=$?
WARROOM_DIR="$L51/w" bash -c '. "$1/_common.sh"; wr_create "$2/.dang"' _ "$B" "$L51/w" 2>/dev/null; r2=$?
printf 'keep\n' > "$L51/w/.keep"; WARROOM_DIR="$L51/w" bash -c '. "$1/_common.sh"; wr_create "$2/.keep"' _ "$B" "$L51/w"; r3=$?
[ $r1 != 0 ] && [ $r2 = 1 ] && [ ! -e "$L51/tgt/x" ] && [ $r3 = 0 ] && [ "$(cat "$L51/w/.keep")" = keep ] && ok "create: a dangling link is refused by the raw create and by wr_create (target absent); an existing file keeps its bytes" || bad "create: link/exist: raw $r1, wr_create $r2 / $r3"

# 54. guard mark restore (PR B). The board is made busy so the post fails; a copy of bin/ + hooks/ with a failing board.sh covers a post that fails
#     after a partial append.
G54="$T/g54"; rm -rf "$G54"; mkdir -p "$G54/w"
printf '[00:00 · W1] working\n' > "$G54/w/board.md"
# G1a: no old mark: the failed post puts back "-" (never unlinks); the next prompt tries again and posts once
hold "$G54/w/board.md"; WARROOM_DIR="$G54/w" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null >/dev/null 2>&1; unhold "$G54/w/board.md"
m=$(cat "$G54/w/.guard-W1" 2>/dev/null); WARROOM_DIR="$G54/w" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null >/dev/null 2>&1
[ "$m" = "-" ] && [ "$(grep -c '@W1 ACTION: no board post' "$G54/w/board.md")" = 1 ] && ok "guard: a failed post with no old mark leaves '-' (not unlinked); the next prompt retries and posts once" || bad "guard G1a: mark '$m', posts $(grep -c '@W1 ACTION: no board post' "$G54/w/board.md")"
# G1b: an old mark is set: the failed post puts the old mark back, byte for byte
printf '[00:00 · W1] working again\n' >> "$G54/w/board.md"; m0=$(cat "$G54/w/.guard-W1")
hold "$G54/w/board.md"; WARROOM_DIR="$G54/w" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null >/dev/null 2>&1; unhold "$G54/w/board.md"
[ "$(cat "$G54/w/.guard-W1")" = "$m0" ] && ok "guard: a failed post with an old mark puts that mark back unchanged" || bad "guard G1b: mark '$(cat "$G54/w/.guard-W1")' want '$m0'"
# G1c: a post that fails AFTER a partial append: the mark is restored, the partial line stays on the board, the retry is one more attempt
rm -rf "$G54/c"; mkdir -p "$G54/c/bin" "$G54/c/hooks" "$G54/c/w"; cp "$B"/* "$G54/c/bin/"; cp "$ROOT"/hooks/* "$G54/c/hooks/"
printf '#!/bin/bash\necho "[00:00 · GUARD] partial" >> "$WARROOM_DIR/board.md"; exit 1\n' > "$G54/c/bin/board.sh"; chmod +x "$G54/c/bin/board.sh"
printf '[00:00 · W1] working\n' > "$G54/c/w/board.md"
e=$(WARROOM_DIR="$G54/c/w" WARROOM_IDLE_MIN=0 bash "$G54/c/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null)
[ "$(cat "$G54/c/w/.guard-W1")" = "-" ] && grep -q 'GUARD\] partial' "$G54/c/w/board.md" && ok "guard: a post that fails after a partial append restores the mark; the retry is one more attempt, not exactly one visible reminder" || bad "guard G1c: mark '$(cat "$G54/c/w/.guard-W1")', '$e'"
# G2: the restore itself fails (second replace of the mark): the NEW mark stays, a diagnostic says so, the next prompt may be silent
cat > "$SH51/python3" <<SHIM
#!/bin/sh
case "\$*" in *os.replace*.guard-W1) c=\$(cat "$T/g2.cnt" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > "$T/g2.cnt"; [ \$c = 2 ] && { echo "shim: replace refused" >&2; exit 1; } ;; esac
exec $REALPY "\$@"
SHIM
chmod +x "$SH51/python3"
rm -f "$T/g2.cnt" "$G54/c/w/.guard-W1"; printf '[00:00 · W1] working\n' > "$G54/c/w/board.md"
e=$(WARROOM_DIR="$G54/c/w" PATH="$SH51:$PATH" WARROOM_IDLE_MIN=0 bash "$G54/c/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); mk=$(cat "$G54/c/w/.guard-W1")
n0=$(grep -c . "$G54/c/w/board.md"); WARROOM_DIR="$G54/c/w" WARROOM_IDLE_MIN=0 bash "$G54/c/hooks/board-guard.sh" </dev/null >/dev/null 2>&1; n1=$(grep -c . "$G54/c/w/board.md")
case "$e" in *"mark could not be restored"*) true ;; *) false ;; esac && [ "$mk" != "-" ] && [ -n "$mk" ] && [ "$n0" = "$n1" ] && ok "guard: when the restore fails the new mark stays, the hook says the next reminder may be skipped, and the next prompt posts nothing" || bad "guard G2: mark '$mk', lines $n0->$n1, '$e'"

# 55. a failed filter or checksum consumes nothing (PR B). Armed waiter, a fault appears, a wake line is posted: the waiter stays up, the
#     position does not move, it says so; once the fault is gone the line is delivered.
l55_run() { # name mode desc: mode = filter | gen | prefix | snap, the fault is set before the wake line is posted
  l52_base; rm -f "$L51/w/seats.tsv"; WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/waiter.sh" W1 sid-$1 > "$L51/o" 2>"$L51/e" & WP=$!; sleep 2; c0=$(cksum < "$L51/w/.cursor-W1")
  case $2 in
    filter) fault_set awk filter ;;
    gen)    fault_set cksum "$(head -n 1 "$L51/w/board.md" | wc -c | tr -d ' ')" ;;
    prefix) fault_set cksum "$(wc -c < "$L51/w/board.md" | tr -d ' ')" ;;
    snap)   fault_set cksum "$(( $(wc -c < "$L51/w/board.md") + $(printf '[00:00 · BOSS] @W1 ACTION: %s line\n' "$1" | wc -c) ))" ;;
  esac
  WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: $1 line" >/dev/null; sleep 3
  alive=0; kill -0 $WP 2>/dev/null && alive=1; mid=$(cksum < "$L51/w/.cursor-W1"); said=$(grep -c "nothing consumed" "$L51/e"); fault_clear
  wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null
  if [ $alive = 1 ] && [ "$mid" = "$c0" ] && [ "$said" -ge 1 ] && grep -q "$1 line" "$L51/o"; then ok "consume: $3 consumes nothing (waiter stays up, position kept, message) and the line comes on the next good poll"; else bad "consume $1: alive $alive said $said same-pos $([ "$mid" = "$c0" ] && echo y || echo n), out '$(cat "$L51/o")', err '$(cat "$L51/e")'"; fi
}
if [ "$PS_OK" = 1 ]; then
l55_run filterfault filter "a failed filter"
l55_run gensumfault gen "a failed generation checksum"
l55_run prefixsumfault prefix "a failed prefix checksum"
l55_run snapsumfault snap "a failed snapshot checksum"
# arm-time prefix checksum: the arm exits 1, 'not armed', registry and cursor unchanged
l52_base; WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-k0 >/dev/null 2>&1 & WP=$!; sleep 2; kill $WP 2>/dev/null; wait $WP 2>/dev/null
s0=$(cksum < "$L51/w/seats.tsv"); c0=$(cksum < "$L51/w/.cursor-W1"); fault_set cksum all
WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/waiter.sh" W1 sid-k1 >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; fault_clear
[ $r = 1 ] && grep -q "not armed" "$L51/e" && [ "$(cksum < "$L51/w/seats.tsv")" = "$s0" ] && [ "$(cksum < "$L51/w/.cursor-W1")" = "$c0" ] && ok "consume: a checksum that fails while arming exits 1 'not armed' with the registry and cursor unchanged" || bad "consume: arm-time sum fault: rc $r, '$(cat "$L51/e")'"
else echo "skip consume: failed filter and checksums, arm-time sum (ps cannot read process start times here, so a waiter cannot arm)"; fi
# board.sh tail: a failed checksum marks nothing as read and the same lines come again; E1: an empty board prints nothing and works
l52_base; WARROOM_DIR="$L51/w" "$B/board.sh" tail BOSS >/dev/null; printf '[00:00 · W1] fresh for the tail\n' >> "$L51/w/board.md"; a0=$(cksum < "$L51/w/.anchor-BOSS"); fault_set cksum all
o=$(WARROOM_DIR="$L51/w" PATH="$SH55:$PATH" "$B/board.sh" tail BOSS 2>"$L51/e"); r=$?; fault_clear
[ $r = 1 ] && [ -z "$o" ] && [ "$(cksum < "$L51/w/.anchor-BOSS")" = "$a0" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && o2=$(WARROOM_DIR="$L51/w" "$B/board.sh" tail BOSS) && case "$o2" in *"fresh for the tail"*) true ;; *) false ;; esac \
  && ok "consume: a failed tail checksum prints nothing, marks nothing as read (anchor kept, no temp), and the next tail shows the line" || bad "consume: tail sum fault: rc $r, out '$o', err '$(cat "$L51/e")'"
l51_base; : > "$L51/w/board.md"; o=$(WARROOM_DIR="$L51/w" "$B/board.sh" tail BOSS 2>"$L51/e"); r=$?
[ $r = 0 ] && [ -z "$o" ] && [ -z "$(cat "$L51/e")" ] && [ -f "$L51/w/.anchor-BOSS" ] && ok "consume: tail on an EMPTY board works (rc 0, nothing printed, no head -n 0, an anchor is saved)" || bad "consume: empty-board tail: rc $r, out '$o', err '$(cat "$L51/e")'"

# 55b. write faults AFTER the temp exists (PR B): a mktemp shim hands out a read-only temp on the Nth call, so the printf/head/cp into it
#      fails while the allocation and the rename would have worked. "N" counts every mktemp; "N waiter.sh" counts only those made by a
#      process whose command line has that word (pids.sh check also makes temps on every poll). Stages: cursor, anchor, snapshot, chunk, guard mark. Each: the final
#      file is as it was, the message is exact, the fault was reached (hit marker), and a retry without the fault delivers.
SHRO="$T/shimro"; mkdir -p "$SHRO"; FRO="$T/faultro"; _rmk=$(command -v mktemp)
cat > "$SHRO/mktemp" <<SHIM
#!/bin/sh
f="$FRO"
if [ -f "\$f" ]; then
  k=\$(cat "\$f"); n=\${k%% *}; pat=\${k#* }; [ "\$pat" = "\$k" ] && pat=""
  if [ -n "\$pat" ]; then par=\$(ps -o command= -p \$PPID 2>/dev/null); case "\$par" in *"\$pat"*) ;; *) exec $_rmk "\$@" ;; esac; fi
  c=\$(cat "\$f.cnt" 2>/dev/null || echo 0); c=\$((c+1)); echo "\$c" > "\$f.cnt"
  if [ "\$n" = "\$c" ]; then p=\$($_rmk "\$@") || exit 1; chmod 444 "\$p"; echo "\$c" >> "\$f.hit"; echo "\$p"; exit 0; fi
fi
exec $_rmk "\$@"
SHIM
chmod +x "$SHRO/mktemp"
ro_set() { rm -f "$FRO.cnt" "$FRO.hit"; printf '%s\n' "$1" > "$FRO"; }
ro_clear() { rm -f "$FRO" "$FRO.cnt"; }
ro_hit() { [ -s "$FRO.hit" ]; }
f2_base() { rm -rf "$L51/w"; mkdir -p "$L51/w"; printf '[00:00 · BOSS] one\n[00:00 · BOSS] three words here\n' > "$L51/w/board.md"; }
f2_tail() { WARROOM_DIR="$L51/w" PATH="$SHRO:$PATH" "$B/board.sh" tail BOSS 2>"$L51/e"; }
if [ "$(id -u)" != 0 ]; then
for st in "snapshot 1 scratch" "chunk 2 scratch" "anchor 3 position"; do
  set -- $st; name=$1; nth=$2; kind=$3
  f2_base; WARROOM_DIR="$L51/w" "$B/board.sh" tail BOSS >/dev/null; printf '[00:00 · W1] fresh %s\n' "$name" >> "$L51/w/board.md"; a0=$(cksum < "$L51/w/.anchor-BOSS")
  ro_set "$nth"; o=$(f2_tail); r=$?; ro_clear
  want="could not write a scratch file"; [ $kind = position ] && want="could not save the read position"
  o2=$(WARROOM_DIR="$L51/w" "$B/board.sh" tail BOSS 2>&1); r2=$?
  pr=n; if [ $kind = scratch ]; then [ -z "$o" ] && pr=y; else case "$o" in *"fresh $name"*) pr=y ;; esac; fi
  [ $r = 1 ] && ro_hit && [ $pr = y ] && grep -q "$want" "$L51/e" && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && case "$o2" in *"fresh $name"*) true ;; *) false ;; esac && [ $r2 = 0 ] && [ "$(cksum < "$L51/w/.anchor-BOSS")" != "$a0" ] \
    && ok "write fault: a failed $name write in board.sh tail exits 1 with '$want', the fault was reached, no temp is left, and the retry shows the line and moves the anchor" || bad "write fault $name: rc $r, out '$o', err '$(cat "$L51/e")', hit $(ro_hit && echo y || echo n), retry rc $r2 '$o2'"
  [ $kind = position ] && { [ "$(cksum < "$L51/w/.anchor-BOSS")" != "$a0" ] || bad "write fault anchor: the retry did not move the anchor"; }
done
# the anchor test above also needs: while the write failed, the anchor was as it was
f2_base; WARROOM_DIR="$L51/w" "$B/board.sh" tail BOSS >/dev/null; printf '[00:00 · W1] fresh keep\n' >> "$L51/w/board.md"; a0=$(cksum < "$L51/w/.anchor-BOSS"); ro_set 3; f2_tail >/dev/null; ro_clear
[ "$(cksum < "$L51/w/.anchor-BOSS")" = "$a0" ] && ok "write fault: after a failed anchor write the old anchor is byte-equal" || bad "write fault anchor: the old anchor changed"
# guard mark: the mark temp cannot be written: nothing is posted, no mark is saved, it says so, and the next prompt posts and saves it
f2_base; printf '[00:00 · W1] a\n[00:00 · W1] working on this longer line\n' > "$L51/w/board.md"; b0=$(cksum < "$L51/w/board.md"); ro_set 1
e=$(WARROOM_DIR="$L51/w" PATH="$SHRO:$PATH" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); r=$?; ro_clear
if [ $r = 0 ] && ro_hit && [ "$(cksum < "$L51/w/board.md")" = "$b0" ] && [ ! -e "$L51/w/.guard-W1" ] && case "$e" in *"could not save the mark"*) true ;; *) false ;; esac && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ]; then
  WARROOM_DIR="$L51/w" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null >/dev/null 2>&1
  [ -s "$L51/w/.guard-W1" ] && [ "$(cksum < "$L51/w/board.md")" != "$b0" ] && ok "write fault: a failed guard-mark write posts nothing and saves no mark (said so, no temp left), and the next prompt posts and saves it" || bad "write fault guard: the retry did not post and save the mark"
else bad "write fault guard: rc $r, hit $(ro_hit && echo y || echo n), mark '$(cat "$L51/w/.guard-W1" 2>/dev/null)', err '$e'"; fi
else echo "skip write faults: read-only temps do not stop root (running as root)"; fi
if [ "$PS_OK" = 1 ] && [ "$(id -u)" != 0 ]; then
# waiter: the arm-time cursor write fails: exit 1 'not armed', cursor and registry byte-equal; the retry arms
f2_base; WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-w0 >/dev/null 2>&1 & WP=$!; sleep 2; kill $WP 2>/dev/null; wait $WP 2>/dev/null
s0=$(cksum < "$L51/w/seats.tsv"); c0=$(cksum < "$L51/w/.cursor-W1"); ro_set "1 waiter.sh"
WARROOM_DIR="$L51/w" PATH="$SHRO:$PATH" "$B/waiter.sh" W1 sid-w1 >/dev/null 2>"$L51/e" & WP=$!; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; ro_clear; s1=$(cksum < "$L51/w/seats.tsv"); c1=$(cksum < "$L51/w/.cursor-W1")
WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-w2 >/dev/null 2>&1 & WP=$!; sleep 2; kill -0 $WP 2>/dev/null && armed=1 || armed=0; kill $WP 2>/dev/null; wait $WP 2>/dev/null
[ $r = 1 ] && ro_hit && grep -q "could not save the position of seat W1" "$L51/e" && grep -q "not armed" "$L51/e" && [ "$s1" = "$s0" ] && [ "$c1" = "$c0" ] && [ -z "$(find "$L51/w" -name '.wrtmp.*')" ] && [ $armed = 1 ] \
  && ok "write fault: a failed arm-time cursor write exits 1 'not armed' (fault reached, no temp left) and the retry arms" || bad "write fault arm cursor: rc $r, hit $(ro_hit && echo y || echo n), armed $armed, err '$(cat "$L51/e")'"
# waiter poll: the snapshot (call 1) and the chunk (call 2) cannot be written: the waiter stays up, the position is kept, it says so, the line comes on the next good poll
for st in "snapshot 1" "chunk 2"; do
  set -- $st; name=$1; nth=$2
  f2_base; rm -f "$L51/w/seats.tsv"; WARROOM_DIR="$L51/w" PATH="$SHRO:$PATH" "$B/waiter.sh" W1 sid-p$name > "$L51/o" 2>"$L51/e" & WP=$!; sleep 2
  ro_set "$nth waiter.sh"; WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: wf $name line" >/dev/null
  wait_exit $WP 10 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; ro_clear; said=$(grep -c "nothing consumed" "$L51/e")
  [ "$said" -ge 1 ] && grep -q "wf $name line" "$L51/o" && ro_hit \
    && ok "write fault: an unwritable $name in the waiter poll consumes nothing (said so, fault reached) and the same line is delivered by the next poll" || bad "write fault waiter $name: said $said, hit $(ro_hit && echo y || echo n), out '$(cat "$L51/o")', err '$(cat "$L51/e")'"
done
# waiter delivery: the position write (call 3 of the run: snapshot, chunk, cursor) fails: exit 1 'printed but not marked', header and lines printed, position kept, re-arm gets them again
f2_base; rm -f "$L51/w/seats.tsv"; WARROOM_DIR="$L51/w" PATH="$SHRO:$PATH" "$B/waiter.sh" W1 sid-pd > "$L51/o" 2>"$L51/e" & WP=$!; sleep 2
ro_set "3 waiter.sh"; WARROOM_DIR="$L51/w" "$B/board.sh" post BOSS "@W1 ACTION: wf deliver line" >/dev/null; wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?; ro_clear
WARROOM_DIR="$L51/w" "$B/waiter.sh" W1 sid-pd2 > "$L51/o2" 2>/dev/null & WP=$!; sleep 3; kill $WP 2>/dev/null; wait $WP 2>/dev/null
[ $r = 1 ] && ro_hit && grep -q "printed but not marked" "$L51/e" && grep -q "^\[WAKE" "$L51/o" && grep -q "wf deliver line" "$L51/o" && grep -q "wf deliver line" "$L51/o2" \
  && ok "write fault: a failed position write at delivery exits 1 'printed but not marked' (header and line printed, fault reached) and the re-arm delivers it again" || bad "write fault waiter delivery: rc $r, hit $(ro_hit && echo y || echo n), out '$(cat "$L51/o")', err '$(cat "$L51/e")', retry '$(cat "$L51/o2")'"
else echo "skip write faults in the waiter: cursor, snapshot, chunk, delivery position (no ps start times, or running as root)"; fi

# 59. mutants of the checks above: each is a copy of bin/ and hooks/ in $T with ONE change (asserted by grep -c); the copy
# without the change passes the fixture, the copy with it fails the fixture at the printed assert.
MA="$T/mutA"; mkdir -p "$MA"
pa_mcopy() { rm -rf "${MA:?}/${1:?}"; mkdir -p "$MA/$1"; cp -R "$B" "$MA/$1/bin"; cp -R "$ROOT/hooks" "$MA/$1/hooks"; }
pa_msed() { _mt=$(sed "$3" "$MA/$1/$2") && printf '%s\n' "$_mt" > "$MA/$1/$2"; }   # rewritten in place: the exec bit stays
pa_mawk() { _mt=$(awk "$3" "$MA/$1/$2") && printf '%s\n' "$_mt" > "$MA/$1/$2"; }
pa_mut() { # pa_mut NAME FIXTURE: the pristine copy passes FIXTURE, the mutated copy fails it
  _n=$1; _fx=$2; PA_WHY=""; PA_SKIP=""
  PB="$MA/pristine/bin"; PHK="$MA/pristine/hooks"
  if ! "$_fx"; then bad "mutant $_n: the unmutated copy fails $_fx: $PA_WHY"; PB="$B"; PHK="$ROOT/hooks"; return; fi
  if [ -n "$PA_SKIP" ]; then echo "skip mutant $_n ($PA_SKIP)"; PB="$B"; PHK="$ROOT/hooks"; return; fi
  PB="$MA/$_n/bin"; PHK="$MA/$_n/hooks"; PA_WHY=""
  if "$_fx"; then bad "mutant $_n survived: $_fx passed"; else ok "mutant $_n: $_fx fails at: $(printf '%s' "$PA_WHY" | head -c 150)"; fi
  PB="$B"; PHK="$ROOT/hooks"
}
pa_mcopy pristine
pa_mcopy nofold; pa_msed nofold bin/_common.sh "s/^wr_fold() { printf '%s' \"\$1\" | tr 'A-Z' 'a-z'; }/wr_fold() { printf '%s' \"\$1\"; }/"
[ "$(grep -c "^wr_fold() { printf '%s' \"\$1\"; }" "$MA/nofold/bin/_common.sh")" = 1 ] && [ "$(grep -c "tr 'A-Z' 'a-z'" "$MA/nofold/bin/_common.sh")" = 0 ] && pa_mut nofold fx_n1 || bad "mutant nofold: the change was not applied"
pa_mcopy late; pa_mawk late bin/_common.sh '/^  wr_validate_paths \|\| return 2$/ {next} {print} /^  mkdir -p "\$W" 2>\/dev\/null$/ {print "  wr_validate_paths || return 2"}'
[ "$(grep -c '^  wr_validate_paths || return 2$' "$MA/late/bin/_common.sh")" = 1 ] && [ "$(grep -n '^  wr_validate_paths || return 2$' "$MA/late/bin/_common.sh" | cut -d: -f1)" -gt "$(grep -n '^  mkdir -p "\$W" 2>/dev/null$' "$MA/late/bin/_common.sh" | cut -d: -f1)" ] && pa_mut late fx_r3 || bad "mutant late: the change was not applied"
pa_mcopy lexical; pa_msed lexical bin/_common.sh 's|^  _ra=$(cd -P -- "$_rs" 2>/dev/null \&\& pwd -P) \|\| return 1$|  _ra=$_rs|'
[ "$(grep -c '^  _ra=\$_rs$' "$MA/lexical/bin/_common.sh")" = 1 ] && [ "$(grep -c 'cd -P -- "\$_rs"' "$MA/lexical/bin/_common.sh")" = 0 ] && pa_mut lexical fx_n3 || bad "mutant lexical: the change was not applied"
pa_mcopy nod6; pa_mawk nod6 bin/_common.sh '/^  # D6 /{skip=1} /^  return 0$/{skip=0} !skip{print}'
[ "$(grep -c '# D6 ' "$MA/nod6/bin/_common.sh")" = 0 ] && [ "$(grep -c 'wr_ef_reserved "\$WR_C_SEL"' "$MA/nod6/bin/_common.sh")" = 0 ] && pa_mut nod6 fx_n6a || bad "mutant nod6: the change was not applied"
pa_mcopy tailseat; pa_msed tailseat bin/board.sh 's|^    wr_seat_arg "\$seat"; a=|    a=|'
[ "$(grep -c 'wr_seat_arg' "$MA/tailseat/bin/board.sh")" = 0 ] && [ "$(grep -c '^    a="\$W/.anchor-\$seat"' "$MA/tailseat/bin/board.sh")" = 1 ] && pa_mut tailseat fx_s1 || bad "mutant tailseat: the change was not applied"
pa_mcopy nopython; pa_msed nopython bin/_common.sh 's/^  wr_need_python || return 2$/  :/'
[ "$(grep -c '^  wr_need_python || return 2$' "$MA/nopython/bin/_common.sh")" = 0 ] && [ "$(grep -c '^  :$' "$MA/nopython/bin/_common.sh")" = 1 ] && pa_mut nopython fx_p1 || bad "mutant nopython: the change was not applied"
pa_mcopy noiso; pa_msed noiso hooks/waiter-check.sh 's|python3 -I -S -c |python3 -c |'; pa_msed noiso hooks/board-tail.sh 's|python3 -I -S -c |python3 -c |'
[ "$(grep -c "python3 -I -S -c" "$MA/noiso/hooks/waiter-check.sh" "$MA/noiso/hooks/board-tail.sh" | grep -vc ':0$')" = 0 ] && [ "$(grep -c "python3 -c 'import sys,json" "$MA/noiso/hooks/waiter-check.sh" "$MA/noiso/hooks/board-tail.sh" | grep -c ':1$')" = 2 ] && pa_mut noiso fx_p3 || bad "mutant noiso: the change was not applied"
pa_mcopy relw; pa_msed relw bin/_common.sh '/^  case "\$WARROOM_DIR" in \/\*) ;; \*) { echo/d;/^  case "\$_rp" in \/\*) ;; \*) _WR_WHY="is not an absolute path"/d'
[ "$(grep -c 'WARROOM_DIR must be an absolute path' "$MA/relw/bin/_common.sh")" = 0 ] && [ "$(grep -c '_WR_WHY="is not an absolute path"' "$MA/relw/bin/_common.sh")" = 0 ] && pa_mut relw fx_r6 || bad "mutant relw: the change was not applied"
pa_mcopy noancestor; pa_msed noancestor bin/_common.sh '/^  case "\$_fw\/" in "\$_fb"\/\*) { echo/d'
[ "$(grep -c 'is a folder above the run folder' "$MA/noancestor/bin/_common.sh")" = 0 ] && pa_mut noancestor fx_r5 || bad "mutant noancestor: the change was not applied"

# --- fixtures for the PR B mutants (each takes the code under test from $PB / $PHK, like the A fixtures) ---
pa_w() { PW="$PAW/w"; mkdir -p "$PW"; printf '[00:00 · BOSS] one\n' > "$PW/board.md"; }
fx_l1() { # the gap marker as a dangling link, then as a hard link: the delivery is refused, the other name is not touched (kills plain "touch")
  pa_setup; pa_w
  pa_run WARROOM_DIR="$PW" "$PB/waiter.sh" W1 sid-l1 > "$PAW/o" 2> "$PAW/e" & WPA=$!; sleep 2
  ln -s "$PAW/target-absent" "$PW/.lastwake-W1"; pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: l1 line" >/dev/null
  wait_exit $WPA 8 || { kill $WPA 2>/dev/null; wait $WPA 2>/dev/null; PA_WHY="L1: the waiter did not end (marker through a dangling link accepted)"; return 1; }; wait $WPA 2>/dev/null; _r=$?
  [ "$_r" = 1 ] || { PA_WHY="L1: rc $_r (want 1)"; return 1; }
  [ ! -e "$PAW/target-absent" ] || { PA_WHY="L1: the link target was created (touch followed the link)"; return 1; }
  rm -f "$PW/.lastwake-W1"; printf 'outside\n' > "$PAW/out"; ln "$PAW/out" "$PW/.lastwake-W1"; sleep 1; _m0=$(pa_mt "$PAW/out")
  pa_run WARROOM_DIR="$PW" "$PB/waiter.sh" W1 sid-l2 > "$PAW/o" 2> "$PAW/e" & WPA=$!; sleep 2
  pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: l2 line" >/dev/null
  wait_exit $WPA 8 || { kill $WPA 2>/dev/null; wait $WPA 2>/dev/null; PA_WHY="L2: the waiter did not end (marker with a second name accepted)"; return 1; }; wait $WPA 2>/dev/null; _r=$?
  [ "$_r" = 1 ] && [ "$(pa_mt "$PAW/out")" = "$_m0" ] || { PA_WHY="L2: rc $_r, mtime of the other name $_m0 -> $(pa_mt "$PAW/out")"; return 1; }
}
fx_l4() { # same-PID legacy temp names planted as links: never written through (kills the "> FINAL.tmp.PID" temp)
  pa_setup; pa_w; printf 'victim\n' > "$PAW/victim"
  PBX=$PB; export PBX; ( cd "$PAW/cwd" && env HOME="$PAH" CLAUDE_CONFIG_DIR="$PAC" WARROOM_ENV="$PAW/none.env" SEATS="BOSS W1" WARROOM_POLL=1 WARROOM_MIN_GAP=0 WARROOM_DIR="$PW" \
    bash -c 'ln -s "$1/victim" "$2/.cursor-W1.tmp.$$"; ln -s "$1/victim" "$2/seats.tsv.tmp.$$"; exec "$3/waiter.sh" W1 sid-l4' _ "$PAW" "$PW" "$PBX" ) >/dev/null 2>&1 & WPA=$!; sleep 2
  kill $WPA 2>/dev/null; wait $WPA 2>/dev/null
  [ "$(cat "$PAW/victim")" = victim ] || { PA_WHY="L4: the victim file was written through a planted temp link: '$(cat "$PAW/victim")'"; return 1; }
}
fx_l3() { # FINAL becomes a directory right after the precheck; python3 AND mv shims do it, then exec the real tool (kills "mv" replace)
  pa_setup; pa_w; mkdir -p "$PAW/shim"; _py=$(command -v python3); _mv=$(command -v mv)
  printf '#!/bin/sh\ncase "$*" in *os.replace*.cursor-W1) for a in "$@"; do f=$a; done; rm -f "$f"; mkdir "$f" ;; esac\nexec %s "$@"\n' "$_py" > "$PAW/shim/python3"
  printf '#!/bin/sh\nfor a in "$@"; do f=$a; done\ncase "$f" in *.cursor-W1) rm -f "$f"; mkdir "$f" ;; esac\nexec %s "$@"\n' "$_mv" > "$PAW/shim/mv"; chmod +x "$PAW/shim/python3" "$PAW/shim/mv"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-l3 >/dev/null 2>"$PAW/e" & WPA=$!
  wait_exit $WPA 8 || { kill $WPA 2>/dev/null; wait $WPA 2>/dev/null; PA_WHY="L3: the arm succeeded with a directory at the cursor"; return 1; }; wait $WPA 2>/dev/null; _r=$?
  [ "$_r" = 1 ] && [ -d "$PW/.cursor-W1" ] && [ -z "$(ls -A "$PW/.cursor-W1")" ] || { PA_WHY="L3: rc $_r, directory content '$(ls -A "$PW/.cursor-W1" 2>&1)'"; return 1; }
}
fx_g1() { # a failed post with no old mark leaves "-" (kills the old rollback that removed the mark)
  pa_setup; pa_w; printf '[00:00 · W1] working\n' > "$PW/board.md"
  hold "$PW/board.md"; pa_run WARROOM_DIR="$PW" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$PHK/board-guard.sh" </dev/null >/dev/null 2>&1; unhold "$PW/board.md"
  [ "$(cat "$PW/.guard-W1" 2>/dev/null)" = "-" ] || { PA_WHY="G1: mark after a failed post is '$(cat "$PW/.guard-W1" 2>&1)' (want '-')"; return 1; }
}
fx_c1() { # the cursor record grammar: a valid record resumes, a valid old one is "none", an absent one is "none"; every corrupt shape is status 1, nothing on stdout, a line on stderr
  pa_setup; printf '[00:00 · BOSS] a\n[00:00 · BOSS] b\n' > "$PAW/cb.md"
  _c1g=$(pa_run WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_generation "$BOARD_FILE"' _ "$PB") || { PA_WHY="C1: no generation"; return 1; }
  _c1p=$(pa_run WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_prefixsum "$BOARD_FILE" 2' _ "$PB") || { PA_WHY="C1: no prefix sum"; return 1; }
  _c1n=$(date +%s); _c1i=0
  while IFS='|' read -r _nm _body _wrc _wout; do
    [ -n "$_nm" ] || continue
    _c1i=$((_c1i + 1)); _cf="$PAW/cur$_c1i"
    # shellcheck disable=SC2059
    printf "$(printf '%s' "$_body" | sed -e "s/@G/$_c1g/g" -e "s/@P/$_c1p/g" -e "s/@N/$_c1n/g" -e "s/@OLD/$((_c1n - 200000))/g" -e "s/@FUT/$((_c1n + 90000))/g")" > "$_cf"
    PA_IN=""; pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2" "$BOARD_FILE" 99999 2>"$3"' _ "$PB" "$_cf" "$PAW/err$_c1i"
    [ "$PA_RC" = "$_wrc" ] && [ "$PA_OUT" = "$_wout" ] || { PA_WHY="C1 $_nm: rc $PA_RC out '$PA_OUT' (want rc $_wrc out '$_wout')"; return 1; }
    if [ "$_wrc" = 1 ]; then [ -s "$PAW/err$_c1i" ] || { PA_WHY="C1 $_nm: status 1 with nothing on stderr"; return 1; }; fi
  done <<'TBL'
current|@G 2 @N @P\n|0|2
no-sum|@G 2 @N\n|0|2
last-line-sum, wrong|@G 2 @N 12345\n|0|0
prefix-sum, wrong|@G 2 @N 1-2\n|0|0
valid but old|@G 2 @OLD @P\n|0|none
future by more than a day|@G 2 @FUT @P\n|1|
leading zero in the count|@G 08 @N @P\n|1|
twenty-digit time|@G 2 12345678901234567890 @P\n|1|
negative count|@G -1 @N @P\n|1|
sixteen-digit count|@G 1000000000000000 @N @P\n|1|
extra field|@G 2 @N @P x\n|1|
extra line|@G 2 @N @P\nx\n|1|
no final newline|@G 2 @N @P|1|
empty file||1|
generation not digits:digits|abc 2 @N\n|1|
generation without a colon|55 2 @N\n|1|
generation with a trailing colon|5: 2 @N\n|1|
generation with two colons|1:2:3 2 @N\n|1|
checksum not digits|@G 2 @N x-y\n|1|
checksum with an empty half|@G 2 @N 5-\n|1|
TBL
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2/absent" "$BOARD_FILE" 99999' _ "$PB" "$PAW"
  { [ "$PA_RC" = 0 ] && [ "$PA_OUT" = none ]; } || { PA_WHY="C1 absent: rc $PA_RC out '$PA_OUT' (want rc 0 none)"; return 1; }
  # a cursor whose folder is not there is not known to be absent: status 1, nothing on stdout, a line on stderr
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2/nofolder/cur" "$BOARD_FILE" 99999 2>"$3"' _ "$PB" "$PAW" "$PAW/errnf"
  { [ "$PA_RC" = 1 ] && [ -z "$PA_OUT" ] && [ -s "$PAW/errnf" ]; } || { PA_WHY="C1 missing folder: rc $PA_RC out '$PA_OUT' (want rc 1, nothing on stdout, a line on stderr)"; return 1; }
  ln -s "$PAW/cb.md" "$PAW/curlink"
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2" "$BOARD_FILE" 99999 2>/dev/null' _ "$PB" "$PAW/curlink"
  { [ "$PA_RC" = 1 ] && [ -z "$PA_OUT" ]; } || { PA_WHY="C1 symlink: rc $PA_RC out '$PA_OUT' (want rc 1, nothing)"; return 1; }
  printf '%s 2 %s %s\n' "$_c1g" "$_c1n" "$_c1p" > "$PAW/curunr"; chmod 000 "$PAW/curunr"
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2" "$BOARD_FILE" 99999 2>/dev/null' _ "$PB" "$PAW/curunr"; _r=$PA_RC; _o=$PA_OUT; chmod 600 "$PAW/curunr"
  if [ "$(id -u)" != 0 ]; then { [ "$_r" = 1 ] && [ -z "$_o" ]; } || { PA_WHY="C1 unreadable: rc $_r out '$_o' (want rc 1, nothing)"; return 1; }; fi
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2/c" "$BOARD_FILE" 99999 2>/dev/null' _ "$PB" "$PAW/cb.md"
  { [ "$PA_RC" = 1 ] && [ -z "$PA_OUT" ]; } || { PA_WHY="C1 folder is a file: rc $PA_RC out '$PA_OUT' (want rc 1, nothing: absence is not proven)"; return 1; }
  mkdir "$PAW/nosearch"; chmod 000 "$PAW/nosearch"
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2/c" "$BOARD_FILE" 99999 2>/dev/null' _ "$PB" "$PAW/nosearch"; _r=$PA_RC; _o=$PA_OUT; chmod 700 "$PAW/nosearch"
  if [ "$(id -u)" != 0 ]; then { [ "$_r" = 1 ] && [ -z "$_o" ]; } || { PA_WHY="C1 unsearchable folder: rc $_r out '$_o' (want rc 1, nothing: absence is not proven)"; return 1; }; fi
  printf '%s 2 %s %s\n' "$_c1g" "$_c1n" "$_c1p" > "$PAW/curfix"
  pa_exec WARROOM_DIR="$PAW" BOARD=cb.md bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_cursor_get "$2" "$BOARD_FILE" 99999' _ "$PB" "$PAW/curfix"
  { [ "$PA_RC" = 0 ] && [ "$PA_OUT" = 2 ]; } || { PA_WHY="C1 repaired record: rc $PA_RC out '$PA_OUT' (want rc 0, 2)"; return 1; }
}
fx_t1() { # process judgement: dead only on "no such process" or another start time; a refused kill and a failed or partial ps are unknown
  pa_setup; mkdir -p "$PAW/shim"
  _t1=$(pa_run WARROOM_DIR="$PAW" BOARD=t1.md bash -c '. "$1/_common.sh"; sleep 30 & p=$!; me=$(wr_started "$p") || exit 9; echo "a:$(wr_proc "$p") b:$(wr_proc "$p" "$me") c:$(wr_proc "$p" "not the start") d:$(wr_proc 99999)"; kill "$p"; wait "$p" 2>/dev/null; echo "f:$(wr_proc "$p" "$me")"' _ "$PB" 2>&1)
  case "$_t1" in *"a:alive b:alive c:dead d:dead"*"f:dead"*) ;; *) PA_WHY="proc plain states: '$_t1'"; return 1 ;; esac
  if [ "$(id -u)" != 0 ]; then
    _t1=$(pa_run WARROOM_DIR="$PAW" BOARD=t1.md bash -c '. "$1/_common.sh"; echo "pid1:$(wr_proc 1) pid1s:$(wr_proc 1 "anything")"' _ "$PB" 2>&1)
    [ "$_t1" = "pid1:unknown pid1s:unknown" ] || { PA_WHY="proc a live process of another owner (pid 1): '$_t1' (want unknown, never dead)"; return 1; }
  fi
  printf '#!/bin/sh\nprintf "Thu Nov"\nexit 1\n' > "$PAW/shim/ps"; chmod +x "$PAW/shim/ps"
  _t1=$(pa_run WARROOM_DIR="$PAW" BOARD=t1.md PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; o=$(wr_started $$); echo "rc=$? out=[$o]"; echo "proc:$(wr_proc $$ "Thu Nov")"' _ "$PB" 2>&1)
  case "$_t1" in *"rc=1 out=[]"*"proc:unknown"*) ;; *) PA_WHY="proc a ps that prints part of a time and fails: '$_t1' (want rc 1 with nothing, and unknown)"; return 1 ;; esac
}
fx_gr1() { # the guard judges only from reads it could make: a failed board / job-ledger / mark read, an odd stamp or an odd clock is no post and says why; an absent ledger or mark is the normal first use
  pa_setup; mkdir -p "$PAW/shim"; _aw=$(command -v awk)
  cat > "$PAW/shim/awk" <<SHIM
#!/bin/sh
for a; do last=\$a; done
if [ -f "$PAW/awkfault" ] && [ "\$last" = "\$(cat "$PAW/awkfault")" ]; then echo "shim: awk refused" >&2; exit 2; fi
exec $_aw "\$@"
SHIM
  chmod +x "$PAW/shim/awk"
  _ct=$(command -v cat)   # the registry reader is a cat: the same fault, named by the file it was asked to read
  cat > "$PAW/shim/cat" <<SHIM
#!/bin/sh
for a; do last=\$a; done
if [ -f "$PAW/awkfault" ] && [ "\$last" = "\$($_ct "$PAW/awkfault")" ]; then echo "shim: cat refused" >&2; exit 2; fi
exec $_ct "\$@"
SHIM
  chmod +x "$PAW/shim/cat"
  printf '#!/bin/sh\nif [ -f "%s/datefault" ]; then cat "%s/datefault"; exit 0; fi\nexec /bin/date "$@"\n' "$PAW" "$PAW" > "$PAW/shim/date"; chmod +x "$PAW/shim/date"
  _gw() { PW="$PAW/g$1"; rm -rf "$PW"; mkdir -p "$PW"; printf '%s\n' "${2:-[00:00 · W1] working}" > "$PW/board.md"; rm -f "$PAW/awkfault" "$PAW/datefault"; }
  _gposts() { grep -c '@W1 ACTION: no board post' "$PW/board.md"; }
  _gwant() { # _gwant NAME PATTERN POSTS : the hook ends 0 (a hook never blocks the prompt) unless said, says PATTERN, and the board has POSTS reminders
    pa_exec WARROOM_DIR="$PW" WARROOM_IDLE_MIN=0 PATH="$PAW/shim:$PATH" "$PHK/board-guard.sh"
    [ "$PA_RC" = "${4:-0}" ] || { PA_WHY="$1: rc $PA_RC (want ${4:-0}): $(printf '%s' "$PA_OUT" | head -c 200)"; return 1; }
    [ -z "$2" ] || printf '%s\n' "$PA_OUT" | grep -q -- "$2" || { PA_WHY="$1: no '$2' in: $(printf '%s' "$PA_OUT" | head -c 200)"; return 1; }
    [ "$(_gposts)" = "$3" ] || { PA_WHY="$1: $(_gposts) reminders on the board (want $3): $(printf '%s' "$PA_OUT" | head -c 200)"; return 1; }
  }
  PA_IN='{}'
  # control: first use (no ledger, no mark) posts once and leaves a real mark; the same prompt again says nothing more
  _gw 1; _gwant "G1 first use" "" 1 || return 1
  [ "$(cat "$PW/.guard-W1")" != "-" ] && grep -Eq '^[0-9]+:[0-9]+ [0-9]+ [0-9]+$' "$PW/.guard-W1" || { PA_WHY="G1: the mark after first use is '$(cat "$PW/.guard-W1")'"; return 1; }
  _gwant "G1 again" "" 1 || return 1
  # an empty, odd or two-line mark is refused (not a new silence), the file stays as it was
  for _mk in "" "garbage" "1:2 3" "1:2 3 4
5"; do
    _gw 2; printf '%s' "$_mk" > "$PW/.guard-W1"; _m0=$(cksum < "$PW/.guard-W1")
    _gwant "G2 mark '$_mk'" "is not a mark" 0 || return 1
    [ "$(cksum < "$PW/.guard-W1")" = "$_m0" ] || { PA_WHY="G2: the refused mark changed"; return 1; }
  done
  # the "-" sentinel is a valid mark and the post goes out
  _gw 3; printf -- '-\n' > "$PW/.guard-W1"; _gwant "G2 sentinel" "" 1 || return 1
  # a job ledger that is there and cannot be read is no judgement: no post, no mark, one line saying so
  _gw 4; printf 'job\t99999999\tW9\t\n' > "$PW/pids.tsv"; printf '%s' "$PW/pids.tsv" > "$PAW/awkfault"
  _gwant "G3 ledger" "cannot read the job ledger" 0 || return 1
  [ ! -e "$PW/.guard-W1" ] || { PA_WHY="G3: a mark was written although the ledger could not be read"; return 1; }
  rm -f "$PAW/awkfault"; _gwant "G3 ledger readable again" "" 1 || return 1
  # a board that cannot be read is not "never posted"
  _gw 5; printf '%s' "$PW/board.md" > "$PAW/awkfault"
  _gwant "G4 board" "could not read the board" 0 || return 1
  [ ! -e "$PW/.guard-W1" ] || { PA_WHY="G4: a mark was written although the board could not be read"; return 1; }
  # a stamp that is not a time, and a clock that is not a time
  _gw 6 '[99:99 · W1] odd'; _gwant "G5 stamp" "not a time" 0 || return 1
  _gw 7; printf '25:99\n' > "$PAW/datefault"; _gwant "G6 clock" "not HH:MM" 0 1 || return 1
  return 0
}
fx_st1() { # identity stat: an inode, a link count and a modification time are a plain decimal or nothing (status 1, nothing printed); a stat that fails or prints something odd is never turned into a default
  pa_setup; pa_w; mkdir -p "$PAW/shim"; _rst=$(command -v stat) || { PA_WHY="ST1: no stat to wrap"; return 1; }
  cat > "$PAW/shim/stat" <<SHIM
#!/bin/sh
f="$PAW/statfault"
if [ -f "\$f" ]; then
  m=\$(cat "\$f")
  case "\$m" in
    fail) exit 1 ;;
    print:*) echo "\${m#print:}"; exit 0 ;;
  esac
fi
exec "$_rst" "\$@"
SHIM
  chmod +x "$PAW/shim/stat"; _f="$PW/board.md"
  # the real file: each reader gives a decimal and status 0
  for _fn in wr_inode _wr_links wr_mtime; do
    _o=$(pa_run WARROOM_DIR="$PW" bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; "$2" "$3"' _ "$PB" "$_fn" "$_f" 2>/dev/null); _r=$?
    { [ $_r = 0 ] && case "$_o" in ''|0*|*[!0-9]*) false ;; *) true ;; esac; } || { PA_WHY="ST1: $_fn on a real file -> rc $_r out '$_o' (want a plain decimal)"; return 1; }
  done
  # a failing stat, and every odd answer: status 1 and nothing printed, for all three readers
  for _m in fail print: print:0 print:012 print:abc print:-4 print:1234567890123456 'print:12 34'; do
    printf '%s\n' "$_m" > "$PAW/statfault"
    for _fn in wr_inode _wr_links wr_mtime; do
      _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; "$2" "$3"' _ "$PB" "$_fn" "$_f" 2>/dev/null); _r=$?
      { [ $_r != 0 ] && [ -z "$_o" ]; } || { PA_WHY="ST1: $_fn with stat '$_m' -> rc $_r out '$_o' (want failure and no output)"; return 1; }
    done
  done
  # the consequences: no generation for a board whose inode cannot be read; a leaf with an unreadable link count is not ok; a lock
  # on an existing file refuses; the gap check cannot tell
  printf 'fail\n' > "$PAW/statfault"
  pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; wr_generation "$2"' _ "$PB" "$_f"
  { [ "$PA_RC" != 0 ] && [ -z "$PA_OUT" ]; } || { PA_WHY="ST1: wr_generation with a failing stat -> rc $PA_RC out '$PA_OUT'"; return 1; }
  pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; wr_leaf_ok "$2"' _ "$PB" "$_f"
  [ "$PA_RC" != 0 ] || { PA_WHY="ST1: wr_leaf_ok accepted a file whose link count cannot be read"; return 1; }
  : > "$PW/lk"; pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; wr_lock "$2"' _ "$PB" "$PW/lk"
  { [ "$PA_RC" = 1 ] && printf '%s\n' "$PA_OUT" | grep -q "its link count cannot be read"; } || { PA_WHY="ST1: wr_lock on an existing file with a failing stat -> rc $PA_RC out '$PA_OUT'"; return 1; }
  rm -f "$PAW/statfault"
  pa_pass WARROOM_DIR="$PW" bash -c '. "$1/_common.sh"; wr_leaf_ok "$2"' _ "$PB" "$_f" || return 1
}
fx_ck1() { # the clock is read once, checked and validated: a bad stamp or time is no post, no arming, no delivery (never an empty or odd value on the board, in the registry or in a gap sum)
  pa_setup; pa_w; mkdir -p "$PAW/shim"
  cat > "$PAW/shim/date" <<SHIM
#!/bin/sh
f="$PAW/datefault"
if [ -f "\$f" ]; then
  m=\$(cat "\$f")
  case "\$m" in
    stamp) [ "\$1" = "+%H:%M" ] && { echo ab:cd; exit 0; } ;;
    fail) exit 1 ;;
    epoch:*) [ "\$1" = "+%s" ] && { echo "\${m#epoch:}"; exit 0; } ;;
  esac
fi
exec /bin/date "\$@"
SHIM
  chmod +x "$PAW/shim/date"
  # the epoch reader: a canonical decimal or nothing
  for _v in "1700000000:0" "x:1" "0123:1" "-5:1" "1234567890123456:1" ":1"; do
    printf 'epoch:%s\n' "${_v%:*}" > "$PAW/datefault"
    _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; wr_epoch' _ "$PB" 2>/dev/null); _r=$?
    if [ "${_v#*:}" = 0 ]; then [ $_r = 0 ] && [ "$_o" = "${_v%:*}" ] || { PA_WHY="K1: wr_epoch '${_v%:*}' -> rc $_r out '$_o' (want 0 and the value)"; return 1; }
    else [ $_r != 0 ] && [ -z "$_o" ] || { PA_WHY="K1: wr_epoch '${_v%:*}' -> rc $_r out '$_o' (want failure and no output)"; return 1; }; fi
  done
  printf 'fail\n' > "$PAW/datefault"
  _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; wr_epoch' _ "$PB" 2>/dev/null) && { PA_WHY="K1: wr_epoch succeeded with a failing date"; return 1; }
  # a post with a clock that is not a time (printed garbage, or a failing date): nothing is posted
  for _m in stamp fail; do
    printf '%s\n' "$_m" > "$PAW/datefault"; _b0=$(cksum < "$PW/board.md")
    pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" post BOSS "k1 $_m line"
    [ "$PA_RC" = 1 ] && [ "$(cksum < "$PW/board.md")" = "$_b0" ] && printf '%s\n' "$PA_OUT" | grep -q "could not read the clock: nothing posted" || { PA_WHY="K1 ($_m): post rc $PA_RC (want 1), board changed=$([ "$(cksum < "$PW/board.md")" = "$_b0" ] && echo n || echo y): $(printf '%s' "$PA_OUT" | head -c 160)"; return 1; }
  done
  rm -f "$PAW/datefault"
  pa_pass WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" post BOSS "k1 good line" || return 1
  tail -1 "$PW/board.md" | grep -Eq '^\[[0-9]{2}:[0-9]{2} · BOSS\] k1 good line$' || { PA_WHY="K1: the control post has no HH:MM stamp: $(tail -1 "$PW/board.md")"; return 1; }
  [ "$PS_OK" = 1 ] || { PA_SKIP="the waiter half needs ps start times (the clock readers above ran)"; return 0; }
  # arming with a clock that is not a time: the waiter says so and leaves no registry row
  printf 'stamp\n' > "$PAW/datefault"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-k1arm > "$PAW/o.arm" 2>&1 & _wpk=$!
  if ! wait_exit "$_wpk" 8; then   # a waiter that armed is still running: stop it (by its registered pid) and fail
    _wp=$(awk -F'\t' '$1 == "sid-k1arm" { print $3 }' "$PW/seats.tsv" 2>/dev/null); [ -z "$_wp" ] || kill "$_wp" 2>/dev/null; kill "$_wpk" 2>/dev/null; wait "$_wpk" 2>/dev/null
    PA_WHY="K1: the waiter armed with a clock that is not a time: $(head -c 120 "$PAW/o.arm")"; return 1
  fi
  wait "$_wpk"; _rk=$?
  { [ "$_rk" != 0 ] && grep -q "could not read the clock: not armed" "$PAW/o.arm" && ! grep -q "sid-k1arm" "$PW/seats.tsv" 2>/dev/null; } || { PA_WHY="K1: arming with a bad clock: rc $_rk, out '$(head -c 160 "$PAW/o.arm")'"; return 1; }
  rm -f "$PAW/datefault"
  # the gap check: a delivery sets the gap; the next wake is held for the gap. With the clock unreadable it is NOT delivered
  # (the waiter says so and looks again); it is not treated as "gap open"
  pa_run WARROOM_DIR="$PW" WARROOM_MIN_GAP=300 PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-k1a > "$PAW/o.a" 2> "$PAW/e.a" & _wpa=$!
  for _ in 1 2 3 4 5 6 7 8; do grep -q "sid-k1a" "$PW/seats.tsv" 2>/dev/null && break; sleep 1; done
  pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: k1 first line" >/dev/null
  wait_exit "$_wpa" 8 || { kill "$_wpa" 2>/dev/null; PA_WHY="K1: the first wake was not delivered"; return 1; }
  wait "$_wpa" 2>/dev/null; grep -q "k1 first line" "$PAW/o.a" || { PA_WHY="K1: the first wake is missing: $(head -c 160 "$PAW/e.a")"; return 1; }
  pa_run WARROOM_DIR="$PW" WARROOM_MIN_GAP=300 PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-k1b > "$PAW/o.b" 2> "$PAW/e.b" & _wpb=$!
  for _ in 1 2 3 4 5 6 7 8; do grep -q "sid-k1b" "$PW/seats.tsv" 2>/dev/null && break; sleep 1; done
  _wp=$(awk -F'\t' '$1 == "sid-k1b" { print $3 }' "$PW/seats.tsv")
  [ -n "$_wp" ] || { kill "$_wpb" 2>/dev/null; PA_WHY="K1: the second waiter did not arm"; return 1; }
  printf 'epoch:x\n' > "$PAW/datefault"
  pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: k1 second line" >/dev/null; sleep 4
  _alive=n; kill -0 "$_wp" 2>/dev/null && _alive=y
  rm -f "$PAW/datefault"
  _ok=y; [ "$_alive" = y ] && [ -z "$(cat "$PAW/o.b")" ] && grep -q "could not read the clock; nothing delivered" "$PAW/e.b" || _ok=n
  kill "$_wp" 2>/dev/null; wait "$_wpb" 2>/dev/null
  [ "$_ok" = y ] || { PA_WHY="K1: with the clock unreadable at the gap check: alive=$_alive (want y), delivered='$(head -c 80 "$PAW/o.b")' (want none), err '$(head -c 160 "$PAW/e.b")'"; return 1; }
  return 0
}
fx_m1() { # the seat registry cannot be read: the waiter stays up and delivers nothing (poll check and delivery check), then delivers once it can read; only a registry that is read and lacks the row ends it
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_setup; pa_w; mkdir -p "$PAW/shim"; _aw=$(command -v cat)
  cat > "$PAW/shim/cat" <<SHIM
#!/bin/sh
f="$PAW/regfault"
if [ -f "\$f" ]; then
  for a; do last=\$a; done
  if [ "\$last" = "$PW/seats.tsv" ]; then
    k=\$($_aw "\$f")
    if [ "\$k" = all ] || { [ "\$k" = locked ] && { [ -e /dev/fd/8 ] || [ -e /dev/fd/9 ]; }; }; then echo hit >> "\$f.hit"; echo "shim: cat refused" >&2; exit 2; fi
  fi
fi
exec $_aw "\$@"
SHIM
  chmod +x "$PAW/shim/cat"
  for _case in poll lock; do
    _sid="sid-m1$_case"; : > "$PAW/o.$_case"; : > "$PAW/e.$_case"
    pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 "$_sid" > "$PAW/o.$_case" 2> "$PAW/e.$_case" & _wpa=$!
    for _ in 1 2 3 4 5 6 7 8; do grep -q "$_sid" "$PW/seats.tsv" 2>/dev/null && break; sleep 1; done
    _wp=$(awk -F'\t' -v s="$_sid" '$1 == s { print $3 }' "$PW/seats.tsv")
    [ -n "$_wp" ] || { kill "$_wpa" 2>/dev/null; PA_WHY="M1 ($_case): the waiter did not arm"; return 1; }
    rm -f "$PAW/regfault.hit"
    if [ "$_case" = poll ]; then printf 'all\n' > "$PAW/regfault"; else printf 'locked\n' > "$PAW/regfault"; fi   # locked: only a read made while the waiter holds a lock descriptor (the delivery check)
    _c0=$(cksum < "$PW/.cursor-W1" 2>/dev/null)
    pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: m1 $_case line" >/dev/null; sleep 4
    _alive=n; kill -0 "$_wp" 2>/dev/null && _alive=y
    _hit=n; [ -s "$PAW/regfault.hit" ] && _hit=y
    _c1=$(cksum < "$PW/.cursor-W1" 2>/dev/null)
    rm -f "$PAW/regfault"
    { [ "$_alive" = y ] && [ "$_hit" = y ]; } || { kill "$_wp" 2>/dev/null; wait "$_wpa" 2>/dev/null; PA_WHY="M1 ($_case): with the registry unreadable the waiter alive=$_alive (want y), fault reached=$_hit (want y): $(head -c 200 "$PAW/e.$_case")"; return 1; }
    grep -q "could not be read" "$PAW/e.$_case" || { kill "$_wp" 2>/dev/null; wait "$_wpa" 2>/dev/null; PA_WHY="M1 ($_case): no line saying the registry could not be read: $(head -c 200 "$PAW/e.$_case")"; return 1; }
    grep -q "WAITER REPLACED" "$PAW/e.$_case" && { PA_WHY="M1 ($_case): an unreadable registry was treated as replaced"; return 1; }
    [ -z "$(cat "$PAW/o.$_case")" ] && [ "$_c0" = "$_c1" ] || { kill "$_wp" 2>/dev/null; wait "$_wpa" 2>/dev/null; PA_WHY="M1 ($_case): the wake was delivered or the position moved while the registry was unreadable"; return 1; }
    wait_exit "$_wpa" 8 || { kill "$_wp" 2>/dev/null; wait "$_wpa" 2>/dev/null; PA_WHY="M1 ($_case): the line was not delivered once the registry could be read"; return 1; }
    wait "$_wpa" 2>/dev/null; grep -q "m1 $_case line" "$PAW/o.$_case" || { PA_WHY="M1 ($_case): the waiter ended without the line"; return 1; }
  done
}
fx_ab1() { # the seat registry is gone while the waiter runs: that is "no row for this waiter" (replaced, exit 3), not "cannot tell"
  pa_setup; pa_w
  pa_run WARROOM_DIR="$PW" "$PB/waiter.sh" W1 sid-ab1 > "$PAW/o" 2>"$PAW/e" & WPA=$!
  for _ in 1 2 3 4 5 6 7 8; do grep -q sid-ab1 "$PW/seats.tsv" 2>/dev/null && break; sleep 1; done
  grep -q sid-ab1 "$PW/seats.tsv" 2>/dev/null || { kill $WPA 2>/dev/null; wait $WPA 2>/dev/null; PA_WHY="AB1: the waiter did not arm"; return 1; }
  rm -f "$PW/seats.tsv"
  wait_exit $WPA 12 || { kill $WPA 2>/dev/null; wait $WPA 2>/dev/null; PA_WHY="AB1: with the registry gone the waiter stayed up: $(head -c 200 "$PAW/e")"; return 1; }
  wait $WPA 2>/dev/null; _r=$?
  { [ "$_r" = 3 ] && grep -q "WAITER REPLACED" "$PAW/e" && [ ! -s "$PAW/o" ]; } || { PA_WHY="AB1: rc $_r (want 3), out '$(cat "$PAW/o")', err '$(head -c 200 "$PAW/e")'"; return 1; }
}
fx_g2() { # the restore fails: the new mark stays and the hook says so (kills a failed-restore-only "rm")
  pa_setup; pa_w; printf '[00:00 · W1] working\n' > "$PW/board.md"; mkdir -p "$PAW/shim"; _py=$(command -v python3)
  printf '#!/bin/sh\ncase "$*" in *os.replace*.guard-W1) c=$(cat "%s" 2>/dev/null || echo 0); c=$((c+1)); echo $c > "%s"; [ $c = 2 ] && { echo "shim: replace refused" >&2; exit 1; } ;; esac\nexec %s "$@"\n' "$PAW/cnt" "$PAW/cnt" "$_py" > "$PAW/shim/python3"; chmod +x "$PAW/shim/python3"
  hold "$PW/board.md"; _e=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" WARROOM_LOCK_WAIT=1 WARROOM_IDLE_MIN=0 bash "$PHK/board-guard.sh" </dev/null 2>&1 >/dev/null); unhold "$PW/board.md"
  _m=$(cat "$PW/.guard-W1" 2>/dev/null)
  case "$_e" in *"could not be restored"*) true ;; *) PA_WHY="G2: no diagnostic: '$_e'"; return 1 ;; esac
  { [ -n "$_m" ] && [ "$_m" != "-" ]; } || { PA_WHY="G2: the new mark did not stay: '$_m'"; return 1; }
}
fx_k11() { # the filter fails: nothing is consumed and the line is delivered on the next good poll (kills an unchecked filter)
  pa_setup; pa_w; mkdir -p "$PAW/shim"; _aw=$(command -v awk)
  printf '#!/bin/sh\n[ -f "%s" ] && [ "$1" = -v ] && case "$2" in seat=*) echo "shim: awk refused" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$PAW/awkfault" "$_aw" > "$PAW/shim/awk"; chmod +x "$PAW/shim/awk"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-k11 > "$PAW/o" 2>"$PAW/e" & WPA=$!; sleep 2
  : > "$PAW/awkfault"; pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: k11 line" >/dev/null; sleep 3; rm -f "$PAW/awkfault"
  wait_exit $WPA 8 || { kill $WPA 2>/dev/null; wait $WPA 2>/dev/null; PA_WHY="K11: the line was not delivered after the fault ended (it was consumed by the failed filter)"; return 1; }; wait $WPA 2>/dev/null
  grep -q "k11 line" "$PAW/o" || { PA_WHY="K11: the waiter ended without the line"; return 1; }
}
# --- F9 and F1 fixtures: the fault hits the exact call (a cksum or awk shim keyed on the call's input or program), leaves a hit marker, and the diagnostic is the exact one ---
pa_ck() { # cksum shim: while $PAW/ckfault holds SIZE (or "all"), a cksum whose input has SIZE bytes fails and leaves a line in ckfault.hit
  mkdir -p "$PAW/shim"; _ck=$(command -v cksum)
  cat > "$PAW/shim/cksum" <<SHIM
#!/bin/sh
f="$PAW/ckfault"
if [ -f "\$f" ]; then
  k=\$(cat "\$f"); in="\$f.in.\$\$"; cat > "\$in"; sz=\$(wc -c < "\$in" | tr -d " ")
  if [ "\$k" = all ] || [ "\$k" = "\$sz" ]; then rm -f "\$in"; echo hit >> "\$f.hit"; echo "shim: cksum refused" >&2; exit 1; fi
  $_ck < "\$in"; r=\$?; rm -f "\$in"; exit \$r
fi
exec $_ck "\$@"
SHIM
  chmod +x "$PAW/shim/cksum"
}
pa_ckset() { rm -f "$PAW/ckfault.hit"; printf '%s\n' "$1" > "$PAW/ckfault"; }
pa_ckoff() { rm -f "$PAW/ckfault"; }
pa_ckhit() { [ -s "$PAW/ckfault.hit" ]; }
pa_b2() { pa_setup; pa_w; printf '[00:00 · BOSS] one\n[00:00 · BOSS] three words here\n' > "$PW/board.md"; pa_ck; }
fx_f9a() { # board.sh tail: the prefix checksum of a saved anchor fails: nothing printed, anchor kept, exit 1, the next tail shows only the new line
  pa_b2; pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS >/dev/null; printf '[00:00 · W1] fresh f9a\n' >> "$PW/board.md"; _a0=$(cksum < "$PW/.anchor-BOSS")
  pa_ckset "$(head -n 2 "$PW/board.md" | wc -c | tr -d ' ')"
  _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" tail BOSS 2>"$PAW/e"); _r=$?; pa_ckoff
  { [ "$_r" = 1 ] && [ -z "$_o" ]; } || { PA_WHY="F9a: rc $_r, out '$_o' (want rc 1, nothing printed)"; return 1; }
  { pa_ckhit && grep -q "checksum the board" "$PAW/e"; } || { PA_WHY="F9a: the fault was not reached or the diagnostic differs: '$(cat "$PAW/e")'"; return 1; }
  { [ "$(cksum < "$PW/.anchor-BOSS")" = "$_a0" ] && [ -z "$(find "$PW" -name '.wrtmp.*')" ]; } || { PA_WHY="F9a: the anchor moved or a temp is left"; return 1; }
  _o=$(pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS)
  case "$_o" in *"fresh f9a"*) ;; *) PA_WHY="F9a: the retry does not show the new line"; return 1 ;; esac
  case "$_o" in *"three words here"*) PA_WHY="F9a: the retry printed the whole board"; return 1 ;; esac
}
fx_f9b() { # board.sh tail: an anchor from the older version (checksum of the last line) whose line checksum fails
  pa_b2; _ino=$(stat -c %i "$PW/board.md" 2>/dev/null || stat -f %i "$PW/board.md"); _gc=$(head -n 1 "$PW/board.md" | cksum | cut -d' ' -f1); _ls=$(sed -n 2p "$PW/board.md" | cksum | cut -d' ' -f1)
  printf '%s:%s 2 %s %s\n' "$_ino" "$_gc" "$(date +%s)" "$_ls" > "$PW/.anchor-BOSS"; printf '[00:00 · W1] fresh f9b\n' >> "$PW/board.md"; _a0=$(cksum < "$PW/.anchor-BOSS")
  pa_ckset "$(sed -n 2p "$PW/board.md" | wc -c | tr -d ' ')"
  _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" tail BOSS 2>"$PAW/e"); _r=$?; pa_ckoff
  { [ "$_r" = 1 ] && [ -z "$_o" ]; } || { PA_WHY="F9b: rc $_r, out '$_o' (want rc 1, nothing printed)"; return 1; }
  { pa_ckhit && grep -q "checksum the board" "$PAW/e" && [ "$(cksum < "$PW/.anchor-BOSS")" = "$_a0" ]; } || { PA_WHY="F9b: fault not reached, diagnostic differs, or the anchor moved: '$(cat "$PAW/e")'"; return 1; }
  _o=$(pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS)
  case "$_o" in *"fresh f9b"*) ;; *) PA_WHY="F9b: the retry does not show the new line"; return 1 ;; esac
  case "$_o" in *"three words here"*) PA_WHY="F9b: the retry printed the whole board (the older anchor is not accepted)"; return 1 ;; esac
}
fx_f9c() { # board-tail.sh (the prompt hook): a failed generation or prefix checksum in the cursor check shows no count and says why
  pa_b2; pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS >/dev/null; printf 'sid-f9c\tBOSS\t1\t00:00\n' > "$PW/seats.tsv"; printf '[00:00 · W1] @BOSS fresh f9c\n' >> "$PW/board.md"
  _o=$(printf '{"session_id":"sid-f9c"}' | pa_run WARROOM_DIR="$PW" bash "$PHK/board-tail.sh" 2>/dev/null)
  case "$_o" in *"1 new line"*) ;; *) PA_WHY="F9c: the control without a fault does not show '1 new line': '$_o'"; return 1 ;; esac
  for _v in gen prefix; do
    if [ $_v = gen ]; then pa_ckset "$(head -n 1 "$PW/board.md" | wc -c | tr -d ' ')"; else pa_ckset "$(head -n 2 "$PW/board.md" | wc -c | tr -d ' ')"; fi
    _o=$(printf '{"session_id":"sid-f9c"}' | pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PHK/board-tail.sh" 2>"$PAW/e"); pa_ckoff
    { [ -z "$_o" ] && pa_ckhit && grep -q "could not read the read position of seat" "$PAW/e"; } || { PA_WHY="F9c ($_v): out '$_o', hit $(pa_ckhit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
  done
}
fx_f9d() { # waiter arm: a saved cursor whose prefix checksum fails: exit 1 'not armed', registry and cursor byte-equal
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; rm -f "$PW/seats.tsv"; pa_run WARROOM_DIR="$PW" "$PB/waiter.sh" W1 sid-f9d1 >/dev/null 2>&1 & _wp=$!; sleep 2; kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-f9d1" 2>/dev/null; sleep 1
  [ -s "$PW/.cursor-W1" ] || { PA_WHY="F9d: the first arm saved no cursor"; return 1; }
  _s0=$(cksum < "$PW/seats.tsv"); _c0=$(cksum < "$PW/.cursor-W1"); pa_ckset "$(wc -c < "$PW/board.md" | tr -d ' ')"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-f9d2 >/dev/null 2>"$PAW/e" & _wp=$!
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pa_ckoff; PA_WHY="F9d: the waiter armed although the cursor checksum failed"; return 1; }; wait $_wp 2>/dev/null; _r=$?; pa_ckoff
  { [ "$_r" = 1 ] && pa_ckhit && grep -q "checksum the board" "$PAW/e" && grep -q "not armed" "$PAW/e"; } || { PA_WHY="F9d: rc $_r, hit $(pa_ckhit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
  { [ "$(cksum < "$PW/seats.tsv")" = "$_s0" ] && [ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ]; } || { PA_WHY="F9d: the registry or the cursor changed"; return 1; }
}
fx_f9e() { # board-guard: the checksum of the post line fails: nothing posted, no mark saved, said so; the next prompt posts and saves the mark
  pa_b2; printf '[00:00 · W1] a\n[00:00 · W1] working on this longer line\n' > "$PW/board.md"; _b0=$(cksum < "$PW/board.md")
  pa_ckset "$(tail -n 1 "$PW/board.md" | wc -c | tr -d ' ')"
  _e=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" WARROOM_IDLE_MIN=0 bash "$PHK/board-guard.sh" </dev/null 2>&1 >/dev/null); _r=$?; pa_ckoff
  { [ "$_r" = 0 ] && pa_ckhit && [ "$(cksum < "$PW/board.md")" = "$_b0" ] && [ ! -e "$PW/.guard-W1" ]; } || { PA_WHY="F9e: rc $_r, hit $(pa_ckhit && echo y || echo n), board changed or a mark exists: '$_e'"; return 1; }
  case "$_e" in *"could not checksum the post"*) ;; *) PA_WHY="F9e: no diagnostic: '$_e'"; return 1 ;; esac
  pa_run WARROOM_DIR="$PW" WARROOM_IDLE_MIN=0 bash "$PHK/board-guard.sh" </dev/null >/dev/null 2>&1
  { [ -s "$PW/.guard-W1" ] && [ "$(cksum < "$PW/board.md")" != "$_b0" ]; } || { PA_WHY="F9e: the next prompt did not post and save the mark"; return 1; }
}
fx_f1a() { # waiter arm: the registry rewrite (awk) fails, and only that awk call: exit 1 with the registry diagnostic, registry byte-equal, hit marker
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; printf 'other-sid\tBOSS\t1\t00:00\n' > "$PW/seats.tsv"; _s0=$(cksum < "$PW/seats.tsv"); mkdir -p "$PAW/shim"; _aw=$(command -v awk)
  cat > "$PAW/shim/awk" <<SHIM
#!/bin/sh
if [ -f "$PAW/awkfault" ]; then
  case "\$*" in *'\$1!=s && \$2!=seat'*) echo hit >> "$PAW/awkfault.hit"; echo "shim: awk refused" >&2; exit 1 ;; esac
fi
exec $_aw "\$@"
SHIM
  chmod +x "$PAW/shim/awk"; : > "$PAW/awkfault"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-f1a >/dev/null 2>"$PAW/e" & _wp=$!
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; PA_WHY="F1a: the waiter armed although the registry rewrite failed"; return 1; }; wait $_wp 2>/dev/null; _r=$?; rm -f "$PAW/awkfault"
  { [ "$_r" = 1 ] && [ -s "$PAW/awkfault.hit" ] && grep -q "could not write the seat registry: not armed" "$PAW/e"; } || { PA_WHY="F1a: rc $_r, hit $([ -s "$PAW/awkfault.hit" ] && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
  { [ "$(cksum < "$PW/seats.tsv")" = "$_s0" ] && [ -z "$(find "$PW" -name '.wrtmp.*')" ]; } || { PA_WHY="F1a: the registry changed or a temp is left"; return 1; }
}
fx_f1b() { # waiter arm: the arm-time prefix checksum fails (a fresh seat: no cursor, the generation call works): exit 1 with the checksum diagnostic, no cursor, registry byte-equal
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; printf 'other-sid\tBOSS\t1\t00:00\n' > "$PW/seats.tsv"; _s0=$(cksum < "$PW/seats.tsv"); pa_ckset "$(wc -c < "$PW/board.md" | tr -d ' ')"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-f1b >/dev/null 2>"$PAW/e" & _wp=$!
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pa_ckoff; PA_WHY="F1b: the waiter armed although the arm-time checksum failed"; return 1; }; wait $_wp 2>/dev/null; _r=$?; pa_ckoff
  { [ "$_r" = 1 ] && pa_ckhit && grep -q "checksum the board" "$PAW/e" && grep -q "not armed" "$PAW/e"; } || { PA_WHY="F1b: rc $_r, hit $(pa_ckhit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
  { [ ! -e "$PW/.cursor-W1" ] && [ "$(cksum < "$PW/seats.tsv")" = "$_s0" ]; } || { PA_WHY="F1b: a cursor was saved or the registry changed"; return 1; }
}
fx_f1c() { # board.sh tail: the generation checksum fails (first call): exit 1 with the generation diagnostic ('could not read the board'), no anchor
  pa_b2; pa_ckset all
  _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" tail BOSS 2>"$PAW/e"); _r=$?; pa_ckoff
  { [ "$_r" = 1 ] && [ -z "$_o" ] && pa_ckhit && grep -q "could not read the board" "$PAW/e" && [ ! -e "$PW/.anchor-BOSS" ] && [ -z "$(find "$PW" -name '.wrtmp.*')" ]; } || { PA_WHY="F1c: rc $_r, out '$_o', hit $(pa_ckhit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
}
fx_sm1() { # checksum helpers: a good run prints one answer and status 0; a failing cksum that already printed something leaves status 1 and NOTHING on stdout
  pa_setup; pa_w; mkdir -p "$PAW/shim"
  printf '#!/bin/sh\necho "99 9"\nexit 1\n' > "$PAW/shim/cksum"; chmod +x "$PAW/shim/cksum"
  for _fn in wr_sum wr_sumstdin; do
    _o=$(printf 'abc\n' | pa_run WARROOM_DIR="$PW" bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; "$2"' _ "$PB" "$_fn" 2>/dev/null); _r=$?
    case "$_fn:$_o" in wr_sum:1112837078|wr_sumstdin:1112837078-4) ;; *) PA_WHY="SM1: $_fn good run -> '$_o'"; return 1 ;; esac
    [ "$_r" = 0 ] || { PA_WHY="SM1: $_fn good run -> rc $_r"; return 1; }
    _o=$(printf 'abc\n' | pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash -c '. "$1/_common.sh"; . "$1/_cursor.sh"; "$2"' _ "$PB" "$_fn" 2>/dev/null); _r=$?
    { [ "$_r" != 0 ] && [ -z "$_o" ]; } || { PA_WHY="SM1: $_fn with a failing cksum -> rc $_r out '$_o' (want failure and no output)"; return 1; }
  done
  return 0
}
fx_lg1() { # job ledger: a ledger that cannot be read (a read that prints a row and then fails) posts nothing and removes nothing; a readable one still posts for a dead job and drops its row
  pa_setup; pa_w; mkdir -p "$PAW/shim"; _rcat=$(command -v cat) || { PA_WHY="LG1: no cat to wrap"; return 1; }
  cat > "$PAW/shim/cat" <<SHIM
#!/bin/sh
case "\$*" in
  *pids.tsv*) [ -f "$PAW/catfault" ] && { printf 'dead1\t999999\tBOSS\tx\n'; exit 1; } ;;
esac
exec "$_rcat" "\$@"
SHIM
  chmod +x "$PAW/shim/cat"; _l="$PW/pids.tsv"; _b="$PW/board.md"
  printf 'dead1\t999999\tBOSS\tx\n' > "$_l"; : > "$PAW/catfault"
  _lb=$(cksum < "$_l"); _bb=$(cksum < "$_b" 2>/dev/null)
  pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PB/pids.sh" check
  { [ "$PA_RC" = 1 ] && [ "$(cksum < "$_l")" = "$_lb" ] && [ "$(cksum < "$_b" 2>/dev/null)" = "$_bb" ] && printf '%s' "$PA_OUT" | grep -q "could not be read; nothing changed"; } \
    || { PA_WHY="LG1: unreadable ledger -> rc $PA_RC, ledger or board changed, or no message: $PA_OUT"; return 1; }
  rm -f "$PAW/catfault"
  pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PB/pids.sh" check
  { [ "$PA_RC" = 0 ] && [ ! -s "$_l" ] && grep -q "job 'dead1' (pid 999999) is no longer running" "$_b"; } \
    || { PA_WHY="LG1: readable ledger -> rc $PA_RC, row kept or no wake: $PA_OUT"; return 1; }
  return 0
}
fx_rg1() { # seat registry read by the hooks: a registry that cannot be read (a read that prints a row and then fails) is said so, exit 1, and the hook never shows a stale row or "not armed"; an absent one is an empty registry
  pa_setup; pa_w; mkdir -p "$PAW/shim"; _rcat=$(command -v cat) || { PA_WHY="RG1: no cat to wrap"; return 1; }
  cat > "$PAW/shim/cat" <<SHIM
#!/bin/sh
case "\$*" in
  *seats.tsv*) [ -f "$PAW/catfault" ] && { printf 'sid-pa\tBOSS\t999999\t10:00\tx\n'; exit 1; } ;;
esac
exec "$_rcat" "\$@"
SHIM
  chmod +x "$PAW/shim/cat"; _r="$PW/seats.tsv"; : > "$PAW/catfault"
  printf 'sid-pa\tBOSS\t999999\t10:00\tx\n' > "$_r"; _rb=$(cksum < "$_r")
  for _h in board-tail.sh waiter-check.sh; do
    PA_IN='{"session_id": "sid-pa"}' pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PHK/$_h"
    { [ "$PA_RC" = 1 ] && printf '%s' "$PA_OUT" | grep -q "seat registry" && ! printf '%s' "$PA_OUT" | grep -q "WAITER ENDED\|WAITER NOT ARMED\|^\[BOARD\]" && [ "$(cksum < "$_r")" = "$_rb" ]; } \
      || { PA_WHY="RG1: $_h with an unreadable registry -> rc $PA_RC: $PA_OUT"; return 1; }
  done
  rm -f "$PAW/catfault"
  PA_IN='{"session_id": "sid-pa"}' pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PHK/waiter-check.sh"
  { [ "$PA_RC" = 0 ] && printf '%s' "$PA_OUT" | grep -q "WAITER ENDED"; } || { PA_WHY="RG1: waiter-check with a readable registry -> rc $PA_RC: $PA_OUT"; return 1; }
  rm -f "$_r"
  PA_IN='{"session_id": "sid-pa"}' pa_exec WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PHK/board-tail.sh"
  { [ "$PA_RC" = 0 ] && [ -z "$PA_OUT" ]; } || { PA_WHY="RG1: board-tail with no registry -> rc $PA_RC: $PA_OUT"; return 1; }
  return 0
}
fx_ep1() { # entry paths: every script finds its own folder by a plain expansion, from a bare name, ./name, an absolute path, a symlinked folder and a folder with a space in it
  pa_setup; pa_w; _ep="$PAW/sp ace"; mkdir -p "$_ep" || { PA_WHY="EP1: no folder"; return 1; }
  cp -R "$PB" "$_ep/bin" && cp -R "$PHK" "$_ep/hooks" && ln -s "$_ep/bin" "$PAW/lnkbin" && ln -s "$_ep/hooks" "$PAW/lnkhooks" || { PA_WHY="EP1: copy"; return 1; }
  for _s in bin/board.sh bin/pids.sh bin/waiter.sh hooks/board-tail.sh hooks/waiter-check.sh hooks/board-guard.sh; do
    _d=${_s%/*}; _b=${_s##*/}
    PA_IN='{"session_id": "sid-pa"}' pa_exec WARROOM_DIR="$PW" bash "$_ep/$_s"; _r0=$PA_RC; _o0=$PA_OUT
    case "$_o0" in *"No such file"*|*"cannot"*"folder"*) PA_WHY="EP1: $_s by absolute path -> $_o0"; return 1 ;; esac
    for _how in "bare" "dot" "link"; do
      case "$_how" in
        bare) _cmd="cd '$_ep/$_d' && bash '$_b'" ;;
        dot) _cmd="cd '$_ep/$_d' && bash './$_b'" ;;
        link) _cmd="bash '$PAW/lnk$_d/$_b'" ;;
      esac
      _o=$(printf '%s' '{"session_id": "sid-pa"}' | pa_run WARROOM_DIR="$PW" bash -c "$_cmd" 2>&1); _r=$?
      { [ "$_r" = "$_r0" ] && [ "$_o" = "$_o0" ]; } || { PA_WHY="EP1: $_s ($_how) -> rc $_r '$_o' (absolute: rc $_r0 '$_o0')"; return 1; }
    done
  done
  return 0
}
pa_run_fx fx_c1 "cursor record: a valid record resumes, an old one or none is \"none\", and every corrupt shape (leading zero, 20 digits, future time, extra field or line, no newline, bad generation or checksum, symlink, unreadable, unsearchable folder) is status 1 with nothing on stdout; a repaired record recovers"
pa_run_fx fx_t1 "process judgement: a gone pid or another start time is dead; a live process of another owner and a ps that fails after printing part of a time are unknown, never dead"
pa_run_fx fx_gr1 "guard reads: an absent ledger or mark is first use and posts once; an unreadable ledger or board, an odd mark, stamp or clock posts nothing and says why"
pa_run_fx fx_st1 "identity stat: an inode, a link count and a modification time are a plain decimal or nothing; a failing or odd stat is never a default, and the generation, the leaf check and the lock refuse on it"
pa_run_fx fx_ck1 "clock: a bad or failing date is no post stamp, no arming and no delivery past the gap; the epoch reader accepts only a canonical decimal"
pa_run_fx fx_ep1 "entry paths: every script finds its own folder by a plain expansion and one checked capture, from a bare name, ./name, an absolute path, a symlinked folder and a folder with a space in it"
pa_run_fx fx_rg1 "seat registry in the hooks: an unreadable registry is said so with exit 1 and never shows a stale row or not armed; an absent one is empty"
pa_run_fx fx_lg1 "job ledger: a ledger that cannot be read posts nothing and removes nothing; a readable one posts for a dead job and drops its row"
pa_run_fx fx_sm1 "checksum helpers: a good run prints one answer; a failing stage that already printed leaves status 1 and nothing on stdout"
pa_run_fx fx_m1 "seat registry unreadable: the waiter stays up at the poll check and at the locked delivery check, delivers nothing and keeps its position, then delivers when the registry reads again"
pa_run_fx fx_ab1 "seat registry gone while the waiter runs: the waiter stops as replaced (exit 3), delivers nothing"
pa_run_fx fx_f9a "F9: a failed cursor prefix checksum in board.sh tail prints nothing, exits 1, keeps the anchor, and the retry shows only the new line"
pa_run_fx fx_f9b "F9: a failed line checksum on an older-format anchor prints nothing, exits 1, keeps the anchor; the retry accepts the older anchor"
pa_run_fx fx_f9c "F9: a failed generation or prefix checksum in the prompt hook shows no count and says why"
pa_run_fx fx_f9d "F9: a failed cursor checksum while arming exits 1 'not armed' (no re-read from line 1), registry and cursor byte-equal"
pa_run_fx fx_f9e "F9: a failed checksum of the post line in board-guard posts nothing, saves no mark and says why; the next prompt posts and saves it"
pa_run_fx fx_f1a "F1: a failed registry rewrite (only that awk call) exits 1 with the registry diagnostic, registry byte-equal, no temp left"
pa_run_fx fx_f1b "F1: a failed arm-time prefix checksum (no cursor yet) exits 1 with the checksum diagnostic, no cursor saved, registry byte-equal"
pa_run_fx fx_f1c "F1: a failed generation checksum in board.sh tail exits 1 with the generation diagnostic and saves no anchor"
pa_wc() { # wc shim: while $PAW/wcfault holds N, the Nth `wc -l` of the run fails ("all": every one) and leaves a line in wcfault.hit
  mkdir -p "$PAW/shim"; _wcb=$(command -v wc)
  cat > "$PAW/shim/wc" <<SHIM
#!/bin/sh
f="$PAW/wcfault"
if [ -f "\$f" ] && [ "\$1" = -l ]; then
  k=\$(cat "\$f"); c=\$(cat "\$f.cnt" 2>/dev/null || echo 0); c=\$((c+1)); echo "\$c" > "\$f.cnt"
  if [ "\$k" = all ] || [ "\$k" = "\$c" ]; then echo hit >> "\$f.hit"; echo "shim: wc refused" >&2; exit 1; fi
fi
exec $_wcb "\$@"
SHIM
  chmod +x "$PAW/shim/wc"
}
pa_wcset() { rm -f "$PAW/wcfault.cnt" "$PAW/wcfault.hit"; printf '%s\n' "$1" > "$PAW/wcfault"; }
pa_wcoff() { rm -f "$PAW/wcfault" "$PAW/wcfault.cnt"; }
pa_wchit() { [ -s "$PAW/wcfault.hit" ]; }
fx_w1() { # board.sh tail: the line count fails (call 1 board.sh, call 2 the cursor check): exit 1 with that call's diagnostic, nothing printed, anchor byte-equal, the retry shows the line
  pa_b2; pa_wc; pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS >/dev/null; printf '[00:00 · W1] fresh w1\n' >> "$PW/board.md"; _a0=$(cksum < "$PW/.anchor-BOSS")
  for _c in 1 2; do
    pa_wcset $_c; _o=$(pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" tail BOSS 2>"$PAW/e"); _r=$?; pa_wcoff
    if [ $_c = 1 ]; then _want="could not count the lines of the board"; else _want="checksum the board"; fi
    { [ "$_r" = 1 ] && [ -z "$_o" ] && pa_wchit && grep -q "$_want" "$PAW/e" && [ "$(cksum < "$PW/.anchor-BOSS")" = "$_a0" ] && [ -z "$(find "$PW" -name '.wrtmp.*')" ]; } || { PA_WHY="W1 (wc call $_c): rc $_r, out '$_o', hit $(pa_wchit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
  done
  _o=$(pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS)
  case "$_o" in *"fresh w1"*) ;; *) PA_WHY="W1: the retry does not show the new line"; return 1 ;; esac
  case "$_o" in *"three words here"*) PA_WHY="W1: the retry printed the whole board"; return 1 ;; esac
}
fx_w2() { # board-tail.sh (the prompt hook): the line count fails (call 1 the hook, call 2 the cursor check): no count shown, the diagnostic of that call
  pa_b2; pa_wc; pa_run WARROOM_DIR="$PW" "$PB/board.sh" tail BOSS >/dev/null; printf 'sid-w2\tBOSS\t1\t00:00\n' > "$PW/seats.tsv"; printf '[00:00 · W1] @BOSS fresh w2\n' >> "$PW/board.md"
  for _c in 1 2; do
    pa_wcset $_c; _o=$(printf '{"session_id":"sid-w2"}' | pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" bash "$PHK/board-tail.sh" 2>"$PAW/e"); pa_wcoff
    if [ $_c = 1 ]; then _want="could not count the lines of the board"; else _want="could not read the read position of seat"; fi
    { [ -z "$_o" ] && pa_wchit && grep -q "$_want" "$PAW/e"; } || { PA_WHY="W2 (wc call $_c): out '$_o', hit $(pa_wchit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
  done
}
fx_w3() { # waiter arm: the line count fails (call 1 the arm, call 2 the cursor check of a saved cursor): exit 1 'not armed', registry and cursor byte-equal
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; pa_wc; rm -f "$PW/seats.tsv"
  pa_run WARROOM_DIR="$PW" "$PB/waiter.sh" W1 sid-w3a >/dev/null 2>&1 & _wp=$!; sleep 2; kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-w3a" 2>/dev/null; sleep 1
  [ -s "$PW/.cursor-W1" ] || { PA_WHY="W3: the first arm saved no cursor"; return 1; }
  _s0=$(cksum < "$PW/seats.tsv"); _c0=$(cksum < "$PW/.cursor-W1")
  for _c in 1 2; do
    pa_wcset $_c; pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-w3b$_c >/dev/null 2>"$PAW/e" & _wp=$!
    wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-w3b$_c" 2>/dev/null; pa_wcoff; PA_WHY="W3 (wc call $_c): the waiter armed although the count failed"; return 1; }; wait $_wp 2>/dev/null; _r=$?; pa_wcoff
    if [ $_c = 1 ]; then _want="could not count the lines of the board"; else _want="checksum the board"; fi
    { [ "$_r" = 1 ] && pa_wchit && grep -q "$_want" "$PAW/e" && grep -q "not armed" "$PAW/e"; } || { PA_WHY="W3 (wc call $_c): rc $_r, hit $(pa_wchit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
    { [ "$(cksum < "$PW/seats.tsv")" = "$_s0" ] && [ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ]; } || { PA_WHY="W3 (wc call $_c): the registry or the cursor changed"; return 1; }
  done
}
fx_w4() { # waiter poll: the line count fails on every poll while the fault stands: the waiter stays up, says so, consumes nothing, and delivers the line once the fault is gone
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; pa_wc; rm -f "$PW/seats.tsv"
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/waiter.sh" W1 sid-w4 > "$PAW/o" 2>"$PAW/e" & _wp=$!; sleep 2
  pa_wcset all; pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: w4 line" >/dev/null; sleep 3
  _alive=0; pkill -0 -f "waiter.sh W1 sid-w4" 2>/dev/null && _alive=1; pa_wcoff
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-w4" 2>/dev/null; PA_WHY="W4: the line was not delivered after the fault ended"; return 1; }; wait $_wp 2>/dev/null
  { [ $_alive = 1 ] && grep -q "could not count the lines of the board" "$PAW/e" && grep -q "nothing consumed" "$PAW/e" && grep -q "w4 line" "$PAW/o"; } || { PA_WHY="W4: alive $_alive, err '$(cat "$PAW/e")', out '$(cat "$PAW/o")'"; return 1; }
}
fx_w5() { # board.sh post: the line count of the text fails: exit 1, nothing posted (the 10-line limit is not skipped)
  pa_b2; pa_wc; _b0=$(cksum < "$PW/board.md"); pa_wcset all
  pa_run WARROOM_DIR="$PW" PATH="$PAW/shim:$PATH" "$PB/board.sh" post BOSS "w5 line" >/dev/null 2>"$PAW/e"; _r=$?; pa_wcoff
  { [ "$_r" = 1 ] && pa_wchit && grep -q "could not count the lines of the post" "$PAW/e" && [ "$(cksum < "$PW/board.md")" = "$_b0" ]; } || { PA_WHY="W5: rc $_r, hit $(pa_wchit && echo y || echo n), err '$(cat "$PAW/e")'"; return 1; }
}
pa_run_fx fx_w1 "wc: a failed line count in board.sh tail (its own, or inside the cursor check) prints nothing, exits 1 with that call's diagnostic, keeps the anchor"
pa_run_fx fx_w2 "wc: a failed line count in the prompt hook (its own, or inside the cursor check) shows no count and says which"
pa_run_fx fx_w3 "wc: a failed line count while arming (its own, or inside the cursor check) exits 1 'not armed', registry and cursor byte-equal"
pa_run_fx fx_w4 "wc: a failed line count in the waiter poll consumes nothing (stays up, says so) and the line is delivered when the fault ends"
pa_run_fx fx_w5 "wc: a failed line count of a post's text exits 1 and posts nothing"
pa_probe_bin() { # PBP := a copy of PB whose 4 delivery error branches first try an independent nonblocking flock on the cursor lock file and append free/HELD to $WR_PROBE (so the lock is checked BEFORE the diagnostic, not only after the process has exited). The probe is a python3 script that writes the file itself: a shell echo here would flush the text a failed builtin write left in the buffer into the probe file
  rm -rf "$PAW.pt"; mkdir -p "$PAW.pt" && cp -R "$PB" "$PAW.pt/bin" && cp -R "$PHK" "$PAW.pt/hooks" || return 1
  printf '%s\n' 'import fcntl, sys' 'f = open(sys.argv[1])' 'try:' '    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)' '    r = "free"' 'except OSError:' '    r = "HELD"' 'open(sys.argv[2], "a").write(r + "\n")' > "$PAW.pt/probe.py" || return 1
  python3 -I - "$PAW.pt/bin/waiter.sh" "$PAW.pt/probe.py" <<'PYE' || return 1
import re, sys
p = sys.argv[1]; s = open(p).read()
probe = 'python3 -I "%s" "$CUR.flock" "$WR_PROBE" 2>/dev/null; ' % sys.argv[2]
s, n = re.subn(r'echo "\[WAITER ERROR\] (?=could not write the |the lines were printed but not marked)', lambda m: probe + m.group(0), s)
if n != 4: sys.exit(1)
open(p, 'w').write(s)
PYE
  PBP="$PAW.pt/bin"; rm -f "$PAW/probe"
}
pa_probe_free() { [ "$(cat "$PAW/probe" 2>/dev/null)" = free ] || { PA_WHY="$1: the cursor lock was still held when the error was reported (probe says '$(cat "$PAW/probe" 2>/dev/null)', want exactly one 'free')"; return 1; }; }
fx_k1() { # delivery, the position cannot be saved (the 3rd temp of the run, the cursor, is unwritable): the header and the line are printed FIRST, exit 1 'printed but not marked', the cursor is as it was, and the fresh gap marker stays (nothing is unlinked)
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  [ "$(id -u)" != 0 ] || { PA_SKIP="running as root: mode 444 does not block root"; return 0; }
  pa_b2; rm -f "$PW/seats.tsv"; pa_probe_bin || { PA_WHY="K1: no probe copy"; return 1; }
  pa_run WARROOM_DIR="$PW" WR_PROBE="$PAW/probe" PATH="$SHRO:$PATH" "$PBP/waiter.sh" W1 sid-k > "$PAW/o" 2>"$PAW/e" & _wp=$!; sleep 2; _c0=$(cksum < "$PW/.cursor-W1"); rm -f "$PW/.lastwake-W1"
  ro_set "3 waiter.sh"; pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: k1 line" >/dev/null
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-k" 2>/dev/null; ro_clear; PA_WHY="K1: the waiter did not exit"; return 1; }; wait $_wp 2>/dev/null; _r=$?; _hit=n; ro_hit && _hit=y; ro_clear
  _hdr=$(grep -n '^\[WAKE' "$PAW/o" | head -1 | cut -d: -f1); _ln=$(grep -n 'k1 line' "$PAW/o" | head -1 | cut -d: -f1)
  { [ "$_r" = 1 ] && [ "$_hit" = y ] && [ -n "$_hdr" ] && [ -n "$_ln" ] && [ "$_hdr" -lt "$_ln" ] && grep -q "printed but not marked" "$PAW/e" && [ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ] && [ -e "$PW/.lastwake-W1" ]; } || { PA_WHY="K1: rc $_r, fault reached $_hit, header line '$_hdr', line '$_ln', err '$(tail -c 300 "$PAW/e")', cursor $([ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ] && echo kept || echo CHANGED), marker $([ -e "$PW/.lastwake-W1" ] && echo kept || echo GONE)"; return 1; }
  pa_probe_free K1
}
fx_k2() { # delivery, the header cannot be written (stdout closed): exit 1 naming the header (K2b: the header step ran, not only the payload step), nothing saved, the next arm delivers the line
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; rm -f "$PW/seats.tsv"; pa_probe_bin || { PA_WHY="K2: no probe copy"; return 1; }
  pa_run WARROOM_DIR="$PW" WR_PROBE="$PAW/probe" "$PBP/waiter.sh" W1 sid-k >&- 2>"$PAW/e" & _wp=$!; sleep 2; _c0=$(cksum < "$PW/.cursor-W1"); rm -f "$PW/.lastwake-W1"
  pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: k2 line" >/dev/null
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-k" 2>/dev/null; PA_WHY="K2: the waiter did not exit"; return 1; }; wait $_wp 2>/dev/null; _r=$?
  { [ "$_r" = 1 ] && grep -q "could not write the wake header" "$PAW/e" && [ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ] && [ ! -e "$PW/.lastwake-W1" ]; } || { PA_WHY="K2: rc $_r, err '$(cat "$PAW/e")', cursor $([ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ] && echo kept || echo CHANGED), marker $([ -e "$PW/.lastwake-W1" ] && echo WRITTEN || echo absent)"; return 1; }
  pa_probe_free K2 || return 1
  pa_run WARROOM_DIR="$PW" "$PB/waiter.sh" W1 sid-k2b > "$PAW/o2" 2>/dev/null & _wp=$!; sleep 3; kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-k2b" 2>/dev/null
  grep -q "k2 line" "$PAW/o2" || { PA_WHY="K2: the re-arm did not deliver the line again"; return 1; }
}
fx_k5() { # delivery, the reader closes after the header while the payload is larger than a pipe buffer: the write fails (trap '' PIPE, not death by SIGPIPE): exit 1 naming the lines, nothing saved
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; rm -f "$PW/seats.tsv"; _ff="$PAW/ff"; mkfifo "$_ff"; pa_probe_bin || { PA_WHY="K5: no probe copy"; return 1; }
  pa_run WARROOM_DIR="$PW" WR_PROBE="$PAW/probe" "$PBP/waiter.sh" W1 sid-k > "$_ff" 2>"$PAW/e" & _wp=$!
  ( IFS= read -r _h; sleep 1 ) < "$_ff" & _rp=$!; sleep 2; _c0=$(cksum < "$PW/.cursor-W1"); rm -f "$PW/.lastwake-W1"
  _pad=$(printf 'x%.0s' $(seq 1 3000)); for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do printf '[00:00 · BOSS] @W1 ACTION: k5 %s %s\n' "$_i" "$_pad"; done >> "$PW/board.md"
  wait_exit $_wp 12 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-k" 2>/dev/null; PA_WHY="K5: the waiter did not exit"; return 1; }; wait $_wp 2>/dev/null; _r=$?; wait $_rp 2>/dev/null
  { [ "$_r" = 1 ] && grep -q "could not write the lines" "$PAW/e" && [ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ] && [ ! -e "$PW/.lastwake-W1" ]; } || { PA_WHY="K5: rc $_r (141 = killed by SIGPIPE), err '$(cat "$PAW/e" | head -c 200)'"; return 1; }
  pa_probe_free K5
}
fx_k3() { # delivery, the gap marker cannot be written (a dangling link at the marker name): the header and the line are printed first, exit 1 'printed but not marked', the position is untouched, and the cursor lock is released before the diagnostic
  [ "$PS_OK" = 1 ] || { PA_SKIP="ps cannot read process start times here"; return 0; }
  pa_b2; rm -f "$PW/seats.tsv"; pa_probe_bin || { PA_WHY="K3: no probe copy"; return 1; }
  pa_run WARROOM_DIR="$PW" WR_PROBE="$PAW/probe" "$PBP/waiter.sh" W1 sid-k > "$PAW/o" 2>"$PAW/e" & _wp=$!; sleep 2; _c0=$(cksum < "$PW/.cursor-W1"); rm -f "$PW/.lastwake-W1"; ln -s "$PAW/no-such-dir/marker" "$PW/.lastwake-W1"
  pa_run WARROOM_DIR="$PW" "$PB/board.sh" post BOSS "@W1 ACTION: k3 line" >/dev/null
  wait_exit $_wp 8 || { kill $_wp 2>/dev/null; wait $_wp 2>/dev/null; pkill -f "waiter.sh W1 sid-k" 2>/dev/null; PA_WHY="K3: the waiter did not exit"; return 1; }; wait $_wp 2>/dev/null; _r=$?
  { [ "$_r" = 1 ] && grep -q '^\[WAKE' "$PAW/o" && grep -q "k3 line" "$PAW/o" && grep -q "printed but not marked" "$PAW/e" && grep -q "gap marker" "$PAW/e" && [ "$(cksum < "$PW/.cursor-W1")" = "$_c0" ]; } || { PA_WHY="K3: rc $_r, out '$(head -c 200 "$PAW/o")', err '$(head -c 300 "$PAW/e")'"; return 1; }
  pa_probe_free K3
}
pa_run_fx fx_k1 "delivery: the header and the lines are printed first; a position that cannot be saved exits 1 'printed but not marked', keeps the cursor and the fresh gap marker"
pa_run_fx fx_k2 "delivery: a header that cannot be written exits 1 naming the header, saves nothing, and the next arm delivers the line"
pa_run_fx fx_k3 "delivery: a gap marker that cannot be written exits 1 'printed but not marked' after the header and the line, keeps the position, and has released the cursor lock before it reports"
pa_run_fx fx_k5 "delivery: a closed reader during a large payload is a failed write (exit 1 naming the lines), not death by SIGPIPE; nothing saved"
# --- B mutants ---
if [ "$PS_OK" = 1 ]; then
pa_mcopy touchlast; pa_msed touchlast bin/waiter.sh 's|if ! wr_stamp "\$LAST"; then|if ! touch "$LAST"; then|'
[ "$(grep -c 'if ! touch "\$LAST"; then' "$MA/touchlast/bin/waiter.sh")" = 1 ] && [ "$(grep -c 'wr_stamp "\$LAST"' "$MA/touchlast/bin/waiter.sh")" = 0 ] && pa_mut touchlast fx_l1 || bad "mutant touchlast: the change was not applied"
pa_mcopy legacytemp; pa_msed legacytemp bin/_common.sh 's|^  _wr_tn=$(mktemp "$_wr_td/.wrtmp.XXXXXXXX" 2>/dev/null) \|\| return 1$|  _wr_tn="$1.tmp.$$"; : > "$_wr_tn" \|\| return 1|'
[ "$(grep -c '_wr_tn="\$1.tmp.\$\$"; : > "\$_wr_tn"' "$MA/legacytemp/bin/_common.sh")" = 1 ] && [ "$(grep -c 'mktemp "\$_wr_td' "$MA/legacytemp/bin/_common.sh")" = 0 ] && pa_mut legacytemp fx_l4 || bad "mutant legacytemp: the change was not applied"
pa_mcopy mvreplace; pa_msed mvreplace bin/_common.sh "s#^  _wr_re=\$(python3 -I -S -c 'import os,sys; os.replace(sys.argv\[1\], sys.argv\[2\])' \"\$_wr_rt\" \"\$_wr_rf\" 2>&1) \&\& return 0#  _wr_re=\$(mv -f -- \"\$_wr_rt\" \"\$_wr_rf\" 2>\&1) \&\& return 0#"
[ "$(grep -c '_wr_re=$(mv -f -- ' "$MA/mvreplace/bin/_common.sh")" = 1 ] && [ "$(grep -c 'os.replace(sys.argv' "$MA/mvreplace/bin/_common.sh")" = 0 ] && pa_mut mvreplace fx_l3 || bad "mutant mvreplace: the change was not applied"
else echo "skip mutants touchlast, legacytemp, mvreplace (ps cannot read process start times here, so a waiter cannot arm)"; fi
pa_mcopy oldrollback; pa_msed oldrollback hooks/board-guard.sh 's|^      wr_temp "\$mark" \|\| { wr_unlock "\$mark"; echo "board-guard: the post for|      if [ "$prev" = "-" ]; then rm -f "$mark"; wr_unlock "$mark"; return 1; fi; wr_temp "$mark" \|\| { wr_unlock "$mark"; echo "board-guard: the post for|'
[ "$(grep -c 'if \[ "\$prev" = "-" \]; then rm -f "\$mark"' "$MA/oldrollback/hooks/board-guard.sh")" = 1 ] && pa_mut oldrollback fx_g1 || bad "mutant oldrollback: the change was not applied"
pa_mcopy restorerm; pa_msed restorerm hooks/board-guard.sh 's|^      wr_replace "\$mark_t" "\$mark" \|\| { wr_drop "\$mark_t"; wr_unlock "\$mark"; echo "board-guard: the post for|      wr_replace "$mark_t" "$mark" \|\| { rm -f "$mark"; wr_drop "$mark_t"; wr_unlock "$mark"; echo "board-guard: the post for|'
[ "$(grep -c 'rm -f "\$mark"; wr_drop' "$MA/restorerm/hooks/board-guard.sh")" = 1 ] && pa_mut restorerm fx_g2 || bad "mutant restorerm: the change was not applied"
if [ "$PS_OK" = 1 ]; then
pa_mcopy nofiltercheck; pa_msed nofiltercheck bin/waiter.sh 's|new=$(filter < "$chunk_t") \|\||new=$(filter < "$chunk_t" \|\| true) \|\||'
[ "$(grep -c 'filter < "\$chunk_t" || true' "$MA/nofiltercheck/bin/waiter.sh")" = 1 ] && pa_mut nofiltercheck fx_k11 || bad "mutant nofiltercheck: the change was not applied"
else echo "skip mutant nofiltercheck (ps cannot read process start times here, so a waiter cannot arm)"; fi

pa_mcopy c1len; pa_msed c1len bin/_cursor.sh 's/^  \[ "\${#1}" -le 15 \]$/  true/'
[ "$(grep -c '^  true$' "$MA/c1len/bin/_cursor.sh")" = 1 ] && pa_mut c1len fx_c1 || bad "mutant c1len: the change was not applied"
pa_mcopy c1fut; pa_msed c1fut bin/_cursor.sh '/more than a day ahead of the clock" >&2; return 1; }$/d'
[ "$(grep -c 'more than a day ahead of the clock" >&2' "$MA/c1fut/bin/_cursor.sh")" = 0 ] && pa_mut c1fut fx_c1 || bad "mutant c1fut: the change was not applied"
pa_mcopy c1abs; pa_msed c1abs bin/_common.sh 's/^  if \[ "\$_wa" = dir \]; then echo yes; else echo no; fi$/  echo yes/'
[ "$(grep -c '^  echo yes$' "$MA/c1abs/bin/_common.sh")" = 1 ] && pa_mut c1abs fx_c1 || bad "mutant c1abs: the change was not applied"
pa_mcopy t1kill; pa_msed t1kill bin/_common.sh 's/^    except OSError: return "unknown"$/    except OSError: return "dead"/'
[ "$(grep -c '^    except OSError: return "dead"$' "$MA/t1kill/bin/_common.sh")" = 1 ] && pa_mut t1kill fx_t1 || bad "mutant t1kill: the change was not applied"
pa_mcopy t1pipe; pa_msed t1pipe bin/_common.sh 's/^  _wr_st=\$( set -o pipefail; /  _wr_st=$( /'
[ "$(grep -c 'set -o pipefail; { ps -o lstart=' "$MA/t1pipe/bin/_common.sh")" = 0 ] && pa_mut t1pipe fx_t1 || bad "mutant t1pipe: the change was not applied"
if [ "$PS_OK" = 1 ]; then
pa_mcopy m1poll; pa_msed m1poll bin/waiter.sh 's/^  mine || { echo "\[WAITER\] the seat registry .*$/  mine || replaced/'
[ "$(grep -c '^  mine || replaced$' "$MA/m1poll/bin/waiter.sh")" = 1 ] && pa_mut m1poll fx_m1 || bad "mutant m1poll: the change was not applied"
pa_mcopy m1lock; pa_msed m1lock bin/waiter.sh 's/^  mine || { wr_unlock "\$CUR"; echo "\[WAITER\] the seat registry .*$/  mine || { wr_unlock "$CUR"; replaced; }/'
[ "$(grep -c '^  mine || { wr_unlock "\$CUR"; replaced; }$' "$MA/m1lock/bin/waiter.sh")" = 1 ] && pa_mut m1lock fx_m1 || bad "mutant m1lock: the change was not applied"
else echo "skip mutants m1poll and m1lock (ps cannot read process start times here, so a waiter cannot arm)"; fi
pa_mcopy gledger; pa_msed gledger hooks/board-guard.sh 's/^    || { echo "board-guard: skipped \$seat (cannot read the job ledger.*$/    || true/'
[ "$(grep -c 'cannot read the job ledger' "$MA/gledger/hooks/board-guard.sh")" = 0 ] && pa_mut gledger fx_gr1 || bad "mutant gledger: the change was not applied"
pa_mcopy gboard; pa_msed gboard hooks/board-guard.sh 's/^    || { echo "board-guard: skipped \$seat (could not read the board), will retry on the next prompt" >&2; return 1; }$/    || true/'
[ "$(grep -c '^    || true$' "$MA/gboard/hooks/board-guard.sh")" = 1 ] && pa_mut gboard fx_gr1 || bad "mutant gboard: the change was not applied"
pa_mcopy gmark; pa_msed gmark hooks/board-guard.sh 's/^    if \[ "\$prev" != "-" \] \&\& ! \[\[ \$prev =~ \$mre \]\]; then$/    if false; then/'
[ "$(grep -c '^    if false; then$' "$MA/gmark/hooks/board-guard.sh")" = 1 ] && pa_mut gmark fx_gr1 || bad "mutant gmark: the change was not applied"
pa_mcopy gstamp; pa_msed gstamp hooks/board-guard.sh '/^  wr_hhmm "\$hm" || /d'
[ "$(grep -c 'its last post is stamped' "$MA/gstamp/hooks/board-guard.sh")" = 0 ] && pa_mut gstamp fx_gr1 || bad "mutant gstamp: the change was not applied"
pa_mcopy gclock; pa_msed gclock hooks/board-guard.sh '/^wr_hhmm "\$now" || /d'
[ "$(grep -c "not HH:MM" "$MA/gclock/hooks/board-guard.sh")" = 0 ] && pa_mut gclock fx_gr1 || bad "mutant gclock: the change was not applied"
pa_mcopy kboard; pa_msed kboard bin/board.sh '/^    wr_hhmm "\$stamp" || /d'
[ "$(grep -c 'wr_hhmm "\$stamp"' "$MA/kboard/bin/board.sh")" = 0 ] && pa_mut kboard fx_ck1 || bad "mutant kboard: the change was not applied"
pa_mcopy kepoch; pa_msed kepoch bin/_common.sh 's/^wr_epoch() { .*$/wr_epoch() { date +%s; }/'
[ "$(grep -c '^wr_epoch() { date +%s; }$' "$MA/kepoch/bin/_common.sh")" = 1 ] && pa_mut kepoch fx_ck1 || bad "mutant kepoch: the change was not applied"
if [ "$PS_OK" = 1 ]; then
pa_mcopy karm; pa_msed karm bin/waiter.sh '/^wr_hhmm "\$_at" || /d'
[ "$(grep -c 'wr_hhmm "\$_at"' "$MA/karm/bin/waiter.sh")" = 0 ] && pa_mut karm fx_ck1 || bad "mutant karm: the change was not applied"
pa_mcopy kgap; pa_msed kgap bin/waiter.sh 's/^  _gn=\$(wr_epoch) || return 1$/  _gn=$(wr_epoch) || _gn=0/'
[ "$(grep -c '^  _gn=\$(wr_epoch) || _gn=0$' "$MA/kgap/bin/waiter.sh")" = 1 ] && pa_mut kgap fx_ck1 || bad "mutant kgap: the change was not applied"
pa_mcopy stfall; pa_msed stfall bin/_common.sh 's/\(_sn=\$(stat [^)]*)\) || return 1/\1 || _sn=1/'
[ "$(grep -c '|| _sn=1' "$MA/stfall/bin/_common.sh")" = 2 ] && pa_mut stfall fx_st1 || bad "mutant stfall: the change was not applied"
pa_mcopy stcase; pa_msed stcase bin/_common.sh "s/^  case \"\$_sn\" in ''|0\*|/  case \"\$_sn\" in ''|/"
[ "$(grep -c "case \"\$_sn\" in ''|\*\[!0-9\]\*) return 1" "$MA/stcase/bin/_common.sh")" = 1 ] && pa_mut stcase fx_st1 || bad "mutant stcase: the change was not applied"
pa_mcopy stgen; pa_msed stgen bin/_cursor.sh 's/_gi=\$(wr_inode "\$1") || return 1; /_gi=$(wr_inode "$1"); /'
[ "$(grep -c '_gi=\$(wr_inode "\$1"); _gs=' "$MA/stgen/bin/_cursor.sh")" = 1 ] && pa_mut stgen fx_st1 || bad "mutant stgen: the change was not applied"
pa_mcopy epslash; pa_msed epslash bin/board.sh 's|\*) _d=\. ;; esac|*) _d=/nonexistent ;; esac|'
[ "$(grep -c '_d=/nonexistent ;; esac' "$MA/epslash/bin/board.sh")" = 1 ] && pa_mut epslash fx_ep1 || bad "mutant epslash: the change was not applied"
pa_mcopy smpart; pa_msed smpart bin/_cursor.sh 's/^wr_sum() {.*$/wr_sum() { ( set -o pipefail; cksum | cut -d" " -f1 ); }/'
[ "$(grep -c '^wr_sum() { ( set -o pipefail; cksum | cut -d" " -f1 ); }$' "$MA/smpart/bin/_cursor.sh")" = 1 ] && pa_mut smpart fx_sm1 || bad "mutant smpart: the change was not applied"
pa_mcopy lgread; pa_msed lgread bin/pids.sh 's/^\(    rows=\$(wr_registry_read "\$P")\) || {.*$/\1/'
[ "$(grep -c '^    rows=\$(wr_registry_read "\$P")$' "$MA/lgread/bin/pids.sh")" = 1 ] && pa_mut lgread fx_lg1 || bad "mutant lgread: the change was not applied"
pa_mcopy rgwait; pa_msed rgwait hooks/waiter-check.sh 's/^\(rows=\$(wr_registry_read "\$REG")\) || {.*$/\1/'
[ "$(grep -c '^rows=\$(wr_registry_read "\$REG")$' "$MA/rgwait/hooks/waiter-check.sh")" = 1 ] && pa_mut rgwait fx_rg1 || bad "mutant rgwait: the change was not applied"
pa_mcopy rgtail; pa_msed rgtail hooks/board-tail.sh 's/^\(rows=\$(wr_registry_read "\$W\/seats.tsv")\) || {.*$/\1/'
[ "$(grep -c '^rows=\$(wr_registry_read "\$W/seats.tsv")$' "$MA/rgtail/hooks/board-tail.sh")" = 1 ] && pa_mut rgtail fx_rg1 || bad "mutant rgtail: the change was not applied"
pa_mcopy abreg; pa_msed abreg bin/_common.sh 's/^  if \[ "\$_wr_ab" = yes \]; then return 0; fi$/  if [ "$_wr_ab" = yes ]; then return 1; fi/'
[ "$(grep -c '^  if \[ "\$_wr_ab" = yes \]; then return 1; fi$' "$MA/abreg/bin/_common.sh")" = 1 ] && pa_mut abreg fx_ab1 || bad "mutant abreg: the change was not applied"
else echo "skip mutants karm and kgap (ps cannot read process start times here, so a waiter cannot arm)"; fi
# --- F9 / F1 mutants: one change each, the diagnostic or the state check of its fixture fails ---
pa_mcopy f9tail; pa_msed f9tail bin/board.sh 's/^\(    last=\$(wr_cursor_get [^)]*)\) || {.*$/\1 || true/'
[ "$(grep -c 'wr_cursor_get .*|| true$' "$MA/f9tail/bin/board.sh")" = 1 ] && pa_mut f9tail fx_f9a || bad "mutant f9tail: the change was not applied"
pa_mcopy f9prefix; pa_msed f9prefix bin/_cursor.sh 's/\(_cs=\$(wr_prefixsum "\$2" "\$_l")\) || return 1/\1/'
[ "$(grep -c '_cs=\$(wr_prefixsum "\$2" "\$_l") ;;' "$MA/f9prefix/bin/_cursor.sh")" = 1 ] && pa_mut f9prefix fx_f9a || bad "mutant f9prefix: the change was not applied"
pa_mcopy f9line; pa_msed f9line bin/_cursor.sh 's/\(_cs=\$(wr_linesum "\$2" "\$_l")\) || return 1/\1/'
[ "$(grep -c '_cs=\$(wr_linesum "\$2" "\$_l") ;;' "$MA/f9line/bin/_cursor.sh")" = 1 ] && pa_mut f9line fx_f9b || bad "mutant f9line: the change was not applied"
pa_mcopy f9gen; pa_msed f9gen bin/_cursor.sh 's/\(_cg=\$(wr_generation "\$2")\) || return 1/\1/'
[ "$(grep -c '^  _cg=\$(wr_generation "\$2")$' "$MA/f9gen/bin/_cursor.sh")" = 1 ] && pa_mut f9gen fx_f9c || bad "mutant f9gen: the change was not applied"
pa_mcopy f9hook; pa_msed f9hook hooks/board-tail.sh 's/^\(last=\$(wr_cursor_get [^)]*)\) || {.*$/\1 || true/'
[ "$(grep -c 'wr_cursor_get .*|| true$' "$MA/f9hook/hooks/board-tail.sh")" = 1 ] && pa_mut f9hook fx_f9c || bad "mutant f9hook: the change was not applied"
pa_mcopy f9guard; pa_msed f9guard hooks/board-guard.sh 's/^\(  lsum=.*wr_sum )\) || {.*$/\1 || true/'
[ "$(grep -c '^  lsum=.*wr_sum ) || true$' "$MA/f9guard/hooks/board-guard.sh")" = 1 ] && pa_mut f9guard fx_f9e || bad "mutant f9guard: the change was not applied"
pa_mcopy f1tailgen; pa_msed f1tailgen bin/board.sh 's/^\(    g=\$(wr_generation "\$BOARD_FILE")\) || {.*$/\1 || true/'
[ "$(grep -c '^    g=\$(wr_generation "\$BOARD_FILE") || true$' "$MA/f1tailgen/bin/board.sh")" = 1 ] && pa_mut f1tailgen fx_f1c || bad "mutant f1tailgen: the change was not applied"
if [ "$PS_OK" = 1 ]; then
pa_mcopy f9arm; pa_msed f9arm bin/waiter.sh 's/^\(  c=\$(wr_cursor_get [^)]*)\) || {.*$/\1/'
[ "$(grep -c '^  c=\$(wr_cursor_get "\$CUR" "\$BOARD_FILE" "\$AGE")$' "$MA/f9arm/bin/waiter.sh")" = 1 ] && pa_mut f9arm fx_f9d || bad "mutant f9arm: the change was not applied"
pa_mcopy f1reg; pa_msed f1reg bin/waiter.sh 's/^\(  awk -F.*> "\$reg_t"\) || {.*$/\1 || true/'
[ "$(grep -c 'could not write the seat registry' "$MA/f1reg/bin/waiter.sh")" = 0 ] && pa_mut f1reg fx_f1a || bad "mutant f1reg: the change was not applied"
pa_mcopy f1arm; pa_msed f1arm bin/waiter.sh 's/^\(  lastck=.*\) || {.*$/\1/'
[ "$(grep -c '^  lastck=.*||' "$MA/f1arm/bin/waiter.sh")" = 0 ] && [ "$(grep -c '^  lastck=' "$MA/f1arm/bin/waiter.sh")" = 1 ] && pa_mut f1arm fx_f1b || bad "mutant f1arm: the change was not applied"
else echo "skip mutants f9arm, f1reg, f1arm (ps cannot read process start times here, so a waiter cannot arm)"; fi

# --- line-count mutants ---
pa_mcopy wcursor; pa_msed wcursor bin/_cursor.sh 's/\(_n=\$(wr_lines "\$2")\) || return 1/\1/'
[ "$(grep -c '^    _n=\$(wr_lines "\$2")$' "$MA/wcursor/bin/_cursor.sh")" = 1 ] && pa_mut wcursor fx_w1 || bad "mutant wcursor: the change was not applied"
pa_mcopy wtail; pa_msed wtail bin/board.sh 's/^\(    n=\$(wr_lines "\$BOARD_FILE")\) || {.*$/\1 || true/'
[ "$(grep -c '^    n=\$(wr_lines "\$BOARD_FILE") || true$' "$MA/wtail/bin/board.sh")" = 1 ] && pa_mut wtail fx_w1 || bad "mutant wtail: the change was not applied"
pa_mcopy whook; pa_msed whook hooks/board-tail.sh 's/^\(n=\$(wr_lines "\$BOARD_FILE")\) || {.*$/\1 || true/'
[ "$(grep -c '^n=\$(wr_lines "\$BOARD_FILE") || true$' "$MA/whook/hooks/board-tail.sh")" = 1 ] && pa_mut whook fx_w2 || bad "mutant whook: the change was not applied"
pa_mcopy wpost; pa_msed wpost bin/board.sh 's/^\(    n=\$(printf .%s\\n. "\$text" | wr_lines \/dev\/stdin)\) || {.*$/\1 || true/'
[ "$(grep -c 'wr_lines /dev/stdin) || true$' "$MA/wpost/bin/board.sh")" = 1 ] && pa_mut wpost fx_w5 || bad "mutant wpost: the change was not applied"
if [ "$PS_OK" = 1 ]; then
pa_mcopy warm; pa_msed warm bin/waiter.sh 's/^\(  base=\$(wr_lines "\$BOARD_FILE")\) || {.*$/\1/'
[ "$(grep -c '^  base=\$(wr_lines "\$BOARD_FILE")$' "$MA/warm/bin/waiter.sh")" = 1 ] && pa_mut warm fx_w3 || bad "mutant warm: the change was not applied"
pa_mcopy wpoll; pa_msed wpoll bin/waiter.sh 's/^\(  n=\$(wr_lines "\$BOARD_FILE")\) || {.*$/\1 || true/'
[ "$(grep -c '^  n=\$(wr_lines "\$BOARD_FILE") || true$' "$MA/wpoll/bin/waiter.sh")" = 1 ] && pa_mut wpoll fx_w4 || bad "mutant wpoll: the change was not applied"
else echo "skip mutants warm, wpoll (ps cannot read process start times here, so a waiter cannot arm)"; fi

# --- delivery-order mutants ---
if [ "$PS_OK" = 1 ]; then
pa_mcopy krm; pa_msed krm bin/waiter.sh 's|if ! wr_cursor_put "\$CUR" "\$gen" "\$base" "\$lastck"; then|if ! wr_cursor_put "$CUR" "$gen" "$base" "$lastck"; then rm -f "$LAST";|'
[ "$(grep -c 'then rm -f "\$LAST";' "$MA/krm/bin/waiter.sh")" = 1 ] && pa_mut krm fx_k1 || bad "mutant krm: the change was not applied"
# F3 root control (id double): K1's own root skip reaches pa_mut as a skip, counted as neither ok nor FAIL
mkdir -p "$T/idroot" && printf '%s\n' '#!/bin/sh' '[ "$1" = -u ] && { echo 0; exit 0; }' 'exec /usr/bin/id "$@"' > "$T/idroot/id" && chmod +x "$T/idroot/id"
_f0=$fail; _p0=$PATH; PATH="$T/idroot:$PATH"; pa_mut krm fx_k1 > "$T/skiproot.out" 2>&1; PATH=$_p0
[ "$fail" = "$_f0" ] && grep -q '^skip mutant krm (running as root: mode 444 does not block root)$' "$T/skiproot.out" && [ "$(grep -Ec '^(ok|FAIL) ' "$T/skiproot.out")" = 0 ] && ok "mutants: K1 under an id double that reports root skips; pa_mut prints the skip and counts neither ok nor FAIL" || bad "mutants: K1 root-skip control: $(cat "$T/skiproot.out")"
pa_mcopy khdr; pa_msed khdr bin/waiter.sh 's|^  if ! echo \(".*"\); then$|  echo \1; if false; then|'
[ "$(grep -c 'if false; then$' "$MA/khdr/bin/waiter.sh")" = 1 ] && pa_mut khdr fx_k2 || bad "mutant khdr: the change was not applied"
pa_mcopy knotrap; pa_msed knotrap bin/waiter.sh "s|^trap '' PIPE.*\$|:|"
[ "$(grep -c "^trap '' PIPE" "$MA/knotrap/bin/waiter.sh")" = 0 ] && pa_mut knotrap fx_k5 || bad "mutant knotrap: the change was not applied"
pa_mcopy knounlock; pa_msed knounlock bin/waiter.sh 's|wr_unlock "\$CUR"; echo "\[WAITER ERROR\]|echo "[WAITER ERROR]|'
[ "$(grep -c 'wr_unlock "\$CUR"; echo "\[WAITER ERROR\]' "$MA/knounlock/bin/waiter.sh")" = 0 ] && for _kf in fx_k1 fx_k2 fx_k3 fx_k5; do pa_mut knounlock $_kf; done || bad "mutant knounlock: the change was not applied"
else echo "skip mutants krm, khdr, knotrap, knounlock (ps cannot read process start times here, so a waiter cannot arm)"; fi
# a fixture that skips (root, no ps) makes pa_mut print a skip and count nothing: no ok, no FAIL
fx_skipctl() { PA_SKIP="control: this fixture always skips"; return 0; }
_f0=$fail; pa_mut skipctl fx_skipctl > "$T/skipctl.out" 2>&1
[ "$fail" = "$_f0" ] && grep -q '^skip mutant skipctl (control: this fixture always skips)$' "$T/skipctl.out" && [ "$(grep -Ec '^(ok|FAIL) ' "$T/skipctl.out")" = 0 ] && ok "mutants: a skipped fixture makes pa_mut print a skip and count neither ok nor FAIL" || bad "mutants: pa_mut on a skipped fixture: $(cat "$T/skipctl.out")"
# 60. read gate, report mode (enforcing after the repairs). The block must fail when the gate cannot run or runs as an empty
# no-op: each stage has to print its own summary line, the inventory has to cover every script in bin/ and hooks/, and a missing
# python3 is a failure, not a skip.
rg_stage() {    # $1 gate script, $2 tree root; prints one "ok" or "FAIL" line per stage
  local gate=$1 root=$2 out rc want
  if ! command -v python3 >/dev/null 2>&1; then bad "read gate needs python3 and it is not on PATH"; return; fi
  out=$(python3 -I "$gate" --self-test 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | head -1 | grep -Eq '^read-gate self-test: [1-9][0-9]* checks passed, 0 failed \([1-9][0-9]* fixtures, [1-9][0-9]* trees, [1-9][0-9]* mutants, [1-9][0-9]* code mutants\)$'; then
    ok "read gate self-test: $(printf '%s\n' "$out" | head -1)"
  else
    bad "read gate self-test (rc $rc, no summary line?): $(printf '%s\n' "$out" | head -8)"
  fi
  # every file under bin/ and hooks/, found without the gate's own glob: a script the gate does not read (no .sh, a subfolder, a link)
  # makes the counts differ, and the inventory stage fails
  want=$(find "$root/bin" "$root/hooks" \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
  out=$(python3 -I "$gate" --root "$root" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ "$want" != 0 ] && printf '%s\n' "$out" | head -1 | grep -Eq "^read-gate \(report mode\): files=$want occurrences=[1-9][0-9]* "; then
    ok "read gate inventory (report only): $(printf '%s\n' "$out" | head -1)"
    printf '%s\n' "$out" | sed -n '2,$p' | sed 's/^/     /'
  else
    bad "read gate inventory (rc $rc, want files=$want): $(printf '%s\n' "$out" | head -8)"
  fi
}
rg_stage "$ROOT/tests/read-gate.py" "$ROOT"
# the block itself: an empty no-op gate and a missing python3 must both fail it, and with the summary checks taken out the no-op passes
RG_T=$(mktemp -d) || exit 1
printf 'pass\n' > "$RG_T/noop.py"
RG_TOOLS="$RG_T/tools"; mkdir "$RG_TOOLS"
for RG_X in grep ls wc head tr sed; do ln -s "$(command -v "$RG_X")" "$RG_TOOLS/$RG_X"; done
RG_NOOP=$( (rg_stage "$RG_T/noop.py" "$ROOT") 2>&1 )
if printf '%s\n' "$RG_NOOP" | grep -q '^FAIL read gate self-test' && printf '%s\n' "$RG_NOOP" | grep -q '^FAIL read gate inventory' && ! printf '%s\n' "$RG_NOOP" | grep -q '^ok '; then
  ok "read gate block: an empty no-op gate fails both stages"
else
  bad "read gate block accepts an empty no-op gate: $RG_NOOP"
fi
RG_NOPY=$( (PATH="$RG_TOOLS"; rg_stage "$ROOT/tests/read-gate.py" "$ROOT") 2>&1 )
if printf '%s\n' "$RG_NOPY" | grep -q '^FAIL read gate needs python3' && ! printf '%s\n' "$RG_NOPY" | grep -q '^ok '; then
  ok "read gate block: a missing python3 is a failure, not a skip"
else
  bad "read gate block passes without python3: $RG_NOPY"
fi
declare -f rg_stage | sed 's/ && printf .*; then$/; then/' > "$RG_T/mutant.sh"
RG_MUT=$( (. "$RG_T/mutant.sh"; rg_stage "$RG_T/noop.py" "$ROOT") 2>&1 )
if printf '%s\n' "$RG_MUT" | grep -q '^FAIL'; then bad "read gate block: the summary checks are not pinned (the mutant still fails): $RG_MUT"; else ok "read gate block: with the summary checks removed an empty no-op passes (so the checks are what stops it)"; fi
rm -rf "$RG_T"

[ $fail = 0 ] && echo "smoke: all passed" || echo "smoke: FAILED"
exit $fail
