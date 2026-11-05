# refused: argument
# expect: fail argument
printf '%s %s\n' "$a" "$(date +%s)" >> "$T" || exit 1
