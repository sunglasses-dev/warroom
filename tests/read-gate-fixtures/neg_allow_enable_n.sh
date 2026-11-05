# the allowlist does not accept this shape: enable n
# expect: fail hides or redefines
enable -n exit
F=${1:-}
x=$(cat "$F") || exit 1
echo "$x" > out
