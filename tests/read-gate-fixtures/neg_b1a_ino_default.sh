# refused: falls back
# expect: fail falls back
_ino=$(stat -c %i "$1" 2>/dev/null) || _ino=0
echo "$_ino"
