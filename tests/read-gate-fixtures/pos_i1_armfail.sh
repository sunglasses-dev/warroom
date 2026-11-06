# I1: the refusal is a function whose last statement exits
# expect: pass
armfail() { echo "$1" >&2; exit 1; }
F=${1:-}
x=$(cat "$F") || armfail "could not read"
echo "$x"
