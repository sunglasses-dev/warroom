# refused: only continues the loop
# expect: fail only continues the loop
for f in a b; do
  x=$(cat "$f") || continue
  echo "$x"
done
