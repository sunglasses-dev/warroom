# C: continue bound to the named loop
# expect: pass
# allow: C line=6 idx=0
F=${1:-}
for _ in 1 2; do
  x=$(cat "$F") || continue
  echo "$x"
done
