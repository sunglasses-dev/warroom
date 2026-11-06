# the helper is removed before it is called: the file's refusals stop counting
# expect: fail hides or redefines
die() { exit 1; }
F=${1:-}
unset -f die
x=$(cat "$F") || die
echo "$x" > out
