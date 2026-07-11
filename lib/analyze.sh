# shellcheck shell=bash
# lib/analyze.sh — read a captured tunnel and report what the call actually did:
# tunnel establishment, whether it stayed up (roaming), and audio direction
# (the one-way-audio verdict) from per-second packet rates.

analyze_usage() {
  cat <<'EOF'
usage: wcdiag analyze <tunnel.log | tunnel.pcap>

Analyzes a capture from 'wcdiag capture':
  - when/if the IPsec tunnel established (UDP 500 -> 4500 handshake)
  - whether it stayed up or re-handshaked mid-call (a sign of WiFi roaming)
  - per-second uplink vs downlink packet rates
  - a one-way-audio verdict (a full voice stream is ~50 packets/sec)
EOF
}

# echo the private/cgnat (local) or public (epdg) endpoint from the capture.
# tcpdump prints "src.port > dst.port:" -- the dst token carries a trailing ':',
# so the IP.port regex only ever matches the *source* address of each line. That
# is sufficient: outbound lines supply the local source, inbound lines the public.
_first_endpoint() {
  local file="$1" want="$2" x
  awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+>?$/){
          split($i,a,"."); print a[1]"."a[2]"."a[3]"."a[4]; break}}' "$file" \
  | while read -r x; do
      case "$(ip_class "$x")" in
        private|cgnat) [ "$want" = local ] && { echo "$x"; break; } ;;
        public)        [ "$want" = epdg  ] && { echo "$x"; break; } ;;
      esac
    done
}

analyze_main() {
  case "${1:-}" in
    "" ) analyze_usage; return 1 ;;
    -h|--help|help) analyze_usage; return 0 ;;
  esac
  local src="$1"
  [ -r "$src" ] || die "cannot read: $src"
  require_cmd awk

  local tmp; tmp=$(mktemp)
  case "$src" in
    *.pcap|*.pcapng)
      require_cmd tcpdump
      tcpdump -n -tttt -q -r "$src" 'udp port 500 or udp port 4500' 2>/dev/null > "$tmp" ;;
    *) cp "$src" "$tmp" ;;
  esac
  [ -s "$tmp" ] || { rm -f "$tmp"; die "no tunnel packets found in $src"; }

  local local_ip epdg_ip
  local_ip=$(_first_endpoint "$tmp" local)
  epdg_ip=$(_first_endpoint "$tmp" epdg)

  hdr "Endpoints"
  info "phone (local): ${local_ip:-?}"
  info "carrier ePDG:  ${epdg_ip:-?}"
  [ -n "$local_ip" ] && [ -n "$epdg_ip" ] || { rm -f "$tmp"; die "could not identify both endpoints"; }

  hdr "Tunnel establishment"
  local first500 first4500 span_start span_end reinit
  first500=$(grep -m1 '\.500 >' "$tmp"  | awk '{print $2}')
  first4500=$(grep -m1 '\.4500 >' "$tmp" | awk '{print $2}')
  span_start=$(head -1 "$tmp" | awk '{print $2}')
  span_end=$(tail -1 "$tmp"   | awk '{print $2}')
  info "capture span:      $span_start .. $span_end"
  [ -n "$first500" ]  && ok "IKE_SA_INIT (udp/500) at   $first500"  || warn "no udp/500 seen"
  [ -n "$first4500" ] && ok "NAT-T switch (udp/4500) at  $first4500" || warn "no udp/4500 seen"
  # grep -c already prints 0 (and exits 1) on no match; don't append a second 0
  reinit=$(grep -c '\.500 >' "$tmp" 2>/dev/null); reinit=${reinit:-0}
  if [ "${reinit:-0}" -gt 4 ]; then
    warn "multiple udp/500 exchanges ($reinit) -- tunnel may have re-handshaked (WiFi roaming?)"
  else
    ok "no mid-call re-handshake (tunnel stable, no roaming drop)"
  fi

  # per-second table -> $tmp.tbl (shown); summary numbers -> $tmp.sum (parsed)
  hdr "Audio direction (per second: UP=you->them  DOWN=them->you)"
  awk -v L="$local_ip" -v E="$epdg_ip" -v SUM="$tmp.sum" '
    { split($2,t,"."); sec=t[1]
      if (index($0, L".") && index($0, "> "E)) { o[sec]++; oo++ }
      else if (index($0, E".") && index($0, "> "L)) { d[sec]++; dd++ }
      seen[sec]=1 }
    END {
      c=0; for(s in seen) key[++c]=s
      for(i=1;i<=c;i++) for(j=i+1;j<=c;j++) if(key[i]>key[j]){sw=key[i];key[i]=key[j];key[j]=sw}
      pu=0; pd=0
      for(i=1;i<=c;i++){ s=key[i]
        printf "  %s   UP %3d | DOWN %3d\n", s, o[s]+0, d[s]+0
        if(o[s]>pu)pu=o[s]; if(d[s]>pd)pd=d[s] }
      printf "%d %d %d %d\n", oo+0, dd+0, pu, pd > SUM
    }' "$tmp" | tee "$tmp.tbl"

  local uptot downtot peakup peakdown
  read -r uptot downtot peakup peakdown < "$tmp.sum" 2>/dev/null
  peakup=${peakup:-0}; peakdown=${peakdown:-0}; uptot=${uptot:-0}; downtot=${downtot:-0}

  hdr "Verdict"
  info "totals  UP:${uptot:-0}  DOWN:${downtot:-0}    peak  UP:${peakup}/s  DOWN:${peakdown}/s  (voice stream ~= 50/s)"
  if   [ "$peakdown" -ge 25 ] && [ "$peakup" -lt 8 ]; then
    bad "downlink streamed, uplink did not -> ONE-WAY (they can't hear you) OR you were only listening"
  elif [ "$peakup" -ge 25 ] && [ "$peakdown" -lt 8 ]; then
    bad "uplink streamed, downlink did not -> ONE-WAY (you can't hear them)"
  elif [ "$peakup" -ge 20 ] && [ "$peakdown" -ge 20 ]; then
    ok "two-way voice streams present -> media path healthy on this network"
  else
    warn "no sustained voice stream -- call may not have connected, or was too short"
  fi
  info "note: 'listening only' also shows low uplink; confirm against what you heard."
  rm -f "$tmp" "$tmp.sum" "$tmp.tbl"
}
