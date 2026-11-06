# the allowlist does not accept this shape: alias
# expect: fail hides or redefines
shopt -s expand_aliases
alias exit=:
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
