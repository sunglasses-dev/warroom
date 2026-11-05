# Install by hand

Five steps, run from the clone. Nothing here edits your Claude Code settings for you: you (or your Claude Code session) make the one edit in step 3, with a copy saved first.
1. **Config.** Copy the example and edit the seats, run directory and board name. It is read as data, never run.
```
mkdir -p ~/.warroom && cp warroom.env.example ~/.warroom/warroom.env
```
2. **Run directory and board.** Use the `WARROOM_DIR` and `BOARD` you set in step 1 (the example uses `~/warroom-run` and `board.md`):
```
mkdir -p ~/warroom-run && : >> ~/warroom-run/board.md
```
3. **Hooks.** They go in your Claude Code settings file, `settings.json` in `$CLAUDE_CONFIG_DIR`, or else in the `.claude` folder of your home folder, and apply to every session that reads it. Set `f` to that file (run this line even if the file does not exist yet); the second line saves a uniquely named copy when the file exists and prints nothing when it does not:
```
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
[ -f "$f" ] && cp "$f" "$f.before-warroom-$(date +%s)"
```
Replace `/ABSOLUTE/PATH/TO/warroom` below with the full path of this clone, keeping the single quotes. Merge the `"hooks"` property into the file: no file yet, make this block the whole file; no `"hooks"` key, add this one; a `"hooks"` key already there, keep every event and entry in it and add only these as new groups at the end of each event's list. Never add a second `"hooks"` key or a second JSON document.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash '/ABSOLUTE/PATH/TO/warroom/hooks/waiter-check.sh'" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command", "command": "bash '/ABSOLUTE/PATH/TO/warroom/hooks/waiter-check.sh'" },
        { "type": "command", "command": "bash '/ABSOLUTE/PATH/TO/warroom/hooks/board-tail.sh'" },
        { "type": "command", "command": "bash '/ABSOLUTE/PATH/TO/warroom/hooks/board-guard.sh'" }
      ] }
    ]
  }
}
```

4. **Check the file still parses.** On Claude Code 2.1.318 we saw that a settings file that is not valid JSON is reported as not loaded and nothing in it is in effect, permission rules included. Other mistakes were not tried:
```
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" && echo parses
```
Compare the file with your copy: `diff "$f".before-warroom-* "$f"` (skip this if step 3 made no copy; with several copies, name one instead of the `*`). Keep the copy until step 5 passes.

5. **Two fresh sessions, then the wake check.** Open a new Claude Code session (an open one may need a restart before it uses the hooks) and paste this as its first message, once per seat, with the seat name in place of `BOSS` (use `W1` in the second session) and your clone path in place of the placeholder:

```
You are BOSS. This session shows a [WAITER NOT ARMED] line that ends with your session id. As a background job, run the command that line gives, with BOSS in place of its <one of: …> part, then read docs/PROTOCOL.md in the clone and post: bash '/ABSOLUTE/PATH/TO/warroom/bin/board.sh' post BOSS "online"
```
That paste is README Quick start step 2, so do not paste it again there: continue with its steps 3 and 4. That two-session wake check is the real test. A waiter ends after one wake: re-arm it, as a background job, before the next post.

## Uninstall
Remove the four hook entries from the settings file (they are the commands that end in `waiter-check.sh`, `board-tail.sh` and `board-guard.sh`), stop any waiter or watcher jobs you started, and delete the run directory and `~/.warroom` only after looking inside them: the board, the seat registry and the job ledger are in the run directory and are lost with it.

```
rm -r -- ~/.warroom ~/warroom-run
```
