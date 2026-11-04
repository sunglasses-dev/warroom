# Installer scope: print the hooks, do not write them

Status: design, not built. The code follows only after this note is reviewed. This replaces an earlier plan in this file (one manifest and one lock per settings file). Review found that plan could still let the installer delete a settings entry it never wrote.

## Why

Four review rounds found the same kind of failure. Whenever `install.sh` decides which entries in the user's `settings.json` are its own, some sequence of events makes it remove, keep or duplicate the wrong one: an interrupted run, a moved clone, two installers, or an entry the user wrote by hand. Each fix added state that the next case broke. So the installer stops writing `settings.json` at all. The failure class is removed, not hardened.

## What `install.sh` does

1. **Writes only war room files:** `warroom.env`, the run directory and an empty board, as today.
2. **Prints the four hook entries as one JSON block,** plus the path of the settings file they belong in. That path is `$CLAUDE_CONFIG_DIR/settings.json`, or `settings.json` in the `.claude` folder in your home folder when that variable is not set.
   - The entries are: `SessionStart` runs `waiter-check.sh`; `UserPromptSubmit` runs `waiter-check.sh`, `board-tail.sh` and `board-guard.sh`.
   - Each command is `bash` followed by the shell-quoted absolute path in this clone.
   - The text says: add these to the `"hooks"` key and keep everything else.
3. **Prints one first message per seat,** as today.

It never opens `settings.json` for writing. There is no manifest, no lock on settings, no settings backup, no adoption of entries and no migration.

## `install.sh --check` (read-only)

- **What it reads:** the same settings file.
- **What it reports:** each of the four (event, command) pairs as present or missing. A pair is present when some entry under that event, with any matcher, has a command exactly equal to the printed string.
- **Exit codes:**
  - 0 when all four pairs are present;
  - 1 when any pair is missing;
  - 2 when the file is missing, is not valid JSON, or `"hooks"` is not an object of lists (it says which).
- **Other war room commands:** commands that name one of the three scripts but are not exactly this clone's are listed as "not this clone", for example after a move. They are listed, not judged.

It writes nothing.

## `install.sh --uninstall` (prints only)

It prints:
- the four entries to remove from the settings file;
- one command that removes `warroom.env` and the run directory, with both paths shown.

It deletes nothing itself.

## A moved clone

The commands hold the clone's absolute path. After a move, `--check` reports the four pairs as missing and lists the old ones as "not this clone". The user replaces them with the block that `install.sh` prints from the new place.

## Two ways in

- **Recommended:** paste the README prompt into a Claude Code session. Claude Code runs `install.sh`, adds the printed block to the settings file itself, then runs `install.sh --check`. The user's own agent edits the user's own file, where the user can see it.
- **By hand:** read `install.sh`, run it, paste the block yourself, run `--check`.

## What this closes, what stays

Closes every finding about the installer owning, migrating, locking or racing on entries in `settings.json`. That code path no longer exists.

Stays, and the README says so:
- **The paste is a manual edit** (by the user or the user's agent). A wrong paste can break `settings.json`. `--check` reports a file that does not parse and entries that are missing; it does not prove the hooks run.
- **Separate writes:** steps 1 and 2 are separate writes, as today.
- **Scope:** the hooks apply to every session that reads that settings file.

For review: what Claude Code does with a settings file or hook entry that is malformed. This note makes no claim about it.

## Tests the code change must add (each fails on the current installer)

1. `install.sh` prints a block that parses as JSON with exactly the four entries, quoted correctly for a clone path that contains a space. The settings file stays byte-identical, and a missing one is not created.
2. `--check` exits 0 with all four present, 1 with one missing, and 2 on invalid JSON or a wrong `"hooks"` shape. The settings file stays byte-identical in every case.
3. `--uninstall` changes no file: the settings file, `warroom.env` and the run directory stay byte-identical.
4. `--dry-run` prints the same block as a real run and writes nothing.
