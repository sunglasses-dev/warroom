# the allowlist does not accept this shape: while pipe
# expect: fail another process
F=${1:-}
printf "a\n" | while read -r l; do x=$(cat "$F") || exit 1; echo "$x" > out; done
echo ok > state
