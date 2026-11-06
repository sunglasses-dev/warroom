# return outside a function fails and the script goes on
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || return 1
echo "$x" > out
