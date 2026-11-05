# refused: __PARSE__
# expect: error outside the supported subset
x=$(( 1 + 1 )) ; if (( x > 1 )); then echo big; fi
