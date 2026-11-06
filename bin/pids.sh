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
case $0 in */*) _d=${0%/*}; [ -n "$_d" ] || _d=/ ;; *) _d=. ;; esac
HERE=$(cd -P -- "$_d" && pwd) || exit 1
. "$HERE/_common.sh" || exit 1
# a row of the ledger that cannot be split: nothing is posted or dropped (keep is the temp of the new ledger, P the ledger)
ledgerfail() { wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: could not split a row of the job ledger; ledger unchanged" >&2; exit 1; }
P="$W/pids.tsv"; wr_create "$P" || { echo "cannot write the ledger $P" >&2; exit 1; }
# check_row ROW: judge one ledger row (the raw line, split here) for the checker. Every row goes into the new ledger (keep)
# first, byte for byte as it was read (an old three-column row does not gain a column). A
# live job keeps its row; one that cannot be told apart from a reused pid keeps it too and is said (unk); a dead one posts to
# its owner, and a delivered post records the row's line number in gone so that ONE filter after the loop drops it. A post
# that fails is said and the row simply stays (return 1: the loop goes on with the next row, the next check tries again).
# It leaves the script (exit 1, ledger unchanged) when a process cannot be judged.
check_row() {
  rl=$(wr_col 1 "$1") || ledgerfail
  rp=$(wr_col 2 "$1") || ledgerfail
  ro=$(wr_col 3 "$1") || ledgerfail
  rs=$(wr_col 4 "$1") || ledgerfail
  [ -n "$rl" ] || return 0
  st=$(wr_proc "$rp" "$rs") || { wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: could not judge pid $rp (job '$rl'); ledger unchanged" >&2; exit 1; }
  printf '%s\n' "$1" >> "$keep" || bad=1
  nrow=$((nrow + 1))
  case "$st" in
    alive) ;;
    unknown)          # cannot tell a live job from a reused pid: keep the row, say so, look again
      echo "pids.sh: cannot read the start time of pid $rp (job '$rl'): ps failed, so a live job cannot be told from a reused pid; row kept" >&2; unk=1 ;;
    dead)
      if wr_run "$HERE/board.sh" post GUARD "@$ro ACTION: job '$rl' (pid $rp) is no longer running. Read its receipt, then continue or restart it." </dev/null >/dev/null; then
        gone="$gone $nrow"            # delivered: the row is dropped by the filter after the loop
      else
        echo "pids.sh: could not post the wake for job '$rl' (pid $rp); row kept, the next check tries again" >&2; return 1
      fi ;;
    *) wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: unexpected answer '$st' for pid $rp (job '$rl'); ledger unchanged" >&2; exit 1 ;;
  esac
  return 0
}
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
    bad=0; unk=0; nrow=0; gone=""
    wr_lock "$P" || { echo "pids.sh: could not lock the job ledger; nothing changed" >&2; exit 1; }
    # the new ledger is built in a temp this call made (keep); without one nothing is posted or dropped
    wr_temp "$P" || { wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; }
    keep=$_WR_TMP
    # the whole ledger is read first and judged from that copy: a read that fails, at the start or after some rows, posts nothing
    # and removes nothing
    rows=$(wr_registry_read "$P") || { wr_drop "$keep"; wr_unlock "$P"; echo "pids.sh: the job ledger $P could not be read; nothing changed" >&2; exit 1; }
    while IFS= read -r row; do check_row "$row" || continue; done <<< "$rows"
    # a failed write to the new ledger means it is incomplete: keep the old one (a wake may then repeat) and say so
    if [ "$bad" != 0 ]; then wr_drop "$keep"; wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; fi
    # nothing was delivered: the ledger is not rewritten at all (its bytes stay exactly as they were)
    if [ -z "$gone" ]; then wr_drop "$keep"; wr_unlock "$P"; [ "$unk" = 0 ] || exit 3; exit 0; fi
    # rows whose wake was delivered are dropped by ONE filter over the new ledger; a failure here keeps the old ledger (the wakes
    # may then repeat once)
    wr_temp "$P" || { wr_drop "$keep"; wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; }
    fil=$_WR_TMP
    awk -v gone="$gone" 'BEGIN { n = split(gone, a, " "); for (i = 1; i <= n; i++) g[a[i]] = 1 } !(NR in g)' "$keep" > "$fil" \
      || { wr_drop "$keep"; wr_drop "$fil"; wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; }
    wr_drop "$keep"; keep=$fil
    if wr_replace "$keep" "$P"; then wr_unlock "$P"; [ "$unk" = 0 ] || exit 3
    else wr_drop "$keep"; wr_unlock "$P"; echo "could not write the ledger $P: ledger unchanged" >&2; exit 1; fi ;;
  -h|--help|help|"") sed -n -- '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command (add|done|list|check|--help)" >&2; exit 2 ;;
esac
