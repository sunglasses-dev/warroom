#!/usr/bin/env bash
# install.sh — set up the war room on this machine. Read it first; it is short.
#   bash install.sh [--seats "BOSS MANAGER W1 W2"] [--dir DIR] [--replace-config] [--dry-run]
# What it does, in order (every check runs before anything is written):
#   1. writes warroom.env ($WARROOM_ENV, else ~/.warroom/warroom.env). An existing one is kept and used; if --seats or
#      --dir ask for something else it stops and says so. --replace-config backs the old file up and writes a new one.
#   2. creates the run directory and an empty board
#   3. adds four hook entries to the Claude Code settings file: a backup first, then a temp file in the same folder that
#      is checked and moved into place in one step, then read back. Running again changes nothing. Entries from a clone
#      that was moved are pointed at this clone instead of being added twice.
#   4. prints one first message per seat to paste into that seat's session
# Settings live in $CLAUDE_CONFIG_DIR/settings.json, or $HOME/.claude/settings.json when that variable is not set.
# Seats: [A-Z][A-Z0-9_]{0,15}; ALL, NONE, GUARD are reserved. DIR: an absolute path of letters, digits, space, _ . / ~ -
# Needs: bash, python3. --dry-run runs every check, prints the plan and writes nothing.
set -e
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/_config.sh
. "$HERE/bin/_config.sh"
SEATS_ARG=""; DIR_ARG=""; DRY=0; REPLACE=0
DEF_SEATS="BOSS MANAGER W1 W2"; DEF_DIR="$HOME/warroom-run"
while [ $# -gt 0 ]; do case "$1" in
  --seats) SEATS_ARG=${2:?--seats needs a value}; shift 2 ;; --dir) DIR_ARG=${2:?--dir needs a value}; shift 2 ;;
  --replace-config) REPLACE=1; shift ;; --dry-run) DRY=1; shift ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option $1 (try --help)" >&2; exit 2 ;; esac; done
die() { echo "install.sh: $*" >&2; echo "Nothing was changed." >&2; exit 1; }
command -v python3 >/dev/null || die "python3 is required"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; SET="$CFG/settings.json"; ENVF=$(wr_config_path)
q() { printf '%q' "$1"; }   # a path printed for copy-paste, quoted when it needs it

# --- checks (no writes) ---
if [ -n "$SEATS_ARG" ]; then
  wr_seats_ok "$SEATS_ARG" || die "--seats '$SEATS_ARG': names are [A-Z][A-Z0-9_]{0,15}, no repeats; ALL, NONE and GUARD are reserved"
  # shellcheck disable=SC2086,SC2116  # word splitting on purpose: one space between names
  SEATS_ARG=$(echo $SEATS_ARG)
fi
if [ -n "$DIR_ARG" ]; then
  DIR_ARG=$(wr_check_value "$DIR_ARG") || die "--dir '$DIR_ARG': use letters, digits, space and _ . / ~ - only"
  case "$DIR_ARG" in /*) ;; *) die "--dir must be an absolute path (it is used from every folder)" ;; esac
fi
WRITE_ENV=1
if [ -f "$ENVF" ] && [ $REPLACE = 0 ]; then
  # read the existing file with the same parser the scripts use, with the environment out of the way
  have=$(unset SEATS WARROOM_DIR BOARD; wr_load_config "$ENVF" && printf '%s\n%s\n' "${SEATS:-}" "${WARROOM_DIR:-}") \
    || die "$ENVF is not a valid warroom.env (reason above). Fix it, or pass --replace-config to back it up and write a new one."
  H_SEATS=$(printf '%s\n' "$have" | sed -n 1p); H_DIR=$(printf '%s\n' "$have" | sed -n 2p)
  # shellcheck disable=SC2086,SC2116  # word splitting on purpose: one space between names
  H_SEATS=$(echo ${H_SEATS:-$DEF_SEATS}); H_DIR=${H_DIR:-$DEF_DIR}
  [ -z "$SEATS_ARG" ] || [ "$SEATS_ARG" = "$H_SEATS" ] || die "$ENVF already has SEATS=\"$H_SEATS\", not \"$SEATS_ARG\". Edit it, or pass --replace-config."
  [ -z "$DIR_ARG" ] || [ "$DIR_ARG" = "$H_DIR" ] || die "$ENVF already has WARROOM_DIR=\"$H_DIR\", not \"$DIR_ARG\". Edit it, or pass --replace-config."
  SEATS_USE=$H_SEATS; DIR_USE=$H_DIR; WRITE_ENV=0
else
  SEATS_USE=${SEATS_ARG:-$DEF_SEATS}; DIR_USE=${DIR_ARG:-$DEF_DIR}
fi
# the settings file is checked before anything is written; the same program writes it in step 3
settings() { HOOKS_DIR="$HERE/hooks" python3 - "$1" "$SET" <<'PY'
import json, os, shlex, stat, sys, tempfile, time
mode, path = sys.argv[1], os.path.realpath(sys.argv[2])   # realpath: a symlinked settings.json keeps its link
hd = os.environ['HOOKS_DIR']
WANT = {'SessionStart': ['waiter-check.sh'], 'UserPromptSubmit': ['waiter-check.sh', 'board-tail.sh', 'board-guard.sh']}
NAMES = {'waiter-check.sh', 'board-tail.sh', 'board-guard.sh'}
def die(msg):
    tail = ' Nothing was changed.' if mode == 'check' else ' settings.json was not changed.'
    print('   ' + msg + tail, file=sys.stderr); sys.exit(1)
raw = None; data = {}
if os.path.exists(path):
    with open(path, 'rb') as f:
        raw = f.read()
    try:
        data = json.loads(raw)
    except ValueError as e:
        die(f'{path} is not valid JSON ({e}). Fix it, or restore a backup next to it.')
    if not isinstance(data, dict):
        die(f'{path} does not hold a JSON object.')
hooks = data.get('hooks', {})
if not isinstance(hooks, dict):
    die(f'{path}: "hooks" is not a JSON object.')
for ev in WANT:
    groups = hooks.get(ev, [])
    ok = isinstance(groups, list) and all(isinstance(g, dict) and isinstance(g.get('hooks', []), list)
                                          and all(isinstance(h, dict) for h in g.get('hooks', [])) for g in groups)
    if not ok:
        die(f'{path}: hooks.{ev} is not a list of hook groups.')
mine = lambda s: 'bash ' + shlex.quote(os.path.join(hd, s))
def ours(cmd):
    """the script name when cmd is a war room hook from some clone (this one or a moved one), else None"""
    try:
        parts = shlex.split(cmd) if isinstance(cmd, str) else []
    except ValueError:
        return None
    if len(parts) != 2 or parts[0] != 'bash':
        return None
    p = parts[1]; name = os.path.basename(p)
    if name not in NAMES or os.path.basename(os.path.dirname(p)) != 'hooks':
        return None
    clone = os.path.dirname(os.path.dirname(p))
    if os.path.exists(p) and not os.path.isfile(os.path.join(clone, 'bin', 'waiter.sh')):
        return None                   # a live file from some other tool: not ours, leave it alone
    return name
new = json.loads(json.dumps(data)); nh = new.setdefault('hooks', {})
added = moved = dropped = 0
for ev, scripts in WANT.items():
    groups = nh.setdefault(ev, []); seen = set(); emptied = []
    for g in groups:
        keep = []; before = len(g.get('hooks', []))
        for h in g.get('hooks', []):
            name = ours(h.get('command'))
            if name is not None:
                if h.get('command') != mine(name):
                    h['command'] = mine(name); moved += 1     # entry from a moved clone: point it here
                if h['command'] in seen:
                    dropped += 1; continue                    # a second copy of the same entry
                seen.add(h['command'])
            keep.append(h)
        if 'hooks' in g:
            g['hooks'] = keep
        if before and not keep:
            emptied.append(g)                                  # only groups this run emptied are removed
    nh[ev] = [g for g in groups if not any(g is e for e in emptied)]
    for s in scripts:
        if mine(s) not in seen:
            nh[ev].append({'hooks': [{'type': 'command', 'command': mine(s)}]}); added += 1
plan = f'{added} to add, {moved} to point at this clone, {dropped} duplicate(s) to remove'
if new == data and raw is not None:
    print('   already installed, nothing to change'); sys.exit(0)
if mode == 'check':
    print(f'   settings ok: {plan}'); sys.exit(0)
d = os.path.dirname(path); os.makedirs(d, exist_ok=True)
bak = None
if raw is not None:   # backup name carries pid + milliseconds and is created exclusively, so it never replaces an older one
    bak = f"{path}.warroom-bak-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{int(time.time() * 1000) % 1000:03d}"
    with open(bak, 'xb') as f:
        f.write(raw); f.flush(); os.fsync(f.fileno())
out = (json.dumps(new, indent=2) + '\n').encode()
fd, tmp = tempfile.mkstemp(prefix='.settings.json.warroom-', dir=d)
try:
    with os.fdopen(fd, 'wb') as f:
        f.write(out); f.flush(); os.fsync(f.fileno())
    with open(tmp, 'rb') as f:
        if f.read() != out:
            raise OSError('the temp file did not read back as written')
    now = None
    if os.path.exists(path):
        with open(path, 'rb') as f:
            now = f.read()
    if now != raw:
        raise OSError('settings.json changed while this ran (another program wrote it); run install.sh again')
    if raw is not None:
        os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
    os.replace(tmp, path)             # one step: the file is either the old one or the new one, never half of either
except BaseException as e:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    die(f'could not write {path} ({e}).')
with open(path, 'rb') as f:
    back = f.read()
if back != out or json.loads(back) != new:
    sys.exit(f'   {path} did not read back as written. Restore {bak or "it"} by hand.')
print(f'   written and read back: {plan}' + (f'; backup {bak}' if bak else ''))
PY
}
settings check || exit 1

# --- writes ---
echo "1. config: $ENVF"
if [ $WRITE_ENV = 0 ]; then echo "   exists, kept (SEATS=\"$SEATS_USE\", WARROOM_DIR=\"$DIR_USE\")"
elif [ $DRY = 1 ]; then echo "   [dry-run] would write SEATS=\"$SEATS_USE\" WARROOM_DIR=\"$DIR_USE\" BOARD=\"board.md\""
else
  mkdir -p "$(dirname "$ENVF")"
  if [ -f "$ENVF" ]; then b="$ENVF.bak-$(date +%Y%m%d-%H%M%S)-$$"; cp "$ENVF" "$b"; echo "   old file backed up: $b"; fi
  # values passed the grammar above (no quotes, no $), so they are written as plain data. A dir under $HOME is written
  # as $HOME/..., so a home folder name with other characters (an @, an accent) still reads back under the grammar.
  case "$DIR_USE" in "$HOME"/*) DIR_OUT="\$HOME/${DIR_USE#"$HOME"/}" ;; *) DIR_OUT=$DIR_USE ;; esac
  printf 'SEATS="%s"\nWARROOM_DIR="%s"\nBOARD="board.md"\n' "$SEATS_USE" "$DIR_OUT" > "$ENVF.tmp.$$" && mv "$ENVF.tmp.$$" "$ENVF"
  echo "   written"
fi
echo "2. run directory: $DIR_USE"
if [ $DRY = 1 ]; then echo "   [dry-run] would create it and an empty board.md"; else mkdir -p "$DIR_USE"; touch "$DIR_USE/board.md"; fi
echo "3. hooks in $SET"
if [ $DRY = 1 ]; then echo "   [dry-run] nothing written"; else settings apply || exit 1; fi

echo "4. first message for each seat (paste it as the first message of that seat's session):"
for s in $SEATS_USE; do
  echo
  echo "   You are $s. This session shows a [WAITER NOT ARMED] line that ends with your session id. As a background job, run: bash $(q "$HERE/bin/waiter.sh") $s <that session id>. Then read $(q "$HERE/docs/PROTOCOL.md") and post your first line with: bash $(q "$HERE/bin/board.sh") post $s \"online\""
done
echo
echo "Done. Nothing was run in the background. To undo: remove the four war room hook entries from $SET (or restore the backup next to it)."
