# D display printed inside another substitution: the outer check says nothing about the display inside it
# expect: fail must be printed by echo or printf
# allow: D line=4 idx=1
hint=$(printf "%q" "$(date +%H:%M:%S)") || exit 1
printf '%s\n' "$hint" > "$1"
