# Protocol

Skeleton for v0.1. Every rule here is one a script in `bin/` or `hooks/` enforces or reads; rules with no script behind them are marked (convention).

## Roles

| seat | job |
|---|---|
| first seat in `SEATS` | the boss: rulings, merges, anything that needs a decision. Receives guard alerts when no job owner is known. |
| other seats | take rows, do the work, post results. |

Seat names come from `warroom.env`. Nothing else in the repo names a seat.

## Board grammar

| line shape | meaning |
|---|---|
| `[HH:MM · SEAT] text` | a post. `bin/board.sh post` writes it; extra lines are indented two spaces. |
| `@SEAT ACTION: text` | wakes `SEAT`. Put it on the first line of a post. |
| `@ALL ACTION: text` | wakes every seat. |
| `@SEAT` anywhere else | a plain mention. Wakes nobody. |
| `[HH:MM · GUARD] ...` | written by `pids.sh check`, `board-guard.sh` and `cpu-sentinel.py`. |

## Token rules

| rule | how it is kept |
|---|---|
| no clock wakes | a seat sleeps until a line names it; `waiter.sh` is the only trigger |
| waiting is done by scripts | `merge-daemon.sh` waits for green and merges once; an agent does not poll |
| posts are at most 10 lines | `board.sh post` refuses longer posts |
| one wake per seat per `WARROOM_MIN_GAP` seconds | the waiter holds the lines and delivers them after the gap; none are dropped |

## Receipts

| job | receipt |
|---|---|
| a merge | `$WARROOM_DIR/receipts/merge_<PR>_<time>.md` and a board line ending `POSTCONDITION PASS` or `POSTCONDITION FAIL` |
| a long job | register it with `pids.sh add LABEL PID SEAT`; its owner is woken once when the pid is gone |
| a reopen | one card per seat in `$WARROOM_DIR/cards/` and a ledger row in `REOPEN_LEDGER.md` |

## Reopen

`reopen.sh arm` → each seat finishes its row, writes its card and posts `banked for reopen` → `reopen.sh build` writes the paste sheet → you open new sessions and paste one message each → `reopen.sh done`.

## Not covered in v0.1

(convention) who reviews whose work, how rulings are numbered, how cards are written. Those are team choices; `examples/4-seat/` shows one way.
