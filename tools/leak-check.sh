#!/usr/bin/env bash
# leak-check.sh — fail if the tree contains something that must not be public.
#   tools/leak-check.sh [DIR]            check DIR (default: the repo root)
# Built-in patterns (always on): home-directory paths, e-mail addresses other than example.com, 40-character hex ids,
# token shapes, and numbered seat names like T9.
# Private patterns (optional): set LEAKCHECK_DENYLIST to a file of extended regular expressions, one per line
# (# comments and blank lines ignored). Keep that file OUT of this repository: it holds the names you are protecting.
# In CI, store its contents as a repository secret and write it to a file before this step.
# It also fails when the tree holds a file or folder named like the run directory's state (board.md, pids.tsv, cards/,
# receipts/, .cursor-* ...): keep WARROOM_DIR outside the clone, because .gitignore only knows the default names.
# Coverage is bounded: text files only (grep -I), a short fixed list of shapes plus your private patterns, no git history.
# A clean run means those patterns were not found in those files, not that the tree is safe to publish.
# Output names the file, line and pattern number only, never the matching text.
# Exit 0 = clean, 1 = hits, 2 = usage error or a scan that could not complete (bad pattern, unreadable file).
case "${1:-}" in -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
export LC_ALL=C
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
[ -d "$ROOT" ] || { echo "no such directory: $ROOT" >&2; exit 2; }
PATS=$(mktemp); trap 'rm -f "$PATS"' EXIT
cat > "$PATS" <<'EOP'
/(Users|home)/[a-z][a-z0-9._-]{1,30}/
[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|net|org|io|dev|ai|co|me|app)
\b[0-9a-f]{40}\b
\bgh[pousr]_[A-Za-z0-9]{20,}
\bsk-[A-Za-z0-9_-]{20,}
\bAKIA[0-9A-Z]{16}\b
\bT[0-9]{1,2}[A-Z]?\b
EOP
if [ -n "${LEAKCHECK_DENYLIST:-}" ]; then
  [ -f "$LEAKCHECK_DENYLIST" ] || { echo "LEAKCHECK_DENYLIST is not a file" >&2; exit 2; }
  grep -vE '^[[:space:]]*(#|$)' "$LEAKCHECK_DENYLIST" >> "$PATS"
fi
total=$(grep -c . "$PATS"); hits=0; i=0; errs=0
ERR=$(mktemp); trap 'rm -f "$PATS" "$ERR"' EXIT
while IFS= read -r pat; do
  i=$((i+1))
  # grep exits 0 = matches, 1 = none, 2+ = error (bad pattern, unreadable file): an error must never count as clean
  raw=$(grep -rnIoE --exclude-dir=.git --exclude=leak-check.sh -e "$pat" "$ROOT" 2>"$ERR"); rc=$?
  if [ "$rc" -ge 2 ]; then echo "ERROR pattern $i/$total  the scan did not complete (grep exit $rc)"; errs=$((errs+1)); fi
  # allowed: example.com addresses, and the word CONTRACT inside the standard MIT text of LICENSE
  out=$(printf '%s\n' "$raw" | grep -vE -e '^$' -e ':[^:]*@example\.com$' -e '/LICENSE:[0-9]+:CONTRACT$' | cut -d: -f1,2 || true)
  if [ -n "$out" ]; then
    while IFS= read -r l; do echo "HIT pattern $i/$total  ${l#$ROOT/}"; hits=$((hits+1)); done <<EOO
$out
EOO
  fi
done < "$PATS"
# state files of a run directory that ended up inside the tree
state=$(find "$ROOT" -path "$ROOT/.git" -prune -o \( -name board.md -o -name pids.tsv -o -name seats.tsv -o -name warroom.env \
  -o -name '.cursor-*' -o -name '.lastwake-*' -o -name '.anchor-*' \
  -o -name '.guard-*' -o -name receipts -o -name cards -o -name '*.lock' -o -name '*.flock' \) -print 2>"$ERR"); rc=$?
if [ "$rc" -ne 0 ]; then echo "ERROR state-file scan did not complete"; errs=$((errs+1)); fi
if [ -n "$state" ]; then
  while IFS= read -r l; do echo "HIT run-state file  ${l#$ROOT/}"; hits=$((hits+1)); done <<EOO
$state
EOO
fi
if [ "$errs" -gt 0 ]; then echo "leak-check: $errs scan error(s); the result is NOT clean"; exit 2; fi
if [ "$hits" -gt 0 ]; then echo "leak-check: $hits hit(s)"; exit 1; fi
echo "leak-check: 0 hits ($total patterns, $(find "$ROOT" -type f -not -path '*/.git/*' | wc -l | tr -d ' ') files)"
