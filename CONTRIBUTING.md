# Contributing

Thanks for looking. This project is small on purpose: a board file, a waiter, a job ledger, a reopen ritual, and a few hooks. A change that keeps it small is the best kind.

## Before you open a pull request

Run the same three checks CI runs. All three must pass.

```bash
bash tools/leak-check.sh          # 0 hits for the configured patterns; it does not read git history, so check names, credentials and history yourself
shellcheck -S warning bin/*.sh hooks/*.sh install.sh tools/*.sh tests/*.sh
bash tests/smoke.sh               # throwaway board in a temp dir: wake, refuse, dead job, guard, installer
```

`python3 -m py_compile bin/*.py` covers the one Python file.

## What a good pull request looks like

- **One mechanism per pull request.** A waiter fix and a new hook are two pull requests.
- **Say how you proved it.** The command you ran and what it printed. If you fixed a bug, add a check to `tests/smoke.sh` that fails without your fix.
- **No new dependencies.** bash, python3, and `gh` for pr-watch. That is the whole list.
- **Plain words in docs.** Say what a thing does, not how good it is.

## How review works

- Every pull request, ours included, needs green CI. (Pull requests from forks run the leak check with the built-in patterns only; a maintainer runs the full list before merging.) External pull requests are never merged automatically: a maintainer reads the whole diff first.
- We aim to answer new issues and pull requests within 24 hours, even if the answer is "not yet".
- If your fork fixes something real and we take it, we thank you by handle in the release notes.

## Questions

Use Discussions for questions, including the ones that feel too basic to ask. Use Issues for bugs and for "it did not wake" reports (there is a template for that).

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), not public issues.
