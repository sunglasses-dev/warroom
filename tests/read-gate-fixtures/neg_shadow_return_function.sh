# a function named return replaces the refusal: tool error
# expect: error shadows
return() { :; }
f() {
  x=$(cat "$1") || return 1
  echo "$x" > out
}
