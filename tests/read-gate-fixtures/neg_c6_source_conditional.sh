# counterexample C6: refused (statement after it)
# expect: fail statement after it
HERE=/x
. "$HERE/a.sh"; . "$HERE/b.sh" || exit 1
