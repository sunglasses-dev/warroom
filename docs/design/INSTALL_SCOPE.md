# Installer scope: print the hooks, do not write them

Status: built. An earlier plan in this file kept one manifest and one lock per settings file; review found it could still delete a settings entry the installer never wrote.

## Why

Four review rounds found the same kind of failure. Whenever `install.sh` decided which entries in the user's `settings.json` were its own, some sequence of events made it remove, keep or duplicate the wrong one: an interrupted run, a moved clone, two installers, or an entry the user wrote by hand. Each fix added state that the next case broke. So the installer no longer writes `settings.json`. The ownership problem is removed, not hardened.

## What `install.sh` does

1. **Two runtime writes:** `warroom.env`, and the run directory with the board (created if missing; an existing board is left as it is). These are separate writes; if the second fails, the first stays.
2. **No write target may be the settings file.** Before writing, it resolves every destination (`warroom.env`, its temp and backup names, the run directory, the board) and refuses when one is the settings file or links to it. Without this, `WARROOM_ENV` naming the settings file plus `--replace-config` would overwrite it with config text. It assumes stable paths: it does not defend against a file being swapped while it runs.
3. **Prints one first message per seat.**
4. **Prints the four hook entries as one JSON block, last** (one top-level `"hooks"` object), so the block ends the output: the settings file they belong in, and what to do for the state that file is in now: missing, empty, not valid JSON, no `"hooks"` key, some entries missing, all present. When the file exists, it prints a copy command to run first.
   - Settings file: `$CLAUDE_CONFIG_DIR/settings.json`, or `settings.json` in the `.claude` folder in your home folder.
   - Entries: `SessionStart` runs `waiter-check.sh`; `UserPromptSubmit` runs `waiter-check.sh`, `board-tail.sh` and `board-guard.sh`. Each command is `bash` plus the shell-quoted absolute path in this clone.

A dry run ends with "Dry run: nothing was written", not with the "Done" and undo lines of a real run.

It reads the settings file to give that advice, and never opens it for writing. There is no manifest, no lock on settings, no settings backup, no adoption of entries and no migration. Files left by the earlier implementation (a manifest next to `warroom.env`, settings backups) are not read, moved or deleted.

`--check`, `--uninstall` and `--dry-run` run every check and write nothing. `install.sh` loads only `bin/_config.sh`, which defines functions and writes nothing.

## `install.sh --check` (read only)

An inventory of one file, by exact command text. It does not read other settings files, does not show that hooks are enabled or that they run, and runs nothing.

- For each of the four (event, command) pairs: how many times it was found, and where (group, entry, matcher). A matcher is shown, not judged.
- Skipped, with the reason: an entry under the two events that is not an object, has a `"command"` that is not a string, or a `"type"` that is not `"command"`.
- **Other reference:** a command that names one of the three scripts but differs from this clone's text: an older clone, the same path quoted another way, or another tool. Listed for review by hand, never counted.
- A `"disableAllHooks": true` in the file is shown.
- **Exit codes:** 0 = all four found; 1 = at least one not found in a file it could inspect (no `"hooks"` key or no such event counts as not found); 2 = it cannot inspect the file: missing, empty, unreadable, a directory, not valid JSON, a key set twice in one object, a root that is not an object, `"hooks"` that is not an object, or one of the two events that is not a list of groups. Each case prints its reason.

## `install.sh --uninstall` (prints only)

1. What the settings file holds now: this clone's entries and other references, with their locations. The user removes the ones that are this war room's and keeps the groups and hooks around them.
2. The four commands this clone prints.
3. A separate, optional cleanup command: `rm -r --` with `warroom.env` and the run directory, shell-quoted. When `warroom.env` is in the default `~/.warroom` folder and that folder holds only it and its backups, the folder is listed instead, so no empty folder is left; a `WARROOM_ENV` you chose is listed as that one file. It says first that this deletes the board, its whole history, the state files and any receipts there, and that it should run only after every seat session and background job has stopped.

It deletes nothing itself.

## A moved clone

The commands hold the clone's absolute path. After a move, `--check` usually finds none of the four new commands and lists the old ones as other references; a partial edit gives a mix. The user replaces them with the block `install.sh` prints from the new place.

## Two ways in

- **By hand:** read `install.sh`, run it, save a copy of the settings file, add the block as its advice says, run `--check`, then the two-session wake check in the README.
- **With your Claude Code session:** the README prompt asks the session to do the same edit, show the diff and run `--check`. The user's agent edits the user's file; that is visible, not verified. The wake check is the real test.

## What stays

- **The settings edit is manual** (by the user or the user's agent): taking a copy first, valid JSON, merging into existing events, not adding duplicates, and not editing at the same time as another program are the editor's job. There is no rollback.
- **A wrong paste has a wide effect.** Observed on Claude Code 2.1.318, in a fresh session: a settings file that is not valid JSON is reported as not loaded, and nothing in it is in effect, hooks and permission rules included; one hook entry whose command is a number is skipped and the rest of the file stays in effect. Other shapes, live reload in an open session and how other settings files combine with a rejected one were not checked.
- **`--check` limits:** one file, exact text. It does not cover effective scope, enabled hooks, other spellings of the same command, script health or actual delivery.
- **Cleanup is manual.** A moved clone or an uninstall needs entries removed by hand; a familiar script name is not proof of where an entry came from.
- **Scope:** the hooks apply to every session that reads that settings file.

## Tests (`tests/smoke.sh` sections 5, 18, 19, 22, 23, 26, 26b, 26c)

- The printed block parses as JSON with exactly the four entries, and each command splits back to `bash` and the path, for a clone path with a space and an apostrophe. The settings file stays byte-identical; a missing one is not created.
- `--check` gives 0 / 1 / 2 with the reason for each case (all found, one missing, invalid JSON, a key twice, wrong `"hooks"` shapes, a missing file), byte-identical every time; counts and matchers, skipped entries, other spellings and `disableAllHooks` are reported.
- `--uninstall` exits 0, lists four entries, prints the block, the target path and the quoted cleanup command, and changes no file, mtimes included.
- In a fresh home, `--check`, `--uninstall` and `--dry-run` create nothing; `--dry-run` prints the same non-empty block as a real run.
- `WARROOM_ENV` naming the settings file, or a link to it, and a board that links to it (also a dangling link) are refused before any write; a normal install keeps an existing board unchanged.
- The hook block comes after the seat messages and ends the output; a dry run says nothing was written and offers no undo; `--uninstall` lists the default `~/.warroom` folder only when it holds `warroom.env` and its backups alone (another file or a link there, or a `WARROOM_ENV` you chose: the file only).
- Run against the previous installer, the new tests in sections 5, 18, 19, 22, 23, 26 and 26b fail.
