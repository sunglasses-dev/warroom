# the allowlist does not accept this shape: use in fn called before def
# expect: fail falls back
f() { x=$(cat "$1") || die; echo "$x" > out; }
f "${1:-}"
die() { exit 1; }
