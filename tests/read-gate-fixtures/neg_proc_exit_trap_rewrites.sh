# an EXIT trap rewrites the exit status: the file's refusals stop counting
# expect: fail hides or redefines
trap 'exit 0' EXIT
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
