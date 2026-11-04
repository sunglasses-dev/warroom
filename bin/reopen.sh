#!/usr/bin/env bash
# reopen.sh — start fresh sessions without losing the thread. Each seat writes a card, you close the windows,
# open new ones and paste one message per seat. Nothing runs in the background; the state is one marker file,
# board lines and a ledger.
#   reopen.sh arm              post the request (a unique id) to the board, then write the marker; a failed post writes nothing
#   reopen.sh status           who has banked, who has reopened
#   reopen.sh card SEAT        print a card template for SEAT (save it as $WARROOM_DIR/cards/SEAT_REOPEN_<date>.md)
#   reopen.sh build [--force]  write the paste sheet $WARROOM_DIR/REOPEN_MESSAGES_<date>.md (one message per seat). It is
#                              READY only when every seat has banked and has a card written after the request; otherwise
#                              it refuses, or with --force writes a sheet marked INCOMPLETE DRAFT that says not to close
#   reopen.sh done [--force]   close the reopen: it needs a "reopened" post from every seat after this request's line, then appends the
#                              ledger row, posts the end line and clears the marker. With --force it closes anyway; the ledger row
#                              and the board line then say INCOMPLETE and name the seats that did not come back. If the ledger row
#                              or the board line cannot be written, it exits 1 and the marker stays
# A seat "banks" by posting "[HH:MM · SEAT] banked for reopen" after its card is written and its jobs are accounted for.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/_common.sh"
M="$W/.reopen-requested"; LEDGER="$W/REOPEN_LEDGER.md"; CARDS="$W/cards"
stamp()    { head -1 "$M" 2>/dev/null; }
# the request id is unique per arm (epoch seconds + 4 hex), so two reopens in one minute never share posts
new_id()   { printf 'R-%s-%s\n' "$(date +%s)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"; }
req_line() { # line number of the LAST board line that is this request, posted by the boss seat; 0 when it is not on the board
  LC_ALL=C awk -v k=" · $BOSS_SEAT] @ALL ACTION: REOPEN REQUESTED $1. " 'index($0, k) && substr($0, 1, 1) == "[" {n = NR} END {print n + 0}' "$BOARD_FILE" 2>/dev/null || echo 0
}
seats_with() { # seats that posted "<phrase>" after the exact current request line (nothing when that line is not on the board)
  s=$(stamp); [ -n "$s" ] || return 0
  n=$(req_line "$s"); [ "$n" -gt 0 ] || return 0
  sed -n "$((n + 1)),\$p" "$BOARD_FILE" | grep -E "^\[[0-9:]+ · [A-Z0-9_]+\] $1" | sed -E 's/^\[[0-9:]+ · ([A-Z0-9_]+)\].*/\1/' | sort -u
}
card_of() { ls -t "$CARDS/$1"_REOPEN_*.md 2>/dev/null | head -1; }
post_request() {
  "$HERE/board.sh" post "$BOSS_SEAT" "@ALL ACTION: REOPEN REQUESTED $1. Every seat: finish the row you are on, start no new row, write your card (bash $(printf '%q' "$HERE/reopen.sh") card SEAT), check that every job you started will outlive the window (verify it; a parent pid of 1 is a hint, not a guarantee) or is listed on your card, then post: banked for reopen."
}
case "${1:-status}" in
  arm)
    if [ -f "$M" ]; then
      s=$(stamp)
      if [ -n "$s" ] && [ "$(req_line "$s")" -gt 0 ]; then echo "already armed: $s"; exit 0; fi
      # a marker whose request never reached the board (an earlier post failed): post it now, same id
      [ -n "$s" ] || { echo "the marker $M has no request id; remove it and arm again" >&2; exit 1; }
      post_request "$s" || { echo "could not post the request $s to the board; nothing changed, run arm again once the board is writable" >&2; exit 1; }
      echo "armed $s (request posted again: it was not on the board)"; exit 0
    fi
    # the request goes to the board first; the marker is written only after the post worked
    S=$(new_id)
    post_request "$S" || { echo "could not post the request to the board; not armed, no marker written" >&2; exit 1; }
    printf '%s\n%s\n' "$S" "$(date '+%Y-%m-%d %H:%M')" > "$M" \
      || { echo "the request $S is on the board, but the marker $M could not be written: not armed. Fix the folder and arm again" >&2; exit 1; }
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
## Background jobs I own (verified to outlive a closed window, or re-started from here; say how I verified)
- <pid> <command> · parent <pid> · receipt <path>
## Work not saved anywhere else
- <patch path + checksum, or branch + head>
## First actions on reopen
0. Arm the waiter first: bash $(printf '%q' "$HERE/waiter.sh") $s <session id> (background job). Nothing else before that.
1. Read the board past my bank line; verify every pid and sha above live.
2. Post "reopened", then continue the row.
EOT
    mkdir -p "$CARDS"; echo "save it to: $CARDS/${s}_REOPEN_$(date +%Y-%m-%d).md" >&2 ;;
  build)
    force=0; [ "${2:-}" = "--force" ] && force=1
    s=$(stamp); [ -n "$s" ] || { echo "not armed" >&2; exit 1; }
    # READY needs, for every seat: it has banked, and a card exists that is newer than the request marker
    banked=" $(seats_with "banked for reopen" | tr '\n' ' ')"; missing=""
    for t in $SEATS; do c=$(card_of "$t")
      case "$banked" in *" $t "*) b=1 ;; *) b=0 ;; esac
      if [ "$b" = 0 ] || [ -z "$c" ] || [ ! "$c" -nt "$M" ]; then missing="$missing $t"; fi
    done
    if [ -n "$missing" ] && [ $force = 0 ]; then
      echo "not ready: no banked line or no current card for:$missing (cards newer than the request in $CARDS). Closing windows now would lose work. Fix that, or use: reopen.sh build --force (writes an INCOMPLETE DRAFT)" >&2; exit 1
    fi
    out="$W/REOPEN_MESSAGES_$(date +%Y-%m-%d).md"
    # the sheet must be written and read back before READY (or DRAFT) is posted
    if [ -d "$out" ] || [ -L "$out" ]; then echo "could not write the sheet: $out is a directory or a link; no READY posted" >&2; exit 1; fi
    { echo "# Reopen messages — $(date +%Y-%m-%d) ($s)"; echo
      if [ -n "$missing" ]; then echo "INCOMPLETE DRAFT: do NOT close any window yet. No banked line or no current card for:$missing."
      else echo "Close every window. Open one new session per seat and paste its message."; fi
      echo
      for t in $SEATS; do c=$(card_of "$t")
        echo "## $t"; echo '```'
        case "$missing" in *" $t"*) cardtxt="<no current card for $t: write it first>" ;; *) cardtxt=$c ;; esac
        echo "You are $t. First arm your waiter (bash $(printf '%q' "$HERE/waiter.sh") $t <session id>, as a background job). Then read $cardtxt and the board past your bank line. Verify every pid and sha on the card live, post: reopened, and continue your row."
        echo '```'; echo
      done; } > "$out" || { echo "could not write the sheet $out; no READY posted" >&2; exit 1; }
    grep -qF "($s)" "$out" 2>/dev/null || { echo "the sheet $out does not read back with request $s; no READY posted" >&2; exit 1; }
    if [ -n "$missing" ]; then line="REOPEN DRAFT $s (not ready, missing:$missing): sheet $out"; else line="REOPEN READY $s: sheet $out"; fi
    "$HERE/board.sh" post "$BOSS_SEAT" "$line" || { echo "the sheet $out is written, but the board line could not be posted: run build again once the board is writable" >&2; exit 1; }
    echo "$out" ;;
  done)
    force=0; [ "${2:-}" = "--force" ] && force=1
    s=$(stamp); [ -n "$s" ] || { echo "not armed"; exit 0; }
    # every seat that was asked to reopen must have posted "reopened" since the request
    back=" $(seats_with reopened | tr '\n' ' ')"; missing=""
    for t in $SEATS; do case "$back" in *" $t "*) ;; *) missing="$missing $t" ;; esac; done
    if [ -n "$missing" ] && [ $force = 0 ]; then
      echo "not done: no 'reopened' post since $s from:$missing. Wait for them, or close it as incomplete with: reopen.sh done --force" >&2; exit 1
    fi
    if [ -n "$missing" ]; then cell="$(seats_with reopened | tr '\n' ' ')· INCOMPLETE (forced), not back:$missing"; end="REOPEN DONE $s INCOMPLETE (forced; not back:$missing): ledger $LEDGER"
    else cell="$(seats_with reopened | tr '\n' ' ')"; end="REOPEN DONE $s: ledger $LEDGER"; fi
    if [ ! -f "$LEDGER" ]; then printf '# Reopen ledger\n| when | id | seats back |\n|---|---|---|\n' > "$LEDGER" || { echo "could not write the ledger $LEDGER" >&2; exit 1; }; fi
    # keyed on the unique request id: a rerun of the same reopen after a failed board post adds no second row
    if ! grep -qF "| $s | " "$LEDGER"; then
      echo "| $(date '+%Y-%m-%d %H:%M') | $s | $cell |" >> "$LEDGER" || { echo "could not write the ledger $LEDGER" >&2; exit 1; }
    fi
    "$HERE/board.sh" post "$BOSS_SEAT" "$end" || { echo "could not post the end line; the reopen stays open (run done again once the board is writable)" >&2; exit 1; }
    if ! rm -f "$M" 2>/dev/null || [ -e "$M" ]; then echo "the ledger row and the end line are written, but the marker $M could not be removed: remove it by hand" >&2; exit 1; fi
    echo "done" ;;
  -h|--help|help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: reopen.sh arm|status|card SEAT|build [--force]|done [--force]|--help" >&2; exit 2 ;;
esac
