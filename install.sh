#!/usr/bin/env bash
# install.sh — set up the war room on this machine. Read it first; it is short.
#   bash install.sh [--seats "BOSS MANAGER W1 W2"] [--dir DIR] [--replace-config] [--dry-run]
#   bash install.sh --check        read only: lists where the four hook commands appear in the settings file
#   bash install.sh --uninstall    prints what to remove; deletes nothing
# What it does, in order (every check runs before anything is written):
#   1. writes warroom.env ($WARROOM_ENV, else ~/.warroom/warroom.env). An existing one is kept and used; if --seats or
#      --dir ask for something else it stops and says so. --replace-config backs the old file up and writes a new one.
#   2. creates the run directory, and the board if it is missing (an existing board is left as it is)
#   3. prints one first message per seat to paste into that seat's session
#   4. prints four hook entries as one JSON block, last, so it ends the output: the settings file they belong in, and
#      how to add them for the state that file is in now. install.sh never writes that file: you (or your Claude Code
#      session) edit it.
# Steps 1 and 2 are separate writes. Both refuse to run when a destination is the settings file, or links to it.
# Settings live in $CLAUDE_CONFIG_DIR/settings.json, or $HOME/.claude/settings.json when that variable is not set.
# Seats: [A-Z][A-Z0-9_]{0,15}; ALL, NONE, GUARD are reserved. DIR: an absolute path of letters, digits, space, _ . / ~ -
# Needs: bash, python3. --dry-run runs every check, prints the plan and the same hook block, and writes nothing.
set -e
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/_config.sh
. "$HERE/bin/_config.sh"   # functions only, it writes nothing (bin/_common.sh would create run files, so it is not used)
SEATS_ARG=""; DIR_ARG=""; DRY=0; REPLACE=0; MODE=install
DEF_SEATS="BOSS MANAGER W1 W2"; DEF_DIR="$HOME/warroom-run"
while [ $# -gt 0 ]; do case "$1" in
  --seats) SEATS_ARG=${2:?--seats needs a value}; shift 2 ;; --dir) DIR_ARG=${2:?--dir needs a value}; shift 2 ;;
  --replace-config) REPLACE=1; shift ;; --dry-run) DRY=1; shift ;;
  --check|--uninstall) [ $MODE = install ] || { echo "use one of --check and --uninstall" >&2; exit 2; }; MODE=${1#--}; shift ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option $1 (try --help)" >&2; exit 2 ;; esac; done
die() { echo "install.sh: $*" >&2; echo "Nothing was changed." >&2; exit 1; }
command -v python3 >/dev/null || die "python3 is required"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; SET="$CFG/settings.json"; ENVF=$(wr_config_path)
q() { printf '%q' "$1"; }   # a path printed for copy-paste, quoted when it needs it

# One read-only program for the settings file. It never writes it and never runs a command it finds there.
#   print   the JSON block              check    inventory, exit 0 all four found / 1 some not found / 2 cannot inspect
#   advise  how to add the block now    refs     what --uninstall lists       collide  exit 1 if a write target is SET
# A command is "bash" plus the shell-quoted absolute path of the hook script in this clone.
hooks() { HOOKS_DIR="$HERE/hooks" python3 - "$@" <<'PY'
import json, os, shlex, sys
mode, path = sys.argv[1], sys.argv[2]
hd = os.environ['HOOKS_DIR']
WANT = [('SessionStart', 'waiter-check.sh'), ('UserPromptSubmit', 'waiter-check.sh'),
        ('UserPromptSubmit', 'board-tail.sh'), ('UserPromptSubmit', 'board-guard.sh')]
EVENTS = ['SessionStart', 'UserPromptSubmit']
NAMES = sorted({s for _, s in WANT})
def cmd(script):
    return 'bash ' + shlex.quote(os.path.join(hd, script))
PAIRS = [(ev, cmd(s)) for ev, s in WANT]
show = json.dumps   # commands are shown as JSON strings: quoted, control characters escaped
def out(line=''):
    print('   ' + line if line else '')

if mode == 'print':
    block = {'hooks': {}}
    for ev, c in PAIRS:
        block['hooks'].setdefault(ev, [{'hooks': []}])[0]['hooks'].append({'type': 'command', 'command': c})
    print(json.dumps(block, indent=2))
    sys.exit(0)

if mode == 'collide':   # argv[3:] = every path steps 1-2 would write; a match is the settings file itself or a link to it
    def same(a, b):
        if os.path.realpath(a) == os.path.realpath(b):
            return True
        try:
            return os.path.samefile(a, b)
        except OSError:
            return False
    for dest in sys.argv[3:]:
        if same(dest, path):
            print(dest)
            sys.exit(1)
    sys.exit(0)

def inspect():
    """('missing'|'empty'|'error', message) or ('ok', found, other, skipped, data)"""
    if not os.path.lexists(path):
        return ('missing', f'{path} does not exist')
    if os.path.isdir(path):
        return ('error', f'{path} is a directory, not a file')
    try:
        with open(path, 'rb') as f:
            raw = f.read()
    except OSError as e:
        return ('error', f'{path} cannot be read ({e.strerror})')
    if not raw.strip():
        return ('empty', f'{path} is empty, which is not valid JSON')
    def no_dups(pairs):
        keys = [k for k, _ in pairs]
        dup = sorted({k for k in keys if keys.count(k) > 1})
        if dup:
            raise ValueError('the key ' + show(dup[0]) + ' appears twice in one object')
        return dict(pairs)
    try:
        data = json.loads(raw, object_pairs_hook=no_dups)
    except ValueError as e:
        return ('error', f'{path} is not valid JSON: {e}')
    if not isinstance(data, dict):
        return ('error', f'{path} does not hold a JSON object')
    if 'hooks' not in data:
        return ('ok', [], [], [], data)
    hooks = data['hooks']
    if not isinstance(hooks, dict):
        return ('error', f'{path}: "hooks" is not a JSON object')
    found, other, skipped = [], [], []   # found/other: (event, command, where); skipped: (where, why)
    for ev, groups in hooks.items():
        if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
            if ev in EVENTS:
                return ('error', f'{path}: hooks.{ev} is not a list of hook groups')
            skipped.append((f'hooks.{ev}', 'not a list of hook groups, not inspected'))
            continue
        for gi, g in enumerate(groups):
            m = f' (matcher {show(g["matcher"])})' if 'matcher' in g else ' (no matcher)'
            entries = g.get('hooks', [])
            if not isinstance(entries, list):
                if ev in EVENTS:
                    return ('error', f'{path}: hooks.{ev}[{gi}].hooks is not a list')
                continue
            for hj, h in enumerate(entries):
                where = f'hooks.{ev}[{gi}].hooks[{hj}]{m}'
                c = h.get('command') if isinstance(h, dict) else None
                why = ('not an object' if not isinstance(h, dict) else '"command" is not a string' if not isinstance(c, str)
                       else '"type" is not "command"' if h.get('type') != 'command' else '')
                if why:
                    if ev in EVENTS:
                        skipped.append((where, why + ', not counted'))
                    continue
                if (ev, c) in PAIRS:
                    found.append((ev, c, where))
                elif any(n in c for n in NAMES):
                    other.append((ev, c, where))
    return ('ok', found, other, skipped, data)

r = inspect()
state = r[0]
if mode == 'check':
    out(f'inventory of one file: {path}')
    out('It looks for the exact command text only. It does not read other settings files, does not show that hooks')
    out('are enabled or that they run, and runs nothing. The real test is the two-session wake check in the README.')
    if state != 'ok':
        out(f'cannot inspect: {r[1]}.')
        sys.exit(2)
    _, found, other, skipped, data = r
    if data.get('disableAllHooks') is True:
        out('note: this file sets "disableAllHooks" to true.')
    missing = 0
    for ev, c in PAIRS:
        at = [w for e, cc, w in found if (e, cc) == (ev, c)]
        missing += not at
        out(f'found {len(at)}  {ev}  {show(c)}' + ''.join(f'\n     at {w}' for w in at))
    for ev, c, w in other:
        out(f'other reference  {ev}  {show(c)}\n     at {w}: names a war room script, but the text differs from this clone\'s. Review it by hand.')
    for w, why in skipped:
        out(f'skipped  {w}: {why}')
    if missing:
        out(f'result: {missing} of 4 not found as exact text. Add the block install.sh prints, then run --check again.')
        sys.exit(1)
    out('result: 4 of 4 found as exact text in this file.')
    sys.exit(0)

if mode == 'advise':
    if state == 'missing':
        out(f'{path} does not exist yet. Create it (and its folder) with the block below as its whole content.')
    elif state == 'empty':
        out(f'{path} is empty, which is not valid JSON. Save a copy (command below), then make the block below its whole content.')
    elif state == 'error':
        out(f'{r[1]}. Do not paste into it. Save a copy (command below), repair the file or put back a good copy,')
        out('then run install.sh again to see how to add the block.')
    else:
        _, found, other, skipped, data = r
        have = {(e, c) for e, c, _ in found}
        todo = [(e, c) for e, c in PAIRS if (e, c) not in have]
        if not todo:
            out('All four commands are already in this file as exact text: add nothing. Run --check to see where.')
        elif 'hooks' not in data:
            out('Save a copy first (command below). The file has no "hooks" key: add the "hooks" property of the block as one')
            out('more property of the top-level object and keep every other property (mind the comma between properties).')
        else:
            out('Save a copy first (command below). Keep the "hooks" object and every event, group and entry already in it.')
            out('For an event the file does not have, add it from the block. For an event it has, add only the missing')
            out('entries as one new group at the end of that event\'s list. Never add a second "hooks" key. Missing now:')
            for e, c in todo:
                out(f'  {e}  {show(c)}')
        if other:
            out(f'{len(other)} other reference(s) to war room scripts are in the file (an older clone, or another spelling).')
            out('install.sh --check lists them; review them by hand.')
    out('After the edit: the file must still parse; compare it with the copy for unrelated changes; run install.sh --check')
    out('with the same CLAUDE_CONFIG_DIR; then do the two-session wake check in the README. A session that was already')
    out('open may need a restart before it uses the new hooks.')
    sys.exit(0)

if mode == 'refs':
    if state != 'ok':
        out(f'{r[1]}, so it cannot list them here. The commands are in the block below.')
        sys.exit(0)
    _, found, other, skipped, data = r
    if not found and not other:
        out('none of the war room commands are in this file.')
    for ev, c, w in found:
        out(f'this clone  {ev}  {show(c)}\n     at {w}')
    for ev, c, w in other:
        out(f'other reference  {ev}  {show(c)}\n     at {w}: the text differs from this clone\'s; remove it only if you know it is a war room entry')
    sys.exit(0)
sys.exit(2)
PY
}
block() { echo "--- begin hook block ---"; hooks print "$SET"; echo "--- end hook block ---"; }
copy_cmd() { [ -e "$SET" ] || return 0; echo "   save a copy: cp -p -- $(q "$SET") $(q "$SET.before-warroom")"; }

if [ $MODE = check ]; then
  rc=0; hooks check "$SET" || rc=$?; exit $rc
fi

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

if [ $MODE = uninstall ]; then
  # prints only. The run directory comes from warroom.env when it can be read, else from --dir or the default.
  U_DIR=${DIR_ARG:-$DEF_DIR}
  if [ -f "$ENVF" ]; then
    u=$(unset SEATS WARROOM_DIR BOARD; wr_load_config "$ENVF" && printf '%s\n' "${WARROOM_DIR:-}") \
      && U_DIR=${u:-$DEF_DIR} || echo "($ENVF could not be read, so the run directory shown is ${DIR_ARG:+--dir}${DIR_ARG:-the default})"
  fi
  echo "install.sh --uninstall deletes nothing. To remove the war room from this machine:"
  echo "1. hooks: in $SET, remove the war room entries. Keep the groups, matchers and other hooks around them."
  echo "   What this file holds now:"
  hooks refs "$SET"
  copy_cmd
  echo "   The four commands this clone prints:"
  block
  echo "2. optional, only after every seat session and background job has stopped: delete the config and the run"
  echo "   directory. This deletes the board, its whole history, the state files and any receipts in that directory."
  echo "   Look inside it first; nothing you need should be in it. install.sh will not run this for you."
  # the default config folder (~/.warroom) holding only warroom.env and its backups is listed as the folder, so no empty
  # folder is left behind; a WARROOM_ENV the user chose is listed as that one file
  U_ENV=$ENVF; ED=$(dirname "$ENVF")
  if [ -z "${WARROOM_ENV:-}" ] && [ -f "$ENVF" ] && [ ! -L "$ENVF" ] && [ ! -L "$ED" ]; then
    only=1
    for f in "$ED"/* "$ED"/.[!.]* "$ED"/..?*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      case "${f##*/}" in warroom.env|warroom.env.bak-*) { [ -f "$f" ] && [ ! -L "$f" ]; } || only=0 ;; *) only=0 ;; esac
    done
    [ $only = 0 ] || U_ENV=$ED
  fi
  set --; [ ! -e "$ENVF" ] || set -- "$U_ENV"; [ ! -e "$U_DIR" ] || set -- "$@" "$U_DIR"
  if [ $# = 0 ]; then echo "   nothing to delete: $ENVF and $U_DIR do not exist"
  else printf '   rm -r --'; printf ' %q' "$@"; echo; fi
  exit 0
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
# every path steps 1-2 write. None may be the settings file or a link to it (a stable path is assumed: this does
# not defend against a file being swapped while install.sh runs).
TMP_ENV="$ENVF.tmp.$$"; BAK_ENV="$ENVF.bak-$(date +%Y%m%d-%H%M%S)-$$"; BOARD_F="$DIR_USE/board.md"
set -- "$DIR_USE" "$BOARD_F"; [ $WRITE_ENV = 0 ] || set -- "$@" "$ENVF" "$TMP_ENV" "$BAK_ENV"
hit=$(hooks collide "$SET" "$@") || die "$hit is the Claude Code settings file $SET (or links to it). install.sh never writes that file: choose another WARROOM_ENV or --dir."
[ $WRITE_ENV = 0 ] || { [ ! -e "$TMP_ENV" ] && [ ! -L "$TMP_ENV" ] && [ ! -e "$BAK_ENV" ] && [ ! -L "$BAK_ENV" ]; } || die "$TMP_ENV or $BAK_ENV already exists"
hooks print "$SET" >/dev/null || die "could not build the hook block"

# --- writes ---
echo "1. config: $ENVF"
if [ $WRITE_ENV = 0 ]; then echo "   exists, kept (SEATS=\"$SEATS_USE\", WARROOM_DIR=\"$DIR_USE\")"
elif [ $DRY = 1 ]; then echo "   [dry-run] would write SEATS=\"$SEATS_USE\" WARROOM_DIR=\"$DIR_USE\" BOARD=\"board.md\""
else
  mkdir -p "$(dirname "$ENVF")"
  if [ -f "$ENVF" ]; then cp "$ENVF" "$BAK_ENV"; echo "   old file backed up: $BAK_ENV"; fi
  # values passed the grammar above (no quotes, no $), so they are written as plain data. A dir under $HOME is written
  # as $HOME/..., so a home folder name with other characters (an @, an accent) still reads back under the grammar.
  case "$DIR_USE" in "$HOME"/*) DIR_OUT="\$HOME/${DIR_USE#"$HOME"/}" ;; *) DIR_OUT=$DIR_USE ;; esac
  printf 'SEATS="%s"\nWARROOM_DIR="%s"\nBOARD="board.md"\n' "$SEATS_USE" "$DIR_OUT" > "$TMP_ENV" && mv "$TMP_ENV" "$ENVF"
  echo "   written"
fi
echo "2. run directory: $DIR_USE"
if [ $DRY = 1 ]; then echo "   [dry-run] would create it, and board.md if it is missing"
else mkdir -p "$DIR_USE"; [ -e "$BOARD_F" ] || : >> "$BOARD_F"; fi
echo "3. first message for each seat (paste it as the first message of that seat's session):"
for s in $SEATS_USE; do
  echo
  echo "   You are $s. This session shows a [WAITER NOT ARMED] line that ends with your session id. As a background job, run: bash $(q "$HERE/bin/waiter.sh") $s <that session id>. Then read $(q "$HERE/docs/PROTOCOL.md") and post your first line with: bash $(q "$HERE/bin/board.sh") post $s \"online\""
done
echo
# the block comes last, so it ends the output and nobody has to scroll up past the seat messages to find it
echo "4. hooks: they belong in $SET. install.sh does not write that file; you or your Claude Code session edit it."
hooks advise "$SET"
copy_cmd
block
echo "   Then run: bash $(q "$HERE/install.sh") --check"
if [ $DRY = 1 ]; then echo "Dry run: nothing was written. Run it again without --dry-run to write steps 1 and 2."
else echo "Done. Nothing was run in the background, and $SET was not written. To undo: bash $(q "$HERE/install.sh") --uninstall (it prints the steps)."; fi
