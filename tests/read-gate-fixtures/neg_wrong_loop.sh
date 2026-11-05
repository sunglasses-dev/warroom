# refused: statement after it
# expect: fail statement after it
for f in a; do
  x=$(cat "$f"); [ -n "$x" ] || continue
done
