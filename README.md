# WifiCallingDiagnosticNode

**Turn a spare Linux box into an instrument that finds why WiFi calls fail.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Linux-blue.svg)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey.svg)

When you have no cell signal, every call rides **WiFi Calling (VoWiFi)** — an
encrypted IPsec tunnel from your phone to your carrier's gateway (the *ePDG*) over
UDP 500/4500. When calls fail but web/streaming is fine, the tunnel is being broken
by something between your phone and the carrier: **double NAT**, a **mesh roaming**
event, broken **IPv6**, or a media path that can't traverse your NAT.

The hard part is *seeing* it. A phone tells you nothing, and a normal speed test says
"internet's fine." `wcdiag` uses a Linux box on the same network to map the path,
probe the carrier gateway, watch the call path second-by-second, and — its signature
trick — **become a WiFi access point so your phone's actual call tunnel flows through
it, where it can be captured and read packet-by-packet.**

---

## What it does

| Command | What you get |
|---|---|
| `wcdiag recon` | Interfaces, gateway, **NAT depth (flags double NAT)**, ISP/public IP, IPv6 reachability, DNS |
| `wcdiag epdg <carrier>` | Resolves the carrier ePDG (Verizon / AT&T / T-Mobile) and probes UDP 500/4500 egress |
| `wcdiag monitor` | 1/sec latency + loss log of the call path; reproduce a failed call and correlate |
| `wcdiag capture` | Stands up a WiFi AP + captures the phone's real IPsec tunnel |
| `wcdiag analyze <file>` | Reads a capture: tunnel setup, roaming re-handshakes, **one-way-audio verdict** |
| `wcdiag doctor` | Runs recon + ePDG + a short monitor, then a plain-english verdict |

---

## Quick start

```bash
git clone https://github.com/CustomerNode/WifiCallingDiagnosticNode
cd WifiCallingDiagnosticNode
./wcdiag doctor
```

Reproduce a failed call while the path monitor runs:

```bash
./wcdiag monitor --carrier verizon
#   ... place the call that fails, note the time, Ctrl-C ...
#   a clean path during the failure == the fault is the tunnel/WiFi, not the pipe
```

See the tunnel itself (the decisive test):

```bash
sudo ./wcdiag capture
#   join the phone to the printed SSID, wait for "WiFi Calling", place the call
#   Ctrl-C, then:
./wcdiag analyze ./wcdiag-capture/tunnel.log
```

Install it on `PATH` (optional):

```bash
sudo ln -s "$PWD/wcdiag" /usr/local/bin/wcdiag
```

---

## Requirements

- **Linux** with `bash`, `iproute2` (`ip`), `ping`, `dig`, `nc`, `awk`
- `traceroute` **or** `tracepath` for NAT-depth analysis
- For `capture`: **root** (or `sudo`), `nmcli` (NetworkManager), `tcpdump`, and a
  WiFi adapter that supports **AP mode** — ideally a *second* NIC so your wired
  uplink stays untouched. Check with:
  ```bash
  nmcli -f WIFI-PROPERTIES.AP dev show <wifi-iface>
  ```

Install deps on Debian/Ubuntu/Mint:

```bash
sudo apt install -y iproute2 iputils-ping dnsutils netcat-openbsd \
                    traceroute tcpdump network-manager gawk
```

---

## How it works

WiFi Calling establishes an **IKEv2/IPsec** tunnel to the carrier's **ePDG** and
carries SIP/IMS signaling and RTP voice inside it. Four things commonly break it,
each with a distinct signature `wcdiag` looks for:

1. **Double NAT** — two routers each NAT the tunnel; NAT-traversal mangles, media
   fails. `recon` counts private hops on the path to the internet.
2. **Mesh roaming** — the phone is steered between mesh nodes mid-call and the tunnel
   is torn down. `capture` + `analyze` catch the re-handshake.
3. **Broken/absent IPv6** — some carriers prefer IPv6; a half-broken v6 stalls setup.
   `recon` checks global v6 reachability.
4. **Media-plane NAT failure** — signaling connects but RTP can't traverse the NAT →
   one-way audio / straight-to-voicemail. `analyze` measures uplink vs downlink
   voice packet rates.

Full write-up: **[docs/METHODOLOGY.md](docs/METHODOLOGY.md)**.
A real end-to-end debug: **[docs/CASE-STUDY.md](docs/CASE-STUDY.md)**.

---

## Privacy & safety

- Captures and logs contain your **public IP, device MACs, and traffic metadata**.
  They are git-ignored by default — **don't commit them**.
- `wcdiag` only reads network state and, for `capture`, creates a temporary NAT'd
  hotspot on a spare radio; it tears the hotspot down on exit and never touches your
  default-route interface.
- It captures only **UDP 500/4500** (the tunnel envelope). The tunnel payload is
  encrypted; `wcdiag` reads packet **direction, size, and timing**, not call content.

---

## License

MIT © CustomerNode — see [LICENSE](LICENSE).
