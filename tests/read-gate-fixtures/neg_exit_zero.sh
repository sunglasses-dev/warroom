# refused: falls back
# expect: fail falls back
x=$(cat "$1") || exit 0
echo "$x"
