# Install by hand

Five steps, run from the clone. You need git, bash, python3 and Claude Code, signed in; python3 must be on the PATH your Claude Code hooks run with. There is no settings installer: you add the hook entries by hand after saving a copy. Prefer paths outside the config folder; W equal to its physical directory and the listed W/B settings basenames are refused, while dedicated subdirectories remain allowed.
1. **Config.** Copy the example and edit the seats, run directory and board name. It is read as data, never run. An existing `~/.warroom/warroom.env` is kept as it is: edit it instead.
```
mkdir -p ~/.warroom && { [ -e ~/.warroom/warroom.env ] || cp warroom.env.example ~/.warroom/warroom.env; }
```
2. **Run directory and board.** Use the `WARROOM_DIR` and `BOARD` you set in step 1 (the example uses `~/warroom-run` and `board.md`):
```
mkdir -p ~/warroom-run && : >> ~/warroom-run/board.md
```
3. **Hooks.** They go in your Claude Code settings file, `settings.json` in `$CLAUDE_CONFIG_DIR`, or else in the `.claude` folder of your home folder, and apply to every session that reads it. Run all three lines: they set `f` to that file, create its folder if missing, and save a new copy under a name that is not already taken (they print the name, or `backup FAILED` if the copy could not be written, for instance when the name is already taken: then stop and do not edit, and delete any empty copy; with no file yet there is no copy):
```
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
mkdir -p "$(dirname "$f")"
[ ! -f "$f" ] || { b="$f.before-warroom-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"; ( set -C; cat "$f" > "$b" ) && echo "saved $b" || echo "backup FAILED, stop here: do not edit $f"; }
```
First run the check in step 4 on the file as it is: if it fails, stop and repair that first (a file that does not parse, or a `"hooks"` of the wrong shape). Replace `/ABSOLUTE/PATH/TO/warroom` below with the full path of this clone, keeping the single quotes. The path must not contain a single quote: move the clone first if it does. Merge the `"hooks"` property into the file: no file yet, make this block the whole file; no `"hooks"` key, add this one; a `"hooks"` key already there, keep every event and entry in it and add only these as new groups at the end of each event's list, skipping any entry that is already there with the same command. Never add a second `"hooks"` key or a second JSON document.

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

4. **Check the file.** On Claude Code 2.1.318 we saw two things, each in a fresh session: a settings file that is not valid JSON is reported as not loaded and nothing in it is in effect, permission rules included; one hook entry whose command is a number is skipped and the rest of the file stays in effect. Nothing else was tried. This command checks JSON and the shape of `"hooks"` (an object of lists of groups, each group holding a `"hooks"` list), not that Claude Code runs the hooks; step 5 does that:
```
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); h=d.get("hooks",{}) if isinstance(d,dict) else None; ok=isinstance(h,dict) and all(isinstance(g,list) and all(isinstance(x,dict) and isinstance(x.get("hooks"),list) for x in g) for g in h.values()); sys.exit(0 if ok else "hooks: wrong shape, repair first")' "$f" && echo parses
```
Compare the file with your copy: `diff "$f".before-warroom-* "$f"` (skip this if step 3 made no copy; with several copies, name one instead of the `*`). Keep the copy until step 5 passes. To go back, copy it over the file: `cp "$b" "$f"` with the name step 3 printed.

5. **Two fresh sessions, then the wake check.** Open a new Claude Code session (an open one may need a restart before it uses the hooks) and paste this as its first message, once per seat, with the seat name in place of `BOSS` (use `W1` in the second session) and your clone path in place of the placeholder:

```
You are BOSS. This session shows a [WAITER NOT ARMED] line whose waiter command holds your session id. As a background job, run the command that line gives, with BOSS in place of its <one of: …> part, then read docs/PROTOCOL.md in the clone and post: bash '/ABSOLUTE/PATH/TO/warroom/bin/board.sh' post BOSS "online"
```
That paste is README Quick start step 2, so do not paste it again there: continue with its steps 3 and 4. That two-session wake check is the real test. A waiter ends after one wake: re-arm it, as a background job, before the next post.

## Uninstall
Stop every session, waiter and job that uses this run directory first. Then remove only the four hook entries whose commands name this clone's path (`bash '<clone>/hooks/waiter-check.sh'`, `board-tail.sh`, `board-guard.sh`); other entries stay. Find your real paths, because an edited `BOARD` can be a full path outside the run directory and stays unless you delete it too:

```
grep -E '^(WARROOM_DIR|BOARD)=' ~/.warroom/warroom.env
```
Delete the folders it names (default `~/warroom-run`) and `~/.warroom` only after looking inside them: the board, the seat registry and the job ledger are in the run directory and are lost with it.

```
rm -r -- ~/.warroom ~/warroom-run
```
