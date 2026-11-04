## What changed

<!-- One mechanism. One or two sentences. -->

## How I proved it

<!-- The commands you ran and what they printed. A bug fix adds a check to tests/smoke.sh that fails without it. -->

- [ ] `bash tools/leak-check.sh` → 0 hits
- [ ] `shellcheck -S warning` clean on every script I touched
- [ ] `bash tests/smoke.sh` → all passed
- [ ] no new dependencies
