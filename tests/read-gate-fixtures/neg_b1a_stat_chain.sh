# refused: falls back
# expect: fail falls back
x=$(stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null)
echo "$x"
