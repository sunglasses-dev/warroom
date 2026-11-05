# refused: read returns 1
# expect: fail read returns 1
read -r a < "$1" 2>/dev/null
echo "$a"
