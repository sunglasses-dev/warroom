# refused: pipeline stage
# expect: fail pipeline stage
cat "$1" | cut -c1-5
echo done
