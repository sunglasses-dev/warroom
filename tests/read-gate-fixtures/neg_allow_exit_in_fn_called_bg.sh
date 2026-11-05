# the allowlist does not accept this shape: exit in fn called bg
# expect: fail background
f() { x=$(cat "$1") || exit 1; echo "$x" > out; }
f "$1" &
echo b > state
