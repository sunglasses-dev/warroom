# refused: declaration builtin
# expect: fail declaration builtin
export X=$(cat "$1") || exit 1
