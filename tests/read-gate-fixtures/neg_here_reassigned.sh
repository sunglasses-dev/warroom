# refused: unchecked capture
# expect: fail unchecked capture
rows=$(cat "$1") || exit 1
rows=$(cat "$2")
while IFS= read -r l; do echo "$l"; done <<< "$rows"
