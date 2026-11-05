# refused: file feeding a loop
# expect: fail file feeding a loop
while IFS= read -r l; do echo "$l"; done < "$1"
