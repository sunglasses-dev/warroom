# refused: no match
# expect: fail no match
grep -q x "$1" || exit 1
