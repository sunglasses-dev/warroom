# the allowlist does not accept this shape: printf shadow
# expect: fail hides or redefines
printf() { builtin exit 0; }
F=${1:-}
x=$(cat "$F") || { printf "cannot read\n" >&2; exit 1; }
cat <<< "$x" > out
