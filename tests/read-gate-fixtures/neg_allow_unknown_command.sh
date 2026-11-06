# a command the allowlist does not name is not a refusal, whatever it might do
# expect: fail falls back
F=${1:-}
x=$(cat "$F") || mystery 1
echo "$x" > out
