# Methodology

How `wcdiag` reasons about a failing WiFi call, and what each tool actually measures.

## The model

With no cell signal, a call cannot use the cellular voice network. The phone falls
back to **WiFi Calling (VoWiFi)**:

```
 iPhone/Android  ──IKEv2/IPsec tunnel──►  carrier ePDG  ──►  IMS core  ──►  callee
   (UDP 500 sets up the tunnel; UDP 4500 carries it once NAT is detected)
```

- **UDP 500 (IKE)** negotiates the security association.
- **UDP 4500 (IPsec NAT-T)** carries the encrypted tunnel once a NAT is on the path.
- Inside the tunnel: **SIP/IMS** signaling (call setup, ringing) and **RTP** (voice).

Because the whole call is one UDP flow to one gateway, it is fragile in ways ordinary
web traffic is not: it needs a **stable path**, **clean NAT traversal**, and an
**uninterrupted association** for its entire duration.

## The four failure modes and their signatures

### 1. Double NAT
Two routers in series (e.g. a mesh router in *router* mode behind the ISP gateway),
each performing NAT. IPsec NAT-traversal assumes one translation; two mangle the port
mappings and the media path. Symptom: intermittent setup failures, one-way audio,
straight-to-voicemail.

**Detected by:** `wcdiag recon` walks the path to the internet and counts private
(RFC1918) hops before the first public address. **Two or more private hops ⇒ double
NAT.** Fix: collapse to a single NAT (put the ISP gateway in IP-passthrough/bridge, or
bridge the inner router).

### 2. Mesh roaming
A multi-node mesh steers the client between access points (or bands) mid-call. Each
handoff can drop the tunnel, forcing a re-handshake — or just losing enough packets to
kill the call.

**Detected by:** `wcdiag capture` + `analyze`. On a single AP the tunnel handshakes
once and stays up. Repeated **UDP 500 exchanges after setup** indicate the tunnel was
re-established mid-call — a roaming fingerprint.

### 3. Broken or absent IPv6
Some carriers prefer IPv6 for the ePDG. A network that advertises IPv6 but can't route
it (or provides only ULA/link-local) can cause "happy-eyeballs" stalls and registration
failures.

**Detected by:** `wcdiag recon` checks for a **global** IPv6 address *and* actual
internet reachability over v6, and warns on the half-broken case.

### 4. Media-plane NAT failure
The tunnel and signaling come up (the call "connects"), but RTP can't traverse the NAT
in one or both directions. Symptom: connected call with **one-way audio**, or ringing
that dumps to voicemail with no media.

**Detected by:** `wcdiag analyze` measures **uplink vs downlink** packet rates inside
the tunnel. A live voice stream is ~50 packets/sec (20 ms frames). Downlink streaming
while uplink is silent ⇒ your voice isn't traversing (they can't hear you), and vice
versa.

## Why a wired box can't see everything — and the fix

A monitor running on a **wired** host measures the *shared* path (gateway, ISP, ePDG)
perfectly, which is exactly why it often reports "clean" while calls fail: the fault is
in the **phone's WiFi/tunnel**, which never touches the wired host on a switched LAN.

The resolution is `wcdiag capture`: the box becomes the phone's **access point**, so the
phone's real tunnel traverses it and can be captured. This also yields a clean
controlled experiment — *same phone, same carrier, same internet, different WiFi layer*:

- Works on the box's single AP but fails on the mesh ⇒ the **WiFi/mesh layer** is at
  fault (roaming/steering), not the carrier or the internet.
- Fails on both ⇒ look upstream (NAT depth, carrier-side, the other endpoint).

## Reading a `monitor` correlation

Leave `wcdiag monitor` running, reproduce a failed call, note the time, and inspect the
CSV around that timestamp:

- **Loss/latency spiked at the failure** → transient RF/WAN congestion.
- **Path stayed clean through the failure** → the pipe is innocent; the tunnel,
  registration, or WiFi layer is the culprit → go to `capture`.
