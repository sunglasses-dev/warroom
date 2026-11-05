# a function with a checked read is called in the background: its refusal ends only that process
# expect: fail called in the background
f() { x=$(cat "$1") || exit 1; echo "$x" > out; }
f "$1" &
echo b > state
