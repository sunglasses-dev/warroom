# refused: statement after it
# expect: fail statement after it
rows=$(cat "$1")
while IFS= read -r l; do echo "$l"; done <<< "$rows"
