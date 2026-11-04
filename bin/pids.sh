#!/usr/bin/env bash
# pids.sh — the long-job ledger: label, pid, owner, start time. A job that ends makes the checker post a wake to its owner.
#   pids.sh add LABEL PID OWNER     register a job (PID must be a positive number and alive, its start time must be readable,
#                                   OWNER must be a seat); a label already there is replaced
#   pids.sh done LABEL              remove the row WITHOUT waking anyone: use it only after the job has posted its own receipt
#   pids.sh list                    print the ledger
#   pids.sh check                   for every row whose job is gone: post "@OWNER ACTION:", then drop the row
# The waiter runs "check" on every poll, so no extra daemon is needed. The checker posts before it drops a row; if the
# post fails the row stays and the next check tries again. A crash between the post and the drop can post the wake twice.
# A ledger write that fails (disk full, no permission) leaves the old ledger untouched and the command exits non-zero:
# a job may then be missing from the ledger or a wake may repeat, and nothing here makes a crash or a full disk safe.
# A job counts as gone when its pid is dead or the pid now belongs to a process that started at a different time (a
# reused pid); a row without a recorded start time (an old ledger) is judged by pid alone. Limit: one machine.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
P="$W/pids.tsv"; touch "$P" || { echo "cannot write the ledger $P" >&2; exit 1; }; TAB="$(printf '\t')"
started() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //'; }   # start time of a pid, "" if none
alive() { # alive PID STARTED: the pid exists and, when a start time was recorded, is still the same process
  case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$((10#$1))" -gt 0 ] 2>/dev/null || return 1   # pid 0 would signal a whole group
  kill -0 "$1" 2>/dev/null || return 1
  [ -z "$2" ] || [ "$(started "$1")" = "$2" ]
}
case "${1:-}" in
  add)
    l=${2:?label}; p=${3:?pid}; o=${4:?owner}
    wr_seat_ok "$o" || { echo "owner must be one of: $SEATS" >&2; exit 2; }
    case "$p" in ''|*[!0-9]*|?????????????*) echo "pid must be a positive number" >&2; exit 2 ;; esac
    [ "$((10#$p))" -gt 0 ] || { echo "pid must be a positive number" >&2; exit 2; }
    case "$l" in ''|*[!A-Za-z0-9._:-]*) echo "label may hold only letters, digits, '.', '_', ':' and '-'" >&2; exit 2 ;; esac
    kill -0 "$p" 2>/dev/null || { echo "pid $p is not alive" >&2; exit 2; }
    s=$(started "$p")
    [ -n "$s" ] || { echo "cannot read the start time of pid $p (ps failed), so a reused pid could not be told apart: not registered" >&2; exit 2; }
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }          # drop the old row and add the new one in ONE step
    if awk -F'\t' -v l="$l" '$1!=l' "$P" > "$P.tmp.$$" && printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$P.tmp.$$" && mv "$P.tmp.$$" "$P"; then
      wr_unlock "$P"; echo "registered $l $p $o"
    else
      rm -f "$P.tmp.$$"; wr_unlock "$P"; echo "could not write the ledger $P: $l NOT registered, ledger unchanged" >&2; exit 1
    fi ;;
  done)
    l=${2:?label}
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }
    if awk -F'\t' -v l="$l" '$1!=l' "$P" > "$P.tmp.$$" && mv "$P.tmp.$$" "$P"; then
      wr_unlock "$P"; echo "removed $l"
    else
      rm -f "$P.tmp.$$"; wr_unlock "$P"; echo "could not write the ledger $P: $l NOT removed, ledger unchanged" >&2; exit 1
    fi ;;
  list) cat "$P" ;;
  check)
    # Every waiter runs this on every poll, so two seats can check at the same moment. The whole check runs under the
    # ledger lock: only one caller sees a dead row, posts its wake, then drops it.
    keep="$P.tmp.$$"; bad=0
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }
    : > "$keep" || bad=1
    while IFS="$TAB" read -r l p o s; do
      [ -n "$l" ] || continue
      if alive "$p" "$s"; then
        printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep" || bad=1
      elif wr_run "$HERE/board.sh" post GUARD "@$o ACTION: job '$l' (pid $p) is no longer running. Read its receipt, then continue or restart it." </dev/null >/dev/null; then   # wr_run: the post holds no copy of the ledger lock; its stderr is kept
        :                             # delivered: the row is dropped
      else
        printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep" || bad=1     # not delivered: keep it, the next check tries again
      fi
    done < "$P"
    # a failed write to the new ledger means it is incomplete: keep the old one (a wake may then repeat) and say so
    if [ "$bad" = 0 ] && mv "$keep" "$P"; then wr_unlock "$P"
    else rm -f "$keep"; wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; fi ;;
  -h|--help|help|"") sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command (add|done|list|check|--help)" >&2; exit 2 ;;
esac
