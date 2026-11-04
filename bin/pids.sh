#!/usr/bin/env bash
# pids.sh — the long-job ledger: label, pid, owner. A job that ends wakes its owner (at least once, never lost).
#   pids.sh add LABEL PID OWNER     register a job (PID must be alive, OWNER must be a seat); a label already there is replaced
#   pids.sh done LABEL              remove the row WITHOUT waking anyone: use it only after the job has posted its own receipt
#   pids.sh list                    print the ledger
#   pids.sh check                   for every row whose job is gone: post "@OWNER ACTION:", then drop the row
# The waiter runs "check" on every poll, so no extra daemon is needed. A row is dropped only after its wake is on the
# board; if the post fails the row stays and the next check tries again. If the process dies between the post and the
# drop, the wake can appear twice, never zero times. A job counts as gone when its pid is dead or the pid now belongs to
# a process that started at a different time (a reused pid). Limit: one machine.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
P="$W/pids.tsv"; touch "$P"; TAB="$(printf '\t')"
started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //'; }   # start time of a pid, "" if none
alive() { # alive PID STARTED: the pid exists and, when a start time was recorded, is still the same process
  kill -0 "$1" 2>/dev/null || return 1
  [ -z "$2" ] || [ "$(started "$1")" = "$2" ]
}
case "${1:-}" in
  add)
    l=${2:?label}; p=${3:?pid}; o=${4:?owner}
    wr_seat_ok "$o" || { echo "owner must be one of: $SEATS" >&2; exit 2; }
    case "$p" in ''|*[!0-9]*) echo "pid must be a number" >&2; exit 2 ;; esac
    case "$l" in ''|*[!A-Za-z0-9._:-]*) echo "label may hold only letters, digits, '.', '_', ':' and '-'" >&2; exit 2 ;; esac
    kill -0 "$p" 2>/dev/null || { echo "pid $p is not alive" >&2; exit 2; }
    s=$(started "$p")
    wr_lock "$P" || exit 1          # drop the old row and add the new one in ONE step
    awk -F'\t' -v l="$l" '$1!=l' "$P" > "$P.tmp.$$"; printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$P.tmp.$$"; mv "$P.tmp.$$" "$P"
    wr_unlock "$P"
    echo "registered $l $p $o" ;;
  done)
    l=${2:?label}
    wr_lock "$P" || exit 1
    awk -F'\t' -v l="$l" '$1!=l' "$P" > "$P.tmp.$$" && mv "$P.tmp.$$" "$P"
    wr_unlock "$P"; echo "removed $l" ;;
  list) cat "$P" ;;
  check)
    # Every waiter runs this on every poll, so two seats can check at the same moment. The whole check runs under the
    # ledger lock: only one caller sees a dead row, posts its wake, then drops it.
    keep="$P.tmp.$$"
    wr_lock "$P" || exit 1
    : > "$keep"
    while IFS="$TAB" read -r l p o s; do
      [ -n "$l" ] || continue
      if alive "$p" "$s"; then
        printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep"
      elif "$HERE/board.sh" post GUARD "@$o ACTION: job '$l' (pid $p) is no longer running. Read its receipt, then continue or restart it." </dev/null >/dev/null 2>&1; then
        :                             # delivered: the row is dropped
      else
        printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep"     # not delivered: keep it, the next check tries again
      fi
    done < "$P"
    mv "$keep" "$P"; wr_unlock "$P" ;;
  -h|--help|help|"") sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command (add|done|list|check|--help)" >&2; exit 2 ;;
esac
