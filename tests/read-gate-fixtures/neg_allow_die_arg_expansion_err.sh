# the allowlist does not accept this shape: die arg expansion err
# expect: fail falls back
die() { echo "$1" >&2; exit 1; }
F=${1:-}
x=$(cat "$F") || die "${UNSET_VAR:?}"
echo "$x" > out
