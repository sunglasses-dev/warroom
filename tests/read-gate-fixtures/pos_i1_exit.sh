# I1: a checked capture; the failure exits
# expect: pass
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x"
