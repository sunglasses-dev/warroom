# sourcing: a failed source refuses (the dirname inside is part of the same checked capture); the file sources itself, so the path resolves
# expect: pass
# min-occurrences: 2
HERE=$(dirname "$0") || exit 1
. "$HERE/pos_src_checked.sh" || exit 1
