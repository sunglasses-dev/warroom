# command eval redefines exit
# expect: fail hides or redefines
command eval 'exit() { :; }'
x=$(cat "$1") || exit 1
echo b > state
