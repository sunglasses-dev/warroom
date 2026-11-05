# the whole list runs in the background: the foreground goes on
# expect: fail another process
F=${1:-}
x=$(cat "$F") || exit 1 &
echo "$x" > out
