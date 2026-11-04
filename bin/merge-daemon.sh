#!/usr/bin/env bash
# merge-daemon.sh — TEMPLATE. Wait for one pull request to go green, merge it once, read the result back, leave a receipt.
# No model is involved: a script waits, a script merges, a script checks. Copy it and change the policy to yours.
#   merge-daemon.sh PR --head SHA [--require CHECK]... [--repo OWNER/REPO] [--seat SEAT] [--poll S] [--timeout S] [--dry-run]
# What it does: each look at the PR is ONE gh call (state, head and checks together), so they describe the same moment.
#   - the merge is pinned to --head (a full 40-character sha): if the branch moved, nothing is merged and the run ends FAIL
#   - a check counts as green only when it says so (SUCCESS, NEUTRAL, SKIPPED); a finished check that is not green fails the run
#   - --require NAME (repeatable) names a check that must exist and be green; one that has not appeared yet counts as pending
#   - when all looks green it looks ONE more time, and merges only if that second look shows the same head and the same result
#   - squash merge only, with --match-head-commit; the commit message is the PR title, with an empty body
#   - after the merge the PR is read back: state MERGED and a merge commit exist, or the run ends FAIL
#   - the last board line is "POSTCONDITION PASS" or "POSTCONDITION FAIL" and a receipt file is written either way;
#     if the receipt or the board line cannot be written the run itself ends FAIL
# Limit: this script cannot stop someone else merging. The guarantee that nothing merges unchecked is a server-side one:
# branch protection with required status checks on the target branch. Without --require it also warns, because a check
# that has not registered yet is not waited for. Needs: gh (logged in) and python3. --dry-run merges and writes nothing
#   (no receipt, no board line) on every outcome, pass or fail.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
case "${1:-}" in -h|--help|help|"") sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
PR=$1; shift; HEAD=""; REPO=""; SEAT=$BOSS_SEAT; POLL=30; TIMEOUT=7200; DRY=0; REQUIRE=""
need() { # need OPTION VALUE: an option that takes a value must be followed by one (not by nothing or another option)
  case "${2-}" in ''|--*) echo "$1 needs a value" >&2; exit 2 ;; esac; }
while [ $# -gt 0 ]; do case "$1" in
  --head) need "$@"; HEAD=$2; shift 2 ;; --repo) need "$@"; REPO=$2; shift 2 ;; --seat) need "$@"; SEAT=$2; shift 2 ;;
  --require) need "$@"; REQUIRE="${REQUIRE:+$REQUIRE
}$2"; shift 2 ;;
  --poll) need "$@"; POLL=$2; shift 2 ;; --timeout) need "$@"; TIMEOUT=$2; shift 2 ;; --dry-run) DRY=1; shift ;;
  *) echo "unknown option $1" >&2; exit 2 ;; esac; done
case "$PR" in ''|*[!0-9]*) echo "PR must be a number" >&2; exit 2 ;; esac
case "$HEAD" in
  '') echo "--head SHA is required (the merge is pinned to it)" >&2; exit 2 ;;
  *[!0-9a-f]*) echo "--head must be a full lower-case hex sha" >&2; exit 2 ;;
esac
[ "${#HEAD}" -eq 40 ] || { echo "--head must be the full 40-character sha, not an abbreviation" >&2; exit 2; }
case "$POLL$TIMEOUT" in ''|*[!0-9]*) echo "--poll and --timeout are whole seconds" >&2; exit 2 ;; esac
wr_seat_ok "$SEAT" || { echo "unknown seat '$SEAT' (seats: $SEATS)" >&2; exit 2; }
[ -n "$REQUIRE" ] || echo "warning: no --require given; a check that has not registered yet is not waited for. Branch protection with required checks is the real guard." >&2
R=(); [ -n "$REPO" ] && R=(--repo "$REPO")
RECEIPT="$W/receipts/merge_${PR}_$(date +%Y%m%d_%H%M%S)_$$.md"

finish() { # finish PASS|FAIL "detail" — receipt and board line must both succeed, or the run fails
  _res=$1; _rc=0
  if [ "$DRY" = 1 ]; then      # a dry run ends the same way on every outcome: say it, write nothing (no receipt, no board line)
    echo "dry run: would end $_res for PR $PR: $2 (nothing written)"; [ "$_res" = PASS ] && exit 0; exit 1
  fi
  mkdir -p "$W/receipts" || { echo "could not create $W/receipts" >&2; _rc=1; }
  { echo "# merge receipt PR $PR"; echo "- result: $_res"; echo "- detail: $2"; echo "- pinned head: $HEAD"
    echo "- invocation: pid $$"
    echo "- required checks: ${REQUIRE:-none}" | tr '\n' ' '; echo; echo "- time: $(date '+%Y-%m-%d %H:%M:%S')"; } > "$RECEIPT" \
    || { echo "could not write the receipt $RECEIPT" >&2; _rc=1; }
  "$HERE/board.sh" post "$SEAT" "POSTCONDITION $_res merge of PR $PR: $2 (receipt $RECEIPT)" >/dev/null \
    || { echo "could not post the result to the board" >&2; _rc=1; }
  if [ "$_rc" != 0 ] && [ "$_res" = PASS ]; then echo "merged, but the receipt or the board line failed: run counts as FAIL" >&2; fi
  [ "$_res" = PASS ] && [ "$_rc" = 0 ] && exit 0
  exit 1; }

# snapshot: ONE gh call; sets S_STATE S_HEAD S_BAD S_PENDING S_TOTAL S_MISSING S_TITLE. Returns 1 when gh or parsing failed.
snapshot() {
  _json=$(gh pr view "$PR" "${R[@]}" --json state,headRefOid,title,statusCheckRollup 2>/dev/null) || return 1
  _out=$(REQUIRE="$REQUIRE" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
req = [r for r in os.environ.get("REQUIRE", "").split("\n") if r]
green_c = ("SUCCESS", "NEUTRAL", "SKIPPED")
seen = {}      # name -> list of "g" / "p" / "b"
bad = pending = total = 0
for c in d.get("statusCheckRollup") or []:
    if "state" in c and "status" not in c:                       # commit status
        name = c.get("context") or ""
        st = c.get("state")
        v = "g" if st == "SUCCESS" else ("p" if st in ("PENDING", "EXPECTED") else "b")
    else:                                                        # check run
        name = c.get("name") or ""
        if c.get("status") != "COMPLETED": v = "p"
        else: v = "g" if c.get("conclusion") in green_c else "b"
    total += 1
    seen.setdefault(name, []).append(v)
    if v == "b": bad += 1
    elif v == "p": pending += 1
missing = [r for r in req if r not in seen]
title = (d.get("title") or "").replace("\n", " ").replace("\r", " ")
print(d.get("state") or ""); print(d.get("headRefOid") or ""); print(bad); print(pending); print(total)
print(",".join(missing)); print(title)
' <<< "$_json" 2>/dev/null) || return 1
  { read -r S_STATE; read -r S_HEAD; read -r S_BAD; read -r S_PENDING; read -r S_TOTAL; read -r S_MISSING; read -r S_TITLE; } <<< "$_out"
  case "$S_BAD$S_PENDING$S_TOTAL" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
# judge: look once. 0 = ready to merge, 1 = not yet (keep waiting), 2 = stop (REASON says why)
judge() {
  snapshot || { REASON="could not read the PR (gh or parsing failed)"; return 1; }
  [ "$S_STATE" = OPEN ] || { REASON="PR state is '$S_STATE', not OPEN"; return 2; }
  [ "$S_HEAD" = "$HEAD" ] || { REASON="branch head is $S_HEAD, not the pinned $HEAD"; return 2; }
  [ "$S_BAD" -eq 0 ] || { REASON="$S_BAD check(s) finished without a green result"; return 2; }
  # Zero checks counts as pending (they may not have registered yet), so a PR with no checks times out, never merges.
  if [ "$S_PENDING" -gt 0 ] || [ "$S_TOTAL" -eq 0 ] || [ -n "$S_MISSING" ]; then
    REASON="waiting: $S_PENDING pending, $S_TOTAL total${S_MISSING:+, required not seen: $S_MISSING}"; return 1
  fi
  return 0
}

end=$(( $(date +%s) + TIMEOUT ))
while :; do
  judge; rc=$?
  [ "$rc" = 2 ] && finish FAIL "$REASON"
  if [ "$rc" = 0 ]; then
    judge; rc=$?                                   # the confirming look, right before the merge
    [ "$rc" = 2 ] && finish FAIL "$REASON (seen on the confirming look)"
    [ "$rc" = 0 ] && break
  fi
  [ "$(date +%s)" -ge "$end" ] && finish FAIL "timed out waiting for checks ($REASON)"
  sleep "$POLL"
done
if [ $DRY = 1 ]; then finish PASS "green at $HEAD on two looks; would squash-merge pinned to it"; fi
err=$(gh pr merge "$PR" "${R[@]}" --squash --match-head-commit "$HEAD" --subject "$S_TITLE (#$PR)" --body "" 2>&1 >/dev/null) || {
  _why=$(printf '%s' "$err" | head -n 1 | cut -c1-120)
  # refused: another actor may have merged it between our last look and this call. That is not a merge by this run.
  if snapshot && [ "$S_STATE" = MERGED ]; then
    finish FAIL "NOT merged by this run (invocation $$): gh refused ($_why) and the PR is already MERGED by someone else"
  fi
  finish FAIL "gh pr merge was refused: $_why"; }
snapshot || finish FAIL "merge call (invocation $$) was accepted, but the PR could not be read back"
# Three different outcomes, never one: merged now / accepted but not merged yet (queue or auto-merge) / merged by another account.
rb=$(gh pr view "$PR" "${R[@]}" --json mergeCommit,mergedBy -q '[.mergeCommit.oid // "", .mergedBy.login // ""] | @tsv' 2>/dev/null)
mc=${rb%%$'\t'*}; merger=""; case "$rb" in *$'\t'*) merger=${rb#*$'\t'} ;; esac
me=$(gh api user -q .login 2>/dev/null)
if [ "$S_STATE" != MERGED ]; then
  finish FAIL "merge call (invocation $$) was accepted but the PR is still '$S_STATE': queued or auto-merge? Nothing is merged yet; look again later"
elif [ -z "$mc" ]; then
  finish FAIL "readback shows state '$S_STATE' and no merge commit"
elif [ -n "$merger" ] && [ -n "$me" ] && [ "$merger" = "$me" ]; then
  finish PASS "merged by this run (invocation $$, account $me) as $mc"
elif [ -n "$merger" ] && [ -n "$me" ]; then
  finish FAIL "NOT merged by this run's account: PR is MERGED as $mc by $merger (this run is $me, invocation $$)"
else
  finish PASS "merged as $mc (the merging account could not be read, so this does not prove this run did it; invocation $$)"
fi
