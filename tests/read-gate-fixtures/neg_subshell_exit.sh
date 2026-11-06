# refused: falls back
# expect: fail falls back
x=$(cat "$1") || ( exit 1 )
echo "$x"
