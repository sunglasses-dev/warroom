# a group that is a pipeline stage is a subshell
# expect: fail another process
F=${1:-}
{ x=$(cat "$F") || exit 1; } | true
echo "$x" > out
