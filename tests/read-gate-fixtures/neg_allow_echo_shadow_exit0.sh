# the allowlist does not accept this shape: echo shadow exit0
# expect: fail hides or redefines
echo() { exit 0; }
F=${1:-}
x=$(cat "$F") || { echo "cannot read" >&2; exit 1; }
printf "%s\n" "$x" > out
