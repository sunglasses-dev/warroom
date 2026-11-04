# Installer scope: a smaller installer instead of a harder one

Status: design, not built. The code change follows only after this note is reviewed.

## Why cut instead of fix

Two review rounds in a row found installer ownership failures of the same kind:
- the first found that the installer could not tell its own settings entries from anyone else's; a manifest was added;
- the next found that it still adopts exact commands it never recorded, that an interrupted move migration loses ownership, and that two installers with different manifest paths race one settings file.

Each fix added state that the next case broke. So the installer stops doing the two things that need that state: migrating a moved clone, and adopting entries it did not record.

## The rules

| rule | what it means |
|---|---|
| One manifest per settings file | Kept at `<settings dir>/warroom-installed-hooks.json`, where the settings dir is the folder of the real settings file (symlinks resolved). It no longer lives next to `warroom.env`, so every installer that targets one settings file reads and writes the same manifest, whatever its `WARROOM_ENV`. It holds the settings path, the clone that wrote it (real path), and each entry it wrote: event, matcher, command, script. |
| One lock per settings file | The same kernel lock as the board (a persistent sidecar, `<real settings path>.warroom.flock`, never deleted, released only by close). It is held from the first read of settings and manifest to the last readback. Two installers for one settings file run one after the other, and the second sees what the first wrote. |
| Ours = listed in the manifest, nothing else | An entry whose command is exactly this clone's hook command but is not in the manifest is not adopted. It is printed as "left alone" and never removed. Install adds nothing next to it, so it is not duplicated. |
| A moved clone is refused | If the manifest's clone is not this clone, install changes nothing. It prints the clone it found and two commands: `bash install.sh --uninstall` (from this clone), then `bash install.sh`. There is no migration code path. |
| `--uninstall` removes exactly the manifest's entries | Whichever clone wrote them. It also removes groups that only those entries filled, then the manifest. It backs up settings first. It leaves `warroom.env`, the run directory and the board, and prints their paths. |

## Order of writes: the manifest always covers what is in settings

Invariant: every war room entry in settings that this installer wrote is listed in the manifest, at every step.

- **Install:** write the manifest (its old entries plus the ones to add), then settings, then read settings back.
  - If it stops after the manifest step, the manifest lists entries that are not in settings. The next install adds them; uninstall skips them.
- **Uninstall:** write settings without the listed entries, read them back, then delete the manifest.
  - If it stops between the two, the next uninstall removes nothing more and deletes the manifest.

No step removes an entry from the manifest while it may still be in settings. So a retry never finds an entry it wrote and no longer knows about.

## What it closes, what stays

Closes:
- **interrupted move migration** (the path is gone);
- **two installers with different manifest paths on one settings file** (one manifest and one lock per settings file; a second clone is refused);
- **implicit adoption of exact commands;**
- **the remaining ownership finding** from the earlier round.

Stays, and is stated in the README:
- **Another program editing settings.json at the same moment can still race it.** The installer compares the bytes just before the replace and stops if they changed, which narrows the window but does not close it.
- **Steps 1-2 (config file, run directory) are separate writes.**
- **A manifest in the old location is not read.** v0.1 is the first release, so no migration from it is offered.

The README install paragraph changes with the code. "If you move it, run `install.sh` again" becomes "if you move it, run `install.sh --uninstall` and then `install.sh` from the new place". The manifest location changes too: it moves from next to `warroom.env` to next to the settings file.

## Tests the code change must add

Each test must fail on the current installer and pass on the new one, with a wrong-code control.

1. An install interrupted at the settings replace, then a normal retry: 4 entries, all listed.
2. An uninstall interrupted after the settings write, then a retry: 0 entries, no manifest.
3. Two installers from two clones with different `WARROOM_ENV`, one settings file, started together: one gets 4 entries and the other refuses. Settings bytes stay valid, and nothing is lost.
4. A moved clone: install refuses, settings bytes are unchanged, and the two commands are printed. Uninstall then install gives 4 entries pointing at the new path.
5. A hand-written exact command with no manifest: not adopted, not duplicated, not removed by uninstall.
6. A symlinked settings file: the manifest and the lock sit next to its real target, and the link stays a link.
