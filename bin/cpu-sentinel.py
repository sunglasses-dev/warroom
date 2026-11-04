#!/usr/bin/env python3
"""cpu-sentinel.py — a watchdog for runaway processes on a machine that runs several agent sessions.

Run it once a minute (cron, launchd or a loop; examples/cpu-sentinel.plist is a launchd job). Each run samples every process
above HOT percent CPU and keeps a strike count per process: one strike is one run in which it was still hot.

  system    under /System, /usr, /Library, /Applications ... skipped, except a bare shell, which is judged like any other
  shell     a bare shell (bash, zsh, sh) burning >= LOOP percent .... alert at 3 strikes, kill at 3 only with --enforce
  job       a process in the job ledger (pids.tsv) or one of its children ... alert the owner at 5 strikes, kill at 15
  other     any other hot process whose parent is pid 1 (an orphan) .... alert at 3 strikes, kill at 10

A ledger row counts only when its pid is positive, its owner is a configured seat, and (when the row records a start
time) the pid still belongs to the process that started at that time; otherwise the row is ignored.

Nothing is ever killed unless you pass --enforce. Without it the script reports: it writes its log and strike file and posts
its alerts, so an alert can still reach a seat. `touch $WARROOM_DIR/sentinel/ok-<pid>` stops the kill for that process (the
alert still posts). An alert is one board line, "@OWNER ACTION:", posted once when a hot process reaches its alert
strike count; if the post fails it is tried again on the next run until it succeeds. The strike count and the "already
alerted" mark belong to one hot spell: a process that cools down is forgotten, and a later hot spell can alert again.

  cpu-sentinel.py [--enforce] [--dry-run] [--hot 60] [--loop 70] [--config] [--help]
  --dry-run  changes nothing: no board posts, no kills, no log or strike-file writes; it prints what a run would do
             (using the strike counts a real run saved).
  --config   prints the seats, run directory and board it resolved (same rules as bin/_common.sh) and exits.
"""
import json, os, re, signal, subprocess, sys, time

# warroom.env is DATA, read with the same rules as bin/_config.sh (never sourced, never passed to a shell):
# $WARROOM_ENV or ~/.warroom/warroom.env only; KEY=VALUE lines; a value may use letters, digits, space and _ . / ~ -
# and start with ~/ or $HOME/; environment beats file beats default.
KEYS = ('SEATS', 'WARROOM_DIR', 'BOARD', 'WARROOM_POLL', 'WARROOM_MIN_GAP', 'WARROOM_IDLE_MIN', 'WARROOM_LONG')
DIGITS = ('WARROOM_POLL', 'WARROOM_MIN_GAP', 'WARROOM_IDLE_MIN', 'WARROOM_LONG')
VALUE_RE = re.compile(r'[A-Za-z0-9 _./~-]*\Z')
SEAT_RE = re.compile(r'[A-Z][A-Z0-9_]{0,15}\Z')

def die(msg):
    print(msg, file=sys.stderr); sys.exit(2)

def config_path():
    return os.environ.get('WARROOM_ENV') or os.path.join(os.environ.get('HOME', os.path.expanduser('~')), '.warroom', 'warroom.env')

def check_value(v):
    home = os.environ.get('HOME', os.path.expanduser('~'))
    pre, rest = '', v
    if v in ('~', '$HOME'):
        pre, rest = home, ''
    elif v.startswith('~/'):
        pre, rest = home + '/', v[2:]
    elif v.startswith('$HOME/'):
        pre, rest = home + '/', v[6:]
    return pre + rest if VALUE_RE.match(rest) else None

def load_config():
    out, path = {}, config_path()
    if not os.path.isfile(path):
        return out
    with open(path, 'rb') as f:
        text = f.read().decode('utf-8', errors='replace')
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    for n, line in enumerate(lines, 1):
        line = line[:-1] if line.endswith('\r') else line
        if not line or line.startswith('#'):
            continue
        m = re.match(r'([A-Z_]+)=(.*)\Z', line, re.S)
        if not m:
            die(f'warroom.env line {n} ({path}): expected KEY=VALUE with nothing before KEY')
        k, v = m.groups()
        if k not in KEYS:
            die(f'warroom.env line {n} ({path}): unknown key {k} (known: {" ".join(KEYS)})')
        if k in out:
            die(f'warroom.env line {n} ({path}): {k} is set twice; keep one line')
        if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
            v = v[1:-1]
        v = check_value(v)
        if v is None:
            die(f'warroom.env line {n} ({path}): {k} may only use letters, digits, space and _ . / ~ - (and start with ~/ or $HOME/)')
        if k in DIGITS and not v.isdigit():
            die(f'warroom.env line {n} ({path}): {k} takes digits only')
        out[k] = v
    return out

def setting(cfg, key, default):
    v = os.environ[key] if key in os.environ else cfg.get(key, '')
    return v or default

args = sys.argv[1:]
if '-h' in args or '--help' in args:          # before anything reads a file or writes state
    print(__doc__); sys.exit(0)

CFG = load_config()
SEATS = setting(CFG, 'SEATS', 'BOSS MANAGER W1 W2').split()
if not SEATS or len(set(SEATS)) != len(SEATS) or any(s in ('ALL', 'NONE', 'GUARD') or not SEAT_RE.match(s) for s in SEATS):
    die(f"SEATS='{' '.join(SEATS)}': names are [A-Z][A-Z0-9_]{{0,15}}, no repeats; ALL, NONE and GUARD are reserved")
W = setting(CFG, 'WARROOM_DIR', os.path.join(os.environ.get('HOME', os.path.expanduser('~')), 'warroom-run'))
BOARD = setting(CFG, 'BOARD', 'board.md')
BOARD = BOARD if BOARD.startswith('/') else os.path.join(W, BOARD)
if '--config' in args:                        # print what this script and bin/_common.sh resolve, then stop
    print(f'SEATS={" ".join(SEATS)}\nWARROOM_DIR={W}\nBOARD_FILE={BOARD}'); sys.exit(0)
STATE = os.path.join(W, 'sentinel')
LOG = os.path.join(STATE, 'sentinel.log'); STRIKES = os.path.join(STATE, 'strikes.json')

ENFORCE = '--enforce' in args; DRY = '--dry-run' in args
if not DRY:
    os.makedirs(STATE, exist_ok=True)
def opt(name, default):
    return float(args[args.index(name) + 1]) if name in args else default
HOT, LOOP = opt('--hot', 60.0), opt('--loop', 70.0)
SYSTEM_PREFIX = ('/System/', '/usr/', '/sbin/', '/bin/', '/Library/', '/Applications/', '/private/var/')
SHELLS = {'bash', 'zsh', 'sh', 'dash', '-bash', '-zsh'}

def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {'DRY ' if DRY else ''}{msg}"
    if DRY:
        print(line); return                   # --dry-run writes nothing
    with open(LOG, 'a') as f:
        f.write(line + '\n')

def sample():
    rows = subprocess.run(['ps', '-Ao', 'pid,ppid,pcpu,comm,args'], capture_output=True, text=True).stdout.splitlines()[1:]
    procs = {}
    for ln in rows:
        p = ln.split(None, 4)
        if len(p) < 4:
            continue
        procs[int(p[0])] = dict(pid=int(p[0]), ppid=int(p[1]), cpu=float(p[2]), comm=p[3], args=p[4] if len(p) > 4 else p[3])
    return procs

def started(pid):
    """start time of a pid in the same form pids.sh records it (C locale, blanks squeezed); '' if unreadable"""
    r = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)], capture_output=True, text=True, env=dict(os.environ, LC_ALL='C'))
    return ' '.join(r.stdout.split())

def ledger():
    """pid -> (label, owner) for every valid row of pids.tsv: label, pid, owner[, start time]. A row with a recorded start
    time counts only while that pid still started at that time (a reused pid is someone else's process)."""
    out = {}
    try:
        for ln in open(os.path.join(W, 'pids.tsv')):
            f = ln.rstrip('\n').split('\t')
            if len(f) < 3 or not f[1].isdigit() or int(f[1]) <= 0 or f[2] not in SEATS:
                continue
            if len(f) > 3 and f[3].strip() and ' '.join(f[3].split()) != started(f[1]):
                continue
            out[int(f[1])] = (f[0], f[2])
    except OSError:
        pass
    return out

def ancestors(pid, procs):
    seen = []
    while pid in procs and pid > 1 and pid not in seen:
        seen.append(pid); pid = procs[pid]['ppid']
    return seen

def alert(owner, text):
    if DRY:
        print(f'would post to {owner}: {text}'); return True      # --dry-run posts nothing
    n = subprocess.run(['bash', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'board.sh'), 'post', 'GUARD',
                        f'@{owner} ACTION: {text}'], capture_output=True, text=True)
    if n.returncode:
        log(f'alert could not post: {n.stderr.strip()}')
    return n.returncode == 0

def kill_tree(pid, procs):
    kids = [p for p in procs.values() if p['ppid'] == pid]
    for k in kids:
        kill_tree(k['pid'], procs)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

procs = sample(); jobs = ledger(); me = os.getpid()
try:
    saved = json.load(open(STRIKES))
except (OSError, ValueError):
    saved = {}
# state file: {"strikes": {key: runs hot}, "alerted": [keys]}; an older file is a bare {key: runs hot}
if isinstance(saved.get('strikes'), dict):
    strikes = {k: v for k, v in saved['strikes'].items() if isinstance(v, int)}
    alerted = set(k for k in saved.get('alerted', []) if isinstance(k, str))
else:
    strikes = {k: v for k, v in saved.items() if isinstance(v, int)}; alerted = set()
hot = {}
for p in procs.values():
    if p['pid'] == me or p['cpu'] < HOT:
        continue
    exe = p['comm'] if p['comm'].startswith('/') else p['args'].split()[0]
    if exe.startswith(SYSTEM_PREFIX) and os.path.basename(exe) not in SHELLS:
        continue
    key = f"{p['pid']}:{p['comm']}"; hot[key] = p
    n = strikes.get(key, 0) + 1; strikes[key] = n
    owner = None; label = None
    for a in ancestors(p['pid'], procs):
        if a in jobs:
            label, owner = jobs[a]; break
    base = os.path.basename(p['comm']).lstrip('-')
    if base in SHELLS and p['cpu'] >= LOOP and not owner:
        cls, alert_at, kill_at = 'shell', 3, 3
    elif owner:
        cls, alert_at, kill_at = 'job', 5, 15
    elif p['ppid'] == 1:
        cls, alert_at, kill_at = 'other', 3, 10
    else:
        continue
    log(f"{cls} pid {p['pid']} {p['comm']} cpu {p['cpu']:.0f}% strike {n}" + (f" job {label}" if label else ''))
    who = owner or SEATS[0]
    if n >= alert_at and key not in alerted:         # a failed post leaves the mark unset, so the next run tries again
        if alert(who, f"process {p['pid']} ({os.path.basename(p['comm'])}) has used {p['cpu']:.0f}% CPU for {n} runs ({cls}). "
                      f"Stop it, or touch {STATE}/ok-{p['pid']} to let it run."):
            alerted.add(key)
    if n >= kill_at and not os.path.exists(os.path.join(STATE, f"ok-{p['pid']}")):
        if ENFORCE and not DRY:
            log(f"KILL tree {p['pid']} ({cls})"); kill_tree(p['pid'], procs)
        elif n == kill_at:
            log(f"would kill tree {p['pid']} ({cls}); pass --enforce to do it")
if not DRY:
    with open(STRIKES, 'w') as f:
        json.dump({'strikes': {k: v for k, v in strikes.items() if k in hot}, 'alerted': sorted(k for k in alerted if k in hot)}, f)
