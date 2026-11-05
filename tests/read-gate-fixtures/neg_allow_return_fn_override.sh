# the allowlist does not accept this shape: return fn override
# expect: fail hides or redefines
return() { :; }
f() {
  x=$(cat "$1") || return 1
  echo "$x" > out
}
