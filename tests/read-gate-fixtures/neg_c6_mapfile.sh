# counterexample C6: refused (read returns 1)
# expect: fail read returns 1
mapfile -t rows < "$1" || exit 1
