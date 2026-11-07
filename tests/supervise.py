#!/usr/bin/env python3
"""Run a command in its own process group and make sure nothing of it outlives the run.

    python3 -I tests/supervise.py [--timeout SECONDS] -- COMMAND [ARG...]

tests/smoke.sh starts waiters in subshells and in mutant copies; a trap on the script alone cannot reach them, so an interrupted
run, or one whose parent died, left them behind for hours. Here the command is the leader of a new session. The supervisor then
  * stops the WHOLE group (SIGTERM, 3 s grace, SIGKILL) on SIGINT, SIGTERM, SIGHUP or when --timeout (default $SMOKE_TIMEOUT, else 2400) passes,
  * sweeps the group with SIGKILL after a normal exit too,
  * starts a guard in its own session that does the same if the supervisor itself is killed outright,
  * makes a temp dir, exports it to the command as SMOKE_T (also SMOKE_INNER=1), and removes it last.
Exit status: the command's; 124 on timeout; 128+N when stopped by signal N. Stdlib only.
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

GUARD = 'while kill -0 "$1" 2>/dev/null; do sleep 2; done; kill -KILL -- "-$2" 2>/dev/null; rm -rf "$3"'


def main(argv):
    raw = os.environ.get("SMOKE_TIMEOUT", "2400")
    if argv[:1] == ["--timeout"]:
        if len(argv) < 2:
            sys.exit("supervise: --timeout needs a number of seconds")
        raw, argv = argv[1], argv[2:]
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        sys.exit("usage: supervise.py [--timeout SECONDS] -- COMMAND [ARG...]")
    if not raw.isdigit() or int(raw) < 1:
        sys.exit("supervise: the timeout must be whole seconds >= 1, got %r" % raw)
    limit = int(raw)
    got = []
    for n in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(n, lambda s, f: got.append(s))   # before any child exists: an early signal is kept, not fatal
    tmp = tempfile.mkdtemp(prefix="smoke.")
    env = dict(os.environ, SMOKE_INNER="1", SMOKE_T=tmp)
    run = subprocess.Popen(argv, env=env, start_new_session=True, stdin=subprocess.DEVNULL)
    guard = subprocess.Popen(["bash", "-c", GUARD, "smoke-guard", str(os.getpid()), str(run.pid), tmp],
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.monotonic() + limit
    rc = None
    while rc is None and not got and time.monotonic() < end:
        try:
            rc = run.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass
    timed_out = rc is None and not got
    if rc is None:
        try:
            os.killpg(run.pid, signal.SIGTERM)
            run.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            pass
        rc = run.poll()
    try:
        os.killpg(run.pid, signal.SIGKILL)  # whatever is left in the group, also after a normal exit
    except OSError:           # ProcessLookupError, or EPERM from a group of zombies on macOS: nothing left to stop
        pass
    if rc is None:
        rc = run.wait()
    guard.kill()
    guard.wait()
    shutil.rmtree(tmp, ignore_errors=True)
    if got:
        print("supervise: stopped by signal %d; the run group is gone" % got[0], file=sys.stderr)
        return 128 + got[0]
    if timed_out:
        print("supervise: SMOKE_TIMEOUT %ds exceeded; the run group is stopped" % limit, file=sys.stderr)
        return 124
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
