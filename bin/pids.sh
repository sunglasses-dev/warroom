#!/usr/bin/env bash
# pids.sh — the long-job ledger: label, pid, owner. A job that ends wakes its owner once.
#   pids.sh add LABEL PID OWNER     register a job (PID must be alive, OWNER must be a seat)
#   pids.sh done LABEL              remove the row when the job ends (put it in a trap EXIT)
#   pids.sh list                    print the ledger
#   pids.sh check                   for every row whose pid is gone: post "@OWNER ACTION:" once, drop the row
# The waiter runs "check" on every poll, so no extra daemon is needed.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
P="$W/pids.tsv"; touch "$P"
drop() { # drop the row with label $1 under the lock
  wr_lock "$P" || exit 1
  awk -F'\t' -v l="$1" '$1!=l' "$P" > "$P.tmp.$$" && mv "$P.tmp.$$" "$P"
  wr_unlock "$P"
}
case "${1:-}" in
  add)
    l=${2:?label}; p=${3:?pid}; o=${4:?owner}
    wr_seat_ok "$o" || { echo "owner must be one of: $SEATS" >&2; exit 2; }
    case "$p" in ''|*[!0-9]*) echo "pid must be a number" >&2; exit 2 ;; esac
    kill -0 "$p" 2>/dev/null || { echo "pid $p is not alive" >&2; exit 2; }
    drop "$l"
    wr_lock "$P" || exit 1; printf '%s\t%s\t%s\n' "$l" "$p" "$o" >> "$P"; wr_unlock "$P"
    echo "registered $l $p $o" ;;
  done) l=${2:?label}; drop "$l"; echo "removed $l" ;;
  list) cat "$P" ;;
  check)
    # Every waiter runs this on every poll, so two seats can check at the same moment. The ledger is read and the dead
    # rows are dropped under the lock; only the caller that dropped a row posts its wake, so each dead job wakes once.
    TAB="$(printf '\t')"; dead=""; keep="$P.tmp.$$"
    wr_lock "$P" || exit 1
    : > "$keep"
    while IFS="$TAB" read -r l p o; do
      [ -n "$l" ] || continue
      if kill -0 "$p" 2>/dev/null; then printf '%s\t%s\t%s\n' "$l" "$p" "$o" >> "$keep"
      else dead="$dead$l$TAB$p$TAB$o
"; fi
    done < "$P"
    if [ -n "$dead" ]; then mv "$keep" "$P"; else rm -f "$keep"; fi
    wr_unlock "$P"
    printf '%s' "$dead" | while IFS="$TAB" read -r l p o; do
      [ -n "$l" ] || continue
      "$HERE/board.sh" post GUARD "@$o ACTION: job '$l' (pid $p) is no longer running. Read its receipt, then continue or restart it." >/dev/null
    done ;;
  -h|--help|help|"") sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command (add|done|list|check|--help)" >&2; exit 2 ;;
esac
