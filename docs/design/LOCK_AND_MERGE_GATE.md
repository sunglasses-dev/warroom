# Design: the writer lock and the merge gate

Status: accepted design, Part A (the writer lock) and Part B (the PR watcher). This note is the design record: where it and the scripts, README or PROTOCOL differ, those are current. An earlier draft had a merge helper; the public tool watches and reports, it never merges. Tags in parentheses, such as "(r3d2 FIX 6)", mark the places changed after a round of design review. Repo line references are at main ec57546.
Scope: `bin/_common.sh` (`wr_lock`, `wr_unlock`, `wr_reclaim`) and `bin/merge-daemon.sh` (replaced by `bin/pr-watch.sh`), plus the README / PROTOCOL / SECURITY wording about them.

## Why this is a design doc and not a patch

Two review rounds found the same two problems, each time in a new place:

| problem | round 1 | round 2 |
|---|---|---|
| a lock can be held by two writers | a stale-lock check evicted a live holder | the fix moved the hole into recovery: `wr_reclaim` moves the lock aside before it checks who owns it, so it can move a live successor's lock and let a second writer in |
| "green at the pinned head" is not one moment | one look, then merge | two looks, then merge: the gap between the second look and the merge is still there, so a stub that is green twice and red at merge time still merges |

Both fixes patched a symptom and moved the race. This doc changes the mechanism instead: a kernel lock that is released when its holder exits removes the stale-reclaimer race, and a read-only watcher removes the client-side merge race, within the limits stated below.

## Part A: the writer lock

### What the lock is for

There is one writer at a time per protected file: the board (`wr_append`), the seat registry and a seat cursor (`waiter.sh`), the job ledger (`pids.sh`), a tail anchor (`board.sh tail`) and a guard mark (`board-guard.sh`). The lock is advisory: it only protects writers that use `wr_lock`. Three nestings exist today, and they are the only supported lock order: the ledger lock, then the board lock (`pids.sh check` posts while it holds the ledger); a guard mark lock, then the board lock (`board-guard.sh` posts while it holds the mark); and a seat cursor lock, then the seat registry lock (`waiter.sh` arming, both held by the same shell in slots 8 and 9). In the first two the board lock is taken by a separate `board.sh` process, not by the same shell. "One protected file" means one key under *Protection identity* below. A symlinked leaf and a hard-linked file are refused; a symlinked parent folder is allowed and resolves to the same key.

### Option M: a directory lock plus a reclaim lock (the shape the ruling asked us to argue)

- Lock = `mkdir L.lock`, then write `pid + process start time` into `L.lock/owner`.
- Reclaim = take a second lock, `mkdir L.lock.reclaim`. While holding it, re-read the owner. If the owner is the same dead process we saw, remove `L.lock`. Otherwise leave it alone. Then drop the reclaim lock.

This protects the validate-then-remove step, but it moves the recovery problem one level up instead of solving it, for these callers:

1. **The reclaim lock has the same lifetime problem as the lock.** A reclaimer that dies holding `L.lock.reclaim` leaves it behind. Recovering it unattended needs either a timeout, which cannot tell a crashed reclaimer from a paused one, or a kernel lock, which is Option K with extra steps.
2. **The ownerless window.** Between `mkdir` and writing `owner`, the lock exists with no owner. A paused holder looks like a crashed one. Publishing a fully written owner record atomically (a symlink or hard link) removes this window, but it still needs pid + start-time identity and a conditional remove of exactly the generation that was seen, which is the protocol that failed in round 2.

A directory lock with no automatic reclaim (manual cleanup after stopping every writer) would keep exclusion, but it gives up unattended recovery, which the war room needs: a killed hook must not stop the board for everyone. So M is rejected for these trade-offs, not because every file-system scheme is impossible.

### Option K (recommended): a kernel lock on a file that is never replaced

`flock(2)` locks belong to an open file description. The shell opens the lock file on a fixed descriptor, a short `python3 -I -S` helper calls `flock` on that inherited descriptor and exits, and the lock stays held while any copy of that open description is still open. python3 is already a runtime dependency (`pr-watch.sh`, `hooks/board-tail.sh`, `hooks/waiter-check.sh`).

#### The release rule (chosen explicitly)

**The lock is released when the last copy of the holder's descriptor closes.** Not when the holder calls `wr_unlock`, and not when the holder dies, unless no other copy exists. Every child process that inherits the descriptor holds a copy. So the design controls which children get a copy:

- **Script children never get a copy.** Anything started from a critical section that is a script or can run for a while (`board.sh post` in `pids.sh check` and `board-guard.sh`) is started through `wr_run`, which runs it with `8>&- 9>&-`. Such a child takes its own locks if it needs them.
- **Short foreground commands keep a copy while they run.** These are `mv`, `sed`, `awk`, `cat`, `date`, `printf`, and the command substitutions around them, run in the foreground inside a section. Closing descriptors on each of these adds noise without changing the guarantee, because the holder waits for them anyway.
- **The helper keeps its copy until it exits.** Under ordinary contention that is within the wait deadline. A helper that is itself stopped (SIGSTOP) or stalled falls under the stopped-descendant residual below: `wr_lock` waits for it, and the deadline is not a hard real-time bound (r3d2 FIX 2).
- Nothing is started in the background inside a critical section (a convention: the smoke lint below does not look for background starts).

The disclosed residual: if one of those short foreground commands is stopped (SIGSTOP, a hung disk) and the holder is then killed, the lock stays held until that command ends. Waiters time out with a diagnostic. Nothing steals the lock, and nothing is unlocked with `LOCK_UN`, because unlocking through a shared description would release a live holder's lock.

#### Lock state in one shell

```
wr_lock FILE      # take FILE's lock, waiting up to WARROOM_LOCK_WAIT seconds (default 10)
wr_unlock FILE    # release FILE's lock if this shell holds it
wr_run CMD ARGS   # run CMD with the lock descriptors closed (for children started inside a section)
```

State is two plain shell variables, not exported: `_WR_SLOT8` and `_WR_SLOT9`. Each one holds the key (see *Protection identity*) of the FILE that this shell locked on that descriptor, or is empty. The r3d2 variable `_WR_SUB` is dropped, because the subshell rule no longer depends on slot state. The rules:

| case | behaviour |
|---|---|
| any of `wr_lock`, `wr_unlock`, `wr_run` while `$BASH_SUBSHELL` is not 0 | refused **first**, before any check, open or read, whatever the slot state: no slot used yet, a slot held, or every slot emptied by an earlier unlock. Return 2, "lock used from a subshell" (r3d2 FIX 1). The supported forms are the top level of a script and functions called from it, or a fresh script. A `( … )`, `$( … )` or pipeline-element subshell may not take, release, or run a child under a lock. Verified on bash 3.2.57: `$BASH_SUBSHELL` is 1 in all three of those, and 0 in a function, in a fresh `bash`, in a `while … done < FILE` loop and in a `while … done < <(…)` loop. Every current call site is in one of the 0 forms (`pids.sh:26,32,40`, `waiter.sh:26,28,82`, `board.sh:29`, `board-guard.sh:36`, and `wr_append` via `board.sh:26`) |
| FILE is resolved to its key | see *Protection identity*. A leaf symlink, a hard-linked FILE or a symlinked sidecar is refused with return 2 (r3d2 BLOCKER 1) |
| `wr_lock` on a FILE this shell already holds | refused: return 2, "already holding the lock for FILE" (no recursion, no reference count) |
| `wr_lock` with both slots full | refused: return 2, "lock nesting limit (2)" |
| slot choice | the lowest empty slot, 8 then 9. A slot that is in use is never reopened |
| a fresh process (a new `bash` script) | its slot variables are empty, so an inherited fd 8 or 9 counts as free. Reopening it replaces only this process's copy, and the parent's lock is kept (verified, see below) |
| acquisition fails | the descriptor that was just opened (if any) is closed, the slot stays empty, the return code is 1, and one stderr line names the cause (r3d2 FIX 2): "could not open lock file KEY.flock: REASON" when the open fails; "lock helper failed for FILE: REASON" when python3 is missing, flock is not supported on that file system, or the helper exits with an error; "could not lock FILE: held by another writer for WAITs" only for contention until the deadline |
| `wr_unlock` on a FILE that is in no slot | no-op, return 0 |
| `wr_unlock` on a FILE in a slot | closes that one descriptor (`exec N>&-`) and empties that slot. The other slot is untouched, so release order does not matter |

- Lock file = `FILE.flock`. It is opened with `>>`, so it is created if missing and never truncated. No code removes or renames it. **Never unlink a sidecar while any participant can run:** removing a held lock file would let the next opener lock a new inode. Deleting the stopped, retired run directory removes the sidecars too.
- The wait is one helper call that loops `LOCK_EX|LOCK_NB` against a `time.monotonic()` deadline, so a wall-clock change cannot shorten or stretch it, and ordinary contention returns 1 instead of hanging. The helper exits 0 (locked), 1 (deadline passed) or 3 (error, reason on stderr), so the shell prints the matching line from the table. A full open + lock + close cycle is about 15 ms on this Mac (bash 3.2.57, python 3.14).
- Descriptors 8 and 9 are reserved. Scripts in this repo must not use them for anything else, and a smoke grep checks for `[89][<>]` outside `_common.sh`.
- Deleted outright: `wr_reclaim`, the `owner` file, the 10-second ownerless rule, and the "a reused pid looks alive" limit.

#### Protection identity (r3d2 BLOCKER 1)

r3d2 showed that the r3d2 rule (logical `pwd` of the parent plus the base name) gives a file and a leaf symlink to it two different sidecars. Two independent writers could then hold "the board" at once. We choose the narrow scope: **no leaf symlink or hard-link aliases; stable symlinked parents resolve to the physical parent.**

| case | behaviour |
|---|---|
| the key | `KEY = $(cd -P "$(dirname FILE)" && pwd -P)/$(basename FILE)`, and the sidecar is `KEY.flock`. A symlinked parent directory resolves to the physical directory, so `run/board.md` reached through a linked folder and through the real folder have one key, fill the same slot string and contend on one lock (verified here: both spellings give the same key) |
| FILE is a symlink (`[ -L FILE ]`) | refused: return 2, "FILE is a symlink; point the war room at the real path". The link is refused, not followed. The callers replace data files with `mv TMP FILE`, and `mv` onto a symlink replaces the link, not its target. Following the link for the lock but not for the write would protect one file and write another |
| FILE exists with more than one name (link count from `stat -c %h`, or `stat -f %l` on macOS) | refused: return 2, "FILE has N hard links; a protected file must have exactly one name" |
| `KEY.flock` is a symlink | refused: return 2. Only `wr_lock` creates sidecars (with `>>`), so a healthy run directory never has a linked one |
| FILE does not exist yet | allowed. The checks apply whenever FILE exists |

Not supported, and written in the limits: hard links to a protected file, re-pointing a parent-directory symlink while writers run, and moving or renaming the run directory while writers run. The checks run at every `wr_lock`. They are not re-run during a section, so a non-cooperating process that creates an alias in the middle of a section is outside the guarantee, like any write that bypasses the lock. Most protected paths (`pids.tsv`, `seats.tsv`, cursors, anchors, guard marks) are built by the scripts under `$WARROOM_DIR`; `BOARD` may also be an absolute path and gets the same checks. So a refusal only happens when someone points the config at a symlink or links a protected file by hand, and the error line says what to do. An inode-only key is not used, because the `mv` replacements change the data file's inode while the sidecar must stay the same.

#### What each caller does when the lock is not taken

Before this design, several callers failed silently (r3d FIX 3). The contract is: never write without the lock, and always leave a visible line saying the work was skipped.

The middle column is the historical baseline, the code before this design; the contract column is what the code does now.

| caller | before this design (historical baseline) | contract |
|---|---|---|
| `wr_append` (board post) | returns 1 and prints a reason | unchanged |
| `board.sh tail` anchor | exits 1 and prints a reason | unchanged |
| `waiter.sh` cursor, arming | exits 1 and prints a reason | unchanged |
| `waiter.sh` cursor, delivery (`waiter.sh:82`) | skips this poll silently and tries again on the next | the wake is delivered on a later poll, and the failed lock prints a diagnostic (`wr_lock` reports it, and the waiter keeps its stderr); the cursor lock covers the cursor and the wake timestamp `.lastwake-SEAT` together, and the timestamp is updated with `touch`, never truncated |
| `waiter.sh` registry | exits 1 and prints a reason, after releasing the cursor | unchanged |
| `waiter.sh` ledger check (`waiter.sh:66`, `pids.sh check >/dev/null 2>&1`) | stderr thrown away | stderr kept through this outer call too, so a ledger lock failure reaches the waiter's own output (r3d2 FIX 3) |
| `pids.sh add / done / check` | `exit 1`, prints nothing | prints `pids.sh: could not lock the job ledger; nothing changed` and exits 1 |
| `pids.sh check` nested post (`pids.sh:46`) | stderr thrown away | the post runs through `wr_run`, and its stderr is kept. A row is dropped only when its post succeeded. A failed post, a failed board lock included, keeps the row for the next check, as the code does today |
| `board-guard.sh` mark | `continue`, prints nothing, exits 0 | prints `board-guard: skipped SEAT (mark busy), will retry on the next prompt` and still exits 0, so a busy lock never blocks the prompt. The nested post (`board-guard.sh:39`) runs through `wr_run` and keeps its stderr. The mark is saved before the post, and nothing is posted when it cannot be saved. When the post fails, the old mark is put back, so the seat is named again on the next prompt. Limits: a crash between saving the mark and posting loses that reminder, with no alert; if putting the old mark back fails, the mark is removed instead; and a post that reports failure after its line reached the board is posted again. A reminder can be lost or repeated; there is no exactly-once delivery. The hook runs on every prompt. This makes the line visible in the script's output; how the host shows hook stderr is not something this design promises |
| board bootstrap (`_common.sh:22`) | `[ -e "$BOARD_FILE" ] \|\| : > "$BOARD_FILE"`: an unlocked check, then a truncating create, so a slow starter can empty a board another process has just written | `: >> "$BOARD_FILE"`: creates the file if it is missing and never truncates it (r3d2 FIX 3) |

Under ordinary contention an acquisition times out at the `wr_lock` deadline; a stopped or stalled helper can make it wait longer, with no bound (the disclosed residual in *The release rule*). The waiter's delivery skips that poll and tries again on the next one, and the waiter runs its job check (`pids.sh check`) again at every poll.

"Never write without the lock" means: never change a protected file's **contents** without that file's lock. Three things happen without the lock, and none of them can change contents:

- creating a missing file empty with `>>` or `touch`: `_common.sh:22` after the fix, `pids.sh:12`, `waiter.sh:18`;
- the mtime update that `touch` makes on the ledger and the registry (no code reads those two mtimes; `wr_mtime` is used only on `LAST` and the old lock directory);
- creating a sidecar.

Every content change happens inside a section: an append, a rewrite, an `mv` into place, or a `: >` truncation.

#### Invariants (corrected after r3d)

| # | invariant | why it holds |
|---|---|---|
| L1 | two independent acquisitions of the lock for one protected file never overlap. One protected file is one key, and aliases are refused. Copies inherited by the holder's own children are part of the holder's section, not a second holder | exclusive `flock(2)` on one sidecar inode, and that inode is never replaced. *Protection identity* maps every supported spelling to one key, and refuses the spellings that would give a second key |
| L2 | the lock is free once the last copy of the holder's descriptor is closed: at `wr_unlock`, or when the holder exits or is killed, after the short foreground commands it was waiting for have ended. Script children never hold a copy | kernel release on last close, plus the `wr_run` rule. Residual: a stopped foreground command keeps the lock until it ends (see above) |
| L3 | a live holder is never evicted | no code path removes, renames, unlocks with `LOCK_UN` or steals a lock; a waiter can only time out |
| L4 | a process that is not the holder cannot release the lock | closing your own copy releases nothing while the holder's copy is open |
| L5 | a lock failure is never silent, and it names its cause | `wr_lock` prints one line (open, helper or contention) and returns 1, and every caller follows the table above |
| L6 | the slot state is never corrupted | there is no same-key relock, no third slot, no reuse of an occupied slot, and no subshell use in any slot state; a wrong-file unlock is a no-op, and a failed acquire leaves no descriptor open |
| L7 | no protected content changes without its lock | the caller table, the non-destructive bootstrap, and the three permitted unlocked actions above |

#### Verified behaviour (scratch experiments here and in r3d, not repo code)

These results come from two sets of experiments. One set was run on this Mac before the first draft. The other is the r3d reviewer's set (`tmp/lock_probes.log`, `tmp/stress_probe.log`).

- A lock held through an inherited fd 8 blocks a second locker. SIGKILL of a sole holder releases it.
- Locks on two distinct files, held on 8 and 9, are independent.
- A fresh child that reopens 8 for another file leaves the parent's lock held.
- A background child that inherited 8 keeps the lock after its parent exits. The same child started with `8>&- 9>&-` does not.
- A waited child that is stopped keeps the lock after its parent is SIGKILLed: the residual above.
- The same file opened twice in one process: the second acquisition times out, because flock does not nest across separate opens. That is why the same FILE is refused before it is opened.
- A `( … )` subshell keeps a non-exported variable, while a fresh `bash` does not: why the `$BASH_SUBSHELL` check exists.
- In the stress test, 8 writers each ran 20 sections, 160 in all, with 0 overlaps (r3d and r3d2).
- r3d2 reproduced the identity counterexample against the r3d2 rule: two independent processes held `real_board` and its leaf symlink `alias_board` at the same time. Under *Protection identity* the alias call is refused.
- r3d2 showed that a subshell check run only when a slot is occupied lets `x=$(wr_lock FILE)` return 0 from an empty state. The blanket refusal closes that.
- Checked here: a symlinked parent gives the same `pwd -P` key, `[ -L ]` detects a leaf link, and `stat -f %l` reports 2 for a hard-linked file.

### Upgrading from the old lock

The old `FILE.lock` directories and the new `FILE.flock` files do not exclude each other. So the upgrade is **quiescent**, for **all participants using this run directory**: close every seat session first, because hooks also take locks. Then stop the waiters, every job that posts, and anything run from another clone that points at the same run directory. Update, and start again. The README says this. That README line documents the step. It does not prove anyone stopped their processes, and there is no runtime check that keeps an old writer out (r3d2 Q4: none is needed). After the upgrade, a leftover `FILE.lock` directory is inert and may be deleted. Never unlink a `FILE.flock` while any participant can run; deleting the stopped, retired run directory removes them too.

### Limits that stay (written in the README and the `_common.sh` header)

- The lock works on one machine and a local file system only. flock over NFS or SMB is not trusted.
- The lock is advisory: an editor or an `echo >>` that bypasses `board.sh` is not locked. Only cooperating writers are protected.
- The stopped-foreground-command residual described under the release rule. It includes a stopped helper.
- One name per protected file: symlinked or hard-linked protected files are refused, and re-pointing or moving the run directory while writers run is not supported.

### Why a python3 helper and not a lock utility (r3d2 RIDER 1)

The r3d2 text here was wrong, and it is corrected. macOS `lockf(1)` can lock an already-open descriptor for a shell section (its man page: with no command, the argument must be a file descriptor), and `shlock(1)` is a PID-file lock, so it has the stale-owner problems of Option M. Stock utility sets differ: macOS ships no `flock(1)`, and Linux distributions ship util-linux `flock(1)` and usually not the BSD `lockf(1)`. This code calls neither. Using a utility would mean one code path per system. One `fcntl.flock` call in python3 behaves the same on both, and python3 is already required. A lock daemon would be a new moving part.

### Acceptance tests for Part A (named after r3d; each one fails on the current code or on a wrong implementation)

- `stable_inode_contention_and_crash`: independent writers never overlap. The sidecar's inode is the same at the start and at the end. There is no reclaim path or `.lock` directory in the code. A sole holder's SIGKILL lets the lock be taken again. **Identity (r3d2 BLOCKER 1):**
  - the r3d2 counterexample, real path + leaf alias in two independent processes, never gives two holders: the alias call returns 2 and opens nothing;
  - a hard-linked FILE and a symlinked sidecar return 2;
  - through a symlinked parent, a second independent process times out against the first.

  A per-spelling implementation fails this test.
- `inherited_fd_lifetime`: the probes above, plus a parent killed while it waits for a stopped child, with results matching the release rule. These run the **real** `wr_run` and the real nested callers (`pids.sh check` posting a dead job, `board-guard.sh` posting an idle seat), never hand-written redirections. An independent locker takes the lock while the child is still alive, which shows that the child holds no copy (r3d2 FIX 4).
- `slot_ownership_and_failure_cleanup`: two distinct locks, a third refused, wrong-file unlock, same-key relock refused (also through a symlinked parent), a failed second acquire that leaves slot 9 empty and fd 9 closed, and an out-of-order release then reacquire that never touches the live slot. Then:
  - each of `wr_lock`, `wr_unlock` and `wr_run` in `( … )`, in `$( … )` and in a pipeline element, in three states (no slot used, a slot held, after the last unlock), returns 2 and opens nothing;
  - an open failure (unwritable folder) and a helper failure (python3 not on PATH, and a stub helper that exits 3) each print their own line, close the descriptor and leave the slot empty;
  - descriptors are checked through `/dev/fd`, and each held lock is tried from an independent fresh process. Slot strings alone are not evidence.

  An occupied-slot-only subshell check fails this test.
- `caller_timeout_visibility`: outer and nested lock failures are forced **separately** for every caller in the table, with no unlocked content change. The documented line survives each caller's redirects, through the waiter's `pids.sh check` call and through the guard. When the nested post fails, the ledger row is kept and the guard mark is unchanged. Bootstrap: a board with content stays unchanged when another process sources `_common.sh` with the old existence race forced. The current callers fail this test for the reasons r3d reproduced.
- `lock_order_and_upgrade_boundary`, which is supplementary lint and not evidence of safety (the current code passes it too): ledger→board and mark→board work, and the reverse order is not present in the repo (grep). A smoke lint finds no other use of fds 8 and 9 and no lock call inside `$( … )` or after a pipe; it does not look for background starts. The README upgrade step is present.
- The old lock case, `tests/smoke.sh:122-131` at main (case 11: owner directory, reclaim, non-owner release), is removed together with its header line 13. Its replacements are the tests above. Every other smoke case stays (r3d2 FIX 4).

## Part B: the merge helper becomes a watcher (ruling: demote)

### Why the public tool stops merging

r3d showed that a gated merge needs two things this template cannot establish from the client side. First, it must prove that the target branch's required checks are enforced *for the credential that merges*. Rulesets hide their bypass list from the rules endpoint, and the detail endpoints may omit it, so "unknown" cannot honestly become "no bypass". Second, the merge must be a direct one: `gh pr merge` can enrol a merge queue or turn on auto-merge, so the actual merge happens later and is not tied to the observation. This is the second round on the same class (proving server enforcement for this actor), so the project's two-rounds rule applies (same class twice = stop and narrow the scope). The public v1 therefore drops merging altogether. Any private tool its authors run is separate, is not shipped, and is not described or vouched for by anything in this repo, `pr-watch.sh --help` included.

### What the public tool does

`bin/merge-daemon.sh` is replaced by `bin/pr-watch.sh`. The new name says what it does. The old file is removed, not kept as a shim: the repo has no outside users yet.

```
pr-watch.sh PR --head SHA [--require CHECK]... [--repo OWNER/REPO] [--seat SEAT] [--poll S] [--timeout S]
```

1. **It only reads.** The only GitHub call it makes is `gh pr view` (repo, state, head, base, checks). It never calls `gh pr merge`, `gh api` with a method, or any other write. It cannot merge, approve, enqueue or enable auto-merge.
2. **One look per poll.** Each look is one `gh pr view` response, and that response is the unit of observation. The tool records when the response arrived and reports "the returned PR data showed …". It does not claim the response is one atomic moment on the server (the old `merge-daemon.sh:5` claim is not carried over). The "second confirming look" is removed: it was an observation dressed as a gate (r3d2 FIX 6).
3. **Green rule (unchanged).** A check counts as green when it is SUCCESS, NEUTRAL or SKIPPED. A finished check with any other result is red. **Every** row of the response is judged, required or not, and rows are never merged into a map keyed by name: if two rows share a name and either one is red or pending, that name is red or pending. A legacy status context is green only on SUCCESS (NEUTRAL and SKIPPED apply to check runs only); PENDING and EXPECTED keep waiting; any other state is red. A check row that lacks a field the verdict needs (its name, status, conclusion or state) makes that look unreadable: incomplete rows prevent green, and the watch keeps polling until the timeout, but a red row in the same response may stop the watch before that retry; a missing workflow name, base branch or repository only reads `not reported` in the receipt. Every `--require` name must appear and be green; names are compared exactly as GitHub returned them (only the receipt's display text has control characters replaced). Zero checks counts as pending, so a PR with no checks times out and is never reported green.
4. **Stops when:**
   - the head is not `--head`;
   - a check is red;
   - the PR is closed;
   - the PR is merged by anyone (reported as "merged outside this tool");
   - the timeout passes.
5. **Results.** The last board line starts with one of two words:
   - `WATCH GREEN`, for example: `WATCH GREEN PR 12 at <head>: the PR data returned at 10:34 showed every check green (observed, not a gate; this tool did not merge or modify the PR) (receipt …)`.
   - `WATCH FAIL`, followed by the reason, for example `WATCH FAIL PR 12: merged outside this tool`.

   The fixed template text of a result never uses `POSTCONDITION` or `PASS`, and never claims that a merge happened or that one is safe. Response fields (check names and other data GitHub returned) are printed into the receipt as untrusted display, so a check named `PASS` can appear there. The negative sentence "this tool did not merge or modify the PR" is required, so the word itself is not banned: only positive merge claims are (r3d2 FIX 6).
6. **The receipt** records:
   - the repo and the PR's base branch as GitHub reported them;
   - the pinned head;
   - the time the response arrived;
   - each check's name, result and workflow name as reported, with `not reported` where the response has none (legacy status contexts often have none). Name matching does not authenticate which provider ran a check;
   - the required names;
   - the checks, the head, the base branch and the repository taken from the one response that produced the result, never mixed from earlier polls. The pinned head and the required names are the inputs the caller gave, and the receipt's `observed at` time is the local clock when that response arrived;
   - the sentence: "The returned PR data showed the checks below at the time above. This tool did not merge or modify the PR. Whether a merge can skip these checks is decided by the branch protection on the base branch, which this tool does not read."
7. **Exit codes:** 0 = green seen, 1 = stopped or timed out, 2 = usage error. A receipt or board line that cannot be written makes the run exit 1, as before.

### What the public tool does not do, and says so

- It does not inspect branch protection or rulesets, and it makes no claim about them.
- A green report does not freeze anything. A check can turn red, the head can move, or the base can be retargeted after the look.
- It does not decide that a merge is safe. A seat or a person that merges after `WATCH GREEN` is acting on an observation. Whether a merge can skip the checks is up to the server's branch protection (required checks, and who may bypass them). Setting that up is the repo owner's job. This tool neither reads it nor relies on it.

### Invariants

| # | invariant | why it holds |
|---|---|---|
| W1 | the tool makes no write to GitHub | the only `gh` subcommand in the script is `pr view`; a smoke grep and a gh stub that fails on any other subcommand both check this |
| W2 | `WATCH GREEN` is posted only after one response that showed: the PR open, the head equal to `--head`, every check row green, every required name present (compared exactly), and at least one check | `judge` evaluates every row (no name-keyed map) and returns ready only in that case. Every other path ends in `WATCH FAIL` or keeps waiting |
| W3 | no fixed template text claims that this tool merged anything, that a merge is safe, or that the result is a gate (a report that a PR was merged outside this tool is allowed); response fields are displayed as untrusted evidence and are not covered | the help text, receipt and board line come from fixed templates. The test checks the template text with check names and other response data replaced by placeholders, so a check named `PASS` or `guarantee` cannot fail it. The negative phrases "not a gate", "not a guarantee" and "did not merge" are allowed (r3d2 FIX 6) |

### Acceptance tests for Part B (gh stubbed, no network)

- `watch_no_mutation`: the stub logs every gh call. After **every** run in this section, the log of calls other than `pr view` must be empty, on green and on fail paths alike. A stub that only fails such calls is not enough, because a tool could swallow the failure and print WATCH FAIL. The old `merge-daemon.sh` is the negative control: it calls `gh pr merge`.
- `watch_green_language` (the positive control): a valid green response gives exit 0, exactly one `WATCH GREEN` line and no `WATCH FAIL` line. The receipt and the line contain "observed, not a gate" and "this tool did not merge or modify the PR". The templates pass the W3 check. `--help` says the tool never merges and says nothing about any private tool. A tool that always exits 1 fails this test.
- `watch_stops`: each of these ends `WATCH FAIL` with exit 1 and no green line:
  - the head is not the pinned one;
  - a required check is red;
  - a required check never appears (timeout);
  - there are zero checks (timeout);
  - the PR is closed;
  - the PR was merged elsewhere;
  - a **non-required** check is red;
  - a non-required check stays pending (it keeps waiting, then times out, and is never green);
  - two rows share a name: one SUCCESS and one FAILURE (red), and one SUCCESS and one PENDING (pending);
  - legacy status contexts with FAILURE and with PENDING;
  - malformed or null data: a missing state, or a null checks list;
  - `gh` fails after an earlier pending response, and is never treated as green.

  A watcher that checks only the required names, or keeps the last row per name, fails here (r3d2 FIX 5).
- `watch_receipt_fields`: the stub's responses change the repo, base, head and check rows between polls. The receipt must hold **exactly** the values of the response that produced the result: not an earlier response, and not a mix. A check with no workflow is written `not reported`. If the receipt cannot be written, the run exits 1 with no green line. If the board post fails, the run exits 1 (r3d2 FIX 5).

## Part C: wording that lands with the code (exact replacements)

These lines change in the same pull request as the code, so no doc describes behaviour the code does not have yet.

| place | new text |
|---|---|
| README:4 | "… and optional helpers watch a pull request's checks and leave a receipt of what they saw, and tell a job's owner when it ends." replaces "… optional helpers leave a receipt for a merge and tell a job's owner when it ends." (r3d2 FIX 6) |
| README:19 | `\| A long job can wake its owner, a PR can be watched \| while a waiter is running, a job registered with pids.sh posts a wake line to its owner when its process is gone; pr-watch.sh posts WATCH GREEN or WATCH FAIL when a pull request's checks settle at a pinned head. It reports, it never merges \|` |
| README:24 | "`gh` is needed only for `pr-watch.sh`, which you can leave for later." |
| README:68 | "Quick start. Leave pr-watch.sh and cpu-sentinel.py for later." |
| README:84, examples/4-seat/sample-board.md:10 | `[10:34 · BOSS] WATCH GREEN PR 12 at <head>: the PR data returned at 10:34 showed every check green (observed, not a gate; this tool did not merge or modify the PR) (receipt receipts/watch_12.md)` |
| README:115 | "`pr-watch.sh` watches one pull request at a pinned head and reports when its checks are green or one fails; it never merges, and a green report is an observation, not a guarantee. Whether an unchecked merge is possible is decided by your branch protection." |
| PROTOCOL:29 | `\| waiting is done by scripts \| pr-watch.sh polls a pull request's checks at a pinned head and posts the result; an agent should not poll for green itself (convention). The tool never merges. Who may merge, and whether unchecked merges are possible, is your branch protection's job \|` |
| PROTOCOL:37 | `\| a watched PR \| a finished watch writes $WARROOM_DIR/receipts/watch_<PR>_<time>_<pid>.md and posts a stamped board line that starts WATCH GREEN or WATCH FAIL and ends with the receipt path in parentheses; if the receipt cannot be written or read back, or the board line cannot be posted, the run ends with exit 1 and no green line is posted (when the receipt itself cannot be written, the board line says so instead of giving a path) \|` |
| SECURITY:18 | "- pr-watch.sh making any write to GitHub, or reporting WATCH GREEN for a PR that was not open at the pinned head with every check green" |
| SECURITY:24 | "the read-only `gh pr view` calls pr-watch.sh makes" replaces "the `gh` calls the merge daemon makes" |
| CONTRIBUTING:21, examples/4-seat/BOSS.md:7 | "`gh` for pr-watch" and "use `bin/pr-watch.sh` to wait for checks" |
| `_common.sh` header | The Part A contract: L1-L7, the release rule and its residual (stopped helper included), the slot rules and supported call forms, protection identity and its refusals, reserved fds 8 and 9, never delete a `.flock`, the advisory and local-file-system scope, and the quiescent upgrade |
| README (new lines) | The quiescent-upgrade step "for all participants using this run directory", the advisory scope, "one name per protected file: do not symlink or hard-link the board or the run files", and "never unlink a `.flock` file while any participant can run; deleting the stopped, retired run directory removes them too" |
| `pids.sh`, `waiter.sh`, `board-guard.sh`, `_common.sh:22` | Diagnostics and the bootstrap as in the Part A caller table |
| tests/smoke.sh case 11 (`:122-131`) and case 13, plus header lines 13 and 15 | Replaced by the Part A and Part B tests |

## Questions for the design-only review (r3d3, the last design round for the lock)

1. BLOCKER 1: does *Protection identity* give one lock per protected file for every supported spelling? Are the refusals (leaf symlink, hard links, linked sidecar) plus the written limits a complete statement of what is not supported?
2. FIX 1: is the blanket `$BASH_SUBSHELL` refusal complete across states and forms, and does any current call site use a refused form?
3. FIX 2 and FIX 3: are the monotonic deadline, the helper residual, the three failure lines, the end-to-end stderr, the preserved rows and marks, and the non-destructive bootstrap enough? Is any protected content still changed without its lock?
4. FIX 4 and FIX 5: do the tests now reject the wrong implementations named in r3d2? Those are a per-spelling sidecar, an occupied-slot-only subshell check, hand-sanitised children, a required-names-only watcher, a last-row-wins map, a receipt from a stale or mixed response, and a tool that always fails.
5. FIX 6 and RIDER 1: is any Part B or Part C wording still a claim the watcher cannot back, and is the utilities paragraph now accurate?
6. Is anything left that would let the same class come back a third time?

## r3d3 implementation requirements (required in the code PRs, judged on the code)

- **FIX 1 (lock, waiter):**
  - Add the third nesting, cursor → registry in the same shell (`waiter.sh:26,28`), to the lock-order inventory, with both cursor-failure paths and real-caller tests.
  - The delivery path (`waiter.sh:82`) retries on a later poll, so "no caller retries" is wrong there; say so.
  - Replace `: > "$LAST"` (`waiter.sh:85`) with a non-truncating timestamp update (`touch`). The cursor lock covers the cursor and the wake timestamp as one group.
  - Add a regression for a BOARD configured as the waiter's marker name (`.lastwake-SEAT`). Today that reproduces as a held board truncated from 44 bytes to 0. The board must stay byte-identical.
- **FIX 2 (tests):**
  - Duplicate rows in both orders (FAILURE or PENDING before SUCCESS too).
  - A pending-to-green sequence with the head unchanged and the base and check rows varying. Head drift is a separate test that ends in FAIL.
  - Null or missing fields that the verdict needs, plus a positive case where the workflow is absent.
  - Real caller and descriptor checks, with each named mutant run to show it fails.
- **FIX 3 (receipt):**
  - The pinned head and the required names come from the invocation. The observation time is local. Repo, base, observed head and check rows come from the response that produced the result.
  - On head drift, record both the pinned head and the observed head.
  - On a gh failure or a malformed response, mark the current fields unavailable and never present an earlier response as fresh. If earlier evidence is kept, give its own observation time.
  - Optional workflow metadata may be absent. Fields the verdict needs may not.
- **RIDER 1:**
  - `bin/_common.sh:20` accepts an absolute BOARD, so the identity checks apply to it too, and absolute paths stay supported. Correct the "every protected path is under `$WARROOM_DIR`" sentence.
  - The header says leaf symlinks are refused and stable symlinked parents resolve physically.
  - `flock(1)` availability is a difference between the stock platforms, not a rule.
- Also (review note from the PR #10 CI runs): 8 simultaneous `board.sh post` to a missing board must all land on Linux CI.

Out of scope here: the Claude Code settings file (nothing in this repository writes it) and earlier fixes to the waiter, cursor and ledger.
