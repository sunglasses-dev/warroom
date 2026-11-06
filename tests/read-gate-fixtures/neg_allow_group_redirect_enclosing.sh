# a redirection on the group that holds the read and the refusal
# expect: fail another process
F=${1:-}
{ x=$(cat "$F") || exit 1; } > /nonexistent-dir/x
echo "$x" > out
