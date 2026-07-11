# shellcheck shell=bash
# lib/epdg.sh — resolve and probe carrier ePDG gateways (the WiFi Calling endpoint).

epdg_usage() {
  cat <<'EOF'
usage: wcdiag epdg [carrier]

Resolve and probe the carrier's ePDG (Evolved Packet Data Gateway) -- the
IPsec endpoint every WiFi call connects to on UDP 500 (IKE) and 4500 (NAT-T).

  carrier:  verizon | att | tmobile | all   (default: all)

For each gateway it prints the resolved IPs, an ICMP latency probe, and whether
UDP 500/4500 egress is blocked. Use the resolved IP with 'wcdiag monitor --epdg'.
EOF
}

# carrier -> "label|host1 host2 ..."  (ePDG DNS names)
_epdg_hosts() {
  case "$1" in
    verizon) echo "Verizon|wo.vzwwo.com sg.vzwfemto.com" ;;
    att)     echo "AT&T|epdg.epc.mnc280.mcc310.pub.3gppnetwork.org" ;;
    tmobile) echo "T-Mobile|epdg.epc.mnc260.mcc310.pub.3gppnetwork.org" ;;
    *)       echo "" ;;
  esac
}

_epdg_probe_one() {
  local carrier="$1" spec label hosts host ip ips
  spec=$(_epdg_hosts "$carrier"); [ -n "$spec" ] || { warn "unknown carrier: $carrier"; return 1; }
  label=${spec%%|*}; hosts=${spec#*|}
  hdr "$label ePDG"
  for host in $hosts; do
    ips=$(dig +short +time=2 +tries=1 "$host" 2>/dev/null | grep -Eo '^[0-9.]+$' | tr '\n' ' ')
    if [ -z "$ips" ]; then
      warn "$host -> (no public DNS answer; carriers often resolve ePDG only on-device)"
      continue
    fi
    info "$host -> $ips"
    ip=$(printf '%s' "$ips" | awk '{print $1}')
    local r; r=$(rtt "$ip")
    [ "$r" = LOSS ] && info "    icmp: no reply (normal; many ePDGs drop ping)" || ok "    icmp: ${r} ms"
    info "    udp/500  egress: $(udp_open "$ip" 500)"
    info "    udp/4500 egress: $(udp_open "$ip" 4500)"
  done
}

epdg_main() {
  case "${1:-all}" in -h|--help|help) epdg_usage; return 0 ;; esac
  require_cmd dig ping nc
  local carrier="${1:-all}"
  if [ "$carrier" = all ]; then
    for c in verizon att tmobile; do _epdg_probe_one "$c"; done
  else
    _epdg_probe_one "$carrier"
  fi
  hdr "Note"
  info "'open' means no ICMP reject was seen -- the first tunnel packet can leave. It"
  info "does NOT prove the full tunnel survives NAT. If egress is open but calls fail,"
  info "capture the tunnel with 'wcdiag capture' to see where it actually breaks."
}
