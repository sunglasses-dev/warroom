# Security

These scripts run on your machine, read and write files in your run directory, and run as hooks from your Claude Code settings once you add them. A bug here can matter, so please report it privately.

## Reporting a problem

Use GitHub's private reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Please do not open a public issue for a security problem.

Include what you ran, what happened, and what you expected. A minimal reproduction in a temp directory is ideal.

We aim to reply within 72 hours, tell you what we will do, and credit you in the release notes unless you prefer otherwise.

## What is in scope

- Anything that lets a board line, a file in the run directory, or a pull request run code you did not intend
- A script or hook in this repository that edits the Claude Code settings file as a feature. No dedicated settings editor is included.
- The leak check missing a kind of leak it says it checks for (it checks a fixed list of patterns, nothing more)

## What the scripts do not do

These describe what the scripts are written to do. They are not a sandbox: the scripts run with your user's permissions.

- Make network calls of their own. Claude Code itself talks to its own service.
- Ask for elevated rights. Nothing here uses `sudo`, and nothing checks who runs it, so do not run the scripts as root.
- Read files beyond the ones each tool needs. What each reads: the configured run directory and board path (`$WARROOM_DIR` and `$BOARD`, either of which can point outside the clone), `warroom.env` from `$WARROOM_ENV` or else `~/.warroom/warroom.env` (never found by searching the current folder or the clone), their own scripts, the process list through `ps` (`pids.sh`, `board-guard.sh`, `waiter.sh` and `hooks/waiter-check.sh`). `tools/leak-check.sh` reads the tree and the denylist you point it at.
- `warroom.env` is data. It is parsed line by line with a short list of allowed keys and characters and is never sourced or passed to a shell, so a value cannot run code. A repeated key is refused.
- Import code from your working folder. Every `python3` the scripts and hooks start runs isolated (`-I -S`): it imports only the standard library and ignores the current folder and `PYTHONPATH`, so a `json.py` planted in a project folder is never imported.
- Edit the Claude Code settings file for you. No dedicated settings editor is included. The scripts apply the destination and leaf checks described here; configured paths are not a filesystem sandbox. After reading configuration, a metadata-only validator rejects listed settings basenames for the run folder and the board, the physical config directory for the run folder, and the specified config/state aliases and reserved board paths before bootstrap. Data/state creation uses exclusive create, replacement updates use same-directory rename, and checked board appends, permanent lock-sidecar opens and gap-marker touches use their specified leaf checks. Name checks do not identify arbitrary hard-link or Unicode aliases; existing multi-link board files are separately refused, and path mutation, cross-run nesting and external board sidecars have the stated limits. `docs/INSTALL.md` asks you, or your Claude Code session, to make the one edit by hand after saving a copy.

What the destination checks cover, in plain words. The refused settings names are `settings.json`, its local and managed variants and `.claude.json`, in any letter case. The refused state names are the ones the scripts write inside the run folder (`seats.tsv`, `pids.tsv`, `.cursor-*`, `.lastwake-*`, `.anchor-*`, `.guard-*`, `.poll-*`, `.snap-*`, `*.flock`, and the scripts' temporary files). The settings-name check reads the physical name of the run folder after links are followed: a link named `settings.json` that points to an ordinary folder is accepted, a link that points to the config folder is refused. A board file with more than one hard link is refused when a script locks it or appends to it (for example `board.sh post`); `board.sh path` and `tail` only read it and do not refuse. Run folders nested inside another run folder are not checked against each other. A board outside the run folder gets its lock file (`<board>.flock`) next to it. A folder or link swapped after the checks have run is out of scope, because the checks are not confinement.
