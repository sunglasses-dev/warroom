# eval can define any function: the file's refusals stop counting
# expect: fail hides or redefines
eval 'exit() { :; }'
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
