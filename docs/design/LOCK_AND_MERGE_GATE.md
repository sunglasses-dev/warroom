# Design: the writer lock and the merge gate

Status: DRAFT r3d2 for a design-only review. No code changes before that review says GO. r3d (2026-11-04) returned DESIGN NO GO: Part A is revised below; Part B is rewritten as the demotion the lead ruled (R105 (a)): the public tool watches and reports, it never merges.
Scope: `bin/_common.sh` (`wr_lock`, `wr_unlock`, `wr_reclaim`) and `bin/merge-daemon.sh` (replaced by `bin/pr-watch.sh`), plus the README / PROTOCOL / SECURITY wording about them.

## Why this is a design doc and not a patch

Two review rounds found the same two problems, each time in a new place:

| problem | round 1 | round 2 |
|---|---|---|
| a lock can be held by two writers | a stale-lock check evicted a live holder | the fix moved the hole into recovery: `wr_reclaim` moves the lock aside before it checks who owns it, so it can move a live successor's lock and let a second writer in |
| "green at the pinned head" is not one moment | one look, then merge | two looks, then merge: the gap between the second look and the merge is still there, so a stub that is green twice and red at merge time still merges |

Both fixes patched a symptom and moved the race. This doc changes the mechanism instead, so the race has nowhere to move to.

## Part A: the writer lock

### What the lock is for

There is one writer at a time per protected file: the board (`wr_append`), the seat registry (`waiter.sh`), the job ledger (`pids.sh`), a tail anchor (`board.sh tail`) and a guard mark (`board-guard.sh`). The lock is advisory: it only protects writers that use `wr_lock`. Two nestings exist today, and they are the only supported lock order: the ledger lock, then the board lock (`pids.sh check` posts while it holds the ledger), and a guard mark lock, then the board lock (`board-guard.sh` posts while it holds the mark). In both cases the board lock is taken by a separate `board.sh` process, not by the same shell.

### Option M: a directory lock plus a reclaim lock (the shape the ruling asked us to argue)

- Lock = `mkdir L.lock`, then write `pid + process start time` into `L.lock/owner`.
- Reclaim = take a second lock, `mkdir L.lock.reclaim`. While holding it, re-read the owner. If the owner is the same dead process we saw, remove `L.lock`. Otherwise leave it alone. Then drop the reclaim lock.

This protects the validate-then-remove step, but it moves the recovery problem one level up instead of solving it, for these callers:

1. **The reclaim lock has the same lifetime problem as the lock.** A reclaimer that dies holding `L.lock.reclaim` leaves it behind. Recovering it unattended needs either a timeout, which cannot tell a crashed reclaimer from a paused one, or a kernel lock, which is Option K with extra steps.
2. **The ownerless window.** Between `mkdir` and writing `owner`, the lock exists with no owner. A paused holder looks like a crashed one. Publishing a fully written owner record atomically (a symlink or hard link) removes this window, but it still needs pid + start-time identity and a conditional remove of exactly the generation that was seen, which is the protocol that failed in round 2.

A directory lock with no automatic reclaim (manual cleanup after stopping every writer) would keep exclusion, but it gives up unattended recovery, which the war room needs: a killed hook must not stop the board for everyone. So M is rejected for these trade-offs, not because every file-system scheme is impossible.

### Option K (recommended): a kernel lock on a file that is never replaced

`flock(2)` locks belong to an open file description. The shell opens the lock file on a fixed descriptor, a short `python3 -I -S` helper calls `flock` on that inherited descriptor and exits, and the lock stays held while any copy of that open description is still open. python3 is already a runtime dependency (`merge-daemon.sh`, `hooks/board-tail.sh`, `hooks/waiter-check.sh`).

#### The release rule (chosen explicitly)

**The lock is released when the last copy of the holder's descriptor closes.** Not when the holder calls `wr_unlock`, and not when the holder dies, unless no other copy exists. Every child process that inherits the descriptor holds a copy. So the design controls which children get a copy:

- **Script children never get a copy.** Anything started from a critical section that is a script or can run for a while (`board.sh post` in `pids.sh check` and `board-guard.sh`) is started through `wr_run`, which runs it with `8>&- 9>&-`. Such a child takes its own locks if it needs them.
- **Short foreground commands keep a copy while they run.** These are `mv`, `sed`, `awk`, `cat`, `date`, `printf`, and the command substitutions around them, run in the foreground inside a section. Closing descriptors on each of these adds noise without changing the guarantee, because the holder waits for them anyway.
- **The helper keeps its copy only until it exits**, which happens within the wait deadline.
- Nothing is started in the background inside a critical section. A smoke grep enforces this for the repo's sections.

The disclosed residual: if one of those short foreground commands is stopped (SIGSTOP, a hung disk) and the holder is then killed, the lock stays held until that command ends. Waiters time out with a diagnostic. Nothing steals the lock, and nothing is unlocked with `LOCK_UN`, because unlocking through a shared description would release a live holder's lock.

#### Lock state in one shell

```
wr_lock FILE      # take FILE's lock, waiting up to WARROOM_LOCK_WAIT seconds (default 10)
wr_unlock FILE    # release FILE's lock if this shell holds it
wr_run CMD ARGS   # run CMD with the lock descriptors closed (for children started inside a section)
```

State is two plain shell variables, not exported: `_WR_SLOT8` and `_WR_SLOT9`. Each one holds the canonical path of the FILE that this shell locked on that descriptor, or is empty. A third variable, `_WR_SUB`, holds `$BASH_SUBSHELL` from the moment the first slot was filled. The rules:

| case | behaviour |
|---|---|
| FILE is canonicalised first | `cd "$(dirname FILE)" && pwd` plus the base name, so `./board.md` and the absolute path are one FILE |
| `wr_lock` on a FILE this shell already holds | refused: return 2, "already holding the lock for FILE" (no recursion, no reference count) |
| `wr_lock` with both slots full | refused: return 2, "lock nesting limit (2)" |
| slot choice | the lowest empty slot, 8 then 9. A slot that is in use is never reopened |
| a fresh process (a new `bash` script) | its slot variables are empty, so an inherited fd 8 or 9 counts as free. Reopening it replaces only this process's copy, and the parent's lock is kept (verified, see below) |
| `wr_lock`, `wr_unlock` or `wr_run` called at a different `$BASH_SUBSHELL` than the one that filled a slot | refused: return 2, "lock used from a subshell". The supported forms are: lock and unlock in the same shell, or in a fresh script. A `( … )`, `$( … )` or pipeline-element subshell inherits the variables and the descriptors, so it may not take or release locks (verified on bash 3.2.57: `$BASH_SUBSHELL` is 1 in all three, 0 in a function and in a fresh `bash`) |
| acquisition fails (timeout or helper error) | the descriptor that was just opened is closed, the slot stays empty, one stderr line "could not lock FILE: held by another writer for WAITs" is printed, and the return code is 1 |
| `wr_unlock` on a FILE that is in no slot | no-op, return 0 |
| `wr_unlock` on a FILE in a slot | closes that one descriptor (`exec N>&-`) and empties that slot. The other slot is untouched, so release order does not matter |

- Lock file = `FILE.flock`. It is opened with `>>`, so it is created if missing and never truncated. It is **never removed or renamed** by any code, docs or cleanup step. Removing a held lock file would let the next opener lock a new inode.
- The wait is one helper call that loops `LOCK_EX|LOCK_NB` until a deadline, so a timeout returns 1 instead of hanging. A full open + lock + close cycle is about 15 ms on this Mac (bash 3.2.57, python 3.14).
- Descriptors 8 and 9 are reserved. Scripts in this repo must not use them for anything else, and a smoke grep checks for `[89][<>]` outside `_common.sh`.
- Deleted outright: `wr_reclaim`, the `owner` file, the 10-second ownerless rule, and the "a reused pid looks alive" limit.

#### What each caller does when the lock is not taken

Today several callers fail silently (r3d FIX 3). The contract is: never write without the lock, and always leave a visible line saying the work was skipped.

| caller | today | contract |
|---|---|---|
| `wr_append` (board post) | returns 1 and prints a reason | unchanged |
| `board.sh tail` anchor | exits 1 and prints a reason | unchanged |
| `waiter.sh` registry | exits 1 and prints a reason | unchanged. The ledger check at `waiter.sh:53` stops discarding stderr |
| `pids.sh add / done / check` | `exit 1`, prints nothing | prints `pids.sh: could not lock the job ledger; nothing changed` and exits 1 |
| `pids.sh check` nested post | stderr thrown away | the post runs through `wr_run`, and its stderr is kept |
| `board-guard.sh` mark | `continue`, prints nothing, exits 0 | prints `board-guard: skipped SEAT (mark busy), will retry on the next prompt` and still exits 0, so a busy lock never blocks the prompt. The nested post keeps its stderr. The retry is the next prompt, because the hook runs on every prompt |

No caller retries in a loop beyond the `wr_lock` wait.

#### Invariants (corrected after r3d)

| # | invariant | why it holds |
|---|---|---|
| L1 | two independent acquisitions of one FILE's lock never overlap. Copies inherited by the holder's own children are part of the holder's section, not a second holder | exclusive `flock(2)` on one inode, and that inode is never replaced |
| L2 | the lock is free once the last copy of the holder's descriptor is closed: at `wr_unlock`, or when the holder exits or is killed, after the short foreground commands it was waiting for have ended. Script children never hold a copy | kernel release on last close, plus the `wr_run` rule. Residual: a stopped foreground command keeps the lock until it ends (see above) |
| L3 | a live holder is never evicted | no code path removes, renames, unlocks with `LOCK_UN` or steals a lock; a waiter can only time out |
| L4 | a process that is not the holder cannot release the lock | closing your own copy releases nothing while the holder's copy is open |
| L5 | a timeout is never silent | `wr_lock` prints one line and returns 1, and every caller follows the table above |
| L6 | the slot state is never corrupted | there is no same-FILE relock, no third slot, no reuse of an occupied slot, no subshell use, wrong-file unlock is a no-op, and a failed acquire leaves no descriptor open |

#### Verified behaviour (scratch experiments here and in r3d, not repo code)

These results come from two sets of experiments. One set was run on this Mac before the first draft. The other is ASTRA's r3d set (`tmp/lock_probes.log`, `tmp/stress_probe.log`).

- A lock held through an inherited fd 8 blocks a second locker. SIGKILL of a sole holder releases it.
- Locks on two distinct files, held on 8 and 9, are independent.
- A fresh child that reopens 8 for another file leaves the parent's lock held.
- A background child that inherited 8 keeps the lock after its parent exits. The same child started with `8>&- 9>&-` does not.
- A waited child that is stopped keeps the lock after its parent is SIGKILLed: the residual above.
- The same file opened twice in one process: the second acquisition times out, because flock does not nest across separate opens. That is why the same FILE is refused before it is opened.
- A `( … )` subshell keeps a non-exported variable, while a fresh `bash` does not: why the `$BASH_SUBSHELL` check exists.
- In the stress test, 8 writers each ran 20 sections, 160 in all, with 0 overlaps.

### Upgrading from the old lock

The old `FILE.lock` directories and the new `FILE.flock` files do not exclude each other. So the upgrade is **quiescent**: close every seat session first, because hooks also take locks. Then stop the waiters and every job that posts, update the clone, and start again. The release notes and the README say this. After the upgrade, a leftover `FILE.lock` directory is inert and may be deleted. A `FILE.flock` is never deleted, not even by cleanup instructions.

### Limits that stay (written in the README and the `_common.sh` header)

- The lock works on one machine and a local file system only. flock over NFS or SMB is not trusted.
- The lock is advisory: an editor or an `echo >>` that bypasses `board.sh` is not locked. Only cooperating writers are protected.
- The stopped-foreground-command residual described under the release rule.

### Why not the lock utilities

macOS has `lockf(1)` and `shlock(1)` but no `flock(1)`. Both lock around a single command, while our sections span several shell statements (read, compare, write, move). A lock daemon would be a new moving part.

### Acceptance tests for Part A (named after r3d; each one fails on the current code or on a wrong implementation)

- `stable_inode_contention_and_crash`: independent writers never overlap, the sidecar is never unlinked or renamed, and a sole holder's SIGKILL allows the lock to be taken again.
- `inherited_fd_lifetime`: the four probes above, plus a parent killed while it waits for a stopped child, with results matching the release rule.
- `slot_ownership_and_failure_cleanup`: two distinct locks, a third refused, wrong-file unlock, same-file relock refused, a failed second acquire leaves slot 9 empty and fd 9 closed, and out-of-order release then reacquire never touches the live slot. Each is run in a fresh child and in a `( … )` subshell (refused).
- `caller_timeout_visibility`: a timeout is injected through every caller in the table, with no unlocked write, and the documented line survives each caller's redirects, including the guard and the waiter.
- `lock_order_and_upgrade_boundary`: ledger→board and mark→board work, and the reverse order is not present in the repo (grep). A smoke grep finds no background start inside a section and no other use of fds 8 and 9. The README upgrade step is present.

## Part B: the merge helper becomes a watcher (ruling R105: demote)

### Why the public tool stops merging

r3d showed that a gated merge needs two things this template cannot establish from the client side. First, it must prove that the target branch's required checks are enforced *for the credential that merges*. Rulesets hide their bypass list from the rules endpoint, and the detail endpoints may omit it, so "unknown" cannot honestly become "no bypass". Second, the merge must be a direct one: `gh pr merge` can enrol a merge queue or turn on auto-merge, so the actual merge happens later and is not tied to the observation. This is the second round on the same class (proving server enforcement for this actor), so R31 applies. The public v1 therefore drops merging altogether. The private daemon we run keeps its merge step, and there our own branch protection is the guarantee. That tool is not shipped.

### What the public tool does

`bin/merge-daemon.sh` is replaced by `bin/pr-watch.sh`. The new name says what it does. The old file is removed, not kept as a shim: the repo has no outside users yet.

```
pr-watch.sh PR --head SHA [--require CHECK]... [--repo OWNER/REPO] [--seat SEAT] [--poll S] [--timeout S]
```

1. **It only reads.** The only GitHub call it makes is `gh pr view` (state, head, base, checks). It never calls `gh pr merge`, `gh api` with a method, or any other write. It cannot merge, approve, enqueue or enable auto-merge.
2. **One look per poll.** Each look is one `gh pr view` call. The "second confirming look" is removed: it was an observation dressed as a gate.
3. **Green rule (unchanged).** A check counts as green when it is SUCCESS, NEUTRAL or SKIPPED. A finished check with any other result is red. Every `--require` name must appear and be green. Zero checks counts as pending, so a PR with no checks times out and is never reported green.
4. **Stops when:**
   - the head is not `--head`;
   - a check is red;
   - the PR is closed;
   - the PR is merged by anyone (reported as "merged outside this tool");
   - the timeout passes.
5. **Results.** The last board line starts with one of two words:
   - `WATCH GREEN`, for example: `WATCH GREEN PR 12 at 1a2b3c4d5e6f: checks seen green at 10:34 (observed, not a gate; merging is yours) (receipt …)`.
   - `WATCH FAIL`, followed by the reason.

   The word `POSTCONDITION`, the word `PASS` and the word `merged` are not used for a green result.
6. **The receipt** records:
   - the repo and the PR's base branch as GitHub reported them;
   - the pinned head;
   - the time of the look;
   - each check's name, result and workflow name as reported;
   - the required names;
   - the sentence: "This is an observation at one moment. Nothing was merged. Whether an unchecked merge is possible is decided by the branch protection on the base branch, which this tool does not read."
7. **Exit codes:** 0 = green seen, 1 = stopped or timed out, 2 = usage error. A receipt or board line that cannot be written makes the run exit 1, as before.

### What the public tool does not do, and says so

- It does not inspect branch protection or rulesets, and it makes no claim about them.
- A green report does not freeze anything. A check can turn red, the head can move, or the base can be retargeted after the look.
- It does not decide that a merge is safe. A seat or a person that merges after `WATCH GREEN` is acting on an observation. The guarantee comes from the server: branch protection with required checks, and no bypass for the account that merges.

### Invariants

| # | invariant | why it holds |
|---|---|---|
| W1 | the tool makes no write to GitHub | the only `gh` subcommand in the script is `pr view`; a smoke grep and a gh stub that fails on any other subcommand both check this |
| W2 | `WATCH GREEN` is posted only after a look that showed: the PR open, the head equal to `--head`, every check green, every required name present, and at least one check | `judge` returns ready only in that case; every other path ends in `WATCH FAIL` or keeps waiting |
| W3 | no output claims a merge, a gate or a server guarantee | the help text, receipt and board line are fixed strings, checked by a smoke grep for `PASS`, `merged as`, `gated`, `guarantee` |

### Acceptance tests for Part B (gh stubbed, no network)

- `watch_no_mutation`: the stub logs every gh call and fails on any call other than `pr view`. All runs below pass under it. The old `merge-daemon.sh` fails it as a negative control, because it calls `gh pr merge`.
- `watch_green_language`: on a green PR, the receipt and board line contain "observed, not a gate" and "Nothing was merged", and contain no `PASS` or `merged as`. `--help` says it never merges.
- `watch_stops`: each of these ends `WATCH FAIL` with exit 1 and no green line:
  - the head is not the pinned one;
  - a required check is red;
  - a required check never appears (timeout);
  - there are zero checks (timeout);
  - the PR is closed;
  - the PR was merged elsewhere.
- `watch_receipt_fields`: the base branch, repo, head, time and every check row are in the receipt.

## Part C: wording that lands with the code (exact replacements)

These lines change in the same pull request as the code, so no doc describes behaviour the code does not have yet.

| place | new text |
|---|---|
| README:19 | `\| A long job can wake its owner, a PR can be watched \| while a waiter is running, a job registered with pids.sh posts a wake line to its owner when its process is gone; pr-watch.sh posts WATCH GREEN or WATCH FAIL when a pull request's checks settle at a pinned head. It reports, it never merges \|` |
| README:24 | "`gh` is needed only for `pr-watch.sh`, which you can leave for later." |
| README:68 | "Quick start. Leave pr-watch.sh and cpu-sentinel.py for later." |
| README:84, examples/4-seat/sample-board.md:10 | `[10:34 · BOSS] WATCH GREEN PR 12 at 1a2b3c4d5e6f: checks seen green at 10:34 (observed, not a gate; merging is yours) (receipt receipts/watch_12.md)` |
| README:115 | "`pr-watch.sh` watches one pull request at a pinned head and reports when its checks are green or one fails; it never merges, and a green report is an observation, not a guarantee. Whether an unchecked merge is possible is decided by your branch protection." |
| PROTOCOL:29 | `\| waiting is done by scripts \| pr-watch.sh polls a pull request's checks at a pinned head and posts the result; an agent should not poll for green itself (convention). The tool never merges. Who may merge, and whether unchecked merges are possible, is your branch protection's job \|` |
| PROTOCOL:37 | `\| a watched PR \| a finished watch writes $WARROOM_DIR/receipts/watch_<PR>_<time>.md and posts a board line that starts WATCH GREEN or WATCH FAIL and ends with the receipt path; if either cannot be written the run ends with exit 1 \|` |
| SECURITY:18 | "- pr-watch.sh making any write to GitHub, or reporting WATCH GREEN for a PR that was not open at the pinned head with every check green" |
| SECURITY:24 | "the read-only `gh pr view` calls pr-watch.sh makes" replaces "the `gh` calls the merge daemon makes" |
| CONTRIBUTING:21, examples/4-seat/BOSS.md:7 | "`gh` for pr-watch" and "use `bin/pr-watch.sh` to wait for checks" |
| `_common.sh` header | The Part A contract: L1-L6, the release rule and its residual, the slot rules and supported call forms, reserved fds 8 and 9, never delete a `.flock`, the advisory and local-file-system scope, and the quiescent upgrade |
| README (new lines) | The quiescent-upgrade step, the advisory scope, and "`.flock` files are never deleted" |
| `pids.sh`, `waiter.sh`, `board-guard.sh` | Diagnostics as in the Part A caller table |
| tests/smoke.sh case 13 | Replaced by the four Part B tests |

## Questions for the design-only review (r3d2)

1. Does the last-reference release rule, together with the `wr_run` rule for script children and the disclosed stopped-foreground residual, make L2 true as written?
2. Do the slot rules close the nesting and ownership gaps from r3d BLOCKER 3? Those rules are: canonical FILE, same-FILE refusal, lowest empty slot, no reuse of an occupied slot, `$BASH_SUBSHELL` refusal, and failed-acquire cleanup. Is there a call form we missed?
3. Does the caller table make every lock failure visible without an unlocked write (r3d FIX 3)?
4. Is the quiescent upgrade enough for FIX 4, or is a version marker needed so an old writer refuses to run beside a new one?
5. Do the acceptance tests in Parts A and B tell a correct implementation from a wrong one, or does one of them pass on friendly examples only?
6. Part B: does the watcher make any claim it cannot back? Can it write to GitHub, or report green for anything other than one look at an open PR at the pinned head with every check green? Is any wording still a gate in disguise?
7. Anything in this doc that would let the next review find the same class a third time?

Out of scope here: installer ownership (C699, PR #11) and the FIX bundle (C701, PRs #9 and #10).
