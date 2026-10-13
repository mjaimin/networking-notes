# B3 — NAT (L3/L4 rewrite)

## In one line
NAT is **routing plus rewriting**: the router changes source (SNAT) or destination (DNAT) addresses and ports, and remembers each rewrite in a **connection-tracking table** so replies can be translated back.

## How it actually works

### The pieces
- **SNAT / MASQUERADE** — rewrite the **source** on the way **out**. MASQUERADE = SNAT to "whatever address the egress interface has" (good for DHCP WAN).
- **PAT / NAPT** — many inside hosts share one public IP; flows are told apart by **port**. If two inside hosts pick the same source port, the router picks a new one for the second.
- **DNAT / port-forward** — rewrite the **destination** on the way **in**: `public:8080 → 192.168.1.10:8080`.
- **conntrack** — kernel table of flows: *original tuple* ⇄ *reply tuple*. Only the **first packet** of a flow goes through the NAT rules; the rest are translated from the table.
- **1:1 NAT** — one private ↔ one public IP (cloud "elastic IP"). **CGNAT** — the ISP NATs you again (`100.64.0.0/10`), so even your router's WAN IP is private.

### Where it happens in Linux (netfilter)
```
 in ─▶ PREROUTING (DNAT) ─▶ routing decision ─▶ FORWARD (filter) ─▶ POSTROUTING (SNAT/MASQ) ─▶ out
                                   │
                                   └▶ INPUT (local process) ── OUTPUT ─▶ POSTROUTING
```
- DNAT **before** routing (so the new destination is what gets routed), SNAT **after** (so the egress interface is known).

### Why "inbound is blocked" behind NAT
Not a security feature — **an unsolicited packet has no conntrack entry to match**, so the router doesn't know which inside host it's for. It's delivered to the router itself (→ RST / dropped). Port-forwarding = adding that mapping by hand. A real firewall is still needed for IPv6 (no NAT there).

### What NAT breaks, and the workarounds

| Problem | Why | Workaround |
|---|---|---|
| Hosting a server inside | no inbound mapping | DNAT port-forward, UPnP-IGD / NAT-PMP (app asks the router) |
| Peer-to-peer (calls, games, WebRTC) | both sides behind NAT | **STUN** (learn your public ip:port), hole punching, **TURN** relay as last resort |
| Protocols with IPs in the payload (SIP, FTP active, H.323) | payload not rewritten | ALG helpers (`nf_conntrack_ftp`, `sip`), or avoid |
| Server logs / rate limits | everyone appears as one IP | `X-Forwarded-For`, PROXY protocol, IPv6 |
| Long idle connections | conntrack entries expire (TCP established 5 days on Linux, UDP 30–180 s, CGNAT much shorter) | keepalives |
| Inside host using the public address (**hairpin**) | DNAT only on WAN, asymmetric reply on LAN | hairpin NAT / split-horizon DNS |

### Where NAT shows up
| Place | Kind |
|---|---|
| Home router | MASQUERADE LAN → WAN + port-forwards |
| Mobile networks | CGNAT (often two layers of NAT) |
| Cloud | NAT gateway for private subnets; elastic IP = 1:1 NAT |
| Kubernetes | Service ClusterIP = DNAT (kube-proxy iptables/IPVS); egress SNAT to node IP |
| Docker | `docker0` bridge + MASQUERADE out; `-p 8080:80` = DNAT |
| *VM example* | VirtualBox **"NAT"**: the hypervisor is the router (`10.0.2.2` gateway, `10.0.2.15` guest), port-forwarding rules in VM settings |

## Diagram

```
 l1 192.168.1.10:40000 ─┐                                       srv 198.51.100.10:80
 l2 192.168.1.20:40000 ─┴─▶ [ gw  MASQUERADE ] ── 203.0.113.2 ──▶ sees 203.0.113.2:40000  (l1)
                                 conntrack                          sees 203.0.113.2:18956  (l2, port rewritten)
     orig: 192.168.1.20:40000 → 198.51.100.10:80
     reply: 198.51.100.10:80  → 203.0.113.2:18956     ← reply arrives here, table maps it back to l2
```

## What I saw in the lab

Lab: [`labs/b3-nat.sh`](../labs/b3-nat.sh) — `./labs/run.sh b3-nat`. Output: [`labs/output/b3-nat.txt`](../labs/output/b3-nat.txt).
Public side uses RFC 5737 documentation addresses: gw WAN `203.0.113.2`, "internet" server `198.51.100.10`.

### 1. No NAT: private address leaks out, the reply can't come back
At srv:
```
192.168.1.10 > 198.51.100.10: ICMP echo request
198.51.100.10 > 192.168.1.10: ICMP echo reply
198.51.100.1 > 198.51.100.10: ICMP net 192.168.1.10 unreachable    ← the "internet" has no route to private space
isp: route get 192.168.1.10 → Network unreachable
```
(With `rp_filter` on — the default — the ISP drops it even earlier, on input. Real ISPs filter RFC 1918 sources: BCP 38.)

### 2. MASQUERADE — same ping, both sides of gw
```
-A POSTROUTING -o wan -j MASQUERADE
LAN side: 192.168.1.10 > 198.51.100.10: echo request  |  198.51.100.10 > 192.168.1.10: echo reply
WAN side: 203.0.113.2  > 198.51.100.10: echo request  |  198.51.100.10 > 203.0.113.2:  echo reply
```

### 3. conntrack
```
icmp 1 26 src=192.168.1.10 dst=198.51.100.10 type=8 id=82    src=198.51.100.10 dst=203.0.113.2 type=0 id=82
          └──────────── original direction ────────────┘     └──────────── expected reply ────────────┘
```
(For ICMP the echo **id** plays the role of the port; `26` = seconds left.)

### 4. PAT — two hosts, same source port
```
l1: srv sees you as 203.0.113.2:40000
l2: srv sees you as 203.0.113.2:18956          ← collision → gw picked a new port
conntrack: src=192.168.1.20 sport=40000 dport=80 | src=198.51.100.10 dst=203.0.113.2 sport=80 dport=18956
           src=192.168.1.10 sport=40000 dport=80 | src=198.51.100.10 dst=203.0.113.2 sport=80 dport=40000
```

### 5–6. Inbound: refused → port-forward
```
no rule:  srv → 203.0.113.2:8080 → Connection refused      ← gw itself answered RST; l1 never saw it
-A PREROUTING -i wan -p tcp --dport 8080 -j DNAT --to-destination 192.168.1.10:8080
with rule: srv → "l1 web server - you are 198.51.100.10"   ← DNAT keeps the real client source
conntrack: src=198.51.100.10 dst=203.0.113.2 dport=8080 | src=192.168.1.10 dst=198.51.100.10 sport=8080
```

### 7. Hairpin — an inside host uses the public address
```
7.  no LAN DNAT:  l2 → 203.0.113.2:8080 → Connection refused            (gw's own port 8080 is closed)
7a. DNAT on LAN:  l2 → … → Operation timed out
    what l2 saw:  192.168.1.20 > 203.0.113.2.8080: [S]
                  192.168.1.10.8080 > 192.168.1.20: [S.]          ← reply from an address l2 never called
                  192.168.1.20 > 192.168.1.10.8080: [R]           ← l2 rejects it
7b. + SNAT on LAN: l2 → "l1 web server - you are 192.168.1.1"     ← works; l1 now sees gw as the client
```
→ After DNAT, l1 saw a SYN **from 192.168.1.20** (same subnet) and replied **directly** over the switch, bypassing gw — so the reply was never un-NATed. SNAT forces the reply back through gw.

## Gotchas / things that surprised me
- `-o wan` matters: without it, MASQUERADE would also rewrite LAN-to-LAN traffic.
- **NAT rules only see the first packet** of a flow — changing a rule doesn't affect existing flows until their conntrack entry expires (`conntrack -F` to flush).
- Port-forwarding preserves the **client** IP (DNAT only); hairpin NAT destroys it (SNAT added) — logs inside show the router.
- PAT keeps the original source port **when it can** — that's what makes "port-preserving" NAT friendly to P2P.
- `ttl=62` on the NATed ping: NAT doesn't hide hop count.
- In Docker, `-p 8080:80` is exactly section 6 on your laptop, and "container can't reach the host's published port via the host's LAN IP" is section 7.

## Checkpoint answer
**Same flow before and after NAT — which fields changed?** (l2 → srv:80, outbound)

| Field | LAN side (before) | WAN side (after) |
|---|---|---|
| src IP | 192.168.1.20 | **203.0.113.2** |
| src port | 40000 | **18956** (collision) / unchanged otherwise |
| dst IP / port | 198.51.100.10:80 | same |
| src/dst MAC | l2 → gw(lan) | gw(wan) → isp — as for any routed hop |
| TTL | 64 | 63 |
| IP + TCP checksums | — | recomputed (they cover the addresses) |
| payload | — | unchanged |

Replies get the exact inverse, driven by the conntrack entry.

## Open questions
- Full-cone vs symmetric NAT: why STUN works through one and not the other (Linux MASQUERADE is endpoint-dependent → mostly "symmetric-ish"; `--random-fully` makes it fully random).
- nftables equivalents (`nft add rule ip nat postrouting oifname "wan" masquerade`).
