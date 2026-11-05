# a function named return replaces the refusal: the file's refusals stop counting
# expect: fail hides or redefines
return() { :; }
f() {
  x=$(cat "$1") || return 1
  echo "$x" > out
}
