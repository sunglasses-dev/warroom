# I4: snapshot into a variable with a checked capture, then iterate the variable
# expect: pass
# min-occurrences: 2
F=${1:-}
rows=$(cat "$F") || exit 1
while IFS= read -r line; do
  echo "$line"
done <<< "$rows"
