#!/usr/bin/env bash
# leak-check.sh — fail if the tree contains something that must not be public.
#   tools/leak-check.sh [DIR]            check DIR (default: the repo root)
# Built-in patterns (always on): home-directory paths, e-mail addresses other than example.com, 40-character hex ids,
# token shapes, and numbered seat names like T9.
# Private patterns (optional): set LEAKCHECK_DENYLIST to a file of extended regular expressions, one per line
# (# comments and blank lines ignored). Keep that file OUT of this repository: it holds the names you are protecting.
# In CI, store its contents as a repository secret and write it to a file before this step.
# Output names the file, line and pattern number only, never the matching text. Exit 0 = clean, 1 = hits, 2 = usage error.
case "${1:-}" in -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
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
total=$(grep -c . "$PATS"); hits=0; i=0
while IFS= read -r pat; do
  i=$((i+1))
  # allowed: example.com addresses, and the word CONTRACT inside the standard MIT text of LICENSE
  out=$(grep -rnIoE --exclude-dir=.git --exclude=leak-check.sh -e "$pat" "$ROOT" 2>/dev/null \
        | grep -vE -e ':[^:]*@example\.com$' -e '/LICENSE:[0-9]+:CONTRACT$' | cut -d: -f1,2 || true)
  if [ -n "$out" ]; then
    while IFS= read -r l; do echo "HIT pattern $i/$total  ${l#$ROOT/}"; hits=$((hits+1)); done <<EOO
$out
EOO
  fi
done < "$PATS"
if [ "$hits" -gt 0 ]; then echo "leak-check: $hits hit(s)"; exit 1; fi
echo "leak-check: 0 hits ($total patterns, $(find "$ROOT" -type f -not -path '*/.git/*' | wc -l | tr -d ' ') files)"
