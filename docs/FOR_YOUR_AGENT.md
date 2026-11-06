# For your agent

You are an AI agent. Your user said something like "read this repo and set it up for us". This page is for you. It says what each part does, why it exists, when your user wants it, and how to build it. The README tells the story; the exact commands are in [INSTALL.md](INSTALL.md) and the rules are in [PROTOCOL.md](PROTOCOL.md).

## Frame

- **Developer mode.** This is for Claude Code in terminal sessions: several terminals on one project, working as a team. It is not for the web app or the desktop app.
- **Project scope.** Every setting on this page belongs in the project's `.claude/settings.json` and the project's hooks, not in your user's global Claude Code settings. INSTALL.md step 3 points `f` at the user-level settings file, which applies to every session that reads it. To keep the setup project-scoped, set `f` to the project's `.claude/settings.json` instead and follow the same copy, merge and check steps. We wrote INSTALL.md for the user-level file and have not tested the project-level placement, so run the two-session wake check from the README Quick start after you place the hooks.
- **Ask first.** Where a block says **Ask**, put the question to your user and wait. Never change a setting they did not agree to. Before you edit any settings file, save a copy, as INSTALL.md step 3 shows.
- **What ships and what does not.** Blocks 1 to 8 are scripts in this repo. Blocks 9 and 10 are things we do and settings we use; no script here does them.

## 1. Board

| | |
|---|---|
| What | One text file, `board.md`. Each post is a line `[HH:MM · SEAT] text`. |
| Why | Terminals needed to hand work to each other, and the user was the one copying text between windows. |
| When you want it | Always. Everything else reads or writes it. |
| Build | `bin/board.sh post SEAT "text"`, `tail SEAT`, `read [N]`. Create the file with `: >> "$WARROOM_DIR/board.md"` (INSTALL.md step 2). Posts are limited to 10 lines; `WARROOM_LONG=1` lifts the limit for one call. |

## 2. Mention waiter

| | |
|---|---|
| What | A shell loop, one per seat, that sleeps and exits when a new post starts with `@SEAT ACTION:` or `@ALL ACTION:` from another seat. |
| Why | Having a model check again and again for work was the expensive part. A shell does the waiting and makes no model calls. |
| When you want it | Two or more seats that hand work to each other. |
| Build | `bin/waiter.sh SEAT SESSION_ID`, started by the seat as a Claude Code background task (`run_in_background`), not with a trailing `&`. It ends after one wake, so the seat starts it again after every wake. Only the first line of a post counts. The hook in block 3 prints the exact command with the session id. |
| Ask | Which seats, and their names. Defaults are `BOSS MANAGER W1 W2`; set them in `~/.warroom/warroom.env` (`SEATS=`). |

## 3. Waiter check hook

| | |
|---|---|
| What | `hooks/waiter-check.sh` prints a one-line banner when a seat's waiter is missing or has ended. |
| Why | A seat that forgets to start its waiter never wakes, and nothing tells it. |
| When you want it | Whenever block 2 is in use. |
| Build | Entries under `SessionStart` and `UserPromptSubmit` in the settings file, as in INSTALL.md step 3. Merge into any existing `"hooks"` object; never write a second `"hooks"` key. Check that the file still parses (INSTALL.md step 4). |

## 4. Board tail hook

| | |
|---|---|
| What | `hooks/board-tail.sh` shows how many board lines are new for the seat and prints the ones that name it. |
| Why | A seat reads what is addressed to it without reading the whole board. |
| When you want it | With block 2. |
| Build | A `UserPromptSubmit` entry, in the same block as block 3. |

## 5. Job ledger

| | |
|---|---|
| What | `bin/pids.sh` keeps a list of long jobs with the seat that owns each. When a job's process is gone, the waiter's check posts a wake line to the owner. |
| Why | A seat should not poll for a build or a long run. It registers the job and sleeps. |
| When you want it | Any job that runs longer than a seat wants to sit and watch. |
| Build | `bin/pids.sh add LABEL PID OWNER`. Use `done LABEL` only after the job has posted its own result. No daemon: the waiter runs the check on every poll, so a job is noticed only while some waiter is running. |

## 6. Idle guard

| | |
|---|---|
| What | `hooks/board-guard.sh` posts one `@SEAT ACTION:` line, at most once per silence, naming a seat with no post for `WARROOM_IDLE_MIN` minutes (default 30) and no registered job running. |
| Why | A stalled seat is easy to miss when nobody is reading the board. |
| When you want it | Three or more seats, or a user who is away for hours. A single seat can still use it. |
| Build | A `UserPromptSubmit` entry, in the same block as block 3. |
| Ask | The silence limit. Lower it for fast work, raise it for slow work. |

## 7. Writer lock

| | |
|---|---|
| What | The scripts take a lock on the board, the seat registry, each seat's position and the job ledger, so two scripts never write one file at once. |
| Why | Several seats post in the same second. |
| When you want it | Nothing to build; it is on. Know its limit: an editor or `echo >>` on the board is not locked. Use `board.sh post`. |
| Build | Already in `bin/_common.sh`. Details are in the Writer lock section of PROTOCOL.md. |

## 8. Leak check

| | |
|---|---|
| What | `tools/leak-check.sh [DIR]` fails when a tree holds home-directory paths, e-mail addresses, 40-character hex ids, token shapes, numbered seat names, or any pattern from a private list. |
| Why | A repo made public can publish names and paths its owner never meant to. |
| When you want it | Before any repo that holds a run directory's contents, notes or logs becomes public, and in CI. |
| Build | `bash tools/leak-check.sh`. Put private patterns in a file outside the repo and set `LEAKCHECK_DENYLIST` to it. It reads current text files only, not git history; a clean run is not proof that a tree is safe. |
| Ask | Which names, products or people must never appear. You write the private list from the answer. |

## 9. Reopen rhythm (a convention)

| | |
|---|---|
| What | Every 24 to 30 hours, and never while a seat is in the middle of a row, each seat writes a card, posts that it is banked, and the user opens fresh sessions and pastes one message per seat. |
| Why | We saw long-running sessions get worse over time. This is our experience; we have not measured it. |
| When you want it | Sessions that run for days. Skip it for short work. |
| Build | No script. A card is a short file in `$WARROOM_DIR/cards/`: the seat's name, its current row, what is done and verified, what is next, and anything it is waiting on. The first message for a fresh seat says: read your card, read the last 15 board lines, check live state before trusting anything written, then continue. |
| Ask | How often the user is willing to reopen. |

## 10. Compaction window and re-orient hook (settings we use)

| | |
|---|---|
| What | A setting that decides when Claude Code compacts a long conversation, and a hook that tells a seat what to re-read afterwards. |
| Why | We set the window to 250000 because long seats got worse and lost track of their row past that point. This is our experience, not a measurement. A summary is a hint: after a compaction the seat re-reads its card and the board instead of trusting it. |
| When you want it | Seats that stay open for hours. |
| Ask | Offer three choices and wait: adopt our value, keep the compaction setting the user already has, or stay on the default. No rule says which is right for their work. |

Build the setting (the key is `autoCompactWindow`, a token count; check it against the settings reference of the user's Claude Code version, because it is a setting we use and not part of this repo). Put it in the project's `.claude/settings.json`:

```json
{ "autoCompactWindow": 250000 }
```

Build the hook. Save this as a script outside the clone's tracked files, for example `.claude/post-compact-reorient.sh` in the project, and replace the placeholder with the full path of the clone:

```bash
#!/usr/bin/env bash
# SessionStart hook, matcher "compact": runs right after a compaction. What it prints reaches the model.
echo "Your context was just compacted. The summary above is a hint, not the truth. Before your next action:"
echo "1. Re-read your newest card in the cards folder of the run directory (WARROOM_DIR in ~/.warroom/warroom.env)."
echo "2. Run: bash '/ABSOLUTE/PATH/TO/warroom/bin/board.sh' read 15"
echo "3. Check live state yourself before relying on any id, version or status in the summary."
echo "4. Continue the row you were on. Do not close or bank: the compaction replaced the reopen."
```

Then merge this entry into the project's `hooks` object, the same way as block 3:

```json
{ "hooks": { "SessionStart": [ { "matcher": "compact", "hooks": [ { "type": "command", "command": "bash '/ABSOLUTE/PATH/TO/.claude/post-compact-reorient.sh'" } ] } ] } }
```

After a compaction in a real session, check that its five lines appear. If they do not, the hook did not load: restart the session.

## Order for a first setup

1. Ask the seats question (block 2) and the silence limit (block 6).
2. Follow INSTALL.md steps 1 to 4 (blocks 1 to 4, and 6), with `f` set to the project's settings file as in Frame.
3. Do INSTALL.md step 5, then the two-session wake check from the README Quick start. It is the real test.
4. Offer block 10 and block 9. Add them only if the user says yes.
5. Register long jobs with block 5 from then on.
