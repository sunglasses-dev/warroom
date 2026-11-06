#!/usr/bin/env bash
# pids.sh — the long-job ledger: label, pid, owner, start time. A job that ends makes the checker post a wake to its owner.
#   pids.sh add LABEL PID OWNER     register a job (PID must be a positive number and alive, its start time must be readable,
#                                   OWNER must be a seat); a label already there is replaced
#   pids.sh done LABEL              remove the row WITHOUT waking anyone: use it only after the job has posted its own receipt
#   pids.sh list                    print the ledger
#   pids.sh check                   for every row whose job is gone: post "@OWNER ACTION:", then drop the row
#                                   (exit 3: every row was handled, but at least one job's identity could not be read)
# The waiter runs "check" on every poll, so no extra daemon is needed. The checker posts before it drops a row; if the
# post fails the row stays and the next check tries again. A crash between the post and the drop can post the wake twice.
# A ledger write that fails (disk full, no permission) leaves the old ledger untouched and the command exits non-zero:
# a job may then be missing from the ledger or a wake may repeat, and nothing here makes a crash or a full disk safe.
# A job counts as gone when its pid is dead or the pid now belongs to a process that started at a different time (a
# reused pid); a row without a recorded start time (an old ledger) is judged by pid alone. When the pid exists but its
# start time cannot be read (ps failed), the job is neither: its row is kept, the check says so on stderr and exits 3,
# and the next check looks again. Start times have a resolution of one second. Limit: one machine.
case $0 in */*) _d=${0%/*} ;; *) _d=. ;; esac
HERE=$(cd -P "$_d" && pwd) || exit 1
. "$HERE/_common.sh" || exit 1
P="$W/pids.tsv"; wr_create "$P" || { echo "cannot write the ledger $P" >&2; exit 1; }; TAB="$(printf '\t')"
case "${1:-}" in
  add)
    l=${2:?label}; p=${3:?pid}; o=${4:?owner}
    wr_seat_ok "$o" || { echo "owner must be one of: $SEATS" >&2; exit 2; }
    case "$p" in ''|*[!0-9]*|?????????????*) echo "pid must be a positive number" >&2; exit 2 ;; esac
    [ "$((10#$p))" -gt 0 ] || { echo "pid must be a positive number" >&2; exit 2; }
    case "$l" in ''|*[!A-Za-z0-9._:-]*) echo "label may hold only letters, digits, '.', '_', ':' and '-'" >&2; exit 2 ;; esac
    kill -0 "$p" 2>/dev/null || { echo "pid $p is not alive" >&2; exit 2; }
    s=$(wr_started "$p") || { echo "cannot read the start time of pid $p (ps failed), so a reused pid could not be told apart: not registered" >&2; exit 2; }
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }          # drop the old row and add the new one in ONE step
    wr_temp "$P" || { wr_unlock "$P"; echo "could not write the ledger $P: $l NOT registered, ledger unchanged" >&2; exit 1; }
    led_t=$_WR_TMP
    awk -F'\t' -v l="$l" '$1!=l' "$P" > "$led_t" || { wr_drop "$led_t"; wr_unlock "$P"; echo "could not read or write the ledger $P: $l NOT registered, ledger unchanged" >&2; exit 1; }
    printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$led_t" || { wr_drop "$led_t"; wr_unlock "$P"; echo "could not write the ledger $P: $l NOT registered, ledger unchanged" >&2; exit 1; }
    wr_replace "$led_t" "$P" || { wr_drop "$led_t"; wr_unlock "$P"; echo "could not write the ledger $P: $l NOT registered, ledger unchanged" >&2; exit 1; }
    wr_unlock "$P"; echo "registered $l $p $o" ;;
  done)
    l=${2:?label}
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }
    wr_temp "$P" || { wr_unlock "$P"; echo "could not write the ledger $P: $l NOT removed, ledger unchanged" >&2; exit 1; }
    led_t=$_WR_TMP
    awk -F'\t' -v l="$l" '$1!=l' "$P" > "$led_t" || { wr_drop "$led_t"; wr_unlock "$P"; echo "could not read or write the ledger $P: $l NOT removed, ledger unchanged" >&2; exit 1; }
    wr_replace "$led_t" "$P" || { wr_drop "$led_t"; wr_unlock "$P"; echo "could not write the ledger $P: $l NOT removed, ledger unchanged" >&2; exit 1; }
    wr_unlock "$P"; echo "removed $l" ;;
  list) cat "$P" ;;
  check)
    # Every waiter runs this on every poll, so two seats can check at the same moment. The whole check runs under the
    # ledger lock: only one caller sees a dead row, posts its wake, then drops it.
    bad=0; unk=0
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }
    # the new ledger is built in a temp this call made (keep); without one nothing is posted or dropped
    wr_temp "$P" || { wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; }
    keep=$_WR_TMP
    # the whole ledger is read first and judged from that copy: a read that fails, at the start or after some rows, posts nothing
    # and removes nothing
    rows=$(wr_registry_read "$P") || { wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: the job ledger $P could not be read; nothing changed" >&2; exit 1; }
    while IFS="$TAB" read -r l p o s; do
      [ -n "$l" ] || continue
      st=$(wr_proc "$p" "$s") || { wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: could not judge pid $p (job '$l'); ledger unchanged" >&2; exit 1; }
      case "$st" in
        alive) printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep" || bad=1 ;;
        unknown)          # cannot tell a live job from a reused pid: keep the row, say so, look again
          printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep" || bad=1
          echo "pids.sh: cannot read the start time of pid $p (job '$l'): ps failed, so a live job cannot be told from a reused pid; row kept" >&2; unk=1 ;;
        dead)
          if wr_run "$HERE/board.sh" post GUARD "@$o ACTION: job '$l' (pid $p) is no longer running. Read its receipt, then continue or restart it." </dev/null >/dev/null; then   # wr_run: the post holds no copy of the ledger lock; its stderr is kept
            :                             # delivered: the row is dropped
          else
            printf '%s\t%s\t%s\t%s\n' "$l" "$p" "$o" "$s" >> "$keep" || bad=1     # not delivered: keep it, the next check tries again
          fi ;;
        *) wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: unexpected answer '$st' for pid $p (job '$l'); ledger unchanged" >&2; exit 1 ;;
      esac
    done <<< "$rows"
    # a failed write to the new ledger means it is incomplete: keep the old one (a wake may then repeat) and say so
    if [ "$bad" = 0 ] && wr_replace "$keep" "$P"; then wr_unlock "$P"; [ "$unk" = 0 ] || exit 3
    else wr_drop "$keep"; wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; fi ;;
  -h|--help|help|"") sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command (add|done|list|check|--help)" >&2; exit 2 ;;
esac
