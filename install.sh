#!/usr/bin/env bash
# install.sh — set up the war room on this machine. Read it first; it is short.
#   bash install.sh [--seats "BOSS MANAGER W1 W2"] [--dir DIR] [--dry-run]
# What it does, in order:
#   1. writes ~/.warroom/warroom.env (keeps yours if it already exists)
#   2. creates the run directory and an empty board
#   3. copies the Claude Code settings file to a dated backup, then adds four hook entries to it (once; running again changes nothing)
#   4. prints one first message per seat to paste into that seat's session
# Settings live in $CLAUDE_CONFIG_DIR/settings.json, or $HOME/.claude/settings.json when that variable is not set.
# Needs: bash, python3. --dry-run prints every step and writes nothing.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SEATS_ARG="BOSS MANAGER W1 W2"; DIR_ARG="$HOME/warroom-run"; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --seats) SEATS_ARG=$2; shift 2 ;; --dir) DIR_ARG=$2; shift 2 ;; --dry-run) DRY=1; shift ;;
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option $1 (try --help)" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; SET="$CFG/settings.json"; ENVF="$HOME/.warroom/warroom.env"
do_() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }   # runs its arguments as given, no eval
write_env() { printf 'SEATS="%s"\nWARROOM_DIR="%s"\nBOARD="board.md"\n' "$SEATS_ARG" "$DIR_ARG" > "$ENVF"; }

echo "1. config: $ENVF"
if [ -f "$ENVF" ]; then echo "   exists, kept"; else
  do_ mkdir -p "$HOME/.warroom"
  do_ write_env
fi
echo "2. run directory: $DIR_ARG"
do_ mkdir -p "$DIR_ARG"; do_ touch "$DIR_ARG/board.md"

echo "3. hooks in $SET"
if [ $DRY = 1 ]; then echo "   [dry-run] would back up settings.json and add: SessionStart waiter-check, UserPromptSubmit waiter-check, board-tail, board-guard"; else
  mkdir -p "$CFG"
  if [ -f "$SET" ]; then cp "$SET" "$SET.warroom-bak-$(date +%Y%m%d-%H%M%S)"; echo "   backup written"; fi
  HOOKS_DIR="$HERE/hooks" python3 - "$SET" <<'PY'
import json, os, shlex, sys
path = sys.argv[1]; hd = os.environ['HOOKS_DIR']
if not os.path.exists(path):
    data = {}                       # no settings file yet: start an empty one
else:
    try:
        data = json.load(open(path))
    except ValueError as e:         # never overwrite a file we cannot read: the user's settings would be lost
        sys.exit(f"   {path} is not valid JSON ({e}). Fix it (or restore the backup next to it); nothing was changed.")
    if not isinstance(data, dict):
        sys.exit(f"   {path} does not hold a JSON object; nothing was changed.")
hooks = data.setdefault('hooks', {})
want = {'SessionStart': ['waiter-check.sh'],
        'UserPromptSubmit': ['waiter-check.sh', 'board-tail.sh', 'board-guard.sh']}
added = 0
for event, scripts in want.items():
    groups = hooks.setdefault(event, [])
    have = {h.get('command') for g in groups for h in g.get('hooks', [])}
    for s in scripts:
        cmd = 'bash ' + shlex.quote(os.path.join(hd, s))   # quoted: a folder name with a space must still work
        if cmd not in have:
            groups.append({'hooks': [{'type': 'command', 'command': cmd}]}); added += 1
json.dump(data, open(path, 'w'), indent=2)
print(f'   {added} hook(s) added')
PY
fi

echo "4. first message for each seat (paste it as the first message of that seat's session):"
for s in $SEATS_ARG; do
  echo
  echo "   You are $s. First arm your waiter as a background job: bash $HERE/bin/waiter.sh $s <your session id>. Then read $HERE/docs/PROTOCOL.md and post your first line with: bash $HERE/bin/board.sh post $s \"online\""
done
echo
echo "Done. Nothing was run in the background. Remove the four war room hook entries from $SET (or restore the backup) to undo."
