# the allowlist does not accept this shape: cond def
# expect: fail falls back
if [ -n "${Q:-}" ]; then die() { exit 1; }; fi
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
