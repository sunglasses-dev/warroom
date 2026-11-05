#!/usr/bin/env bash
# waiter.sh SEAT SESSION_ID — the mention waiter. Run it as a background job from the seat's own session.
# It sleeps (no model calls, no tokens) and exits the moment a NEW board post is addressed to the seat. A post wakes a seat
# only when its FIRST line, right after the "[HH:MM · AUTHOR]" stamp, starts with "@SEAT ACTION:" or "@ALL ACTION:" and
# the author is not the seat itself. Prose, "ACTIONABLE", a quoted directive and any later line of a post wake nobody.
# The exit is the wake: the session that started the job is told the job finished and sees the line. Re-arm after every wake.
# SEAT=NONE opts a session out. One live session per seat: arming a taken seat is refused (exit 1). SESSION_ID is required.
# "Live" means the registered waiter process itself (pid and start time), so a reused pid never holds a seat.
# A waiter replaced by a newer arm of the same seat stops with exit 3, so that is never mistaken for a wake (exit 0).
# Position: the last wake is saved in $WARROOM_DIR/.cursor-SEAT with the board's inode, its first line and the last line
# read. A re-arm within WARROOM_CURSOR_MAX_AGE seconds (86400) resumes there, also across midnight; a replaced board, a
# shorter one, or one whose line at that position changed (emptied in place and refilled) is read again from its start.
# The FIRST arm, or one after that age, starts at the end of the board and sees only what follows.
# Rotate a board by moving it away (a new file starts); see bin/_cursor.sh for what is and is not noticed.
# Tuning (warroom.env): WARROOM_POLL seconds between checks (5), WARROOM_MIN_GAP seconds between two wakes (60).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"; . "$HERE/_cursor.sh"
case "${1:-}" in -h|--help|help|"") sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
SEAT=$1; SID=${2:-}; POLL=${WARROOM_POLL:-5}; GAP=${WARROOM_MIN_GAP:-60}; AGE=${WARROOM_CURSOR_MAX_AGE:-86400}
REG="$W/seats.tsv"; TAB="$(printf '\t')"
[ "$SEAT" = NONE ] || wr_seat_arg "$SEAT" ", or NONE"        # before the registry is created or any per-seat path is built
case "$SID" in ''|unknown) echo "a session id is required: waiter.sh SEAT SESSION_ID (see README, quick start)" >&2; exit 2 ;; esac
case "$SID" in *[!A-Za-z0-9._-]*) echo "the session id may hold only letters, digits, '.', '_' and '-'" >&2; exit 2 ;; esac
wr_create "$REG" || { echo "cannot create the seat registry $REG" >&2; exit 1; }
CUR="$W/.cursor-$SEAT"; LAST="$W/.lastwake-$SEAT"
# No row without an identity: the waiter's own start time must be readable before it takes anything. Without it a row could
# only be judged by its pid, and a reused pid would then look like a live waiter.
START=$(wr_started $$) || { echo "cannot read the start time of this waiter (pid $$; ps failed), so its seat row could not be told from a reused pid: not armed. Try again." >&2; exit 1; }
# Arming (take the seat, read the saved position) and delivering a wake both run under the seat's cursor lock, so a
# waiter that is being replaced can never deliver after its replacement has taken over: exactly one of them delivers.
# Lock order is always the cursor lock, then the registry lock.
if [ "$SEAT" != NONE ]; then wr_lock "$CUR" || { echo "could not lock the cursor of seat $SEAT" >&2; exit 1; }; fi
# Look at the holder and take the seat under ONE lock, so two arms at the same moment cannot both win.
wr_lock "$REG" || { [ "$SEAT" = NONE ] || wr_unlock "$CUR"; echo "could not lock the seat registry" >&2; exit 1; }
# Every state write is checked: when one fails the waiter says so and exits 1 without arming, and the file it was writing
# is as it was (a temp made by this arm, then a rename; only that temp is removed, and one that cannot be removed is reported).
reg_t=""
armfail() { wr_drop "$reg_t"; wr_unlock "$REG"; [ "$SEAT" = NONE ] || wr_unlock "$CUR"; echo "$1" >&2; exit 1; }
if [ "$SEAT" != NONE ]; then
  # a holder is the waiter process the row names: same pid AND same start time (column 5), so a stale row whose pid now
  # belongs to an unrelated process does not block the seat. A row with an empty start time (not written by this version)
  # is unknown while its pid lives; only a four-column row from an older version is judged by the pid alone.
  while IFS="$TAB" read -r holder hstart hcols; do
    [ "$hstart" = - ] && hstart=""          # "-" stands for an empty column: read would merge the two tabs
    case "$(wr_rowproc "$holder" "$hstart" "$hcols")" in
      alive) wr_unlock "$REG"; wr_unlock "$CUR"
        echo "REFUSED: seat $SEAT is held by another live session (waiter pid $holder). Arm as NONE, or free the seat first." >&2; exit 1 ;;
      unknown) wr_unlock "$REG"; wr_unlock "$CUR"
        echo "REFUSED: seat $SEAT is held by pid $holder, whose start time is not recorded or cannot be read (ps failed), so it cannot be told from a reused pid. Nothing changed; try again, or free the seat." >&2; exit 1 ;;
    esac
  done < <(awk -F'\t' -v s="$SID" -v seat="$SEAT" 'BEGIN{OFS="\t"} $2==seat && $1!=s {print $3, ($5==""?"-":$5), NF}' "$REG")
  # the position first: it only repeats what the next arm would compute, so a failed registry write after it changes nothing
  gen=$(wr_generation "$BOARD_FILE") || armfail "could not read the board $BOARD_FILE: not armed"
  base=$(wr_lines "$BOARD_FILE") || armfail "could not count the lines of the board $BOARD_FILE: not armed"
  c=$(wr_cursor_get "$CUR" "$BOARD_FILE" "$AGE") || armfail "could not checksum the board $BOARD_FILE: not armed"
  [ "$c" = none ] || base=$c
  lastck=$(wr_prefixsum "$BOARD_FILE" "$base") || armfail "could not checksum the board $BOARD_FILE: not armed"
  wr_cursor_put "$CUR" "$gen" "$base" "$lastck" || armfail "could not save the position of seat $SEAT ($CUR): not armed. Is $W writable and not full?"
fi
wr_temp "$REG" || armfail "could not create a temporary file next to the seat registry: not armed"
reg_t=$_WR_TMP
if [ "$SEAT" != NONE ]; then
  # a real seat replaces this session's old row and any other row of the seat
  awk -F'\t' -v s="$SID" -v seat="$SEAT" '$1!=s && $2!=seat' "$REG" > "$reg_t" || armfail "could not write the seat registry: not armed"
else
  # NONE is a shared marker, not a seat: replace only this session's own row, never another session's opt-out
  awk -F'\t' -v s="$SID" '$1!=s' "$REG" > "$reg_t" || armfail "could not write the seat registry: not armed"
fi
# row: session, seat, waiter pid, armed at, waiter start time (never empty: see START above)
printf '%s\t%s\t%s\t%s\t%s\n' "$SID" "$SEAT" "$$" "$(wr_now)" "$START" >> "$reg_t" && wr_replace "$reg_t" "$REG" || armfail "could not update the seat registry $REG: not armed"
wr_unlock "$REG"
[ "$SEAT" = NONE ] && { echo "this session opted out of board triggers"; exit 0; }
wr_unlock "$CUR"
echo "armed $SEAT pid $$ at line $base $(date +%H:%M:%S)" >&2
# the posts that wake this seat: stamped first line, literal "@SEAT ACTION:" or "@ALL ACTION:", author not the seat
filter() {
  awk -v seat="$SEAT" '
    match($0, /^\[[0-9][0-9]:[0-9][0-9] · [^]]+\] /) {
      head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      author = head; sub(/^\[[0-9][0-9]:[0-9][0-9] · /, "", author); sub(/\] $/, "", author)
      if (author != seat && (index(rest, "@" seat " ACTION:") == 1 || index(rest, "@ALL ACTION:") == 1)) print
    }'
}
mine()     { grep -q "${TAB}${SEAT}${TAB}$$${TAB}" "$REG" 2>/dev/null; }    # still the seat's waiter?
replaced() { echo "[WAITER REPLACED] a newer waiter holds seat $SEAT; this one stops (exit 3). It is not a wake." >&2; exit 3; }
# the two scratch files of one poll are temps this waiter made (snap_t, chunk_t): removed after each poll and at exit; a temp
# that cannot be removed is reported with its path
snap_t=""; chunk_t=""; trap 'wr_drop "$chunk_t"; wr_drop "$snap_t"' EXIT
pend=""
while :; do
  sleep "$POLL"
  mine || replaced
  "$HERE/pids.sh" check >/dev/null || true      # stdout dropped, stderr kept: a ledger lock failure is shown
  g2=$(wr_generation "$BOARD_FILE") || { echo "[WAITER] could not read the board $BOARD_FILE; nothing consumed, will look again" >&2; continue; }
  n=$(wr_lines "$BOARD_FILE") || { echo "[WAITER] could not count the lines of the board $BOARD_FILE; nothing consumed, will look again" >&2; continue; }
  # board replaced, shorter, or changed anywhere in the part already read: read it from the start. A sum that cannot be
  # computed consumes nothing: the checkpoint stays and the next poll tries again.
  pk=""; if [ "$base" -gt 0 ]; then pk=$(wr_prefixsum "$BOARD_FILE" "$base") || { echo "[WAITER] could not checksum the board in $W; nothing consumed, will look again" >&2; continue; }; fi
  if [ "$g2" != "$gen" ] || [ "$n" -lt "$base" ] || { [ "$base" -gt 0 ] && [ "$pk" != "$lastck" ]; }; then base=0; gen=$g2; fi
  if [ "$n" -gt "$base" ]; then
    # one read: the new lines and the sum of everything read come from the same bytes. The checkpoint (lastck, base) moves only
    # after the snapshot, the sum and the filter all succeeded; if any of them fails nothing is consumed and the next poll tries again.
    snap_t=""; chunk_t=""
    if wr_temp "$CUR"; then
      snap_t=$_WR_TMP
      if wr_temp "$CUR"; then chunk_t=$_WR_TMP; else wr_drop "$snap_t"; snap_t=""; fi
    fi
    if [ -z "$chunk_t" ] || ! { head -n "$n" "$BOARD_FILE" > "$snap_t" && lastck_new=$(wr_sumstdin < "$snap_t") && tail -n "$((n-base))" "$snap_t" > "$chunk_t" && new=$(filter < "$chunk_t"); }; then
      wr_drop "$chunk_t"; wr_drop "$snap_t"; snap_t=""; chunk_t=""
      echo "[WAITER] could not write a scratch file or read the board in $W (full or read-only?); nothing consumed, will look again" >&2; continue
    fi
    wr_drop "$chunk_t"; wr_drop "$snap_t"; snap_t=""; chunk_t=""
    lastck=$lastck_new
    base=$n
    [ -n "$new" ] && pend="${pend:+$pend
}$new"
  fi
  if [ -n "$pend" ]; then
    # loop guard: held, not lost. The held lines are delivered once the gap has passed.
    if [ -e "$LAST" ] && [ $(( $(date +%s) - $(wr_mtime "$LAST") )) -lt "$GAP" ]; then continue; fi
    # deliver under the cursor lock: still the seat's waiter? gap still closed? then commit position and gap, then print
    wr_lock "$CUR" || continue
    if ! mine; then wr_unlock "$CUR"; replaced; fi
    if [ -e "$LAST" ] && [ $(( $(date +%s) - $(wr_mtime "$LAST") )) -lt "$GAP" ]; then wr_unlock "$CUR"; continue; fi
    # touch, never ": >": LAST only carries a time, and a BOARD configured with the same name must not be emptied (the
    # cursor lock covers the cursor and LAST together). The gap marker goes FIRST and the position LAST: if either cannot
    # be saved the wake is NOT reported as delivered (exit 1, the held lines are printed), and the saved position is still
    # the old one, so the next arm reads the lines again. The other order moved the position and then failed on the marker,
    # which lost the wake.
    if ! { wr_stamp "$LAST" && { wr_cursor_put "$CUR" "$gen" "$base" "$lastck" || { rm -f "$LAST"; false; }; }; }; then   # no marker without a saved position
      wr_unlock "$CUR"
      echo "[WAITER ERROR] could not save the position of seat $SEAT in $W (full or read-only?). The wake below was NOT marked as delivered; re-arm after fixing it and these lines come again." >&2
      printf '%s\n' "$pend"
      exit 1
    fi
    wr_unlock "$CUR"
    echo "[WAKE -> $SEAT] a board line is addressed to you. Act on it, then re-arm: bash $(printf '%q' "$HERE/waiter.sh") $SEAT $SID (as a background job)."
    printf '%s\n' "$pend"
    exit 0
  fi
done
