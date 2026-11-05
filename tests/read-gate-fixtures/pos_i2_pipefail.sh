# I2: pipefail inside the substitution protects every stage
# expect: pass
F=${1:-}
x=$( set -o pipefail; cat "$F" | cut -d: -f1 ) || exit 1
echo "$x"
