# shellcheck shell=bash
# lib/capture.sh — turn this box into a WiFi AP and capture the phone's call tunnel.
# The phone joins our AP, so its VoWiFi IPsec traffic traverses this host, where we
# tcpdump UDP 500/4500. This is the instrument that *sees* the tunnel instead of
# guessing about it. Your wired uplink is left untouched.

capture_usage() {
  cat <<'EOF'
usage: wcdiag capture [options]

Options:
  --ssid NAME    AP name to broadcast   (default: wcdiag-<random>)
  --pass PASS    AP password, >=8 chars (default: random, printed on start)
  --iface IFACE  WiFi interface to use as the AP (default: auto-detect)
  --dir DIR      where to write capture files (default: ./wcdiag-capture)
  -h, --help     this help

Steps it performs:
  1. brings up a NAT'd WiFi AP on a spare WiFi radio (needs root + nmcli)
  2. captures UDP 500/4500 to <dir>/tunnel.log (text) and <dir>/tunnel.pcap
  3. prints the SSID/password for you to join the phone and place a call
  4. tears the AP down cleanly on Ctrl-C

Then analyze with:  wcdiag analyze <dir>/tunnel.log
EOF
}

_cap_pick_iface() {
  # a WiFi device that is NOT carrying the default route
  local up_if; up_if=$(default_if)
  nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: -v u="$up_if" \
    '$2=="wifi" && $1!=u {print $1; exit}'
}

capture_main() {
  local ssid="" pass="" iface="" dir="./wcdiag-capture"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssid)  need_val "$#" "$1"; ssid="$2"; shift 2 ;;
      --pass)  need_val "$#" "$1"; pass="$2"; shift 2 ;;
      --iface) need_val "$#" "$1"; iface="$2"; shift 2 ;;
      --dir)   need_val "$#" "$1"; dir="$2"; shift 2 ;;
      -h|--help|help) capture_usage; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  require_cmd nmcli tcpdump ip
  require_root

  [ -n "$iface" ] || iface=$(_cap_pick_iface)
  [ -n "$iface" ] || die "no spare WiFi interface found (need a WiFi radio not used for uplink)"
  # never repurpose the interface carrying our route -- that would kill the uplink
  [ "$iface" = "$(default_if)" ] && die "refusing to use '$iface': it carries the default route (would kill your uplink)"
  local rnd; rnd=$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c4); rnd=${rnd:-diag}
  [ -n "$ssid" ] || ssid="wcdiag-$rnd"
  [ -n "$pass" ] || pass="wcdiag$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c6)"
  [ ${#pass} -ge 8 ] || die "password must be >=8 chars"
  mkdir -p "$dir"

  local uplink tailpid="" hs_profile="" _cleaned=0
  uplink=$(default_if)
  info "using WiFi radio '$iface' as the AP (uplink '$uplink' untouched)"

  # cleanup handler: idempotent. kills captures + tail, deletes the hotspot profile.
  cleanup() {
    [ "$_cleaned" = 1 ] && return 0
    _cleaned=1
    echo
    info "tearing down..."
    [ -n "$tailpid" ] && kill "$tailpid" 2>/dev/null
    $SUDO pkill -f "tcpdump -i $iface" 2>/dev/null
    if [ -n "$hs_profile" ]; then $SUDO nmcli connection delete "$hs_profile" 2>/dev/null
    else                          $SUDO nmcli connection down Hotspot 2>/dev/null; fi
    $SUDO nmcli device disconnect "$iface" 2>/dev/null
    ok "AP down. captures kept in $dir/"
  }
  trap 'cleanup; return 0' INT TERM

  info "starting AP..."
  $SUDO nmcli device wifi hotspot ifname "$iface" ssid "$ssid" password "$pass" >/dev/null 2>&1 \
    || die "failed to start hotspot on $iface (does the card support AP mode? 'nmcli -f WIFI-PROPERTIES.AP dev show $iface')"
  sleep 2
  # remember the actual profile name so cleanup deletes exactly it (no accumulation)
  hs_profile=$($SUDO nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null)

  if ! ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
    warn "uplink check failed after AP start -- verify internet before testing calls"
  fi

  info "starting capture..."
  $SUDO sh -c "tcpdump -i '$iface' -n -tttt -q 'udp port 500 or udp port 4500' > '$dir/tunnel.log' 2>/dev/null" &
  $SUDO sh -c "tcpdump -i '$iface' -w '$dir/tunnel.pcap' 'udp port 500 or udp port 4500' 2>/dev/null" &
  sleep 2

  hdr "AP is live -- join your phone and place a call"
  printf '  %sSSID:%s     %s\n' "$C_BOLD" "$C_RESET" "$ssid"
  printf '  %sPASSWORD:%s %s\n' "$C_BOLD" "$C_RESET" "$pass"
  info ""
  info "1. join the phone to that WiFi"
  info "2. wait ~30-60s for 'WiFi Calling' to reappear in the status bar"
  info "3. place the call that normally fails"
  info "4. press Ctrl-C here, then run:  wcdiag analyze $dir/tunnel.log"
  info ""
  info "live tunnel packets (Ctrl-C to stop & tear down):"
  # follow the text log until interrupted
  tail -n0 -F "$dir/tunnel.log" 2>/dev/null &
  tailpid=$!
  wait "$tailpid" 2>/dev/null
  cleanup
}
