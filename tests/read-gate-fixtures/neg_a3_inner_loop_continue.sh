# counterexample A3: refused (only continues the loop)
# expect: fail only continues the loop
for f in a b; do
  while true; do x=$(cat "$f") || continue; break; done
done
