# sourcing: a failed source refuses (the dirname inside is part of the same checked capture)
# expect: pass
# min-occurrences: 2
HERE=$(cd -P "${0%/*}" 2>/dev/null && pwd -P) || exit 1
. "$HERE/_common.sh" || exit 1
