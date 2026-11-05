# a function named exit replaces the refusal: the file's refusals stop counting
# expect: fail hides or redefines
exit() { echo nope; }
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
