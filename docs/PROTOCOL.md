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
| `[HH:MM · GUARD] ...` | written by `pids.sh check` and `board-guard.sh`. |

## Token rules

| rule | how it is kept |
|---|---|
| no model timer | no script starts a model on a clock, and `waiter.sh` is the only thing that wakes a sleeping seat. `board-guard.sh` can post one idle reminder per silence when someone submits a prompt (it saves its mark before posting: a crash between the two loses that reminder, and a post that reports failure after it reached the board is repeated); a seat that owns a registered job whose process is still running counts as working; a job whose start time cannot be read counts too, and the hook says so |
| waiting is done by scripts | register a long job with `pids.sh add` and let the waiter wake the owner when it ends; an agent should not poll for it (convention) |
| posts are at most 10 lines | `board.sh post` refuses longer posts unless `WARROOM_LONG=1` is set; appending to the file directly skips the limit |
| about one wake per seat per `WARROOM_MIN_GAP` seconds | a waiter that keeps running holds the matching lines during the gap and delivers them after it; arming and delivering a wake run under the seat's cursor lock, so two waiters armed for one seat at the same moment give one wake, and the gap is rechecked under that lock. A misconfigured path or link is outside this lock. Its position is saved at arm and at each wake: arming again within `WARROOM_CURSOR_MAX_AGE` seconds (86400) resumes there. The saved position carries a checksum of everything already read: a board replaced by a new file, shorter than the position, or changed anywhere in the part already read is read again from its start. The gap marker is written before the position, so a failure of either leaves the old position: the waiter does not report the wake as delivered, it prints the lines and exits 1, and a timely re-arm retries from the retained position if the board and the saved state are still there. A waiter whose own start time cannot be read does not arm (exit 1), so the seat registry never holds a row it cannot tell from a reused pid. The first arm, or one after that age, starts at the end of the board and sees only what follows |

## Receipts

| job | receipt |
|---|---|
| a long job | register it with `pids.sh add LABEL PID SEAT` (`add` refuses pid 0 and a process whose start time it cannot read). While any waiter is running, its check notices the process is gone (or that its pid now belongs to a process that started at a different time) and posts a wake line to the owner; a process whose start time cannot be read is left in the ledger and looked at again, never treated as gone. The post comes before the row is removed and is retried if it fails, so a crash between the two can post it twice; if the ledger cannot be written the command exits non-zero and leaves the old ledger, so a job can be missing from it or a wake can repeat. The owner needs a waiter of their own. `pids.sh done` removes the row without a wake |
| a reopen | one card per seat, written and saved by you in `$WARROOM_DIR/cards/` (convention; no script reads or checks a card) |

## Reopen

(convention, no script behind it) Each seat finishes its row, writes and saves its card and posts that it is banked. You check the cards, open new sessions and paste one message per seat. Each seat posts that it reopened. Nothing checks that every seat did; read the board.

## Writer lock

| fact | detail |
|---|---|
| what it protects | one writer at a time per protected file: the board, the seat registry, each seat's cursor and read anchor, the job ledger and the guard marks. It is advisory: only scripts that use `wr_lock` in `bin/_common.sh` are held back, and an editor or an `echo >>` is not |
| how it works | `flock(2)` on a sidecar file `FILE.flock`, taken through a short `python3` helper on descriptor 8 or 9. The lock is released when the last copy of that descriptor closes: at unlock, or when the holder exits or is killed. A script started inside a locked section runs with the lock descriptors closed |
| waiting | a writer waits up to `WARROOM_LOCK_WAIT` seconds (default 10), then gives up with one line on stderr naming the cause. Nothing steals a lock and nothing removes a `.flock` file; never delete one while any participant can run |
| order | at most two locks per shell, never the same file twice, never from a subshell. The only nestings: job ledger then board, guard mark then board, seat cursor then seat registry |
| one name per file | a protected file that is a symlink, has more than one hard link, or has a symlinked `.flock` is refused. A symlinked parent folder is fine, because the lock key is the physical folder plus the file name. An absolute `BOARD` gets the same checks |
| limits | one machine and a local disk (not NFS or SMB). A command stopped inside a locked section, such as a hung disk, keeps the lock until it ends if the holder is killed. Moving the run directory or re-pointing a parent link while writers run is not supported |
| upgrade from the old lock | the old `FILE.lock` folders and the `FILE.flock` files do not exclude each other: stop every session, waiter and job that uses the run directory before you update |

## Not covered in v0.1

(convention) who reviews whose work, how rulings are numbered, how cards are written. Those are team choices; `examples/4-seat/` shows one way.
