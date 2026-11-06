# any other case statement ends the prelude: the helper defined after it is not a prelude helper
# expect: fail falls back
case $0 in */*) _d=${0%/*} ;; *) _d=/x ;; esac
die() { echo "$1" >&2; exit 1; }
F=${1:-}
x=$(cat "$F") || die "cannot read $F"
echo "$x" > out
