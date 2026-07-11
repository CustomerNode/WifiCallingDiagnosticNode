# shellcheck shell=bash
# lib/analyze.sh — read a captured tunnel and report what the call likely did.
#
# IMPORTANT: everything here is a HEURISTIC over IPsec *metadata*. The tunnel
# payload is encrypted, so we cannot see RTP directly. We infer a "voice stream"
# from packet size + a sustained per-second rate, and we label every verdict with
# a confidence level. These are leads to confirm against what you actually heard,
# not definitive diagnoses.
#
# Tunables (env overrides): WCDIAG_VOICE_MINB / _MAXB (voice-frame byte band),
# WCDIAG_VOICE_RATE (min packets/sec to call a second "streaming"),
# WCDIAG_VOICE_RUN (min consecutive such seconds), WCDIAG_HS_GAP (sec gap that
# separates two IKE handshake bursts).

analyze_usage() {
  cat <<'EOF'
usage: wcdiag analyze <tunnel.log | tunnel.pcap>

Heuristic read of a capture from 'wcdiag capture':
  - when/if the IPsec tunnel established (UDP 500 -> 4500 handshake)
  - how many separate IKE handshake bursts occurred (re-key / roaming signal)
  - per-second voice-band packet rates per direction
  - a CONFIDENCE-TAGGED audio observation (not proof of RTP direction)

All thresholds are heuristics; override with WCDIAG_VOICE_* / WCDIAG_HS_GAP.
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

  local VMIN=${WCDIAG_VOICE_MINB:-80} VMAX=${WCDIAG_VOICE_MAXB:-240}
  local VRATE=${WCDIAG_VOICE_RATE:-20} VRUN=${WCDIAG_VOICE_RUN:-2}
  local HSGAP=${WCDIAG_HS_GAP:-5}

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
  local first500 first4500 span_start span_end
  first500=$(grep -m1 '\.500 >' "$tmp"  | awk '{print $2}')
  first4500=$(grep -m1 '\.4500 >' "$tmp" | awk '{print $2}')
  span_start=$(head -1 "$tmp" | awk '{print $2}')
  span_end=$(tail -1 "$tmp"   | awk '{print $2}')
  info "capture span:      $span_start .. $span_end"
  [ -n "$first500" ]  && ok "IKE_SA_INIT (udp/500) at   $first500"  || warn "no udp/500 seen (tunnel may predate the capture)"
  [ -n "$first4500" ] && ok "NAT-T switch (udp/4500) at  $first4500" || warn "no udp/4500 seen"

  # Burst-based re-handshake detection: group udp/500 packets into time-separated
  # bursts (gap > HSGAP). One burst = a normal handshake (init + retries). More
  # than one well-separated burst suggests a re-key / re-establish (e.g. roaming).
  local bursts
  bursts=$(awk -v GAP="$HSGAP" '
    /\.500 >/ { split($2,t,":"); split(t[3],s,"."); now=t[1]*3600+t[2]*60+s[1]
                if (prev=="" || now-prev>GAP) b++; prev=now }
    END { print b+0 }' "$tmp")
  if   [ "${bursts:-0}" -le 1 ]; then ok  "1 IKE handshake burst -> stable (no re-key/roaming signal)"
  else warn "${bursts} separate IKE handshake bursts -> tunnel re-keyed/re-established (possible WiFi roaming)"; fi

  # Voice-stream heuristic: count only voice-band packets, per direction, per
  # second; a "stream" requires a sustained run of seconds at >= VRATE.
  hdr "Voice-stream heuristic (per second: only ${VMIN}-${VMAX}B packets counted as candidate voice)"
  awk -v L="$local_ip" -v E="$epdg_ip" -v LO="$VMIN" -v HI="$VMAX" -v RATE="$VRATE" -v SUM="$tmp.sum" '
    function secnum(ts,   a,b){ split(ts,a,":"); split(a[3],b,"."); return a[1]*3600+a[2]*60+b[1] }
    function longest_run(K,c,arr,RATE,   i,s,run,best,prev){
      best=0; run=0; prev=-999
      for(i=1;i<=c;i++){ s=K[i]; if(arr[s]+0>=RATE){ if(s==prev+1)run++; else run=1; if(run>best)best=run; prev=s } }
      return best }
    { sz=$NF+0; s=secnum($2); seen[s]=1
      up=(index($0,L".") && index($0,"> "E)); dn=(index($0,E".") && index($0,"> "L))
      if(sz>=LO && sz<=HI){ if(up){uv[s]++; if(uv[s]>upk)upk=uv[s]} else if(dn){dv[s]++; if(dv[s]>dpk)dpk=dv[s]} } }
    END{
      c=0; for(s in seen) K[++c]=s
      for(i=1;i<=c;i++) for(j=i+1;j<=c;j++) if(K[i]>K[j]){sw=K[i];K[i]=K[j];K[j]=sw}
      for(i=1;i<=c;i++){ s=K[i]; if(uv[s]||dv[s]) printf "  +%3ds   voiceUP %3d | voiceDOWN %3d\n", s-K[1], uv[s]+0, dv[s]+0 }
      printf "%d %d %d %d\n", longest_run(K,c,uv,RATE), longest_run(K,c,dv,RATE), upk+0, dpk+0 > SUM
    }' "$tmp" | tee "$tmp.tbl"

  local urun drun upk dpk
  read -r urun drun upk dpk < "$tmp.sum" 2>/dev/null
  urun=${urun:-0}; drun=${drun:-0}; upk=${upk:-0}; dpk=${dpk:-0}

  hdr "Observation (heuristic, confidence-tagged -- NOT proof)"
  info "sustained voice window  UP:${urun}s  DOWN:${drun}s    peak voice-band  UP:${upk}/s  DOWN:${dpk}/s"
  if   [ "$urun" -ge "$VRUN" ] && [ "$drun" -ge "$VRUN" ]; then
    ok "two-way voice stream observed -> media path looks healthy on this network  [MEDIUM confidence]"
  elif [ "$drun" -ge "$VRUN" ] && [ "$urun" -lt 1 ]; then
    warn "downlink sustained, uplink absent -> POSSIBLE one-way (they can't hear you)  [LOW confidence]"
  elif [ "$urun" -ge "$VRUN" ] && [ "$drun" -lt 1 ]; then
    warn "uplink sustained, downlink absent -> POSSIBLE one-way (you can't hear them)  [LOW confidence]"
  elif [ "$urun" -ge "$VRUN" ] || [ "$drun" -ge "$VRUN" ]; then
    info "one direction streamed, the other was partial -> asymmetric, inconclusive"
  else
    info "no sustained two-way voice stream in this capture -> inconclusive (short/no call?)"
  fi
  info "caveat: encrypted UDP/4500 also carries IMS signaling, keepalives, and"
  info "retransmits; 'listening only' mimics one-way. Confirm against what you heard."
  rm -f "$tmp" "$tmp.sum" "$tmp.tbl"
}
