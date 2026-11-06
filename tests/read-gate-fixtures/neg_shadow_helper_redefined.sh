# a helper defined twice: the second one does not exit
# expect: fail falls back
die() { echo "$1" >&2; exit 1; }
die() { echo "$1" >&2; }
F=${1:-}
x=$(cat "$F") || die "cannot read"
echo "$x" > out
