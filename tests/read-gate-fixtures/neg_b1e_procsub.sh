# refused: process substitution
# expect: fail process substitution
while IFS= read -r l; do echo "$l"; done < <(awk '{print}' "$1")
