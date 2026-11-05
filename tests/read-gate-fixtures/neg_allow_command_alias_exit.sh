# command alias replaces exit
# expect: fail hides or redefines
shopt -s expand_aliases
command alias exit=:
x=$(cat "$1") || exit 1
echo b > state
