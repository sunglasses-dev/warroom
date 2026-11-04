#!/usr/bin/env bash
# reopen.sh — start fresh sessions without losing the thread. Each seat writes a card, you close the windows,
# open new ones and paste one message per seat. Nothing runs in the background; the state is one marker file,
# board lines and a ledger.
#   reopen.sh arm              mark a reopen as requested and post the request to the board
#   reopen.sh status           who has banked, who has reopened
#   reopen.sh card SEAT        print a card template for SEAT (save it as $WARROOM_DIR/cards/SEAT_REOPEN_<date>.md)
#   reopen.sh build            write the paste sheet $WARROOM_DIR/REOPEN_MESSAGES_<date>.md (one message per seat)
#   reopen.sh done             append the ledger row, post the end line, clear the marker
# A seat "banks" by posting "[HH:MM · SEAT] banked for reopen" after its card is written and its jobs are accounted for.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
M="$W/.reopen-requested"; LEDGER="$W/REOPEN_LEDGER.md"; CARDS="$W/cards"
stamp()    { head -1 "$M" 2>/dev/null; }
seats_with() { # seats that posted "<phrase>" after the request line
  s=$(stamp); [ -n "$s" ] || return 0
  sed -n "/REOPEN REQUESTED $s/,\$p" "$BOARD_FILE" | grep -E "^\[[0-9:]+ · [A-Z0-9_]+\] $1" | sed -E 's/^\[[0-9:]+ · ([A-Z0-9_]+)\].*/\1/' | sort -u
}
card_of() { ls -t "$CARDS/$1"_REOPEN_*.md 2>/dev/null | head -1; }
case "${1:-status}" in
  arm)
    if [ -f "$M" ]; then echo "already armed: $(stamp)"; exit 0; fi
    S="R-$(date +%Y%m%d-%H%M)"; printf '%s\n%s\n' "$S" "$(date '+%Y-%m-%d %H:%M')" > "$M"
    "$HERE/board.sh" post "$BOSS_SEAT" "@ALL ACTION: REOPEN REQUESTED $S. Every seat: finish the row you are on, start no new row, write your card (bash $HERE/reopen.sh card SEAT), check that every job you started survives the window closing (its parent pid is 1) or is listed on your card, then post: banked for reopen."
    echo "armed $S" ;;
  status)
    if [ ! -f "$M" ]; then echo "not armed"; exit 0; fi
    b=$(seats_with "banked for reopen" | tr '\n' ' '); n=$(seats_with "banked for reopen" | wc -l | tr -d ' ')
    set -- $SEATS; echo "armed $(stamp) since $(sed -n 2p "$M") · banked $n/$#: $b"
    r=$(seats_with "reopened" | tr '\n' ' '); if [ -n "$r" ]; then echo "reopened: $r"; fi ;;
  card)
    s=${2:?usage: reopen.sh card SEAT}; wr_seat_ok "$s" || { echo "unknown seat '$s' (seats: $SEATS)" >&2; exit 2; }
    cat <<EOT
# $s reopen card — $(date +%Y-%m-%d) $(wr_now) (banked for reopen $(stamp))
Seat: $s. The session name changes on reopen: list your peers first.
## My rows (board truth, verify live)
- <row> · head/sha <...> · waits on <...> · next step <...>
## Background jobs I own (parent pid 1 survives a closed window; anything else is re-started from here)
- <pid> <command> · parent <pid> · receipt <path>
## Work not saved anywhere else
- <patch path + checksum, or branch + head>
## First actions on reopen
0. Arm the waiter first: bash $HERE/waiter.sh $s <session id> (background job). Nothing else before that.
1. Read the board past my bank line; verify every pid and sha above live.
2. Post "reopened", then continue the row.
EOT
    mkdir -p "$CARDS"; echo "save it to: $CARDS/${s}_REOPEN_$(date +%Y-%m-%d).md" >&2 ;;
  build)
    s=$(stamp); [ -n "$s" ] || { echo "not armed" >&2; exit 1; }
    out="$W/REOPEN_MESSAGES_$(date +%Y-%m-%d).md"
    { echo "# Reopen messages — $(date +%Y-%m-%d) ($s)"; echo
      echo "Close every window. Open one new session per seat and paste its message."; echo
      for t in $SEATS; do c=$(card_of "$t")
        echo "## $t"; echo '```'
        echo "You are $t. First arm your waiter (bash $HERE/waiter.sh $t <session id>, as a background job). Then read ${c:-<no card found>} and the board past your bank line. Verify every pid and sha on the card live, post: reopened, and continue your row."
        echo '```'; echo
      done; } > "$out"
    "$HERE/board.sh" post "$BOSS_SEAT" "REOPEN READY $s: sheet $out"
    echo "$out" ;;
  done)
    s=$(stamp); [ -n "$s" ] || { echo "not armed"; exit 0; }
    [ -f "$LEDGER" ] || printf '# Reopen ledger\n| when | id | seats back |\n|---|---|---|\n' > "$LEDGER"
    echo "| $(date '+%Y-%m-%d %H:%M') | $s | $(seats_with reopened | tr '\n' ' ') |" >> "$LEDGER"
    "$HERE/board.sh" post "$BOSS_SEAT" "REOPEN DONE $s: ledger $LEDGER"
    rm -f "$M"; echo "done" ;;
  -h|--help|help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: reopen.sh arm|status|card SEAT|build|done|--help" >&2; exit 2 ;;
esac
