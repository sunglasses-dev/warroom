# refused: more than one substitution
# expect: fail more than one substitution
x=$(cat "$1") y=$(cat "$2") || exit 1
echo "$x$y"
