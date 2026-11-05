# refused: no match
# expect: fail no match
x=$( set -o pipefail; grep a "$1" | cut -c1-3 ) || exit 1
echo "$x"
