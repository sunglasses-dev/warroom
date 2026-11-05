# the allowlist does not accept this shape: die param
# expect: fail falls back
die() { exit "$1"; }
F=${1:-}
x=$(cat "$F") || die 0
echo "$x" > out
