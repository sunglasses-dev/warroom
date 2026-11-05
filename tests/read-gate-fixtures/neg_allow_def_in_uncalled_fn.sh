# the allowlist does not accept this shape: def in uncalled fn
# expect: fail falls back
setup() { die() { exit 1; }; }
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
