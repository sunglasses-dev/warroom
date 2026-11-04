#!/usr/bin/env bash
# install.sh — set up the war room on this machine. Read it first; it is short.
#   bash install.sh [--seats "BOSS MANAGER W1 W2"] [--dir DIR] [--replace-config] [--dry-run]
# What it does, in order (every check runs before anything is written):
#   1. writes warroom.env ($WARROOM_ENV, else ~/.warroom/warroom.env). An existing one is kept and used; if --seats or
#      --dir ask for something else it stops and says so. --replace-config backs the old file up and writes a new one.
#   2. creates the run directory and an empty board
#   3. adds four hook entries to the Claude Code settings file: a backup first, then a temp file in the same folder that
#      is checked and moved into place in one step, then read back. Running again changes nothing. It only changes
#      entries it wrote itself, listed in installed-hooks.json next to warroom.env (an entry from a moved clone is pointed
#      at this clone); entries it did not write are left as they are, even when they look like war room hooks.
#   Steps 1-3 are separate writes, not one transaction: if step 3 fails, the config and run directory from steps 1-2 stay.
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
MANIFEST="$(dirname "$ENVF")/installed-hooks.json"   # the hook entries this installer wrote, so it never guesses
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
  # the values the scripts will really use must pass the same rules as --seats and --dir, before anything is written
  wr_seats_ok "$H_SEATS" || die "$ENVF has SEATS=\"$H_SEATS\": names are [A-Z][A-Z0-9_]{0,15}, no repeats; ALL, NONE and GUARD are reserved. Edit it, or pass --replace-config."
  case "$H_DIR" in /*) ;; *) die "$ENVF has WARROOM_DIR=\"$H_DIR\": it must be an absolute path. Edit it, or pass --replace-config." ;; esac
  SEATS_USE=$H_SEATS; DIR_USE=$H_DIR; WRITE_ENV=0
else
  SEATS_USE=${SEATS_ARG:-$DEF_SEATS}; DIR_USE=${DIR_ARG:-$DEF_DIR}
fi
# the settings file is checked before anything is written; the same program writes it in step 3.
# Ownership: the installer only ever changes hook entries it wrote itself. It records them in a manifest
# ($MANIFEST: event, matcher, command and script name, per settings file) and never guesses from a file name or from a
# path that no longer exists. An entry whose command is exactly this clone's hook command is also counted as ours.
settings() { HOOKS_DIR="$HERE/hooks" MANIFEST="$MANIFEST" python3 - "$1" "$SET" <<'PY'
import fcntl, json, os, shlex, stat, sys, tempfile, time
mode, path = sys.argv[1], os.path.realpath(sys.argv[2])   # realpath: a symlinked settings.json keeps its link
hd = os.environ['HOOKS_DIR']; man_path = os.environ['MANIFEST']
WANT = {'SessionStart': ['waiter-check.sh'], 'UserPromptSubmit': ['waiter-check.sh', 'board-tail.sh', 'board-guard.sh']}
NAMES = {'waiter-check.sh', 'board-tail.sh', 'board-guard.sh'}
def die(msg):
    tail = ' Nothing was changed.' if mode == 'check' else ' settings.json was not changed.'
    print('   ' + msg + tail, file=sys.stderr); sys.exit(1)
lock = None
if mode == 'apply':   # one installer at a time (cooperating writers only: an editor that ignores this lock can still race)
    os.makedirs(os.path.dirname(man_path), exist_ok=True)
    lock = open(man_path + '.lock', 'a')
    deadline = time.time() + 30
    while True:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB); break
        except BlockingIOError:
            if time.time() > deadline:
                die('another install.sh is running (lock ' + man_path + '.lock held for 30 s).')
            time.sleep(0.1)
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
# the manifest: {"version": 1, "settings": {"<settings path>": [{"event", "matcher", "command", "script"}, ...]}}
man = {'version': 1, 'settings': {}}
if os.path.exists(man_path):
    try:
        with open(man_path, 'rb') as f:
            man = json.loads(f.read())
        assert isinstance(man, dict) and man.get('version') == 1 and isinstance(man.get('settings'), dict)
        for e in man['settings'].get(path, []):
            assert isinstance(e, dict) and e.get('event') in WANT and e.get('script') in NAMES
            assert isinstance(e.get('command'), str) and (e.get('matcher') is None or isinstance(e.get('matcher'), str))
    except (ValueError, AssertionError, OSError):
        die(f'{man_path} (the list of hook entries this installer wrote) is not readable. Fix or remove it; '
            'without it the installer only recognises entries that point exactly at this clone.')
mine = lambda s: 'bash ' + shlex.quote(os.path.join(hd, s))
MINE = {mine(s): s for s in NAMES}
owned = {(e['event'], e.get('matcher'), e['command']): e['script'] for e in man['settings'].get(path, [])}
after = {}                                             # (event, matcher, command) -> script, for the new manifest
new = json.loads(json.dumps(data)); nh = new.setdefault('hooks', {})
added = moved = dropped = 0; strangers = []
for ev, scripts in WANT.items():
    groups = nh.setdefault(ev, []); emptied = []; scope_seen = {}
    for g in groups:
        m = g.get('matcher'); m = m if isinstance(m, str) else None
        seen = scope_seen.setdefault(m, [])           # entries already kept in this event + matcher scope
        keep = []; before = len(g.get('hooks', []))
        for h in g.get('hooks', []):
            cmd = h.get('command')
            s = owned.get((ev, m, cmd)) or MINE.get(cmd)   # listed in the manifest, or exactly this clone's command
            if s is not None:
                if cmd != mine(s):
                    h['command'] = mine(s); moved += 1          # we wrote it from a clone that has moved: point it here
                after[(ev, m, h['command'])] = s
                if h in seen:
                    dropped += 1; continue                      # an equal copy of our own entry in the same scope
            elif isinstance(cmd, str) and any(os.path.basename(w) in NAMES for w in cmd.split()):
                strangers.append(f'{ev}: {cmd}')               # looks like a war room hook, but we did not write it
            seen.append(h); keep.append(h)
        if 'hooks' in g:
            g['hooks'] = keep
        if before and not keep:
            emptied.append(g)                                  # only groups this run emptied are removed
    nh[ev] = [g for g in groups if not any(g is e for e in emptied)]
    present = {h.get('command') for g in nh[ev] for h in g.get('hooks', [])}
    for s in scripts:
        if mine(s) not in present:                             # present under any matcher counts: we add nothing next to it
            nh[ev].append({'hooks': [{'type': 'command', 'command': mine(s)}]}); added += 1
            after[(ev, None, mine(s))] = s
entries = sorted(({'event': k[0], 'matcher': k[1], 'command': k[2], 'script': s} for k, s in after.items()),
                 key=lambda e: (e['event'], e['matcher'] or '', e['command']))
plan = f'{added} to add, {moved} to point at this clone, {dropped} duplicate(s) to remove'
for x in strangers:
    print(f'   left alone (not written by this installer): {x}')
man_new = json.loads(json.dumps(man)); man_new['settings'][path] = entries
man_changed = man_new != man or not os.path.exists(man_path)
def atomic_write(target, out, mode_from=None):
    d = os.path.dirname(target); os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(target) + '.warroom-', dir=d)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(out); f.flush(); os.fsync(f.fileno())
        with open(tmp, 'rb') as f:
            if f.read() != out:
                raise OSError('the temp file did not read back as written')
        return tmp
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
if new == data and raw is not None:
    if mode == 'apply' and man_changed:
        try:
            os.replace(atomic_write(man_path, (json.dumps(man_new, indent=2) + '\n').encode()), man_path)
        except OSError as e:
            die(f'could not write {man_path} ({e}).')
    print('   already installed, nothing to change'); sys.exit(0)
if mode == 'check':
    print(f'   settings ok: {plan}'); sys.exit(0)
# the manifest is written first: if the settings write then fails, it lists entries that are not there, which is harmless
try:
    os.replace(atomic_write(man_path, (json.dumps(man_new, indent=2) + '\n').encode()), man_path)
except OSError as e:
    die(f'could not write {man_path} ({e}).')
d = os.path.dirname(path); os.makedirs(d, exist_ok=True)
bak = None
if raw is not None:   # backup name carries pid + milliseconds and is created exclusively, so it never replaces an older one
    bak = f"{path}.warroom-bak-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{int(time.time() * 1000) % 1000:03d}"
    with open(bak, 'xb') as f:
        f.write(raw); f.flush(); os.fsync(f.fileno())
out = (json.dumps(new, indent=2) + '\n').encode()
try:
    tmp = atomic_write(path, out)
except OSError as e:
    die(f'could not write {path} ({e}).')
try:
    now = None
    if os.path.exists(path):
        with open(path, 'rb') as f:
            now = f.read()
    if now != raw:   # narrows, does not close, the window for an editor that ignores the lock (see README)
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
