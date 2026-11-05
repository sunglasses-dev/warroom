# the allowlist does not accept this shape: die in bg fn
# expect: fail background
die() { exit 1; }
F=${1:-}
x=$(cat "$F") || die &
echo "$x" > out
