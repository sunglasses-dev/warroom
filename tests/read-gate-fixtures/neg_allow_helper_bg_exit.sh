# the allowlist does not accept this shape: helper bg exit
# expect: fail falls back
die() { echo e >&2; exit 1 & }
F=${1:-}
x=$(cat "$F") || die
echo "$x" > out
