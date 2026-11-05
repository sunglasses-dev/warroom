# a function that refuses with exit, called inside ( ): the refusal ends the subshell only
# expect: fail called in the background
f() { x=$(cat "$1") || exit 1; echo "$x"; }
( f "$1" )
echo b > state
