# a group that is a pipeline stage is a subshell
# expect: fail another process
sink() { :; }
F=${1:-}
{ x=$(cat "$F") || exit 1; } | sink
echo "$x" > out
