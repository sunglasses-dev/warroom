# a redirection on the if that holds the read and the refusal: when it fails the whole if is skipped
# expect: fail another process
F=${1:-}
if ! x=$(cat "$F"); then
  exit 1
fi > /nonexistent-dir/x
echo "$x" > out
