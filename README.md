
# warroom

Coordinate several Claude Code sessions through one text file. A shell waiter delivers a matching first-line `ACTION` post to a seat, and optional helpers attempt a receipt for a merge and a post when a job ends. How many sessions you can run depends on your plan.

## What is it for

- You run more than one Claude Code terminal at the same time.
- They need to hand work to each other without you copy-pasting between windows.
- You want shell processes to wait, instead of asking a model to check again and again for work.

## Why use it

| fact | what it means |
|---|---|
| A text file is the chat | messages live in `board.md`; seats use `board.sh` to post and read, and helper state (seat registry, job ledger) sits in the run directory |
| Models need not poll | a local shell waiter checks the board for each seat; the seat starts it as a background task and then sleeps |
| The waiting loop makes no model calls | the waiter normally exits when a matching line arrives; it also exits when another waiter replaces it (exit 3, which is not a wake) and on errors |
| A merge attempt tries to leave a receipt, a long job can post a wake | a non-dry merge attempt tries to write a receipt file and post a line starting `POSTCONDITION PASS` or `POSTCONDITION FAIL`, and ends FAIL if either write fails; while a waiter is running, its job check posts a wake line to the owner of a registered job when that process is gone, and keeps the ledger row if the post fails |
| Reopen prepares fresh sessions | `reopen.sh` asks every seat for a card and builds one paste message per seat; you save each card and check it before closing a session |

## Quick start: two sessions

You need git, bash, python3 and Claude Code, signed in. `gh` is needed only for the merge daemon, which you can leave for later.

**1. Install.** The hooks apply to every Claude Code session that reads the settings file the installer edits, including sessions in other projects. Each session you want left alone opts out on its own with `waiter.sh NONE <session id>`.

```
git clone <this repo> warroom && cd warroom
bash install.sh --dry-run     # runs the checks and prints the plan, writes nothing
bash install.sh               # writes warroom.env, backs up your Claude Code settings, adds four hook entries
```

`warroom.env` is read as data and never run. It is looked up at `$WARROOM_ENV`, otherwise `~/.warroom/warroom.env`, and nowhere else.

Keep the clone where it is: the hooks point at its absolute path. If you move it, run `install.sh` again; the entries for the old place are pointed at the new one. The installer only changes hook entries it wrote itself: it lists them in `installed-hooks.json` next to `warroom.env` and leaves every other entry as it is, even one that looks like a war room hook (it prints those as "left alone"). The three steps are separate writes, not one transaction: if the settings step fails, the config file and run directory from the first two steps stay, and running `install.sh` again continues from there. Two installers at once wait for each other; another program editing settings.json at the same moment can still race it, and the installer stops instead of overwriting when it sees the file changed.

**2. Start two Claude Code sessions** and paste one of the first messages `install.sh` printed into each, for example `BOSS` into the first and `W1` into the second.

**3. Arm each waiter with its real session id.** When a session starts, and on its next prompt, the hook prints a banner that holds the session's own id:

```
[WAITER NOT ARMED] ... as a background job: bash <clone>/bin/waiter.sh <one of: BOSS MANAGER W1 W2> <session id>
```

Pick the seat that session is (the one in the first message you pasted), keep the id exactly as the banner prints it, and put the path in quotes if your folder name has a space:

```
bash "<clone>/bin/waiter.sh" W1 <session id>
```

Tell the session to run that as a Claude Code background task (the Bash tool with `run_in_background`), not with a trailing `&`. Do not make up a session id.

**4. Check that a wake arrives.** From the `BOSS` session, with the path of your clone:

```
bash "<clone>/bin/board.sh" post BOSS '@W1 ACTION: reply with ready'
```

When Claude Code delivers the background task's completion, the `W1` session sees the line the waiter printed; this two-session check is how you confirm it on your machine. The default is a 5-second sleep between checks (`WARROOM_POLL`) and a hold of about 60 seconds between ordinary sequential wakes for one seat (`WARROOM_MIN_GAP`). The seat is expected to act on the line and start its waiter again. If nothing arrives, the next prompt reports a missing or dead waiter; a live waiter can stay silent, so also check the line's grammar, the saved position and the gap.

**Show it to your AI instead.** Paste this into a Claude Code session started in the clone:

```
Read README.md, install.sh and hooks/waiter-check.sh in this folder. Run bash install.sh --dry-run,
then install the war room for seats BOSS MANAGER W1 W2. Take my session id from the waiter banner,
start my waiter as a Claude Code background task, and run the two-session wake check from the
Quick start. Leave merge-daemon.sh and cpu-sentinel.py for later.
```

Nothing in this repo is piped from the internet into a shell. Read `install.sh` first; it is short.

## What a day looks like

A synthetic board (`examples/4-seat/sample-board.md`):

```
[09:00 · BOSS] Day start. Rows: R1 add the export flag, R2 write its test, R3 update the changelog line.
@W1 ACTION: take R1. Branch off main, one commit, post the diff stat when done.
[09:02 · W1] TAKEN R1.
[09:31 · W1] R1 done. Flag is --export. 1 file, +14/-2. Receipt receipts/r1.md
@W2 ACTION: R2 can start, flag name above.
[10:13 · MANAGER] @BOSS ACTION: R1 and R2 are ready for your read. PR 12.
[10:34 · BOSS] POSTCONDITION PASS merge of PR 12: merged (receipt receipts/merge_12.md)
```

A waiter reads only the first line of a post, right after its stamp. A post wakes a seat when that line starts with `@SEAT ACTION:` or `@ALL ACTION:` and the author is another seat. A mention in prose, a quoted directive and any later line of a post wake nobody.

## How it fits together

```
        you
         |  paste one first message per seat
         v
 +-------+--------+--------+--------+
 |  BOSS | MANAGER|   W1   |   W2   |      4 Claude Code sessions
 +---+---+----+---+----+---+----+---+
     |        |        |        |
     |  post  |  post  |  post  |  post     board.sh post SEAT "text"
     v        v        v        v
 +--------------------------------------+
 |              board.md                |    one text file = the chat
 +--+-----------+-----------+-----------+
    |           |           |           |
    | waiter.sh BOSS ...  waiter.sh W1 ...  one waiting shell per seat
    v           v           v           v
  exits when a new "@SEAT ACTION:" line names that seat
  (it also exits when replaced by another waiter, or on an error)
    |
    v
  launched as a Claude Code background task, its exit reaches the session;
  the seat reads the line, acts, and starts its waiter again
```

Optional helpers beside the board: `pids.sh` notices when a registered job's process is gone, `merge-daemon.sh` merges a pull request pinned to one head once its checks are green and writes a receipt (it is a template; the guarantee that nothing merges unchecked is branch protection with required checks on the server), `cpu-sentinel.py` reports selected processes that stay hot, `reopen.sh` prepares the cards and paste messages for fresh sessions.

## What it is not

| it is not | so |
|---|---|
| a framework or an agent library | no code of yours imports it |
| a chat API or a server | there is no server: a board file, state files in the run directory, shell scripts and one Python watchdog |
| a model caller | no script here calls a model; the only model calls are your own Claude Code sessions |
| a way to get more from your plan | it avoids spending model turns on repeatedly checking for work; your plan and its limits still apply |
| a lock for every writer | the board, the job ledger and the state files are locked only against the war room's own scripts, on one machine and a local disk; an editor or an `echo >>` is not locked. Give each protected file one name (no symlinked or hard-linked board) and never delete a `.flock` file. Upgrading from a version with the old lock: stop every session, waiter and job using this run directory first |
| a delivery guarantee | a wake is best-effort: it depends on the waiter running and on how Claude Code launched it. The first arm starts at the end of the board and sees only what comes after. The scripts do not check that a seat acted on a line |

## FAQ

| question | answer |
|---|---|
| Does it work with one seat? | Yes. One seat gets the board, the receipts and the job ledger, and can still receive `GUARD` job and idle alerts. More seats add handoffs between roles. |
| Does it need a particular plan? | Not tested on every plan. It uses Claude Code sessions you already have; how many you can run depends on your plan. |
| Windows? | Not yet. The scripts need bash and python3. |
| pip or pipx? | Roadmap, not in v0.1. |
| Where do I ask a question? | Discussions on this repo (Q&A). |

## The story

I am not a programmer. I started building with Claude Code, and one terminal turned into several. They needed to talk to each other, and I was the one copying text between windows. Then the usage meter showed that my agents waiting on each other was the expensive part. So I replaced the waiting with one text file and one sleeping shell per seat. This is that file and those scripts. I use it every day to build [Sunglasses](https://sunglasses.dev), a scanner for AI-agent input.
