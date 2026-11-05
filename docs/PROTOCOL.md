# Protocol

Skeleton for v0.1. This page separates what a script in `bin/` or `hooks/` does from what is team convention. A rule marked (convention) has no script behind it; role duties and the reopen sequence are conventions.

## Roles

| seat | job |
|---|---|
| first seat in `SEATS` | the boss: rulings, merges, anything that needs a decision (convention). The scripts send it guard alerts when no job owner is known. |
| other seats | take rows, do the work, post results (convention). |

Seat names are set in `warroom.env` and default to `BOSS MANAGER W1 W2`; the examples and `warroom.env.example` use those defaults.

## Board grammar

| line shape | meaning |
|---|---|
| `[HH:MM · SEAT] text` | a post. `bin/board.sh post` writes it; extra lines are indented two spaces. |
| `@SEAT ACTION: text` | wakes `SEAT` when it is the first line of a post, right after the stamp, and the author is another seat. A mention in prose, `ACTIONABLE`, a quoted directive and any later line of a post wake nobody. |
| `@ALL ACTION: text` | wakes every other seat that has a waiter running, with the same first-line rule. |
| a mention without `ACTION:` | a plain mention. Wakes nobody. |
| `[HH:MM · GUARD] ...` | written by `pids.sh check`, `board-guard.sh` and `cpu-sentinel.py`. |

## Token rules

| rule | how it is kept |
|---|---|
| no model timer | no script starts a model on a clock, and `waiter.sh` is the only thing that wakes a sleeping seat. `board-guard.sh` can post one idle reminder per silence when someone submits a prompt (it saves its mark before posting: a crash between the two loses that reminder, and a post that reports failure after it reached the board is repeated); a seat that owns a registered job whose process is still running counts as working; a job whose start time cannot be read counts too, and the hook says so |
| waiting is done by scripts | `pr-watch.sh` polls a pull request's checks at a pinned head and posts the result; an agent should not poll for green itself (convention). The tool never merges. Who may merge, and whether unchecked merges are possible, is your branch protection's job |
| posts are at most 10 lines | `board.sh post` refuses longer posts unless `WARROOM_LONG=1` is set; appending to the file directly skips the limit |
| about one wake per seat per `WARROOM_MIN_GAP` seconds | a waiter that keeps running holds the matching lines during the gap and delivers them after it; arming and delivering a wake run under the seat's cursor lock, so two waiters armed for one seat at the same moment give one wake, and the gap is rechecked under that lock. Its position is saved at arm and at each wake: arming again within `WARROOM_CURSOR_MAX_AGE` seconds (86400) resumes there. The saved position carries a checksum of everything already read: a board replaced by a new file, shorter than the position, or changed anywhere in the part already read is read again from its start. The gap marker is written before the position, so a failure of either leaves the old position: the waiter does not report the wake as delivered, it prints the lines, exits 1, and the next arm delivers them again. A waiter whose own start time cannot be read does not arm (exit 1), so the seat registry never holds a row it cannot tell from a reused pid. The first arm, or one after that age, starts at the end of the board and sees only what follows |

## Receipts

| job | receipt |
|---|---|
| a watched PR | a finished watch writes `$WARROOM_DIR/receipts/watch_<PR>_<time>_<pid>.md` and posts a stamped board line that starts `WATCH GREEN` or `WATCH FAIL` and ends with the receipt path in parentheses; if the receipt cannot be written or read back, or the board line cannot be posted, the run ends with exit 1 and no green line is posted (when the receipt itself cannot be written, the board line says so instead of giving a path) |
| a long job | register it with `pids.sh add LABEL PID SEAT` (`add` refuses pid 0 and a process whose start time it cannot read). While any waiter is running, its check notices the process is gone (or that its pid now belongs to a process that started at a different time) and posts a wake line to the owner; a process whose start time cannot be read is left in the ledger and looked at again, never treated as gone. The post comes before the row is removed and is retried if it fails, so a crash between the two can post it twice; if the ledger cannot be written the command exits non-zero and leaves the old ledger, so a job can be missing from it or a wake can repeat. The owner needs a waiter of their own. `pids.sh done` removes the row without a wake |
| a reopen | one card per seat, saved by you in `$WARROOM_DIR/cards/` (`reopen.sh card SEAT` prints a template, it does not save it); `reopen.sh done` adds a ledger row in `REOPEN_LEDGER.md` listing the seats whose reopened post it finds, and refuses until every seat has posted one after this reopen's own request line (each `arm` gets a unique id, so posts from an earlier reopen do not count; `done --force` closes it and labels the row and the end line INCOMPLETE) |

## Reopen

(convention) `reopen.sh arm` (posts the request first and writes the marker only when that post worked) → each seat finishes its row, writes and saves its card and posts `banked for reopen` → `reopen.sh build` writes the paste sheet (READY is posted only after the sheet is written; a failed write or post exits 1) → you check the cards, open new sessions and paste one message each → `reopen.sh done`. `build` checks that every seat banked and has a current card; `done` checks that every seat posted `reopened` after the current request line, and exits 1 if the marker cannot be removed. Neither reads what a card says.

## Not covered in v0.1

(convention) who reviews whose work, how rulings are numbered, how cards are written. Those are team choices; `examples/4-seat/` shows one way.
