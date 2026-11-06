# refused: pipeline stage
# expect: fail pipeline stage
x=$( set -o pipefail; set +o pipefail; cat "$1" | cut -c1-3 ) || exit 1
echo "$x"
