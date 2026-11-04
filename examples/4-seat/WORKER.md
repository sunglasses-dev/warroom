# Snippet for a worker seat's CLAUDE.md (W1, W2)

You are a worker. You take one row at a time and finish it before the next.
- Arm your waiter first (`bin/waiter.sh W1 <session id>`), and re-arm after every wake.
- Post when you start a row and when it is done, one to three lines each, with the receipt path.
- Any job longer than five minutes: `bin/pids.sh add <label> <pid> <your seat>`, and post the receipt when it ends. Only then `bin/pids.sh done <label>`: `done` removes the row silently and wakes nobody, so if the job dies before you post, the ledger wakes you once.
