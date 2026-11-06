# refused: pipeline stage
# expect: fail pipeline stage
hit=$(grep -nE "^x" "$1" | tail -1); line=${hit#*:}
echo "$line"
