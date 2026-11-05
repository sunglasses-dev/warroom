# refused: falls back
# expect: fail falls back
_g=$(wc -l < "$1" 2>/dev/null) || _g=0
echo "$_g"
