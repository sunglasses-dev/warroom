# a statement in front of the definition ends the prelude: the helper is not a prelude helper
# expect: fail falls back
echo start
die() { echo "$1" >&2; exit 1; }
F=${1:-}
x=$(cat "$F") || die "cannot read"
echo "$x" > out
