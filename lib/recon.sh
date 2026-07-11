# shellcheck shell=bash
# lib/recon.sh — network reconnaissance: topology, NAT depth, ISP, IPv6, DNS.

recon_usage() {
  cat <<'EOF'
usage: wcdiag recon

One-shot reconnaissance of the network path a WiFi call must traverse.
Reports: interfaces, gateway(s), NAT depth (flags double NAT), ISP/public IP,
IPv6 internet reachability, and DNS servers.
EOF
}

# Walk the path to the internet and classify each hop; count NAT layers.
_recon_path() {
  local target="${1:-1.1.1.1}" tool hop ip cls privhops
  if have traceroute; then tool="traceroute -n -w2 -q1 -m8 $target"
  elif have tracepath; then tool="tracepath -n -m8 $target"
  else warn "no traceroute/tracepath; skipping path analysis"; return 0; fi

  info "path to $target:"
  # Normalize both tools to "<n> <ip>" lines.
  $tool 2>/dev/null | awk '
      /^[[:space:]]*[0-9]+/ {
        n=$1; sub(/[:?]/,"",n)
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print n, $i; break }
      }' | awk '!seen[$2]++' | while read -r hop ip; do
    cls=$(ip_class "$ip")
    printf '      %2s  %-17s (%s)\n' "$hop" "$ip" "$cls"
  done

  # Second pass for the verdict (subshell above can't export nat count).
  local privhops
  privhops=$($tool 2>/dev/null | awk '
      /^[[:space:]]*[0-9]+/ {
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; break }
      }' | awk '!s[$0]++' | while read -r ip; do
        case "$(ip_class "$ip")" in private) echo x ;; esac
      done | wc -l)

  if   [ "$privhops" -ge 2 ]; then bad  "NAT depth: $privhops private hops -> DOUBLE NAT (breaks WiFi Calling)"
  elif [ "$privhops" -eq 1 ]; then ok   "NAT depth: single NAT (healthy for WiFi Calling)"
  else warn "NAT depth: could not determine (path may filter ICMP)"; fi
}

recon_main() {
  case "${1:-}" in -h|--help|help) recon_usage; return 0 ;; esac
  require_cmd ip ping

  hdr "Interfaces & addresses"
  ip -brief -4 addr show 2>/dev/null | awk '$1!="lo"{printf "  %-14s %s %s\n",$1,$2,$3}'

  hdr "Gateway & path"
  local gw ifc
  gw=$(default_gw); ifc=$(default_if)
  [ -n "$gw" ] && info "default gateway: $gw via ${ifc:-?}  ($(rtt "$gw") ms)" || warn "no default route"
  _recon_path 1.1.1.1

  hdr "Internet & ISP"
  local r4; r4=$(rtt 1.1.1.1)
  [ "$r4" != LOSS ] && ok "IPv4 internet reachable ($r4 ms to 1.1.1.1)" || bad "IPv4 internet unreachable"
  if have curl; then
    local j org city region; j=$(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null)
    if [ -n "$j" ]; then
      org=$(json_field "$j" org); city=$(json_field "$j" city); region=$(json_field "$j" region)
      info "public IP: $(json_field "$j" ip)"
      info "ISP:       ${org:-?}"
      info "location:  ${city:-?}, ${region:-?}"
    fi
  fi

  hdr "IPv6"
  if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 2'; then
    if ping -6 -c1 -W2 2606:4700:4700::1111 >/dev/null 2>&1; then ok "global IPv6 present and reaches the internet"
    else warn "global IPv6 assigned but internet unreachable (half-broken v6 can stall WiFi Calling)"; fi
  else
    warn "no global IPv6 (ULA/link-local only) -- some carriers prefer IPv6 for WiFi Calling"
  fi

  hdr "DNS"
  if have resolvectl; then
    resolvectl status 2>/dev/null | awk '/Current DNS Server:/{print "  server: "$4}' | sort -u
  elif [ -r /etc/resolv.conf ]; then
    awk '/^nameserver/{print "  server: "$2}' /etc/resolv.conf
  fi

  hdr "Summary"
  info "WiFi Calling rides an IPsec tunnel to your carrier's ePDG (UDP 500/4500)."
  info "Next: 'wcdiag epdg <carrier>' to probe that gateway,"
  info "      'wcdiag monitor' to watch the path, 'wcdiag capture' to see the tunnel."
}
