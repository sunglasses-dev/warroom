# a helper used at the top level before the line that defines it: the call finds nothing (127) and the script goes on
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
die() { exit 1; }
