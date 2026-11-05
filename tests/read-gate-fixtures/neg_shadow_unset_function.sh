# the helper is removed before it is called: tool error
# expect: error unset names
die() { exit 1; }
F=${1:-}
unset -f die
x=$(cat "$F") || die
echo "$x" > out
