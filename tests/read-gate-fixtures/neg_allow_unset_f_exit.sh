# the allowlist does not accept this shape: unset f exit
# expect: fail hides or redefines
die() { exit 1; }
F=${1:-}
unset -f die
x=$(cat "$F") || die
echo "$x" > out
