#!/usr/bin/env bash
# tests/smoke.sh — end-to-end check on a throwaway board. Runs in CI and on your machine; touches nothing outside a temp dir.
#   1. a plain mention does not wake a seat; an "@SEAT ACTION:" line does, within a few seconds
#   2. a second waiter on a seat that is already held is refused
#   3. a registered job that dies wakes its owner once, and its row is dropped, also when several seats check at once
#   4. the idle guard names a silent seat once per silence, not once per prompt
#   5. install.sh refuses a settings file that is not valid JSON and leaves it unchanged
#   6. a reopen request wakes the other seats; reopen.sh status exits 0 while they bank
#   7. wake grammar: only a first line "@SEAT ACTION:" from another author wakes (not prose, ACTIONABLE, a second line, the seat's own post)
#   8. a replaced board of the same length is read again from its start; a waiter missing its session id is refused
#   9. two arms of one seat at the same moment: exactly one wins, every round
#  10. a board that cannot be written makes post fail; a job's row is kept until its wake is on the board
#  11. locks: a live owner is never evicted, a dead owner is reclaimed, a non-owner cannot release
#  12. the job ledger: concurrent add of one label gives one row; a reused pid (wrong start time) counts as gone
#  13. merge-daemon (gh stubbed): a check that fails on the second look, or a required check that never appears, merges nothing
#  14-16. warroom.env is data: command text refused, the current folder ignored, shell and cpu-sentinel.py agree
#  17-20. install.sh: refuses command text in --dir, survives an interrupted write, re-points a moved clone, keeps config
#  21. every hook with a bad warroom.env exits 1 (shown, prompt goes through), never 2 (Claude Code blocks the prompt)
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

# 11. locks
L="$T/lk"; sleep 60 & LP=$!
mkdir "$L.lock"; echo "$LP" > "$L.lock/owner"; python3 -c 'import os,sys; os.utime(sys.argv[1], (1e9, 1e9))' "$L.lock"
bash -c '. "$1/bin/_common.sh"; wr_lock "$2"' _ "$ROOT" "$L" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && [ "$(cat "$L.lock/owner")" = "$LP" ] && ok "live owner's old lock is not stolen" || bad "live lock was taken (rc $rc)"
bash -c '. "$1/bin/_common.sh"; wr_unlock "$2"' _ "$ROOT" "$L" >/dev/null 2>&1
[ "$(cat "$L.lock/owner" 2>/dev/null)" = "$LP" ] && ok "a non-owner cannot release a lock" || bad "non-owner released the lock"
kill $LP 2>/dev/null; wait $LP 2>/dev/null
bash -c '. "$1/bin/_common.sh"; wr_lock "$2" && [ "$(cat "$2.lock/owner")" = "$$" ] && wr_unlock "$2" && [ ! -d "$2.lock" ]' _ "$ROOT" "$L" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && ok "dead owner's lock is reclaimed, then released by its new owner" || bad "dead lock not reclaimed (rc $rc)"

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

# 19. reinstall: a moved clone's entries are pointed here, never doubled; a second run changes nothing
mkdir -p "$T/i12/cfg" "$T/i12/home"
printf '{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash /gone/clone/hooks/board-tail.sh"}]}]}}\n' > "$T/i12/cfg/settings.json"
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i12/home" CLAUDE_CONFIG_DIR="$T/i12/cfg" bash "$ROOT/install.sh" --dir "$T/i12/run" >/dev/null 2>&1
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i12/home" CLAUDE_CONFIG_DIR="$T/i12/cfg" bash "$ROOT/install.sh" >"$T/i12/out2" 2>&1
n=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["hooks"]; print(sum(len(g["hooks"]) for e in d.values() for g in e), sum("/gone/" in h["command"] for e in d.values() for g in e for h in g["hooks"]))' "$T/i12/cfg/settings.json")
nb=0; for f in "$T"/i12/cfg/settings.json.warroom-bak-*; do [ -e "$f" ] && nb=$((nb + 1)); done
[ "$n" = "4 0" ] && [ "$nb" = 1 ] && grep -q "nothing to change" "$T/i12/out2" && ok "moved clone re-pointed, second run changes nothing" || bad "reinstall: entries/old '$n', backups $nb"

# 20. reinstall with other seats than the existing config is refused, not silently ignored
env -u WARROOM_ENV -u SEATS -u WARROOM_DIR HOME="$T/i12/home" CLAUDE_CONFIG_DIR="$T/i12/cfg" bash "$ROOT/install.sh" --seats "X1 X2" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && grep -q 'SEATS="BOSS MANAGER W1 W2"' "$T/i12/home/.warroom/warroom.env" && ok "install refuses seats that differ from the existing config" || bad "install with other seats: rc $rc"

# 21. a hook never exits 2 on a bad config: Claude Code would block the prompt, in every session on the machine
hr=""; for h in board-guard board-tail waiter-check; do
  printf '{"session_id": "sid-h21"}' | WARROOM_ENV="$T/bad.env" bash "$ROOT/hooks/$h.sh" >/dev/null 2>&1; hr="$hr $h=$?"
done
[ "$hr" = " board-guard=1 board-tail=1 waiter-check=1" ] && [ ! -e "$T/m-env" ] && ok "hooks exit 1, not 2, on a bad warroom.env" || bad "hook exit codes on a bad config:$hr"

[ $fail = 0 ] && echo "smoke: all passed" || echo "smoke: FAILED"
exit $fail
