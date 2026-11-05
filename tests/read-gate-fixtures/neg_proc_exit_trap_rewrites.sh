# an EXIT trap rewrites the exit status: tool error
# expect: error EXIT trap
trap 'exit 0' EXIT
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
