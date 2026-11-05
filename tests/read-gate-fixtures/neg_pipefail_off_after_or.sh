# pipefail is switched off after ||: the list still reads as "pipefail is on"
# expect: fail pipeline stage
x=$(set -o pipefail; true || set +o pipefail; cat "$1" | cat) || exit 1
printf "consumed=<%s>\n" "$x"
