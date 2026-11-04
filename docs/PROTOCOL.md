# Protocol

Skeleton for v0.1. This page separates what a script in `bin/` or `hooks/` does from what is team convention. A rule marked (convention) has no script behind it; role duties and the reopen sequence are conventions.

## Roles

| seat | job |
|---|---|
| first seat in `SEATS` | the boss: rulings, merges, anything that needs a decision (convention). The scripts send it guard alerts when no job owner is known. |
| other seats | take rows, do the work, post results (convention). |

Seat names are set in `warroom.env` and default to `BOSS MANAGER W1 W2`; the examples and the installer use those defaults.

## Board grammar

| line shape | meaning |
|---|---|
| `[HH:MM · SEAT] text` | a post. `bin/board.sh post` writes it; extra lines are indented two spaces. |
| `@SEAT ACTION: text` | wakes `SEAT` when it is the first line of a post, after the stamp. A seat's own post does not wake that seat. |
| `@ALL ACTION: text` | wakes every other seat that has a waiter running. |
| a mention without `ACTION:` | a plain mention. Wakes nobody. |
| `[HH:MM · GUARD] ...` | written by `pids.sh check`, `board-guard.sh` and `cpu-sentinel.py`. |

## Token rules

| rule | how it is kept |
|---|---|
| no model timer | no script starts a model on a clock, and `waiter.sh` is the only thing that wakes a sleeping seat. `board-guard.sh` can post an age-based reminder when someone submits a prompt |
| waiting is done by scripts | `merge-daemon.sh` polls the checks and makes one merge attempt pinned to a head; an agent should not poll for green itself (convention) |
| posts are at most 10 lines | `board.sh post` refuses longer posts unless `WARROOM_LONG=1` is set; appending to the file directly skips the limit |
| one wake per seat per `WARROOM_MIN_GAP` seconds | a waiter that keeps running holds the matching lines during the gap and delivers them after it; the held lines are in its memory, so a waiter that exits can lose them |

## Receipts

| job | receipt |
|---|---|
| a merge | a finished attempt writes `$WARROOM_DIR/receipts/merge_<PR>_<time>.md` and posts a board line that starts `POSTCONDITION PASS` or `POSTCONDITION FAIL` and ends with the receipt path; a dry run writes neither |
| a long job | register it with `pids.sh add LABEL PID SEAT`. While a waiter is running, a check notices the pid is gone and posts one wake line to the owner; the owner needs a waiter of their own, and a pid number that is reused hides a finished job. `pids.sh done` removes the row without a wake |
| a reopen | one card per seat, saved by you in `$WARROOM_DIR/cards/` (`reopen.sh card SEAT` prints a template, it does not save it); `reopen.sh done` adds a ledger row in `REOPEN_LEDGER.md` listing the seats whose reopened post it finds |

## Reopen

(convention) `reopen.sh arm` → each seat finishes its row, writes and saves its card and posts `banked for reopen` → `reopen.sh build` writes the paste sheet → you check the cards, open new sessions and paste one message each → `reopen.sh done`. The scripts do not check that a card exists, is current, or that a seat came back.

## Not covered in v0.1

(convention) who reviews whose work, how rulings are numbered, how cards are written. Those are team choices; `examples/4-seat/` shows one way.
