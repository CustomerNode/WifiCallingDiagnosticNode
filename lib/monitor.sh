# shellcheck shell=bash
# lib/monitor.sh — continuous path-correlation monitor.
# Logs, once per second, latency/loss to each hop a WiFi call depends on, so you
# can reproduce a failed call and see whether the shared path degraded at that
# instant (transient) or stayed clean (tunnel/registration problem).

monitor_usage() {
  cat <<'EOF'
usage: wcdiag monitor [options]

Options:
  --carrier NAME   resolve & track this carrier's ePDG (verizon|att|tmobile)
  --epdg IP        also probe this carrier ePDG IP (see 'wcdiag epdg')
  --dnat-watch IP  flag if this address (an old inner gateway) reappears
                   in the path -- i.e. a double-NAT config reverted
  --out FILE       CSV output (default: ./wcdiag-monitor.csv)
  --duration SEC   stop after N seconds (default: run until 'wcdiag monitor --stop')
  --stop           signal a running monitor to exit
  -h, --help       this help

The monitor auto-detects your default gateway and always tracks the internet
(1.1.1.1). Reproduce a failed call, note the time, then read the CSV around it:
a clean path during the failure means the fault is in the call tunnel, not the pipe.
EOF
}

monitor_main() {
  local epdg="" carrier="" dnat="" out="./wcdiag-monitor.csv" dur=0 stopfile="/tmp/wcdiag-monitor.stop"
  while [ $# -gt 0 ]; do
    case "$1" in
      --carrier)    need_val "$#" "$1"; carrier="$2"; shift 2 ;;
      --epdg)       need_val "$#" "$1"; epdg="$2"; shift 2 ;;
      --dnat-watch) need_val "$#" "$1"; dnat="$2"; shift 2 ;;
      --out)        need_val "$#" "$1"; out="$2";  shift 2 ;;
      --duration)   need_val "$#" "$1"; dur="$2";  shift 2 ;;
      --stop)       : > "$stopfile"; ok "stop signalled"; return 0 ;;
      -h|--help|help) monitor_usage; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  require_cmd ip ping

  # resolve a carrier ePDG to an IP if requested
  if [ -n "$carrier" ] && [ -z "$epdg" ]; then
    require_cmd dig
    local host
    case "$carrier" in
      verizon) host=sg.vzwfemto.com ;;                                  # answers ICMP
      att)     host=epdg.epc.mnc280.mcc310.pub.3gppnetwork.org ;;
      tmobile) host=epdg.epc.mnc260.mcc310.pub.3gppnetwork.org ;;
      *) die "unknown carrier: $carrier (verizon|att|tmobile)" ;;
    esac
    epdg=$(dig +short +time=2 "$host" 2>/dev/null | grep -Eo '^[0-9.]+$' | head -1)
    [ -n "$epdg" ] && info "resolved $carrier ePDG: $epdg ($host)" \
                   || warn "could not resolve $carrier ePDG; monitoring path only"
  fi

  local gw; gw=$(default_gw); [ -n "$gw" ] || die "no default gateway found"
  rm -f "$stopfile"
  [ -f "$out" ] || echo "timestamp,gw_ms,inet_ms,epdg_ms,note" > "$out"

  info "monitoring: gateway=$gw internet=1.1.1.1 ${epdg:+epdg=$epdg} ${dnat:+dnat-watch=$dnat}"
  info "logging to: $out    (stop: wcdiag monitor --stop, or Ctrl-C)"
  trap 'echo; ok "monitor stopped"; return 0' INT TERM

  local tick=0 ts g i e note
  while :; do
    [ -f "$stopfile" ] && { rm -f "$stopfile"; ok "stopped via --stop"; break; }
    [ "$dur" -gt 0 ] && [ "$tick" -ge "$dur" ] && { ok "reached --duration ${dur}s"; break; }
    ts=$(date '+%F %T'); g=$(rtt "$gw"); i=$(rtt 1.1.1.1)
    e=""; [ -n "$epdg" ] && e=$(rtt "$epdg")
    note=""
    if [ -n "$dnat" ] && [ $((tick % 10)) -eq 0 ]; then
      if ping -c1 -W1 "$dnat" >/dev/null 2>&1; then
        note="DOUBLE_NAT_BACK"
        printf '%s[%s] *** %s reachable again -- double NAT reverted, calls will break ***%s\n' \
               "$C_RED" "$ts" "$dnat" "$C_RESET" >&2
      else note="single-nat-ok"; fi
    fi
    echo "$ts,$g,$i,$e,$note" >> "$out"
    case "$g$i$e" in *LOSS*) printf '%s[%s] LOSS  gw=%s inet=%s epdg=%s%s\n' \
                           "$C_YEL" "$ts" "$g" "$i" "${e:-n/a}" "$C_RESET" >&2 ;; esac
    tick=$((tick+1)); sleep 1
  done
  trap - INT TERM
  hdr "Quick stats"
  awk -F, 'NR>1{n++
      if($2=="LOSS")gl++; if($3=="LOSS")il++; if($4=="LOSS")el++
      if($4!="LOSS"&&$4!=""){es+=$4;en++}}
    END{printf "  samples:%d  loss  gw:%d inet:%d epdg:%d%s\n",n,gl+0,il+0,el+0,
        (en?sprintf("   epdg avg:%.0fms",es/en):"")}' "$out"
}
