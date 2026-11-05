# a helper switches pipefail off before the pipeline
# expect: fail pipeline stage
off() { set +o pipefail; }
x=$(set -o pipefail; off; cat "$1" | cat) || exit 1
printf "consumed=<%s>\n" "$x"
