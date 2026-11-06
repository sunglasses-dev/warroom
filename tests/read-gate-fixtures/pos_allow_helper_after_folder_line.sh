# the line that finds the script's own folder and its checked capture do not end the prelude: a helper after them still refuses
# expect: pass
case $0 in */*) _d=${0%/*}; [ -n "$_d" ] || _d=/ ;; *) _d=. ;; esac
HERE=$(cd -P -- "$_d" && pwd) || exit 1
die() { echo "$1" >&2; exit 1; }
F=${1:-}
x=$(cat "$F") || die "cannot read $F"
echo "$x" > out
