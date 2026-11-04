# Security

These scripts run on your machine, read and write files in your run directory, and add hooks to your Claude Code settings. A bug here can matter, so please report it privately.

## Reporting a problem

Use GitHub's private reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Please do not open a public issue for a security problem.

Include what you ran, what happened, and what you expected. A minimal reproduction in a temp directory is ideal.

We reply within 72 hours, tell you what we will do, and credit you in the release notes unless you prefer otherwise.

## What is in scope

- Anything that lets a board line, a file in the run directory, or a pull request run code you did not intend
- The installer changing settings it should not touch
- The leak check missing a class of secret it claims to catch
- The merge daemon merging something that is not green, or not the pinned head

## What the scripts never do

- Send anything over the network, except `gh` calls the merge daemon makes to the repository you point it at
- Run anything as root
- Read files outside the run directory and the Claude Code settings file
