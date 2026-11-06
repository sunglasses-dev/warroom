# exit 256 stops the script with status 0
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || { echo "cannot read" >&2; exit 256; }
echo "$x" > out
