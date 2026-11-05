# counterexample A7: refused (falls back)
# expect: fail falls back
x=$(cat "$1") || { if [ -n "$2" ]; then exit 1; fi; }
echo "$x"
