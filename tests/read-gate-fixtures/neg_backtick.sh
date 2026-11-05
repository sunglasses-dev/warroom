# refused: backtick
# expect: fail backtick
x=`cat "$1"` || exit 1
echo "$x"
