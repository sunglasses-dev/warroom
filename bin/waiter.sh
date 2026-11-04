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
REG="$W/seats.tsv"; touch "$REG"; TAB="$(printf '\t')"
if [ "$SEAT" != NONE ] && ! wr_seat_ok "$SEAT"; then echo "unknown seat '$SEAT' (seats: $SEATS, or NONE)" >&2; exit 2; fi
case "$SID" in ''|unknown) echo "a session id is required: waiter.sh SEAT SESSION_ID (see README, quick start)" >&2; exit 2 ;; esac
case "$SID" in *[!A-Za-z0-9._-]*) echo "the session id may hold only letters, digits, '.', '_' and '-'" >&2; exit 2 ;; esac
CUR="$W/.cursor-$SEAT"; LAST="$W/.lastwake-$SEAT"
# Arming (take the seat, read the saved position) and delivering a wake both run under the seat's cursor lock, so a
# waiter that is being replaced can never deliver after its replacement has taken over: exactly one of them delivers.
# Lock order is always the cursor lock, then the registry lock.
if [ "$SEAT" != NONE ]; then wr_lock "$CUR" || { echo "could not lock the cursor of seat $SEAT" >&2; exit 1; }; fi
# Look at the holder and take the seat under ONE lock, so two arms at the same moment cannot both win.
wr_lock "$REG" || { [ "$SEAT" = NONE ] || wr_unlock "$CUR"; echo "could not lock the seat registry" >&2; exit 1; }
if [ "$SEAT" != NONE ]; then
  # a holder is the waiter process the row names: same pid AND same start time (column 5; an older row without one is
  # judged by the pid alone), so a stale row whose pid now belongs to an unrelated process does not block the seat
  while IFS="$TAB" read -r holder hstart; do
    case "$(wr_proc "$holder" "$hstart")" in
      alive) wr_unlock "$REG"; wr_unlock "$CUR"
        echo "REFUSED: seat $SEAT is held by another live session (waiter pid $holder). Arm as NONE, or free the seat first." >&2; exit 1 ;;
      unknown) wr_unlock "$REG"; wr_unlock "$CUR"
        echo "REFUSED: seat $SEAT is held by pid $holder, whose start time cannot be read (ps failed), so it cannot be told from a reused pid. Nothing changed; try again." >&2; exit 1 ;;
    esac
  done < <(awk -F'\t' -v s="$SID" -v seat="$SEAT" 'BEGIN{OFS="\t"} $2==seat && $1!=s {print $3, $5}' "$REG")
  # a real seat replaces this session's old row and any other row of the seat
  awk -F'\t' -v s="$SID" -v seat="$SEAT" '$1!=s && $2!=seat' "$REG" > "$REG.tmp.$$"
else
  # NONE is a shared marker, not a seat: replace only this session's own row, never another session's opt-out
  awk -F'\t' -v s="$SID" '$1!=s' "$REG" > "$REG.tmp.$$"
fi
# row: session, seat, waiter pid, armed at, waiter start time ("" when ps could not read it: then the pid alone is judged)
printf '%s\t%s\t%s\t%s\t%s\n' "$SID" "$SEAT" "$$" "$(wr_now)" "$(wr_started $$)" >> "$REG.tmp.$$"; mv "$REG.tmp.$$" "$REG"; wr_unlock "$REG"
[ "$SEAT" = NONE ] && { echo "this session opted out of board triggers"; exit 0; }
gen=$(wr_generation "$BOARD_FILE"); base=$(wc -l < "$BOARD_FILE" | tr -d ' ')
c=$(wr_cursor_get "$CUR" "$BOARD_FILE" "$AGE"); [ "$c" = none ] || base=$c
lastck=$(wr_linesum "$BOARD_FILE" "$base")
wr_cursor_put "$CUR" "$gen" "$base" "$lastck"   # a re-arm after a crash resumes here, not at the end
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
chunk="$W/.poll-$SEAT.$$"; trap 'rm -f "$chunk"' EXIT
pend=""
while :; do
  sleep "$POLL"
  mine || replaced
  "$HERE/pids.sh" check >/dev/null || true      # stdout dropped, stderr kept: a ledger lock failure is shown
  g2=$(wr_generation "$BOARD_FILE"); n=$(wc -l < "$BOARD_FILE" | tr -d ' ')
  # board replaced, shorter, or changed at the line we stopped at: read it from the start
  if [ "$g2" != "$gen" ] || [ "$n" -lt "$base" ] || { [ "$base" -gt 0 ] && [ "$(wr_linesum "$BOARD_FILE" "$base")" != "$lastck" ]; }; then base=0; gen=$g2; fi
  if [ "$n" -gt "$base" ]; then
    sed -n "$((base+1)),${n}p" "$BOARD_FILE" > "$chunk"
    lastck=$(tail -n 1 "$chunk" | wr_sum)        # checksum of line n exactly as read here
    new=$(filter < "$chunk")
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
    wr_cursor_put "$CUR" "$gen" "$base" "$lastck"; touch "$LAST"   # touch, never ": >": LAST only carries a time, and a
    # BOARD configured with the same name must not be emptied (the cursor lock covers the cursor and LAST together)
    wr_unlock "$CUR"
    echo "[WAKE -> $SEAT] a board line is addressed to you. Act on it, then re-arm: bash $(printf '%q' "$HERE/waiter.sh") $SEAT $SID (as a background job)."
    printf '%s\n' "$pend"
    exit 0
  fi
done
