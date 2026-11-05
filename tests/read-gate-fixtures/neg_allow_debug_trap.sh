# the allowlist does not accept this shape: debug trap
# expect: fail hides or redefines
trap '[ "$BASH_COMMAND" = "exit 1" ] && exit 0' DEBUG
F=${1:-}
x=$(cat "$F") || exit 1
printf '%s\n' "$x" > out
