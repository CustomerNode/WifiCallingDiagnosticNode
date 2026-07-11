# shellcheck shell=bash
# lib/common.sh — shared helpers for wcdiag. Sourced, never executed directly.

# ---- color / tty ----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
else
  C_RESET=; C_BOLD=; C_RED=; C_GRN=; C_YEL=
fi

# ---- logging --------------------------------------------------------------
hdr()  { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n'   "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '  %s[warn]%s %s\n'   "$C_YEL" "$C_RESET" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n'   "$C_RED" "$C_RESET" "$*"; }
err()  { printf '%swcdiag: %s%s\n'    "$C_RED" "$*" "$C_RESET" >&2; }
die()  { err "$*"; exit 1; }

# ---- capability checks ----------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local c missing=()
  for c in "$@"; do have "$c" || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

# Sets $SUDO to "sudo" (or "") so callers can prefix privileged commands.
# shellcheck disable=SC2034  # SUDO is consumed by callers that source this file
require_root() {
  if [ "$(id -u)" -eq 0 ]; then SUDO=""
  elif have sudo;         then SUDO="sudo"
  else die "this command needs root; install sudo or re-run as root"; fi
}

# ---- ip address classification -------------------------------------------
# echo one of: private | cgnat | linklocal | loopback | public
ip_class() {
  case "$1" in
    10.*|192.168.*)                                  echo private ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*)           echo private ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo cgnat ;;
    169.254.*)                                       echo linklocal ;;
    127.*)                                           echo loopback ;;
    *)                                               echo public ;;
  esac
}

# First IPv4 default-route gateway.
default_gw()  { ip route 2>/dev/null | awk '/^default/{print $3; exit}'; }
# Interface backing the default route.
default_if()  { ip route 2>/dev/null | awk '/^default/{print $5; exit}'; }

# Single ICMP RTT in ms, or the literal "LOSS". Portable (no PCRE), no stderr leak.
rtt() {
  local t
  t=$(ping -c1 -W1 "$1" 2>/dev/null | grep -oE 'time=[0-9.]+' 2>/dev/null | head -1)
  t=${t#time=}
  [ -n "$t" ] && echo "$t" || echo LOSS
}

# UDP egress probe. NOTE: UDP is connectionless, so "open" only means no ICMP
# reject arrived -- a silent drop also reads as "open". Not proof of a live path.
udp_open() { timeout 2 nc -u -z -w1 "$1" "$2" >/dev/null 2>&1 && echo open || echo reject; }

# Guard for value-taking options under `set -u`: $1 = remaining arg count, $2 = flag.
need_val() { [ "${1:-0}" -ge 2 ] || die "option ${2:-?} requires a value"; }

# Extract a top-level string field from JSON (pretty or compact): json_field <json> <key>
json_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
