# Security

These scripts run on your machine, read and write files in your run directory, and add hooks to your Claude Code settings. A bug here can matter, so please report it privately.

## Reporting a problem

Use GitHub's private reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Please do not open a public issue for a security problem.

Include what you ran, what happened, and what you expected. A minimal reproduction in a temp directory is ideal.

We aim to reply within 72 hours, tell you what we will do, and credit you in the release notes unless you prefer otherwise.

## What is in scope

- Anything that lets a board line, a file in the run directory, or a pull request run code you did not intend
- The installer changing settings it should not touch
- The leak check missing a kind of leak it says it checks for (it checks a fixed list of patterns, nothing more)
- pr-watch.sh making any write to GitHub, or reporting WATCH GREEN for a PR that was not open at the pinned head with every check green

## What the scripts do not do

These describe what the scripts are written to do. They are not a sandbox: the scripts run with your user's permissions.

- Make network calls of their own, except the read-only `gh pr view` calls pr-watch.sh makes to the repository you point it at. `gh` uses your own GitHub login and configuration. Claude Code itself talks to its own service.
- Ask for elevated rights. Nothing here uses `sudo`, and nothing checks who runs it, so do not run the scripts as root.
- Read files beyond the ones each tool needs. What each reads: the configured run directory and board path (`$WARROOM_DIR` and `$BOARD`, either of which can point outside the clone), the Claude Code settings file, `warroom.env` from `$WARROOM_ENV` or else `~/.warroom/warroom.env` (never found by searching the current folder or the clone), their own scripts, the process list through `ps` (`pids.sh` and `cpu-sentinel.py`), and for `pr-watch.sh` what `gh` reads from its own configuration. `tools/leak-check.sh` reads the tree and the denylist you point it at.
- `warroom.env` is data. It is parsed line by line with a short list of allowed keys and characters and is never sourced or passed to a shell, so a value cannot run code. `cpu-sentinel.py` uses the same keys and characters. Do not repeat a key: the shell scripts and the sentinel are not yet checked to resolve a repeated key the same way.
- When the installer changes an existing settings file it first backs it up, then writes a checked temporary file in the same folder, moves it into place in one step and reads it back. A first install with no settings file, or one with nothing to change, makes no backup. The move does not protect an edit another program makes to the settings file after the installer last compared it.
