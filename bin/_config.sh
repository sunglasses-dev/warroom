# shellcheck shell=bash
# bin/_config.sh — reads warroom.env as DATA. The file is never sourced or run, so nothing written in it can execute.
# Sourced by bin/_common.sh.
# Where: $WARROOM_ENV when it is set, otherwise ~/.warroom/warroom.env. No other place is read (not the current folder).
# Grammar, one setting per line; blank lines and lines starting with # are skipped:
#   KEY=VALUE    KEY: SEATS WARROOM_DIR BOARD WARROOM_POLL WARROOM_MIN_GAP WARROOM_IDLE_MIN WARROOM_LONG
#   VALUE may sit inside one pair of "double" or 'single' quotes. It may use letters, digits, space and _ . / ~ -
#   and may start with ~/ or $HOME/ (the only expansion). Any other character ($ ` ; | & < > quotes...) is refused.
#   WARROOM_POLL WARROOM_MIN_GAP WARROOM_IDLE_MIN WARROOM_LONG take digits only.
# Precedence: a variable already set in the environment, then the file, then the built-in default.
# A KEY may appear once: a second line with the same KEY is refused.
# Seat names: [A-Z][A-Z0-9_]{0,15}, no repeats; ALL, NONE and GUARD are reserved.
WR_KEYS="SEATS WARROOM_DIR BOARD WARROOM_POLL WARROOM_MIN_GAP WARROOM_IDLE_MIN WARROOM_LONG"
WR_SEAT_RE='^[A-Z][A-Z0-9_]{0,15}$'

wr_config_path() { if [ -n "${WARROOM_ENV:-}" ]; then printf '%s\n' "$WARROOM_ENV"; else printf '%s\n' "$HOME/.warroom/warroom.env"; fi; }

# wr_check_value VALUE: prints VALUE with a leading ~/ or $HOME/ expanded; returns 1 when VALUE breaks the grammar
# shellcheck disable=SC2088  # the quoted ~ is on purpose: it matches a literal ~ written in the file
wr_check_value() {
  _cv_p=""; _cv_r=$1
  case "$1" in
    "~"|'$HOME') _cv_p=$HOME; _cv_r="" ;;
    "~/"*)       _cv_p="$HOME/"; _cv_r=${1#"~/"} ;;
    '$HOME/'*)   _cv_p="$HOME/"; _cv_r=${1#'$HOME/'} ;;
  esac
  case "$_cv_r" in *[!A-Za-z0-9\ _./~-]*) return 1 ;; esac
  printf '%s' "$_cv_p$_cv_r"
}

# wr_seats_ok "LIST": every name matches the seat grammar, none is reserved, none repeats, the list is not empty
wr_seats_ok() {
  _so_seen=" "; _so_n=0
  for _so_s in $1; do
    case "$_so_s" in ALL|NONE|GUARD) return 1 ;; esac
    [[ $_so_s =~ $WR_SEAT_RE ]] || return 1
    case "$_so_seen" in *" $_so_s "*) return 1 ;; esac
    _so_seen="$_so_seen$_so_s "; _so_n=$((_so_n + 1))
  done
  [ "$_so_n" -gt 0 ]
}

# wr_load_config FILE: sets each KEY found in FILE unless the environment already set it; on a bad line prints why and returns 2
wr_load_config() {
  _lc_n=0; _lc_seen=" "
  while IFS= read -r _lc_line || [ -n "$_lc_line" ]; do
    _lc_n=$((_lc_n + 1)); _lc_line=${_lc_line%$'\r'}
    case "$_lc_line" in ''|'#'*) continue ;; esac
    if ! [[ $_lc_line =~ ^([A-Z_]+)=(.*)$ ]]; then
      echo "warroom.env line $_lc_n ($1): expected KEY=VALUE with nothing before KEY" >&2; return 2; fi
    _lc_k=${BASH_REMATCH[1]}; _lc_v=${BASH_REMATCH[2]}
    case " $WR_KEYS " in *" $_lc_k "*) ;; *) echo "warroom.env line $_lc_n ($1): unknown key $_lc_k (known: $WR_KEYS)" >&2; return 2 ;; esac
    case "$_lc_seen" in *" $_lc_k "*) echo "warroom.env line $_lc_n ($1): $_lc_k is set twice; keep one line" >&2; return 2 ;; esac
    _lc_seen="$_lc_seen$_lc_k "
    case "$_lc_v" in \"*\") _lc_v=${_lc_v#\"}; _lc_v=${_lc_v%\"} ;; \'*\') _lc_v=${_lc_v#\'}; _lc_v=${_lc_v%\'} ;; esac
    if ! _lc_v=$(wr_check_value "$_lc_v"); then
      echo "warroom.env line $_lc_n ($1): $_lc_k may only use letters, digits, space and _ . / ~ - (and start with ~/ or \$HOME/)" >&2; return 2; fi
    case "$_lc_k" in WARROOM_POLL|WARROOM_MIN_GAP|WARROOM_IDLE_MIN|WARROOM_LONG)
      case "$_lc_v" in ''|*[!0-9]*) echo "warroom.env line $_lc_n ($1): $_lc_k takes digits only" >&2; return 2 ;; esac ;; esac
    [ -n "${!_lc_k+x}" ] || printf -v "$_lc_k" '%s' "$_lc_v"
  done < "$1"
  return 0
}
