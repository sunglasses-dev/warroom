# a helper whose last statement is the read propagates its status
# expect: pass
# min-occurrences: 2
rd() { cat "$1"; }
F=${1:-}
x=$(rd "$F") || exit 1
echo "$x"
