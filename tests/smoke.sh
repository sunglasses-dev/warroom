#!/usr/bin/env bash
# tests/smoke.sh — end-to-end check on a throwaway board. Runs in CI and on your machine; touches nothing outside a temp dir.
#   1. a plain mention does not wake a seat; an "@SEAT ACTION:" line does, within a few seconds
#   2. a second waiter on a seat that is already held is refused
#   3. a registered job that dies wakes its owner once, and its row is dropped, also when several seats check at once
#   4. the idle guard names a silent seat once per silence, not once per prompt
#   6. a reopen request wakes the other seats; reopen.sh status exits 0 while they bank
#   7. wake grammar: only a first line "@SEAT ACTION:" from another author wakes (not prose, ACTIONABLE, a second line, the seat's own post)
#   8. a replaced board of the same length is read again from its start; a waiter missing its session id is refused
#   9. two arms of one seat at the same moment: exactly one wins, every round
#  10. a board that cannot be written makes post fail; a job's row is kept until its wake is on the board
#  11. the writer lock: one holder per file (also through aliases, which are refused), a crash releases it, wr_run children
#      hold no copy, subshell use is refused, every failure is visible, a board named like the waiter's marker survives
#  12. the job ledger: concurrent add of one label gives one row; a reused pid (wrong start time) counts as gone
#  13. pr-watch (gh stubbed): only `gh pr view` is ever called, a green needs every row green, and the receipt holds the response that produced it
#  14-16. warroom.env is data: command text refused, the current folder ignored, shell and cpu-sentinel.py agree
#  17. docs/INSTALL.md: its hook block is valid JSON with the four entries, the quoted path works with a space in the clone path,
#      the parse command in the page accepts a good file and refuses a bad one, the page stays short
#  18-20. (unused numbers: the installer was removed)
#  21. every hook with a bad warroom.env exits 1 (shown, prompt goes through), never 2 (Claude Code blocks the prompt)
#  25. a key set twice in warroom.env is refused by the shell scripts and by cpu-sentinel.py alike
#  27-32. second review (waiter, cursor, guard, reopen): shared opt-out rows, one wake when a waiter is replaced, a board refilled in
#         place, the guard's job identity and its mark across board generations, reopen READY only with cards, quoted commands
#  33. a missing board is created without truncating (parallel first posts all survive); an uncreatable board is an error
#  34. a ledger write that fails leaves the ledger as it was and exits non-zero
#  35. pids.sh add refuses pid 0 and a pid whose start time cannot be read
#  36. cpu-sentinel reads the four-column ledger (job policy, owner alerted once); a row with a reused pid is ignored
#  37. cpu-sentinel --dry-run changes nothing; a failed alert post is retried until it lands, then not repeated
#  38. pr-watch: an option without a value exits 2 (no spin)
#  39. leak-check: a bad denylist pattern or an unreadable file is an error (exit 2), run-state files in the tree are a hit
#  40. process identity: ps failing is "unknown" (row kept, seat not taken, guard silent, hook says so), never "dead"; a
#      reused pid holds no seat and inherits no sentinel strikes or opt-out; a failed sentinel sample keeps its state
#  41-43. position integrity (a rewrite anywhere in the part already read is noticed), every state write checked (fault
#         injection with a stub mv), the board bootstrap under a forced race (with a wrong-code control)
#  44. the sample board, replayed through real waiters, wakes W1, W2 and BOSS by exactly their own handoffs
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

# 13. pr-watch (gh stubbed, no network): it only reads, reports an observation, and a green needs every row green
SD="$T/stub"; mkdir -p "$SD"; export GH_STUB_DIR="$SD"; SHA=$(printf 'a%.0s' $(seq 1 40))
cat > "$SD/gh" <<'STUB'
#!/usr/bin/env bash
# logs every call; the Nth `pr view` serves resp.N (the last file repeats); resp.fail.N makes that call fail
d=$GH_STUB_DIR; echo "$*" >> "$d/calls.log"
case "$1 $2" in
  "pr view")
    n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
    [ -e "$d/resp.fail.$n" ] && exit 1
    if [ -e "$d/fault.$n" ]; then for t in "$TMPDIR"/pr-watch.*/; do for f in cur.body prev.body cur.new prev.new; do rm -f "$t$f"; ln -s /nonexistent/pr-watch-fault "$t$f"; done; done; fi
    f="$d/resp.$n"; [ -e "$f" ] || f=$(ls "$d"/resp.[0-9]* | sort -t. -k2 -n | tail -1)
    cat "$f" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$SD/gh"
mkr() { # mkr STATE HEAD REPO BASE ROW...   row = run:NAME:STATUS:CONCLUSION[:WORKFLOW] | ctx:NAME:STATE | ROWS=null
  python3 - "$@" <<'PY'
import json, sys
state, head, repo, base = sys.argv[1:5]; rows = []; nullrows = False
for r in sys.argv[5:]:
    p = r.split(":")
    if r == "ROWS=null": nullrows = True
    elif p[0] == "run":
        c = {"__typename": "CheckRun", "name": p[1], "status": p[2], "conclusion": p[3] or None}
        if len(p) > 4: c["workflowName"] = p[4]
        rows.append(c)
    else: rows.append({"__typename": "StatusContext", "context": p[1], "state": p[2]})
d = {"state": state or None, "headRefOid": head, "baseRefName": base, "url": "https://github.com/%s/pull/7" % repo, "statusCheckRollup": None if nullrows else rows}
print(json.dumps({k: v for k, v in d.items() if v is not None or k == "statusCheckRollup"}))
PY
}
BD="$("$B/board.sh" path)"
# runw RESP... -- [pr-watch args]: serve the responses in order, run pr-watch, leave the new board lines in $NEW and rc in $rc
# The wait is RUNW_TIMEOUT whole seconds (default 3). pr-watch.sh sets its deadline from a whole-second clock read, so a
# timeout of 1 can end the run when the first look merely crosses a second boundary, before the second look is made;
# cases that need a second look (pending, then something else) therefore keep the default, and stops() sets 1.
runw() { rm -f "$SD"/resp.* "$SD/count" "$SD/calls.log"; i=1
  while [ "${1:-}" != "--" ]; do printf '%s\n' "$1" > "$SD/resp.$i"; i=$((i+1)); shift; done; shift
  n0=$(wc -l < "$BD" | tr -d ' '); PATH="$SD:$PATH" "$B/pr-watch.sh" 7 --head "$SHA" --poll 1 --timeout "${RUNW_TIMEOUT:-3}" "$@" >/dev/null 2>&1; rc=$?
  NEW=$(tail -n +$((n0+1)) "$BD"); touch "$SD/calls.log"
  [ -z "$(grep -v '^pr view ' "$SD/calls.log")" ] || NOMUT=bad; }
NOMUT=ok
G=$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS:ci)
stops() { # stops "name" RESP... -- args: the run must end with exit 1, one WATCH FAIL line and no WATCH GREEN
  nm=$1; shift; RUNW_TIMEOUT=1 runw "$@"
  if [ $rc = 1 ] && echo "$NEW" | grep -q 'WATCH FAIL' && ! echo "$NEW" | grep -q 'WATCH GREEN'; then ok "pr-watch stops: $nm"; else bad "pr-watch did not stop: $nm (rc $rc: $NEW)"; fi; }
# green: exit 0, exactly one WATCH GREEN line, no WATCH FAIL; a check named PASS or guarantee must not trip the wording test
runw "$(mkr OPEN "$SHA" o/r main run:PASS:COMPLETED:SUCCESS:ci run:guarantee:COMPLETED:NEUTRAL ctx:legacy:SUCCESS)" -- --require PASS
LINE=$(echo "$NEW" | grep 'WATCH GREEN'); REC=$(ls -t "$WARROOM_DIR"/receipts/watch_7_*.md | head -1)
if [ $rc = 0 ] && [ "$(echo "$NEW" | grep -c 'WATCH GREEN')" = 1 ] && ! echo "$NEW" | grep -q 'WATCH FAIL'; then ok "pr-watch: a green response gives exit 0 and exactly one WATCH GREEN line"; else bad "pr-watch green (rc $rc: $NEW)"; fi
case "$LINE" in *"observed, not a gate; this tool did not merge or modify the PR"*"$REC)") ok "pr-watch: the green line says observed, not a gate, and ends with the receipt path" ;; *) bad "pr-watch green line: $LINE" ;; esac
grep -q 'observed, not a gate' "$REC" && grep -q 'This tool did not merge or modify the PR' "$REC" && ok "pr-watch: the receipt says observed, not a gate, and that it did not merge" || bad "pr-watch receipt wording"
grep -q '  - legacy · SUCCESS · not reported' "$REC" && ok "pr-watch: a check with no workflow is written 'not reported' and is still green" || bad "pr-watch: missing workflow field"
FIXED=$( { echo "$LINE" | sed 's/(receipt .*//'; grep -v '^  - \|required names' "$REC"; "$B/pr-watch.sh" --help; } | sed 's/not a guarantee//g; s/not a gate//g; s/did not merge//g; s/never merges//g')
echo "$FIXED" | grep -Eqi 'POSTCONDITION|PASS|safe to merge|guarantee|merge is safe' && bad "pr-watch wording claims a merge or a gate: $(echo "$FIXED" | grep -Ei 'POSTCONDITION|PASS|safe to merge|guarantee|merge is safe' | head -2)" || ok "pr-watch: no template claims a merge, a safe merge or a gate"
"$B/pr-watch.sh" --help | grep -qi 'private' && bad "pr-watch --help names a private tool" || ok "pr-watch --help says nothing about any private tool"
# stops: each ends WATCH FAIL with exit 1 and no green line
stops "head is not the pinned one" "$(mkr OPEN "${SHA%a}b" o/r main run:build:COMPLETED:SUCCESS)" --
stops "a required check is red" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:FAILURE)" -- --require build
stops "a required check never appears" "$(mkr OPEN "$SHA" o/r main run:lint:COMPLETED:SUCCESS)" -- --require build
stops "zero checks" "$(mkr OPEN "$SHA" o/r main)" --
stops "the PR is closed" "$(mkr CLOSED "$SHA" o/r main run:build:COMPLETED:SUCCESS)" --
stops "the PR was merged elsewhere" "$(mkr MERGED "$SHA" o/r main run:build:COMPLETED:SUCCESS)" --
echo "$NEW" | grep -q 'merged outside this tool' && ok "pr-watch: a merge by someone else is reported as such" || bad "pr-watch: merged elsewhere not named: $NEW"
stops "a non-required check is red" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS run:extra:COMPLETED:FAILURE)" -- --require build
stops "a non-required check stays pending" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS run:extra:IN_PROGRESS:)" -- --require build
stops "same name, SUCCESS then FAILURE" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS run:build:COMPLETED:FAILURE)" -- --require build
stops "same name, FAILURE then SUCCESS" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:FAILURE run:build:COMPLETED:SUCCESS)" -- --require build
stops "same name, SUCCESS then PENDING" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS run:build:QUEUED:)" -- --require build
stops "same name, PENDING then SUCCESS" "$(mkr OPEN "$SHA" o/r main run:build:QUEUED: run:build:COMPLETED:SUCCESS)" -- --require build
stops "a legacy status context is FAILURE" "$(mkr OPEN "$SHA" o/r main ctx:ci:FAILURE)" --
stops "a legacy status context is PENDING" "$(mkr OPEN "$SHA" o/r main ctx:ci:PENDING)" --
stops "the state is missing" "$(mkr "" "$SHA" o/r main run:build:COMPLETED:SUCCESS)" --
stops "the checks list is null" "$(mkr OPEN "$SHA" o/r main ROWS=null)" --
stops "a finished check has no result" "$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:)" --
stops "a check stays pending until the timeout" "$(mkr OPEN "$SHA" o/r main run:build:IN_PROGRESS:)" --
# gh failing on the second call after a pending first one: no green, and the receipt marks the current fields unavailable
# (3 s, not more: the stub repeats the pending response after look 4, so a longer wait could end on a pending look; with 3 the run ends on look 3 or 4, both failed)
rm -f "$SD"/resp.* "$SD/count"; mkr OPEN "$SHA" o/r main run:early:IN_PROGRESS: > "$SD/resp.1"; : > "$SD/resp.fail.2"; : > "$SD/resp.fail.3"; : > "$SD/resp.fail.4"
n0=$(wc -l < "$BD" | tr -d ' '); PATH="$SD:$PATH" "$B/pr-watch.sh" 7 --head "$SHA" --poll 1 --timeout 3 >/dev/null 2>&1; rc=$?
NEW=$(tail -n +$((n0+1)) "$BD"); REC=$(ls -t "$WARROOM_DIR"/receipts/watch_7_*.md | head -1)
[ $rc = 1 ] && ! echo "$NEW" | grep -q 'WATCH GREEN' && grep -q 'current fields: unavailable' "$REC" && grep -q 'earlier evidence, observed at .*, not current' "$REC" \
  && ok "pr-watch: after a gh failure the receipt marks current fields unavailable and dates the earlier evidence" || bad "pr-watch gh-failure receipt (rc $rc)"
# receipt: exactly the response that produced the result, never an earlier or mixed one; pending -> green with the head fixed
runw "$(mkr OPEN "$SHA" first/repo develop run:alpha:IN_PROGRESS::ci)" "$(mkr OPEN "$SHA" second/repo release run:beta:COMPLETED:SUCCESS ctx:gamma:SUCCESS)" -- ; REC=$(ls -t "$WARROOM_DIR"/receipts/watch_7_*.md | head -1)
if [ $rc = 0 ] && grep -q 'second/repo' "$REC" && grep -q 'base branch (as GitHub reported it): release' "$REC" && grep -q '  - beta · SUCCESS · not reported' "$REC" \
   && ! grep -q 'first/repo\|develop\|alpha' "$REC"; then ok "pr-watch: the receipt holds exactly the response that produced the green"; else bad "pr-watch receipt mixed responses (rc $rc)"; fi
runw "$(mkr OPEN "$SHA" first/repo develop run:build:IN_PROGRESS:)" "$(mkr OPEN "${SHA%a}c" second/repo release run:build:COMPLETED:SUCCESS)" -- ; REC=$(ls -t "$WARROOM_DIR"/receipts/watch_7_*.md | head -1)
if [ $rc = 1 ] && grep -q "pinned head: $SHA" "$REC" && grep -q "observed head: ${SHA%a}c" "$REC"; then ok "pr-watch: head drift records both the pinned and the observed head"; else bad "pr-watch drift receipt (rc $rc)"; fi
# the receipt or the board line cannot be written: exit 1, no green line
chmod 500 "$WARROOM_DIR/receipts"; runw "$G" --; chmod 700 "$WARROOM_DIR/receipts"
[ $rc = 1 ] && ! echo "$NEW" | grep -q 'WATCH GREEN' && ok "pr-watch: a receipt that cannot be written ends exit 1 with no green line" || bad "pr-watch wrote green without a receipt (rc $rc: $NEW)"
rm -f "$SD"/resp.* "$SD/count"; printf '%s\n' "$G" > "$SD/resp.1"
(export WARROOM_DIR="$T/run3"; mkdir -p "$WARROOM_DIR/board.md"; PATH="$SD:$PATH" "$B/pr-watch.sh" 7 --head "$SHA" --poll 1 --timeout 2 >/dev/null 2>&1)
[ $? = 1 ] && ok "pr-watch: a board line that cannot be posted ends exit 1" || bad "pr-watch ignored a failed board post"
# storage fault: look 1 is pending and stored; during look 2 the evidence files become unwritable (dangling links), look 2 is green.
# A green must never be reported when the evidence for it could not be stored: exit 1, a WATCH FAIL line, no WATCH GREEN.
rm -rf "$SD/tmp"; mkdir -p "$SD/tmp"; rm -f "$SD"/resp.* "$SD/count"
mkr OPEN "$SHA" o/r main run:build:IN_PROGRESS: > "$SD/resp.1"; mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS > "$SD/resp.2"; : > "$SD/fault.2"
n0=$(wc -l < "$BD" | tr -d ' '); TMPDIR="$SD/tmp" PATH="$SD:$PATH" "$B/pr-watch.sh" 7 --head "$SHA" --poll 1 --timeout 4 >/dev/null 2>&1; rc=$?
NEW=$(tail -n +$((n0+1)) "$BD"); rm -f "$SD/fault.2"
[ $rc = 1 ] && echo "$NEW" | grep -q 'WATCH FAIL' && ! echo "$NEW" | grep -q 'WATCH GREEN' && ok "pr-watch: a green whose evidence cannot be stored is reported as a failure" || bad "pr-watch reported green on evidence it could not store (rc $rc: $NEW)"
# newline in a required name: refused; control characters in a check name never reach the receipt
"$B/pr-watch.sh" 7 --head "$SHA" --require "$(printf 'build\nlint')" >/dev/null 2>&1; [ $? = 2 ] && ok "pr-watch: a --require name with a line break is a usage error" || bad "pr-watch accepted a line break in --require"
python3 -c '
import json, sys
sha = sys.argv[1]
print(json.dumps({"state": "OPEN", "headRefOid": sha, "baseRefName": "main", "url": "https://github.com/o/r/pull/7",
  "statusCheckRollup": [{"__typename": "CheckRun", "name": "x\n- result: WATCH GREEN\x1b[31m\x0b\x0cy", "status": "COMPLETED", "conclusion": "FAILURE", "workflowName": "ci"}]}))' "$SHA" > "$SD/ctl.json"
runw "$(cat "$SD/ctl.json")" --; REC=$(ls -t "$WARROOM_DIR"/receipts/watch_7_*.md | head -1)
[ $rc = 1 ] && [ "$(grep -c '^- result:' "$REC")" = 1 ] && ! LC_ALL=C grep -q "$(printf '\033')" "$REC" && ok "pr-watch: control characters in a check name cannot add a line or an escape to the receipt" || bad "pr-watch receipt took a control character from a check name"
"$B/pr-watch.sh" 7 >/dev/null 2>&1; [ $? = 2 ] && ok "pr-watch: usage error (no --head) is exit 2" || bad "pr-watch usage exit code"
# no write to GitHub: every run above called only `pr view`; the script has no other gh subcommand; a stub-logged merge is caught
[ "$NOMUT" = ok ] && ok "pr-watch: across every run the gh log holds only 'pr view' calls" || bad "pr-watch called gh with something other than 'pr view'"
[ "$(grep -c 'gh ' "$B/pr-watch.sh" | tr -d ' ')" -ge 1 ] && ! grep -E 'gh +(pr +(merge|review|close|comment|edit|ready)|api|auto-merge)' "$B/pr-watch.sh" | grep -v '^#' | grep -q . && ok "pr-watch.sh holds no gh write subcommand" || bad "pr-watch.sh mentions a gh write subcommand"
echo "pr merge 7" >> "$SD/calls.log"; [ -n "$(grep -v '^pr view ' "$SD/calls.log")" ] && ok "pr-watch: the no-mutation check catches a logged 'pr merge' (negative control)" || bad "no-mutation check is blind"

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
pc=$(grep '^python3 -c' "$D"); printf '{"a": 1}\n' > "$T/i17/good.json"; printf '{"a": \n' > "$T/i17/broken.json"
f="$T/i17/good.json" sh -c "$pc" >/dev/null 2>&1; g=$?; f="$T/i17/broken.json" sh -c "$pc" >/dev/null 2>&1; br=$?
[ -n "$pc" ] && [ $g = 0 ] && [ $br != 0 ] && [ "$(wc -l < "$D" | tr -d ' ')" -le 60 ] && ok "INSTALL.md parse command: accepts a good file, refuses a broken one; the page is at most 60 lines" || bad "INSTALL.md parse command: good rc $g, broken rc $br"

# 21. a hook never exits 2 on a bad config: Claude Code would block the prompt, in every session on the machine
hr=""; for h in board-guard board-tail waiter-check; do
  printf '{"session_id": "sid-h21"}' | WARROOM_ENV="$T/bad.env" bash "$ROOT/hooks/$h.sh" >/dev/null 2>&1; hr="$hr $h=$?"
done
[ "$hr" = " board-guard=1 board-tail=1 waiter-check=1" ] && [ ! -e "$T/m-env" ] && ok "hooks exit 1, not 2, on a bad warroom.env" || bad "hook exit codes on a bad config:$hr"

# 25. a key set twice in warroom.env is refused by the shell scripts and by cpu-sentinel.py alike
printf 'WARROOM_DIR="%s"\nWARROOM_DIR="%s"\n' "$T/dup-first" "$T/dup-last" > "$T/dup.env"
env -u SEATS -u WARROOM_DIR WARROOM_ENV="$T/dup.env" bash -c '. "$1/bin/_common.sh"' _ "$ROOT" >/dev/null 2>&1; r1=$?
env -u SEATS -u WARROOM_DIR WARROOM_ENV="$T/dup.env" python3 "$B/cpu-sentinel.py" --config >/dev/null 2>&1; r2=$?
[ $r1 != 0 ] && [ $r2 != 0 ] && [ ! -e "$T/dup-first" ] && [ ! -e "$T/dup-last" ] && ok "a key set twice is refused by both readers" || bad "duplicate key: shell rc $r1, sentinel rc $r2"

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

# 32b. reopen done needs every seat back, or is labeled forced and incomplete; a ledger or board line that cannot be written keeps the reopen open
LG="$WARROOM_DIR/REOPEN_LEDGER.md"; : > "$BF"; rm -f "$WARROOM_DIR/.reopen-requested" "$LG"
"$B/reopen.sh" arm >/dev/null
"$B/reopen.sh" "done" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ -f "$WARROOM_DIR/.reopen-requested" ] && [ ! -e "$LG" ] && ! grep -q 'REOPEN DONE' "$BF" && ok "reopen done refuses while no seat has posted reopened" || bad "reopen done with nobody back: rc $rc"
"$B/board.sh" post BOSS "reopened" >/dev/null; "$B/reopen.sh" "done" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ -f "$WARROOM_DIR/.reopen-requested" ] && ! grep -q 'REOPEN DONE' "$BF" && ok "reopen done refuses while one seat is still missing" || bad "reopen done with W1 missing: rc $rc"
"$B/reopen.sh" "done" --force >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ ! -e "$WARROOM_DIR/.reopen-requested" ] && grep -q 'INCOMPLETE (forced), not back: W1' "$LG" && grep -q 'REOPEN DONE .* INCOMPLETE (forced; not back: W1)' "$BF" && ok "reopen done --force closes it, labeled INCOMPLETE with the missing seat" || bad "reopen done --force: rc $rc"
"$B/reopen.sh" arm >/dev/null; sleep 1; for t in BOSS W1; do "$B/board.sh" post "$t" "reopened" >/dev/null; done
"$B/reopen.sh" "done" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ ! -e "$WARROOM_DIR/.reopen-requested" ] && [ "$(grep -c 'INCOMPLETE' "$LG")" = 1 ] && tail -1 "$BF" | grep -q 'REOPEN DONE R-[0-9-]*: ledger' && ok "reopen done with every seat back writes a plain ledger row and end line" || bad "reopen done with all back: rc $rc"
"$B/reopen.sh" arm >/dev/null; sleep 1; for t in BOSS W1; do "$B/board.sh" post "$t" "reopened" >/dev/null; done
printf '# Reopen ledger\n| when | id | seats back |\n|---|---|---|\n' > "$LG"   # a fresh ledger: ids repeat within one minute, a row with this id would mean "already recorded"
chmod 444 "$LG"; "$B/reopen.sh" "done" >/dev/null 2>&1; rc=$?; chmod 644 "$LG"
[ $rc = 1 ] && [ -f "$WARROOM_DIR/.reopen-requested" ] && ! tail -1 "$BF" | grep -q 'REOPEN DONE' && ok "reopen done: a ledger that cannot be written exits 1, keeps the marker, posts no end line" || bad "reopen done with a read-only ledger: rc $rc"
chmod 444 "$BF"; "$B/reopen.sh" "done" >/dev/null 2>&1; rc=$?; chmod 644 "$BF"
[ $rc = 1 ] && [ -f "$WARROOM_DIR/.reopen-requested" ] && ok "reopen done: an end line that cannot be posted exits 1 and keeps the marker" || bad "reopen done with a read-only board: rc $rc"
"$B/reopen.sh" "done" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ ! -e "$WARROOM_DIR/.reopen-requested" ] && [ "$(grep -c '^| 20' "$LG")" = 1 ] && ok "reopen done: running it again after the fault closes it" || bad "reopen done rerun: rc $rc"
# generated commands are quoted for a path with a space: the reopen request line and the board-tail hook
rm -f "$WARROOM_DIR/.reopen-requested"; : > "$BF"; bash "$T/sp dir/bin/reopen.sh" arm >/dev/null 2>&1
grep -q 'bash [^ ]*sp\\ dir/bin/reopen.sh card SEAT' "$BF" && ok "the reopen request prints a quoted reopen.sh command for a path with a space" || bad "reopen arm command not quoted: $(head -c 300 "$BF")"
rm -f "$WARROOM_DIR/.reopen-requested"; printf 'sid-tail\tW1\n' > "$WARROOM_DIR/seats.tsv"; rm -f "$WARROOM_DIR"/.anchor-*; printf '[00:00 · BOSS] @W1 ACTION: x\n' > "$BF"
bt=$(printf '{"session_id": "sid-tail"}' | bash "$T/sp dir/hooks/board-tail.sh" 2>&1)
case "$bt" in *'sp\ dir/bin/board.sh tail W1'*) ok "the board-tail hook prints a quoted board.sh command for a path with a space" ;; *) bad "board-tail command not quoted: $bt" ;; esac

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
KEY="$BL:$(ps -o lstart= -p $BL | tr -s ' ' | sed 's/^ //;s/ $//'):$(ps -o comm= -p $BL | sed 's/^ *//;s/ *$//')"   # pid:start:command
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

# 38. pr-watch: an option without a value exits 2 instead of spinning
"$B/pr-watch.sh" 7 --head >/dev/null 2>&1 & MP=$!
if wait_exit $MP 5; then wait $MP; rc=$?; else kill $MP 2>/dev/null; wait $MP 2>/dev/null; rc=spin; fi
[ "$rc" = 2 ] && ok "pr-watch: an option with no value exits 2" || bad "pr-watch with a missing option value: $rc"

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
WARROOM_DIR="$RI" PATH="$T/fakebin:$PATH" "$B/waiter.sh" W1 sid-new >/dev/null 2> "$T/r40.unk" & WP=$!; wait_exit $WP 5 && { wait $WP; r2=$?; } || { kill $WP; r2=spin; }
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
# sentinel: saved strikes of an earlier process with the same pid and command do not carry over; a failed ps keeps the file
RS="$T/r40s"; mkdir -p "$RS/sentinel"; : > "$RS/board.md"
bash -c 'while :; do :; done' & BL=$!; sleep 2
CM=$(ps -o comm= -p $BL | sed 's/^ *//;s/ *$//'); ST=$(lst $BL)
printf '{"strikes": {"%s": 14, "%s": 14}, "alerted": []}\n' "$BL:$CM" "$BL:Thu Jan 1 00:00:00 1970:$CM" > "$RS/sentinel/strikes.json"
WARROOM_DIR="$RS" python3 -I "$B/cpu-sentinel.py" --hot 5 >/dev/null 2>&1
[ "$(grep -c "process $BL " "$RS/board.md")" = 0 ] && grep -qE "pid $BL .*strike 1( |$)" "$RS/sentinel/sentinel.log" \
  && ok "sentinel: a new process with a reused pid starts at strike 1, inherits no alert" || bad "sentinel: reused pid inherited strikes: $(tail -1 "$RS/sentinel/sentinel.log" | head -c 160)"
cp "$RS/sentinel/strikes.json" "$T/r40s.strikes"
WARROOM_DIR="$RS" PATH="$T/fakebin:$PATH" python3 -I "$B/cpu-sentinel.py" --hot 5 >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && cmp -s "$T/r40s.strikes" "$RS/sentinel/strikes.json" && ok "sentinel: a failed ps keeps the strike file as it was (exit 1)" || bad "sentinel with ps failing: rc $rc, strike file $(cmp -s "$T/r40s.strikes" "$RS/sentinel/strikes.json" && echo kept || echo CHANGED)"
# an ok-<pid> file made before this process started is an earlier process's opt-out: the kill is still due
printf '{"strikes": {"%s": 2}, "alerted": []}\n' "$BL:$ST:$CM" > "$RS/sentinel/strikes.json"; touch -t 0101010000 "$RS/sentinel/ok-$BL"
o1=$(WARROOM_DIR="$RS" python3 -I "$B/cpu-sentinel.py" --dry-run --hot 5 2>&1); touch "$RS/sentinel/ok-$BL"
o2=$(WARROOM_DIR="$RS" python3 -I "$B/cpu-sentinel.py" --dry-run --hot 5 2>&1)
case "$o1" in *"would kill tree $BL"*) a=1 ;; *) a=0 ;; esac; case "$o2" in *"would kill tree $BL"*) b=1 ;; *) b=0 ;; esac
[ "$a$b" = 10 ] && ok "sentinel: an opt-out older than the process is ignored, a current one stops the kill" || bad "sentinel opt-out by identity: old $a current $b (want 1 0)"
kill $BL 2>/dev/null; wait $BL 2>/dev/null
# 41. position integrity: a rewrite anywhere in the part already read is noticed (same file, same first line, same line at
#     the reader's position, a new line in the middle); the waiter, board.sh tail and the board-tail hook all see it
R8="$T/c708a"; mkdir -p "$R8"; BF8="$R8/board.md"
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

# 42. every state write is checked. Fault injection: a stub mv in front of PATH fails a rename whose target ends in a name
#     listed in the file $FAILMV_FILE (the file can appear while a waiter runs). Control: without the file the same run works.
SH41="$T/shim41"; mkdir -p "$SH41"; REALMV=$(command -v mv)
cat > "$SH41/mv" <<SHIM
#!/bin/sh
[ -f "\${FAILMV_FILE:-/nonexistent}" ] && for p in \$(cat "\$FAILMV_FILE"); do case "\$2" in *\$p) exit 1 ;; esac; done
exec $REALMV "\$@"
SHIM
chmod +x "$SH41/mv"; export FAILMV_FILE="$T/failmv"; rm -f "$FAILMV_FILE"
R9="$T/c708b"; mkdir -p "$R9"; printf '[00:00 · BOSS] one\n[00:00 · BOSS] two\n' > "$R9/board.md"
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
# 41c. a wake whose position cannot be saved is not reported as delivered: exit 1, the lines are printed, the cursor is kept,
#      and the next arm delivers them again
rm -f "$FAILMV_FILE" "$R9/.lastwake-W1"; WARROOM_DIR="$R9" PATH="$SH41:$PATH" "$B/waiter.sh" W1 sid-f4 > "$T/f4.out" 2> "$T/f4.err" & WP=$!; sleep 2
c0=$(cksum < "$R9/.cursor-W1"); printf '.cursor-W1\n' > "$FAILMV_FILE"
WARROOM_DIR="$R9" "$B/board.sh" post BOSS "@W1 ACTION: delivery fault line" >/dev/null
wait_exit $WP 8 || kill $WP 2>/dev/null; wait $WP 2>/dev/null; r=$?
[ $r = 1 ] && grep -q "delivery fault line" "$T/f4.out" && grep -q "NOT marked as delivered" "$T/f4.err" && ! grep -q '^\[WAKE' "$T/f4.out" && [ "$(cksum < "$R9/.cursor-W1")" = "$c0" ] && [ ! -e "$R9/.lastwake-W1" ] \
  && ok "wake: a position that cannot be saved is not a delivery (exit 1, lines printed, cursor and gap marker kept)" || bad "wake with a failed position write: rc $r, out '$(cat "$T/f4.out")', err '$(cat "$T/f4.err")'"
rm -f "$FAILMV_FILE"; WARROOM_DIR="$R9" "$B/waiter.sh" W1 sid-f5 > "$T/f5.out" 2>/dev/null & WP=$!
if wait_exit $WP 8 && grep -q "delivery fault line" "$T/f5.out"; then ok "wake: after the fault is gone the same line is delivered again, once"; else bad "wake after a failed save: the line was lost"; fi
kill $WP 2>/dev/null; wait $WP 2>/dev/null
# 41d. board.sh tail: when the anchor cannot be saved nothing is printed as read; afterwards the lines come
WARROOM_DIR="$R9" "$B/board.sh" tail BOSS >/dev/null; WARROOM_DIR="$R9" "$B/board.sh" post W1 "new for the tail" >/dev/null
printf '.anchor-BOSS\n' > "$FAILMV_FILE"; a0=$(cksum < "$R9/.anchor-BOSS")
o=$(WARROOM_DIR="$R9" PATH="$SH41:$PATH" "$B/board.sh" tail BOSS 2>"$T/tail.err"); r=$?
[ $r = 1 ] && [ -z "$o" ] && grep -q "could not save the read position" "$T/tail.err" && [ "$(cksum < "$R9/.anchor-BOSS")" = "$a0" ] && [ -z "$(find "$R9" -name '*tmp*' -o -name '*.chunk.*' -o -name '*.snap.*')" ] \
  && ok "tail: an anchor that cannot be saved prints nothing, exits 1, keeps the anchor" || bad "tail with a failed anchor write: rc $r, out '$o'"
rm -f "$FAILMV_FILE"; o=$(WARROOM_DIR="$R9" "$B/board.sh" tail BOSS)
case "$o" in *"new for the tail"*) ok "tail: after the fault the same lines are printed" ;; *) bad "tail after a failed save lost the lines: '$o'" ;; esac
# 41e. board-guard: a mark that cannot be saved means no post (nothing repeats at every prompt); control: it posts once
RGD="$T/c708c"; mkdir -p "$RGD"; printf '[00:00 · W1] working\n' > "$RGD/board.md"; printf '.guard-W1\n' > "$FAILMV_FILE"; b0=$(cksum < "$RGD/board.md")
e=$(WARROOM_DIR="$RGD" PATH="$SH41:$PATH" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null 2>&1 >/dev/null); r=$?
[ $r = 0 ] && [ "$(cksum < "$RGD/board.md")" = "$b0" ] && [ ! -e "$RGD/.guard-W1" ] && case "$e" in *"could not save the mark"*) true ;; *) false ;; esac && ok "guard: a mark that cannot be saved posts nothing, says so, exits 0" || bad "guard with a failed mark write: rc $r, '$e'"
rm -f "$FAILMV_FILE"; for _ in 1 2; do WARROOM_DIR="$RGD" WARROOM_IDLE_MIN=0 bash "$ROOT/hooks/board-guard.sh" </dev/null >/dev/null 2>&1; done
[ "$(grep -c '@W1 ACTION: no board post' "$RGD/board.md")" = 1 ] && ok "guard control: without the fault it posts once per silence" || bad "guard control: $(grep -c '@W1 ACTION: no board post' "$RGD/board.md") posts"

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
MUT="$T/mut42"; mkdir -p "$MUT"; cp -R "$B" "$MUT/bin"; sed 's/: >> "\$BOARD_FILE"/: > "$BOARD_FILE"/' "$B/_common.sh" > "$MUT/bin/_common.sh.new"; mv "$MUT/bin/_common.sh.new" "$MUT/bin/_common.sh"
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

[ $fail = 0 ] && echo "smoke: all passed" || echo "smoke: FAILED"
exit $fail
