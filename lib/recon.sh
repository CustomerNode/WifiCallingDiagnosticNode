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

# Walk the path to the internet, classify each hop, estimate NAT depth.
# NAT layers sit at the *start* of the path, so we count LEADING consecutive
# private hops (stopping at the first non-private hop) rather than all private
# hops anywhere -- a private hop deeper in the path is usually ISP infra, not a
# NAT you own. This is still a heuristic (see the caveat printed below).
_recon_path() {
  local target="${1:-1.1.1.1}" tool tmp hop ip privhops=0 stop=0
  if have traceroute; then tool="traceroute -n -w2 -q1 -m8 $target"
  elif have tracepath; then tool="tracepath -n -m8 $target"
  else warn "no traceroute/tracepath; skipping path analysis"; return 0; fi

  tmp=$(mktemp)
  # Normalize both tools to "<hop> <ip>" lines, drop consecutive dupes. One run.
  $tool 2>/dev/null | awk '
      /^[[:space:]]*[0-9]+/ {
        n=$1; sub(/[:?]/,"",n)
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print n, $i; break }
      }' | awk '!seen[$2]++' > "$tmp"

  info "path to $target:"
  while read -r hop ip; do
    printf '      %2s  %-17s (%s)\n' "$hop" "$ip" "$(ip_class "$ip")"
  done < "$tmp"

  while read -r hop ip; do
    if [ "$stop" = 0 ] && [ "$(ip_class "$ip")" = private ]; then privhops=$((privhops+1)); else stop=1; fi
  done < "$tmp"
  rm -f "$tmp"

  if   [ "$privhops" -ge 2 ]; then
    warn "NAT depth: ${privhops} leading private hops -> LIKELY double NAT"
    info "      double NAT can disrupt WiFi Calling's NAT traversal, but does not"
    info "      always break it; VPNs/ISP infra/filtered traceroutes can look similar."
  elif [ "$privhops" -eq 1 ]; then ok "NAT depth: single leading private hop (typical single-NAT home)"
  else warn "NAT depth: undetermined (path filters ICMP, or no private hop seen)"; fi
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
