# Case study: "sometimes I can't make calls"

A real end-to-end debug that motivated this tool. Network details are anonymized.

## Symptom

A home with **no cell coverage** — every call depends on WiFi Calling (Verizon). Data
(web, streaming) always worked; calls **intermittently** failed: no ring then straight
to voicemail, and sometimes connected with **one-way audio** (could hear them, they
couldn't hear us).

## Step 1 — recon

`wcdiag recon` mapped the path to the internet:

```
  1  192.168.x.1        (private)   inner mesh router
  2  192.168.y.1        (private)   ISP gateway
  3  100.64.x.x         (cgnat)     carrier edge
  ...
  [warn] NAT depth: 2 leading private hops -> LIKELY double NAT
```

Two leading private hops = **likely double NAT**: a mesh router in *router mode* behind
the ISP gateway. `recon` also flagged **no global IPv6** (ULA only). The pipe itself was
pristine — 0% loss to the gateway, the internet, and the carrier ePDG.

## Step 2 — the ePDG is reachable, so it's not "blocked"

`wcdiag epdg verizon` resolved Verizon's gateways (`wo.vzwwo.com`,
`sg.vzwfemto.com`) and showed UDP 500/4500 egress **open**. The first tunnel packet
could leave — reachability wasn't the problem, so the failure had to be *inside* the
tunnel's lifecycle (NAT traversal / media / roaming).

## Step 3 — monitor proves the pipe is innocent

`wcdiag monitor --carrier verizon` ran while calls were reproduced. Across hundreds of
samples spanning the failures: **zero loss** to gateway, internet, and ePDG. A clean
path during a failed call means the fault is **not** bandwidth or congestion.

## Step 4 — collapse the double NAT

The ISP gateway was put into **IP-passthrough**, removing the second NAT. `monitor`
caught the change live (the inner gateway dropped out of the path) and its
`--dnat-watch` guard confirmed single-NAT afterward. Calls improved immediately — but
were still **occasionally** flaky.

## Step 5 — capture the tunnel (the decisive step)

`sudo wcdiag capture` turned the box into an access point. The phone joined it and
placed the previously-failing call. For the first time the tunnel was visible:

```
  == Tunnel establishment ==
  [ ok ] IKE_SA_INIT (udp/500) at   14:13:49
  [ ok ] NAT-T switch (udp/4500) at 14:13:49
  [ ok ] 1 IKE handshake burst -> stable (no re-key/roaming signal)

  == Voice-stream heuristic ==
  +  1s   voiceUP  28 | voiceDOWN  50
  +  2s   voiceUP  17 | voiceDOWN  51
  [ ok ] two-way voice stream observed -> media path looks healthy  [MEDIUM confidence]
```

Through the box's **single AP**, the tunnel came up in ~2.5 s, **stayed up**, and voice
flowed **both ways** (a MEDIUM-confidence read — enough, with the "it worked" report,
to pin the residual fault on the mesh). The calls **worked**.

## Conclusion

Same phone, same carrier, same internet — **only the WiFi layer changed** (a single AP
instead of the mesh) and the calls succeeded. That isolated the residual fault to the
**mesh's roaming/steering**, tearing the tunnel mid-call, not to the carrier or the
internet.

The fixes, in order of impact:
1. **Removed the double NAT** (ISP gateway → IP-passthrough) — the primary root cause.
2. **Isolated the mesh roaming** as the residual cause via the capture-AP experiment;
   remediate on the mesh (firmware, steering settings) or keep a stable AP for the
   dead-zone.

From "randomly can't call anyone" to two named root causes — with packet-level proof.
