#!/usr/bin/env bash
# merge-daemon.sh — TEMPLATE. Wait for one pull request to go green, merge it once, read the result back, leave a receipt.
# No model is involved: a script waits, a script merges, a script checks. Copy it and change the policy to yours.
#   merge-daemon.sh PR --head SHA [--repo OWNER/REPO] [--seat SEAT] [--poll SECONDS] [--timeout SECONDS] [--dry-run]
# Rules this template enforces:
#   - the merge is pinned to --head: if the branch moved, nothing is merged and the run ends FAIL
#   - squash merge only; the commit message is the PR title, with an empty body
#   - after the merge the PR is read back: state MERGED and a merge commit exist, or the run ends FAIL
#   - the last board line is "POSTCONDITION PASS" or "POSTCONDITION FAIL", and a receipt file is written either way
# Needs: gh (logged in) and python3. --dry-run prints what it would do and merges nothing.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
case "${1:-}" in -h|--help|help|"") sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
PR=$1; shift; HEAD=""; REPO=""; SEAT=$BOSS_SEAT; POLL=30; TIMEOUT=7200; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --head) HEAD=$2; shift 2 ;; --repo) REPO=$2; shift 2 ;; --seat) SEAT=$2; shift 2 ;;
  --poll) POLL=$2; shift 2 ;; --timeout) TIMEOUT=$2; shift 2 ;; --dry-run) DRY=1; shift ;;
  *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[ -n "$HEAD" ] || { echo "--head SHA is required (the merge is pinned to it)" >&2; exit 2; }
R=(); [ -n "$REPO" ] && R=(--repo "$REPO")
RECEIPT="$W/receipts/merge_${PR}_$(date +%Y%m%d_%H%M%S).md"; mkdir -p "$W/receipts"
say() { "$HERE/board.sh" post "$SEAT" "$1" >/dev/null; }
finish() { # finish PASS|FAIL "detail"
  { echo "# merge receipt PR $PR"; echo "- result: $1"; echo "- detail: $2"; echo "- pinned head: $HEAD"; echo "- time: $(date '+%Y-%m-%d %H:%M:%S')"; } > "$RECEIPT"
  say "POSTCONDITION $1 merge of PR $PR: $2 (receipt $RECEIPT)"; [ "$1" = PASS ] && exit 0 || exit 1; }
view() { gh pr view "$PR" "${R[@]}" --json "$1" -q "$2" 2>/dev/null; }
end=$(( $(date +%s) + TIMEOUT ))
while :; do
  head=$(view headRefOid .headRefOid); state=$(view state .state)
  [ "$state" = OPEN ] || finish FAIL "PR state is '$state', not OPEN"
  [ "$head" = "$HEAD" ] || finish FAIL "branch head is $head, not the pinned $HEAD"
  bad=$(view statusCheckRollup '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT")] | length')
  pending=$(view statusCheckRollup '[.statusCheckRollup[]? | select(.status!="COMPLETED" and .state!="SUCCESS")] | length')
  [ "${bad:-0}" -gt 0 ] && finish FAIL "$bad check(s) failed"
  [ "${pending:-1}" -eq 0 ] && break
  [ "$(date +%s)" -ge "$end" ] && finish FAIL "timed out waiting for checks"
  sleep "$POLL"
done
if [ $DRY = 1 ]; then echo "dry run: PR $PR is green at $HEAD; would squash-merge pinned to it"; exit 0; fi
title=$(view title .title)
gh pr merge "$PR" "${R[@]}" --squash --match-head-commit "$HEAD" --subject "$title (#$PR)" --body "" >/dev/null 2>&1 || finish FAIL "gh pr merge was refused"
state=$(view state .state); mc=$(view mergeCommit .mergeCommit.oid)
if [ "$state" = MERGED ] && [ -n "$mc" ]; then finish PASS "merged as $mc"; else finish FAIL "readback shows state '$state' and no merge commit"; fi
