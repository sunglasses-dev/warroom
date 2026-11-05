# the allowlist does not accept this shape: func def after
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
die() { exit 1; }
