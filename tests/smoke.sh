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
#  11. locks: a live owner is never evicted, a dead owner is reclaimed, a non-owner cannot release
#  12. the job ledger: concurrent add of one label gives one row; a reused pid (wrong start time) counts as gone
#  13. pr-watch (gh stubbed): only `gh pr view` is ever called, a green needs every row green, and the receipt holds the response that produced it
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
#  38. pr-watch: an option without a value exits 2 (no spin)
#  39. leak-check: a bad denylist pattern or an unreadable file is an error (exit 2), run-state files in the tree are a hit
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
runw() { rm -f "$SD"/resp.* "$SD/count" "$SD/calls.log"; i=1
  while [ "${1:-}" != "--" ]; do printf '%s\n' "$1" > "$SD/resp.$i"; i=$((i+1)); shift; done; shift
  n0=$(wc -l < "$BD" | tr -d ' '); PATH="$SD:$PATH" "$B/pr-watch.sh" 7 --head "$SHA" --poll 1 --timeout 1 "$@" >/dev/null 2>&1; rc=$?
  NEW=$(tail -n +$((n0+1)) "$BD"); touch "$SD/calls.log"
  [ -z "$(grep -v '^pr view ' "$SD/calls.log")" ] || NOMUT=bad; }
NOMUT=ok
G=$(mkr OPEN "$SHA" o/r main run:build:COMPLETED:SUCCESS:ci)
stops() { # stops "name" RESP... -- args: the run must end with exit 1, one WATCH FAIL line and no WATCH GREEN
  nm=$1; shift; runw "$@"
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
rm -f "$SD"/resp.* "$SD/count"; mkr OPEN "$SHA" o/r main run:early:IN_PROGRESS: > "$SD/resp.1"; : > "$SD/resp.fail.2"; : > "$SD/resp.fail.3"; : > "$SD/resp.fail.4"
n0=$(wc -l < "$BD" | tr -d ' '); PATH="$SD:$PATH" "$B/pr-watch.sh" 7 --head "$SHA" --poll 1 --timeout 2 >/dev/null 2>&1; rc=$?
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

[ $fail = 0 ] && echo "smoke: all passed" || echo "smoke: FAILED"
exit $fail
