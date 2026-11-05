# refused: falls back
# expect: fail falls back
c=$(cat "$1" 2>/dev/null) || echo none
echo "$c"
