#!/usr/bin/env bash
# board-guard.sh — Claude Code hook for UserPromptSubmit. Names a seat that has been silent too long and has no
# registered job running, with one "@SEAT ACTION:" line on the board, at most once per silence.
# Silent means: no board line stamped with its name for WARROOM_IDLE_MIN minutes (default 30).
# A seat that owns a registered job whose process is still running is working, not idle. "Still running" means the same
# process: when the ledger recorded a start time, a reused pid that started at another time does not count. A job whose
# start time cannot be read (ps failed) counts as running: the guard never calls a seat idle when it cannot tell.
# "At most once per silence": the mark remembers which post it spoke about (board generation, line number and the line
# itself), so a replaced board, or a new post that lands on the same line number, starts a new silence.
# a bad warroom.env must not block the prompt (exit 2 would): see WR_CONFIG_EXIT in bin/_common.sh
# shellcheck disable=SC2034
WR_CONFIG_EXIT=1
case $0 in */*) _d=${0%/*}; [ -n "$_d" ] || _d=/ ;; *) _d=. ;; esac
HERE=$(cd -P -- "$_d" && pwd) || exit 1
. "$HERE/../bin/_common.sh" || exit 1
. "$HERE/../bin/_cursor.sh" || exit 1
case "${1:-}" in -h|--help) sed -n -- '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
cat >/dev/null 2>&1
IDLE=${WARROOM_IDLE_MIN:-30}; TAB="$(printf '\t')"
# one reading of the clock, checked and range-tested before any arithmetic (a failed or odd date is no "now")
now=$(wr_now) || { echo "board-guard: could not read the clock; no reminder this time" >&2; exit 1; }
wr_hhmm "$now" || { echo "board-guard: the clock gave '$now', not HH:MM; no reminder this time" >&2; exit 1; }
nowmin=$((10#${now%%:*}*60+10#${now##*:}))
# guard_seat SEAT: one seat's silence check. Status 1: skipped, and the reason was said (the next prompt tries again). Status 0:
# nothing to say, or said.
guard_seat() {
  seat=$1
  # the seat's last post, found in one pass to the end of the board: "<line number>:<line>". A read that fails is not
  # "never posted" (that would hide a silent seat); no output with status 0 is.
  hit=$(awk -v s="$seat" 'BEGIN { p = "^\\[[0-9][0-9]:[0-9][0-9] · " s "\\]" } $0 ~ p { n = NR; l = $0 } END { if (n) print n ":" l }' "$BOARD_FILE" 2>/dev/null) \
    || { echo "board-guard: skipped $seat (could not read the board), will retry on the next prompt" >&2; return 1; }
  [ -n "$hit" ] || return 0                                    # never posted: not started yet
  lineno=${hit%%:*}; line=${hit#*:}
  hm=${line:1:5}
  wr_hhmm "$hm" || { echo "board-guard: skipped $seat (its last post is stamped '$hm', not a time)" >&2; return 1; }
  lastmin=$((10#${hm%%:*}*60+10#${hm##*:})); age=$(( (nowmin-lastmin+1440) % 1440 ))
  [ "$age" -ge "$IDLE" ] || return 0
  # a seat that owns a registered job whose process is still alive is working (pids.tsv: label pid owner started)
  # the ledger is read whole first (a failed or partial read is never "no jobs"), then walked from that copy. A ledger
  # that is not there yet means no jobs; one that is there and cannot be read means the guard cannot judge: no post.
  ledger=$(wr_registry_read "$W/pids.tsv") \
    || { echo "board-guard: skipped $seat (cannot read the job ledger $W/pids.tsv), will retry on the next prompt" >&2; return 1; }
  # this seat's rows as words: label, pid, start time ("-" when there is none). A row whose label or pid is not plain is not a job.
  jobs=$( set -o pipefail; printf '%s\n' "$ledger" | awk -F'\t' -v s="$seat" 'BEGIN { ORS = "\t" } $3 == s && $1 ~ /^[A-Za-z0-9._:-]+$/ && $2 ~ /^[0-9]+$/ { print $1; print $2; print ($4 == "" ? "-" : $4) }' ) \
    || { echo "board-guard: skipped $seat (cannot read the job ledger $W/pids.tsv), will retry on the next prompt" >&2; return 1; }
  busy=0
  # words split at tabs only: a start time holds spaces
  set -f
  _oifs=$IFS; IFS=$TAB
  # shellcheck disable=SC2086
  set -- $jobs
  IFS=$_oifs
  set +f
  while [ "$#" -ge 3 ]; do
    jl=$1; jp=$2; js=$3; shift 3
    [ "$js" = - ] && js=""
    # same process? (a recorded start time must match; a row without one is judged by the pid alone). A job whose start
    # time cannot be read (ps failed) may still be running, so it counts as working, and the hook says why on stderr.
    jstate=$(wr_proc "$jp" "$js") || { echo "board-guard: skipped $seat (cannot judge pid $jp of job '$jl'), will retry on the next prompt" >&2; return 1; }
    case "$jstate" in
      alive) busy=1 ;;
      unknown) busy=1; echo "board-guard: cannot read the start time of pid $jp (job '$jl'); $seat counted as working" >&2 ;;
    esac
  done
  [ "$busy" = 0 ] || return 0
  mark="$W/.guard-$seat"
  # once per silence: the mark holds the board generation, line number and checksum of the seat's last post; the same
  # three = already said it.
  # Check, mark and post happen under one lock, so two prompts at the same moment say it once. The new mark is made in a
  # temp BEFORE the post (if it cannot be made nothing is posted; the next prompt tries again) and is renamed over the mark
  # only after the post was delivered. A failed post leaves the old mark untouched, so the reminder is tried again. If the
  # post was delivered and the rename fails, the hook says so and the next prompt may remind once more. No mark file is ever
  # unlinked.
  wr_lock "$mark" || { echo "board-guard: skipped $seat (mark busy), will retry on the next prompt" >&2; return 1; }
  gen=$(wr_generation "$BOARD_FILE") || { wr_unlock "$mark"; echo "board-guard: skipped $seat (could not read the board), will retry on the next prompt" >&2; return 1; }
  lsum=$( set -o pipefail; printf '%s\n' "$line" | wr_sum ) || { wr_unlock "$mark"; echo "board-guard: skipped $seat (could not checksum the post), will retry on the next prompt" >&2; return 1; }
  here="$gen $lineno $lsum"
  # the mark: absent = no silence spoken about yet ("-"); present = one checked read that must be "-" or a real mark.
  # An empty or odd mark is refused with a message, never taken as a new silence (the reminder would repeat at every prompt).
  mabs=$(wr_absent "$mark") || { wr_unlock "$mark"; echo "board-guard: skipped $seat (cannot tell whether the mark $mark exists), will retry on the next prompt" >&2; return 1; }
  if [ "$mabs" = yes ]; then prev="-"
  else
    # every byte counts: $( ) drops NUL bytes and trailing newlines, so the file is read with a marker byte after it, and
    # the NUL bytes are counted on their own. A mark is exactly one line and its newline.
    prev=$( cat -- "$mark" && printf x ) || { wr_unlock "$mark"; echo "board-guard: skipped $seat (cannot read the mark $mark), will retry on the next prompt" >&2; return 1; }
    prev=${prev%x}
    mnul=$( set -o pipefail; LC_ALL=C tr -d '\001-\377' < "$mark" | wc -c ) || { wr_unlock "$mark"; echo "board-guard: skipped $seat (cannot read the mark $mark), will retry on the next prompt" >&2; return 1; }
    mre='^[0-9]+:[0-9]+ [0-9]+ [0-9]+$'
    mexact=yes
    case "$prev" in *$'\n') prev=${prev%$'\n'} ;; *) mexact=no ;; esac
    case "$prev" in *$'\n'*) mexact=no ;; esac
    [ "${mnul//[!0-9]/}" = 0 ] || mexact=no
    if [ "$mexact" = no ] || { [ "$prev" != "-" ] && ! [[ $prev =~ $mre ]]; }; then
      wr_unlock "$mark"; echo "board-guard: skipped $seat (the mark $mark is not a mark; delete that one file to start a new silence)" >&2; return 1
    fi
  fi
  if [ "$prev" != "$here" ]; then
    wr_temp "$mark" || { wr_unlock "$mark"; echo "board-guard: skipped $seat (could not save the mark in $W), will retry on the next prompt" >&2; return 1; }
    mark_t=$_WR_TMP
    printf '%s\n' "$here" > "$mark_t" || { wr_drop "$mark_t"; wr_unlock "$mark"; echo "board-guard: skipped $seat (could not save the mark in $W), will retry on the next prompt" >&2; return 1; }
    if wr_run "$HERE/../bin/board.sh" post GUARD "@${seat} ACTION: no board post from you for ${age} min and no registered job. Take the next unclaimed card, or post what you are waiting on." >/dev/null; then
      wr_replace "$mark_t" "$mark" || { wr_drop "$mark_t"; wr_unlock "$mark"; echo "board-guard: the post for $seat was delivered but the mark could not be saved in $W; the next prompt may remind once more" >&2; return 1; }
    else
      wr_drop "$mark_t"; wr_unlock "$mark"; echo "board-guard: the post for $seat failed; the mark is unchanged, will retry on the next prompt" >&2; return 1
    fi
  fi
  wr_unlock "$mark"
  return 0
}
for seat in $SEATS; do guard_seat "$seat" || continue; done
exit 0
