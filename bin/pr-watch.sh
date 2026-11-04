#!/usr/bin/env bash
# pr-watch.sh — watch one pull request's checks at a pinned head and report what they showed. It only reads; it never merges.
#   pr-watch.sh PR --head SHA [--require CHECK]... [--repo OWNER/REPO] [--seat SEAT] [--poll S] [--timeout S]
# What it does: it looks at the PR with `gh pr view` every --poll seconds (the only GitHub call it makes, a read) and stops at the first result.
#   - each look is one response; the tool reports "the returned PR data showed ...", it does not claim one atomic moment on the server
#   - a check is green when it is SUCCESS, NEUTRAL or SKIPPED; every row of the response is judged, required or not, and two rows
#     with one name are both judged. A missing or null field the verdict needs makes the look not green. Zero checks is pending.
#   - --require NAME (repeatable) must appear and be green; there must be at least one check
#   - it stops with WATCH FAIL when the head is not --head, a check is red, the PR is closed, someone merged it, or the time runs out
#   - the last board line starts WATCH GREEN or WATCH FAIL and ends with the receipt path; a receipt is written either way, and
#     if the receipt or the board line cannot be written the run ends with exit 1
# Limit: a green report is an observation, not a gate and not a guarantee. It freezes nothing: a check can turn red, the head can
# move or the base can change after the look. This tool does not read branch protection; whether a merge can skip the checks is
# decided there. Exit codes: 0 = green seen, 1 = stopped or timed out, 2 = usage error. Needs: gh (logged in) and python3.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
case "${1:-}" in -h|--help|help|"") sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
PR=$1; shift; HEAD=""; REPO=""; SEAT=$BOSS_SEAT; POLL=30; TIMEOUT=7200; REQUIRE=""
need() { # need OPTION VALUE: an option that takes a value must be followed by one (not by nothing or another option)
  case "${2-}" in ''|--*) echo "$1 needs a value" >&2; exit 2 ;; esac; }
while [ $# -gt 0 ]; do case "$1" in
  --head) need "$@"; HEAD=$2; shift 2 ;; --repo) need "$@"; REPO=$2; shift 2 ;; --seat) need "$@"; SEAT=$2; shift 2 ;;
  --require) need "$@"; REQUIRE="${REQUIRE:+$REQUIRE
}$2"; shift 2 ;;
  --poll) need "$@"; POLL=$2; shift 2 ;; --timeout) need "$@"; TIMEOUT=$2; shift 2 ;;
  *) echo "unknown option $1" >&2; exit 2 ;; esac; done
case "$PR" in ''|*[!0-9]*) echo "PR must be a number" >&2; exit 2 ;; esac
case "$HEAD" in
  '') echo "--head SHA is required (the watch is pinned to it)" >&2; exit 2 ;;
  *[!0-9a-f]*) echo "--head must be a full lower-case hex sha" >&2; exit 2 ;;
esac
[ "${#HEAD}" -eq 40 ] || { echo "--head must be the full 40-character sha, not an abbreviation" >&2; exit 2; }
case "$POLL$TIMEOUT" in ''|*[!0-9]*) echo "--poll and --timeout are whole seconds" >&2; exit 2 ;; esac
wr_seat_ok "$SEAT" || { echo "unknown seat '$SEAT' (seats: $SEATS)" >&2; exit 2; }
R=(); [ -n "$REPO" ] && R=(--repo "$REPO")
RECEIPT="$W/receipts/watch_${PR}_$(date +%Y%m%d_%H%M%S)_$$.md"; mkdir -p "$W/receipts"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/pr-watch.XXXXXX") || { echo "could not make a temp dir" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT

# judge FILE: reads one response; prints the verdict (GREEN, STOP, WAIT or UNREADABLE) and a one-line reason, and writes the
# receipt section for THIS response to $TMPD/look.body (nothing for UNREADABLE). Every row is judged; no map keyed by name.
judge() {
  REQUIRE="$REQUIRE" python3 -c '
import json, os, re, sys
src, bodyf, pinned = sys.argv[1], sys.argv[2], sys.argv[3]
req = [r for r in os.environ.get("REQUIRE", "").split("\n") if r]
GREEN = ("SUCCESS", "NEUTRAL", "SKIPPED")
def clean(x): return str(x).replace("\n", " ").replace("\r", " ")
def out(v, why): print(v); print(clean(why)); sys.exit(0)
try:
    d = json.load(open(src))
except Exception:
    out("UNREADABLE", "the PR data could not be parsed")
if not isinstance(d, dict): out("UNREADABLE", "the PR data is not an object")
state, head, rows = d.get("state"), d.get("headRefOid"), d.get("statusCheckRollup")
if state not in ("OPEN", "CLOSED", "MERGED"): out("UNREADABLE", "the PR data has no usable state")
items = []   # (name, result text, workflow text, verdict g/p/b/u)
if isinstance(rows, list):
    for c in rows:
        if not isinstance(c, dict): items.append(("not reported", "not reported", "not reported", "u")); continue
        wf = c.get("workflowName"); wf = clean(wf) if isinstance(wf, str) and wf else "not reported"
        if "state" in c and "status" not in c:                      # legacy status context
            name, st = c.get("context"), c.get("state")
            v = "u" if not isinstance(st, str) or not st else ("g" if st == "SUCCESS" else ("p" if st in ("PENDING", "EXPECTED") else "b"))
            res = st if isinstance(st, str) and st else "not reported"
        else:                                                       # check run
            name, status, concl = c.get("name"), c.get("status"), c.get("conclusion")
            if not isinstance(status, str) or not status: v, res = "u", "not reported"
            elif status != "COMPLETED": v, res = "p", status
            elif not isinstance(concl, str) or not concl: v, res = "u", "not reported"
            else: v, res = ("g" if concl in GREEN else "b"), concl
        if not isinstance(name, str) or not name: name, v = "not reported", "u"
        items.append((clean(name), clean(res), wf, v))
url = d.get("url"); m = re.match(r"https?://[^/]+/([^/]+/[^/]+)/pull/", url) if isinstance(url, str) else None
base = d.get("baseRefName")
def body():
    L = ["- repo (as GitHub reported it): " + (m.group(1) if m else "not reported"),
         "- base branch (as GitHub reported it): " + (clean(base) if isinstance(base, str) and base else "not reported"),
         "- PR state: " + state,
         "- pinned head: " + pinned,
         "- observed head: " + (clean(head) if isinstance(head, str) and head else "not reported"),
         "- required names: " + (", ".join(req) if req else "none")]
    if isinstance(rows, list):
        L.append("- checks (name · result · workflow):" + ("" if items else " none reported"))
        L += ["  - %s · %s · %s" % (n, r, w) for n, r, w, _ in items]
    else:
        L.append("- checks: not reported")
    open(bodyf, "w").write("\n".join(L) + "\n")
if state == "MERGED": body(); out("STOP", "merged outside this tool")
if state == "CLOSED": body(); out("STOP", "the PR is closed")
if not isinstance(head, str) or not head: out("UNREADABLE", "the PR data has no head")
if not isinstance(rows, list): out("UNREADABLE", "the PR data has no checks list")
if head != pinned: body(); out("STOP", "the head is %s, not the pinned %s" % (head[:12], pinned[:12]))
bad = sum(1 for i in items if i[3] == "b"); unk = sum(1 for i in items if i[3] == "u")
if bad: body(); out("STOP", "%d check(s) finished without a green result" % bad)
if unk: out("UNREADABLE", "%d check row(s) lack a field the verdict needs" % unk)
pend = sum(1 for i in items if i[3] == "p"); seen = set(i[0] for i in items)
miss = [r for r in req if r not in seen]
if pend or not items or miss:
    body(); out("WAIT", "waiting: %d pending, %d total%s" % (pend, len(items), (", required not seen: " + ", ".join(miss)) if miss else ""))
body(); out("GREEN", "every check green")
' "$1" "$TMPD/look.body" "$HEAD"
}

# finish RESULT REASON: write the receipt, then the board line. Both must succeed, or the run ends 1 with no green line.
finish() {
  _res=$1; _why=$2; _t=$(date +%H:%M); _rc=0
  { echo "# watch receipt PR $PR"
    echo "- result: WATCH $_res"
    echo "- reason: $_why"
    echo "- status: observed, not a gate (this tool did not merge or modify the PR)"
    echo "- written: $(date '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$CUR_TIME" ] && [ -s "$TMPD/cur.body" ]; then
      echo "- observed at: $CUR_TIME (the response that produced this result)"; cat "$TMPD/cur.body"
    else
      echo "- pinned head: $HEAD"; echo "- required names: $([ -n "$REQUIRE" ] && printf '%s' "$REQUIRE" | tr '\n' ',' || echo none)"
      echo "- current fields: unavailable ($CUR_WHY)"
      if [ -n "$PREV_TIME" ] && [ -s "$TMPD/prev.body" ]; then echo "- earlier evidence, observed at $PREV_TIME, not current:"; sed 's/^/  /' "$TMPD/prev.body"; fi
    fi
    echo
    echo "The returned PR data showed the checks above at the time above. This tool did not merge or modify the PR. Whether a merge can skip these checks is decided by the branch protection on the base branch, which this tool does not read."
  } > "$RECEIPT" || { echo "could not write the receipt $RECEIPT" >&2; _rc=1; }
  if [ "$_rc" = 0 ]; then
    if [ "$_res" = GREEN ]; then _line="WATCH GREEN PR $PR at ${HEAD:0:12}: the PR data returned at $_t showed every check green (observed, not a gate; this tool did not merge or modify the PR) (receipt $RECEIPT)"
    else _line="WATCH FAIL PR $PR: $_why (receipt $RECEIPT)"; fi
    "$HERE/board.sh" post "$SEAT" "$_line" >/dev/null || { echo "could not post the result to the board" >&2; _rc=1; }
  else
    "$HERE/board.sh" post "$SEAT" "WATCH FAIL PR $PR: the receipt could not be written ($_why)" >/dev/null 2>&1
  fi
  [ "$_res" = GREEN ] && [ "$_rc" = 0 ] && exit 0
  exit 1; }

CUR_TIME=""; CUR_WHY="no look yet"; PREV_TIME=""
end=$(( $(date +%s) + TIMEOUT ))
while :; do
  rm -f "$TMPD/look.body"
  if gh pr view "$PR" "${R[@]}" --json state,headRefOid,baseRefName,url,statusCheckRollup > "$TMPD/look.json" 2>/dev/null; then
    OBS=$(date +%H:%M:%S)
    { read -r V; read -r WHY; } < <(judge "$TMPD/look.json")
    [ -n "${V:-}" ] || { V=UNREADABLE; WHY="the PR data could not be judged"; }
  else
    OBS=$(date +%H:%M:%S); V=UNREADABLE; WHY="gh could not read the PR"
  fi
  if [ -s "$TMPD/look.body" ]; then
    cp "$TMPD/look.body" "$TMPD/cur.body"; cp "$TMPD/look.body" "$TMPD/prev.body"; CUR_TIME=$OBS; PREV_TIME=$OBS; CUR_WHY=""
  else
    : > "$TMPD/cur.body"; CUR_TIME=""; CUR_WHY="$WHY at $OBS"
  fi
  case "$V" in
    GREEN) finish GREEN "$WHY" ;;
    STOP)  finish FAIL "$WHY" ;;
  esac
  [ "$(date +%s)" -ge "$end" ] && finish FAIL "timed out waiting for the checks to settle ($WHY)"
  sleep "$POLL"
done
