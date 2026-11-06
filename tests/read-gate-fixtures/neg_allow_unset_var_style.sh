# the allowlist does not accept this shape: unset var style
# expect: fail hides or redefines
die() { exit 1; }
unset die
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
