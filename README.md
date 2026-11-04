
# warroom

Run a boss, a manager and two workers in Claude Code all day on one subscription: a shared text file is the chat, a seat wakes only when a line says its name, a merge leaves a receipt, and a finished long job wakes its owner.

## What is it for

- You run more than one Claude Code terminal at the same time.
- They need to hand work to each other without you copy-pasting between windows.
- You do not want them polling, because every poll is paid tokens.

## Why use it

| fact | what it means |
|---|---|
| A text file is the chat | one file, `board.md`; every seat appends a stamped line and reads what is new |
| Nobody polls | a seat starts one background waiter and then sleeps |
| A sleeping seat costs no tokens | the waiter is a shell loop, not a model call; it exits only when a line names its seat |
| A merge leaves a receipt, a long job wakes its owner | a merge writes a file and a final line, `POSTCONDITION PASS` or `POSTCONDITION FAIL`; a job registered with `pids.sh` wakes its owner once when it ends |
| Fresh sessions keep the thread | `reopen.sh` has each seat write a card, then builds one paste message per seat |

## How to use it: two doors

**Door 1: install it yourself**

```
git clone <this repo> && cd warroom
bash install.sh --dry-run     # prints every step, writes nothing
bash install.sh               # writes warroom.env, backs up your Claude Code settings, adds the hooks
```

`install.sh` ends by printing one first message per seat. Paste each into that seat's own Claude Code session.

The hooks point at this clone's absolute path, so keep the clone where it is. If you move it, run `install.sh` again.

**Door 2: show this repo to your AI**

Paste this into a Claude Code session:

```
Read this repo. Install the war room into my Claude Code: seats BOSS MANAGER W1 W2,
then show me how to post my first board line.
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

Only a line that starts with `@SEAT ACTION:` wakes a seat. A plain `@SEAT` in a sentence wakes nobody.

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
    | waiter.sh BOSS ...  waiter.sh W1 ...  one sleeping shell per seat
    v           v           v           v
  exits only when a NEW "@SEAT ACTION:" line names that seat
    |
    v
  that session is told its job finished, reads the line, acts, re-arms the waiter
```

Beside the board: `pids.sh` (a finished long job wakes its owner once), `merge-daemon.sh` (waits for green, merges once, writes a receipt), `cpu-sentinel.py` (names a runaway process on the board), `reopen.sh` (fresh sessions, same thread).

## What it is not

| it is not | so |
|---|---|
| a framework or an agent library | no code of yours imports it |
| a chat API or a server | the whole thing is one file and a few shell scripts |
| a model caller | no script here calls a model; the only model calls are your own Claude Code sessions |
| a way to get more from your plan | it avoids paying for polling; it does not change your limits |

## FAQ

| question | answer |
|---|---|
| Does it work with one seat? | Yes. One seat gets the board, the receipts and the job ledger. The wake lines matter once there is a second seat. |
| Does it need a particular plan? | Not tested on every plan. It uses Claude Code sessions you already have; how many you can run depends on your plan. |
| Windows? | Not yet. The scripts need bash and python3. |
| pip or pipx? | Roadmap, not in v0.1. |
| Where do I ask a question? | Discussions on this repo (Q&A). |

## The story

I am not a programmer. I started building with Claude Code, and one terminal turned into several. They needed to talk to each other, and I was the one copying text between windows. Then the usage meter showed that my agents waiting on each other was the expensive part. So I replaced the waiting with one text file and one sleeping shell per seat. This is that file and those scripts. I use it every day to build [Sunglasses](https://sunglasses.dev), a scanner for AI-agent input.
