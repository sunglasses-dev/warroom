# a function with a checked read is a pipeline stage whose status nobody looks at
# expect: fail runs whatever the status was
f() { x=$(cat "$1") || exit 1; echo "$x" > out; }
echo a | f "$1"
echo b > state
