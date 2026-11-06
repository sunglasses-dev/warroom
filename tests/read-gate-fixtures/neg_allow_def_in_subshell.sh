# the allowlist does not accept this shape: def in subshell
# expect: fail falls back
( die() { exit 1; } )
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
