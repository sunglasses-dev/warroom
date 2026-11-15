# A card of your own Claude Code activity

`tools/yearcard.py` reads the session logs Claude Code keeps on your computer and writes one dark card: sessions, replies, prompts, about how many hours you were active, output tokens, your busiest day, the models you used and when in the week you work. It is free, it needs only `python3`, and it is not made or endorsed by Anthropic.

```bash
python3 tools/yearcard.py            # writes claude-code-card.html in the current folder
```

Open the file in a browser and take a screenshot. A sample made from invented logs: [yearcard-sample.html](yearcard-sample.html).

## Why it may say "last 30 days"

Claude Code deletes session logs older than about 30 days unless you raise the `cleanupPeriodDays` setting ([all settings](https://code.claude.com/docs/en/settings-reference)). So most people get a card of their last month, and the card says exactly how many days it found. It says "YOUR 2026 IN CLAUDE CODE" only when the logs span 300 days or more. Raising the setting keeps more logs on your disk; this tool changes no setting. A monthly card is the normal use.

## Where it looks

| system | folder |
|---|---|
| macOS | `~/.claude/projects` (tested) |
| Linux | `~/.claude/projects` (the checks run on Linux in CI; a run on real logs is not tested yet) |
| Windows | `%USERPROFILE%\.claude\projects` (the same code; not tested yet) |
| any, if you set `CLAUDE_CONFIG_DIR` | `$CLAUDE_CONFIG_DIR/projects` |

Another folder: `python3 tools/yearcard.py --logs PATH`. Another file name: `--out FILE`; an existing file is replaced only with `--force`.

## What it keeps from a log line

The line type, the time, the session id, a message id and request id (so one message counts once), the model id, two token counts, and whether a user line has text. Everything else on the line is dropped as it is read. A line it does not understand is skipped and counted; if it finds no usable line it writes no card and says the format may have changed.

## What the card never shows

No file path, folder or project name, branch, prompt or reply text, session title, link, session id, machine name or account. A model id is shown only when it starts with `claude-`; any other id (a proxy or cloud deployment name, for example) is shown as "other".

## What leaves your computer

Nothing. The tool imports no network code and opens no connection. It writes one file. The page it writes has no script, no image, no font file and no link, and its security policy forbids loading anything. `tests/test_yearcard.py` checks each of these, including a run with every network call set to fail.

```bash
python3 -m unittest tests.test_yearcard
```
