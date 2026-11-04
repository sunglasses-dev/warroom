# Design: the writer lock and the merge gate

Status: DRAFT for a design-only review. No code changes before that review says GO.
Scope: `bin/_common.sh` (`wr_lock`, `wr_unlock`, `wr_reclaim`) and `bin/merge-daemon.sh`, plus the README / PROTOCOL / SECURITY wording about them.

## Why this is a design doc and not a patch

Two review rounds found the same two problems, each time in a new place:

| problem | round 1 | round 2 |
|---|---|---|
| a lock can be held by two writers | a stale-lock check evicted a live holder | the fix moved the hole into recovery: `wr_reclaim` moves the lock aside before it checks who owns it, so it can move a live successor's lock and let a second writer in |
| "green at the pinned head" is not one moment | one look, then merge | two looks, then merge: the gap between the second look and the merge is still there, so a stub that is green twice and red at merge time still merges |

Both fixes patched a symptom and moved the race. This doc changes the mechanism instead, so the race has nowhere to move to.

## Part A: the writer lock

### What the lock is for

There is one writer at a time per protected file: the board (`wr_append`), the seat registry (`waiter.sh`), the job ledger (`pids.sh`), a tail anchor (`board.sh tail`) and a guard mark (`board-guard.sh`). At most two locks are held at once by one process tree: today `pids.sh check` holds the ledger lock while a child `board.sh post` takes the board lock, and `board-guard.sh` holds a mark lock while a child posts.

### Option M: a directory lock plus a reclaim lock (the shape the ruling asked us to argue)

- Lock = `mkdir L.lock`, then write `pid + process start time` into `L.lock/owner`.
- Reclaim = take a second lock, `mkdir L.lock.reclaim`. While holding it, re-read the owner. If the owner is the same dead process we saw, remove `L.lock`. Otherwise leave it alone. Then drop the reclaim lock. Acquirers never remove anything, so validate-then-remove under the reclaim lock cannot hit a live successor.

Option M still has two holes, so it is not the recommendation:

1. **The reclaim lock can go stale too.** If a reclaimer dies while holding `L.lock.reclaim`, someone has to reclaim it, which needs a third lock, and so on. Breaking the recursion with a timeout brings back the exact race we are removing: a slow but live reclaimer gets its reclaim lock removed.
2. **The ownerless window.** Between `mkdir` and writing `owner`, the lock exists with no owner. A holder paused in that window (SIGSTOP, laptop sleep, swap) is indistinguishable from a crashed one. Today's code reclaims an ownerless lock after 10 s. Any number we pick is a guess.

Both holes come from the same root: the file system cannot tell us when a holder died. We are reconstructing that from pids and clocks, and every reconstruction has a window.

### Option K (recommended): a kernel lock that dies with its holder

POSIX shells cannot take a kernel lock directly, but they can hold one. `flock(2)` locks belong to an open file description, not to a process. The shell opens the lock file on a fixed descriptor, a short `python3` child calls `flock` on that inherited descriptor and exits, and the lock stays held as long as the shell keeps the descriptor open. The kernel releases it when the descriptor is closed, including when the holder is killed. python3 is already a runtime dependency: `merge-daemon.sh`, `hooks/board-tail.sh` and `hooks/waiter-check.sh` use it today.

Spec:

```
wr_lock FILE      # take the lock for FILE, wait up to WARROOM_LOCK_WAIT seconds (default 10), return 1 on timeout
wr_unlock FILE    # release it (close the descriptor); a no-op if this process does not hold it
```

- Lock file = `FILE.flock`, a plain empty file. It is created once and **never removed or renamed** (removing a held lock file lets a second opener lock a new inode: the classic flock trap). The old `FILE.lock` directories from earlier versions are ignored, and the README says they can be deleted.
- Descriptor = 8 for the first lock a process holds, 9 for the second. A third nested lock fails loudly (return 1 with "lock nesting limit"), never silently reuses a descriptor. Today's maximum nesting is 2.
- The wait is one `python3 -I -S` call looping `LOCK_EX|LOCK_NB` with a deadline, so a timeout is a clean return 1, not a hang. Measured on this Mac (bash 3.2.57, python 3.14): a full open + lock + close cycle is about 15 ms.
- `wr_unlock` closes the descriptor (`exec 8>&-`). Only the holder has the descriptor, so a non-holder cannot release someone else's lock. That replaces today's owner-file comparison.
- Deleted outright: `wr_reclaim`, the `owner` file, the 10-second ownerless rule, and the "pid reused by another process looks alive" limit. There is nothing left to reclaim.

Invariants this design claims (each one gets a smoke case):

| # | invariant | why it holds |
|---|---|---|
| L1 | two processes never hold the lock for one FILE at the same time | flock(2) exclusive lock on one inode, and the inode is never replaced (lock files are never removed or renamed) |
| L2 | a dead holder never blocks the next writer | the kernel drops the lock when the last descriptor closes, on any exit including SIGKILL |
| L3 | a live holder is never evicted | no code path removes, renames or steals a lock; a waiter can only time out |
| L4 | release by a non-holder is impossible | release = closing your own descriptor |
| L5 | timeout is reported, never silent | `wr_lock` returns 1 and each caller already handles 1 ("could not lock ...") |

Verified on this Mac before writing this (scratch experiment, not repo code): a lock held through an inherited fd 8 blocked a second locker; SIGKILL of the holder released it at once; two nested locks on fds 8 and 9 were both held; a background child that inherited fd 8 kept the lock after its parent exited, and released it when the child ended.

### The one new hazard, and the rule for it

That last result is the cost of Option K: **a child process inherits the lock descriptor.** A command that outlives the critical section keeps the lock held. Today every command run inside a critical section is short-lived (`printf`, `mv`, `board.sh post`). The rules are:

- Inside a critical section, start nothing that can outlive it. If that is ever needed, start it with `8>&- 9>&-`.
- The nesting depth is a plain (not exported) shell variable, so every process starts at depth 0. A child such as `board.sh post` that inherited the parent's fd 8 re-opens fd 8 for its own lock. That closes only the child's copy: the parent's descriptor keeps the parent's lock. This was verified: the parent held `p` on fd 8 while a child re-used fd 8 to lock `q`. Both were held at once, and when the child exited, `q` was free and `p` was still held. Scripts in this repo must not use fds 8/9 for anything else, and a lint/smoke grep enforces that.
- A smoke case starts `sleep` inside a critical section with the close redirections and checks that the lock is free after `wr_unlock`.

### Limits that stay (and are written in the README)

These hold on one machine and a local file system. flock over NFS/SMB is not trusted. Direct writes that bypass `board.sh` (an editor, `echo >>`) are not locked: that is a convention, not a guarantee.

### Rejected alternatives

`flock(1)` is not on macOS. `lockf(1)` and `shlock(1)` run one command under the lock instead of holding it across a shell section. A lock daemon is a new moving part. Symlink locks (`ln -sn pid L`) remove the ownerless window but still need pid-based reclaim, which is the race we are removing.

## Part B: the merge gate

### What changes in the claim

Today the template says it merges "once its checks are green" and backs that with two looks. Round 2 showed two looks are two observations, not a gate: anything can change between the second look and the merge call. Only GitHub can make "required checks green on this exact head" true at merge time, through branch protection or a ruleset with required status checks. So the template stops claiming to be the gate and checks that the real gate exists before it runs.

### Spec

1. **Arm precondition.** Before the first poll, read the target branch's rules:
   - `gh api repos/O/R/rules/branches/BASE` (rulesets; readable with read access), and
   - `gh api repos/O/R/branches/BASE/protection` (classic protection; needs admin, so 403 counts as "cannot read").

   Arm only if at least one source shows **required status checks** that include every `--require` name, and **strict** ("branch must be up to date") is on. The report also notes whether admins can bypass (`enforce_admins` off, or a ruleset bypass list), because that is a hole in the guarantee.
2. **Refusal.** If neither source can be read, or no required checks exist, or a `--require` name is not required on the server, the daemon exits 2 before polling: `not arming: BASE has no server-side required checks (the daemon only observes; GitHub enforces). Add branch protection or a ruleset, or run with --observe-only.`
3. **`--observe-only`** (explicit opt-in) keeps today's behaviour for repos that cannot have protection. Its receipt and board line say `OBSERVED ONLY (no server gate)`, never just `PASS`.
4. **Wording of the two looks.** They stay because they catch the common cases early and cheaply: a moved head, a red check. Help text, receipt and README call them observations. The merge stays pinned with `--match-head-commit`, which GitHub enforces atomically against the head. Required checks are enforced by GitHub on that head.
5. **Receipt** records the protection snapshot it armed on: the source (ruleset or classic), the required check names, strict on or off, and admin bypass yes or no.
6. **Re-read before merge.** The rules are read again right before the merge call, and a change is a FAIL. This is also an observation, and the doc says so: someone with admin rights can change protection after that read. The receipt states this residual. It is not hidden behind "PASS".

Invariants:

| # | invariant | holds because |
|---|---|---|
| G1 | the daemon never merges a head other than `--head` | `--match-head-commit` is checked by GitHub inside the merge call |
| G2 | in gated mode, nothing merges unless GitHub required the named checks green on that head | the daemon refuses to arm unless the server requires them; GitHub refuses the merge otherwise |
| G3 | the daemon never claims more than it checked | gated receipts name the server rules they relied on; observe-only receipts say OBSERVED ONLY |
| G4 | residual: admin bypass and a protection change after the last read | disclosed in the receipt and README; not claimed as covered |

Tests (gh stub, no network): no rules → exit 2 before any poll. Rules without one `--require` name → exit 2. Strict off → exit 2. Rules read OK, then changed before merge → FAIL. `--observe-only` → receipt says OBSERVED ONLY. A stub that is green twice and refuses at merge → FAIL, never PASS (already true, kept).

Found while writing this: `sunglasses-dev/warroom` `main` has no classic protection (`404 Branch not protected`), and its rulesets endpoint returns `[]`. Under this design the daemon would refuse to arm on our own repo until protection is set. That is a repository setting (owner hands), not code.

## Part C: wording to change with the code

- README "Optional helpers" (line 115) and PROTOCOL "waiting is done by scripts" (line 29): "merges once green" becomes "observes until green, then makes one merge attempt pinned to a head; the guarantee is the branch's required checks, which it checks are configured before it starts".
- `_common.sh` header comment: replace the owner/pid/10 s paragraph with the L1-L5 summary and the inherited-descriptor rule.
- SECURITY: list "local file system only" and "admin bypass of branch protection" as known limits.

## Questions for the design-only review

1. Does Option K close the round-2 lock defect as a class, or can you construct two simultaneous holders under the rules above (lock file never removed, fds 8/9, inherited-descriptor rule)?
2. Is the inherited-descriptor hazard handled well enough? That covers a long-lived child keeping a lock, and a child re-using fd 8/9 for its own lock. Or should every `wr_lock` caller close 8/9 for all children it starts?
3. Is Option M's rejection argued correctly, or is there a stale-free reclaim scheme for directory locks we missed?
4. Does the merge-gate precondition (rulesets OR classic, required checks covering every `--require`, strict on) make G2 true, given what GitHub enforces at merge time? Is anything missing, such as required reviews, merge queues, or `required_status_checks` tied to a specific app?
5. Is `--observe-only` an acceptable escape hatch, or should the template refuse outright?
6. Anything in this design that would make the next review find the same class a third time?

Out of scope here: the other round-2 fixes (installer ownership is C699; the FIX bundle is C701).
