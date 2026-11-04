
# warroom

Coordinate several Claude Code sessions through one text file. A shell waiter delivers a matching first-line `ACTION` post to a seat, and optional helpers watch a pull request's checks and leave a receipt of what they saw, and post a wake line to a job's owner when it ends. How many sessions you can run depends on your plan.

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
| A long job can post a wake, a PR can be watched | while a waiter is running, its job check posts a wake line to the owner of a registered job when that process is gone (a process whose start time cannot be read is left in the ledger, not treated as gone), and keeps the ledger row if the post fails; `pr-watch.sh` posts `WATCH GREEN` or `WATCH FAIL` when a pull request's checks settle at a pinned head. It reports, it never merges |
| Reopen prepares fresh sessions | `reopen.sh` asks every seat for a card and builds one paste message per seat; you save each card and check it before closing a session |

## Quick start: two sessions

You need git, bash, python3 and Claude Code, signed in. `gh` is needed only for `pr-watch.sh`, which you can leave for later.

**1. Install.** `install.sh` writes `warroom.env` and the run directory, and prints the four hook entries for you to add. It never edits your Claude Code settings file.

```
git clone https://github.com/sunglasses-dev/warroom warroom && cd warroom
bash install.sh --dry-run     # runs the checks, prints the plan and the hook block, writes nothing
bash install.sh               # writes warroom.env and the run directory, prints the hook block
```

It names the settings file the block belongs in (`$CLAUDE_CONFIG_DIR/settings.json`, or `settings.json` in the `.claude` folder in your home folder) and says what to do for the state that file is in now. Then:

- (a) Save a copy of the settings file. When the file exists, `install.sh` prints the `cp` command; with no file yet there is nothing to copy.
- (b) Add the block. No file yet: create it with the block as its whole content. No `"hooks"` key: add the block's `"hooks"` property and keep every other one. A `"hooks"` key already there: keep every event, group and entry in it, add only the missing entries as a new group at the end of that event's list, and never add a second `"hooks"` key. A file that does not parse: repair it first, do not paste into it.
- (c) Check that the file still parses, and compare it with the copy.
- (d) Run `bash install.sh --check`. It lists where each of the four commands appears in that one file: exit 0 when all four are found, 1 when some are missing, 2 when it cannot read the file (it says why). It checks text, not that the hooks run; Quick start step 4 is the real test.

Take care with the edit. On Claude Code 2.1.318 we saw this, in a fresh session: a settings file that is not valid JSON is reported as not loaded, and nothing in it is in effect, hooks and permission rules included; one hook entry whose command is a number is skipped and the rest of the file stays in effect. Other mistakes were not tried. Whether a session that is already open picks up the change was not checked either: if the banner in Quick start step 3 does not appear, restart the session. Keep the copy until the wake check passes.

The hooks apply to every Claude Code session that reads that settings file, including sessions in other projects. Each session you want left alone opts out on its own with `waiter.sh NONE <session id>`.

`warroom.env` is read as data and never run. It is looked up at `$WARROOM_ENV`, otherwise `~/.warroom/warroom.env`, and nowhere else. `install.sh` refuses to write it, or the board, when either one is the settings file or links to it.

Keep the clone where it is: the hooks hold its absolute path. After a move, `--check` finds the old commands as "other reference" entries; replace them with the block `install.sh` prints from the new place. Writing `warroom.env` and creating the run directory are separate steps: if the second fails, the first stays, and running `install.sh` again continues from there. To remove the war room, `bash install.sh --uninstall` prints the entries to take out and a separate cleanup command; it deletes nothing.

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
then bash install.sh for seats BOSS MANAGER W1 W2. Add the hook block it prints to the settings file
it names, as its advice says for that file: save a copy first, keep every setting, event and entry
already there, add only the missing entries, never a second "hooks" key, and stop and tell me if the
file does not parse. Show me the diff against the copy, then run bash install.sh --check.
I am seat BOSS. Take my session id from the waiter banner (if there is none, tell me to restart this
session) and start my waiter as a Claude Code background task. I will open a second session for W1
with the first message install.sh printed; then run the two-session wake check from the Quick start.
Leave pr-watch.sh, cpu-sentinel.py and the --uninstall cleanup command alone.
```

Nothing in this repo is piped from the internet into a shell. Read `install.sh` first; it is short.

## What a day looks like

A synthetic board (`examples/4-seat/sample-board.md`):

```
[09:00 · BOSS] Day start. Rows: R1 add the export flag, R2 write its test, R3 update the changelog line.
[09:01 · BOSS] @W1 ACTION: take R1. Branch off main, one commit, post the diff stat when done.
[09:02 · W1] TAKEN R1.
[09:31 · W1] R1 done. Flag is --export. 1 file, +14/-2. Receipt receipts/r1.md
[09:32 · W1] @W2 ACTION: R2 can start, flag name above.
[10:13 · MANAGER] @BOSS ACTION: R1 and R2 are ready for your read. PR 12.
[10:34 · BOSS] WATCH GREEN PR 12 at <head>: the PR data returned at 10:34 showed every check green (observed, not a gate; this tool did not merge or modify the PR) (receipt receipts/watch_12.md)
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
  launched as a Claude Code background task: Claude Code reports its exit to
  the session, and the seat then reads the line, acts, and starts its waiter again
```

Optional helpers beside the board: `pids.sh` notices when a registered job's process is gone, `pr-watch.sh` watches one pull request at a pinned head and reports when its checks are green or one fails (it never merges, and a green report is an observation, not a guarantee: whether an unchecked merge is possible is decided by your branch protection), `cpu-sentinel.py` reports selected processes that stay hot, `reopen.sh` prepares the cards and paste messages for fresh sessions.

## What it is not

| it is not | so |
|---|---|
| a framework or an agent library | no code of yours imports it |
| a chat API or a server | there is no server: a board file, state files in the run directory, shell scripts and one Python watchdog |
| a model caller | no script here calls a model; the only model calls are your own Claude Code sessions |
| a way to get more from your plan | it avoids spending model turns on repeatedly checking for work; your plan and its limits still apply |
| a lock for every writer | the board, the seat registry, each seat's cursor and read anchor, the job ledger and the guard's marks are locked against the war room's own scripts, on one machine and a local disk; an editor or an `echo >>` is not locked, and the sentinel's strike file and log and the reopen files are written without that lock. Give each protected file one name (no symlinked or hard-linked board) and never delete a `.flock` file. Upgrading from a version with the old lock: stop every session, waiter and job using this run directory first |
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
