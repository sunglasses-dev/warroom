# the same pipeline stage with the status checked
# expect: pass
# min-occurrences: 2
f() { x=$(cat "$1") || exit 1; echo "$x" > out; }
echo a | f "$1" || exit 1
echo b > state
