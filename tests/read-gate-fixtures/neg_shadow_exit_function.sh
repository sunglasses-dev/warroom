# a function named exit replaces the refusal: tool error
# expect: error shadows
exit() { echo nope; }
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
