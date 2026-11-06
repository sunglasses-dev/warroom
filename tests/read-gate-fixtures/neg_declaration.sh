# refused: declaration builtin
# expect: fail declaration builtin
f() { local x=$(cat "$1") || return 1; echo "$x"; }
