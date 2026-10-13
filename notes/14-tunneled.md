# B5 — Tunneled (bonus)

## In one line
A tunnel **wraps a whole packet (or frame) inside another packet** so it can cross a network that wouldn't carry it — two private sites over the internet, or one L2 segment across many L3 hops — at the cost of extra headers (MTU) and, unless encrypted, zero privacy.

## How it actually works

```
original:              [ inner IP 10.1.0.10 → 10.2.0.10 | ICMP/TCP… ]
GRE (L3 in L3):  [outer IP 203.0.113.2 → 198.51.100.2 | GRE 4 B | inner IP … ]          +24 B
VXLAN (L2 in UDP): [outer IP | UDP → 4789 | VXLAN 8 B (VNI) | inner Ethernet 14 B | inner IP … ]  +50 B
WireGuard:       [outer IP | UDP 51820 | WG hdr | **encrypted** inner IP … | auth tag ]  +60 B (v4)
```

- The **underlay** (internet, DC fabric) routes only the outer header — it never looks inside.
- The **overlay** (inner addresses) is invisible to the underlay: private ranges, overlapping ranges, even non-IP traffic can ride along.
- Tunnel endpoints act like routers (L3 tunnels) or switches (L2 tunnels) for the overlay.

### Common tunnels

| Tunnel | Carries | Encapsulation | Encrypted | Typical use |
|---|---|---|---|---|
| **IPIP** | IPv4 | IP proto 4, +20 B | ❌ | simplest L3 tunnel, Calico (IPIP mode) |
| **GRE** | any L3 (and L2 with `gretap`) | IP proto 47, +24 B | ❌ | site-to-site under IPsec, router-to-router |
| **VXLAN** | **Ethernet frames** | UDP 4789, +50 B; 24-bit **VNI** = 16 M segments | ❌ | DC overlays, EVPN, Kubernetes (Flannel, Cilium), VMware NSX |
| **Geneve** | Ethernet + extensible options | UDP 6081 | ❌ | OVN, AWS GWLB, newer SDN |
| **IPsec (ESP)** | L3 | IP proto 50 (or UDP 4500 behind NAT) | ✅ | site-to-site VPN, cloud VPN gateways |
| **WireGuard** | L3 | UDP, +60 B | ✅ | modern VPN (Tailscale, cloud VPNs) |
| **OpenVPN / SSL VPN** | L3 (tun) or L2 (tap) | UDP/TCP 1194/443 | ✅ | remote access |
| **PPPoE** | PPP over Ethernet | +8 B (MTU 1492) | ❌ | DSL/fibre ISP access links |

### MTU — the price of every tunnel
- Outer packet must fit the underlay MTU (1500) → **inner MTU = 1500 − overhead** (GRE 1476, VXLAN 1450, WireGuard 1420, PPPoE 1492).
- If the inner sender doesn't know: packets with DF get *Frag needed* from the tunnel router (PMTUD) — works only if ICMP gets back.
- **MSS clamping**: the tunnel router rewrites the MSS option in passing SYNs to fit the tunnel (`iptables … -j TCPMSS --clamp-mss-to-pmtu`) so TCP never sends oversized segments at all — robust even when ICMP is filtered. Standard on every VPN and PPPoE router.

### L2 vs L3 tunnels
- **L3 tunnel (GRE, IPsec, WireGuard)** = a routed link. Each site keeps its own subnet; routes point into the tunnel ([B2](11-routed.md)).
- **L2 tunnel (VXLAN, gretap)** = a long virtual cable into a bridge. Both sites share **one subnet and one broadcast domain** ([B1](10-bridged.md)) — great for VM mobility, but every ARP/broadcast/flood crosses the WAN and a loop or storm spans every site.

## Diagram

```
 site A                         "the internet" (routes 203.0.113/24, 198.51.100/24 only)            site B
 a1 10.1.0.10 ─ gwA ════════════ [outer 203.0.113.2 → 198.51.100.2 | GRE | inner 10.1→10.2] ════ gwB ─ b1 10.2.0.10
                gre1 169.254.0.1 ◀──────────────── one logical hop ─────────────────▶ 169.254.0.2

 VXLAN VNI 42:  xA 10.9.0.1 ─ br42 ─ vx42 ═══ UDP 4789 ═══ vx42 ─ br42 ─ xB 10.9.0.2   (same /24, same L2)
```

## What I saw in the lab

Lab: [`labs/b5-tunneled.sh`](../labs/b5-tunneled.sh) — `./labs/run.sh b5-tunneled`. Output: [`labs/output/b5-tunneled.txt`](../labs/output/b5-tunneled.txt).

### Without a tunnel
```
a1 → 10.2.0.10: 100% packet loss            ← "the internet" has no route to 10.x
```

### GRE — what an ISP sees on the wire
```
IP (ttl 64, proto GRE (47), length 108)  203.0.113.2 > 198.51.100.2: GREv0, length 88
    IP (ttl 63, proto ICMP (1), length 84)  10.1.0.10 > 10.2.0.10: ICMP echo request    ← inner packet, in clear
```
- Outer 108 = 20 (outer IP) + 4 (GRE) + 84 (inner packet). Interface MTU: `gre1 … mtu 1476`.
- Inner TTL already 63 (gwA routed it into the tunnel); outer TTL is the tunnel's own.

```
traceroute a1 → b1:   1  10.1.0.1    2  169.254.0.2    3  10.2.0.10
```
→ The internet router in the middle is **invisible** — the whole underlay is one hop.

### MTU and PMTUD
```
ping -M do -s 1472 → From 10.1.0.1 Frag needed and DF set (mtu = 1476)
ping -M do -s 1448 → 1456 bytes from 10.2.0.10                       (1448 + 28 = 1476)
a1 route cache:      cache expires 599sec mtu 1476
```

### MSS clamping (route cache flushed before each test)
```
SYN mss arriving at b1, no clamping:   mss 1460     ← would produce 1500 B packets → too big for gre1
SYN mss arriving at b1, with clamping: mss 1436     ← 1476 − 20 − 20, rewritten by gwA in flight
```

### VXLAN — one L2 segment across both sites
```
vx42 … mtu 1450
outer: 203.0.113.2.39536 > 198.51.100.2.4789: VXLAN, flags [I], vni 42
inner: 02:00:00:00:9a:01 > ff:ff:ff:ff:ff:ff, ARP, Request who-has 10.9.0.2 tell 10.9.0.1     ← a broadcast crossed the WAN
outer: 198.51.100.2 > 203.0.113.2.4789: VXLAN, vni 42
inner: 02:00:00:00:9b:01 > 02:00:00:00:9a:01, ARP, Reply 10.9.0.2 is-at 02:00:00:00:9b:01
outer: … length 148 … vni 42 │ inner: 10.9.0.1 > 10.9.0.2: ICMP echo request, length 98
```
```
xA ip neigh:        10.9.0.2 dev eth0 lladdr 02:00:00:00:9b:01 REACHABLE      ← remote host's MAC, directly
gwA vx42 FDB:       02:00:00:00:9b:01 dst 198.51.100.2 self                    ← MAC → remote VTEP (learned)
                    00:00:00:00:00:00 dst 198.51.100.2 self permanent          ← default flood target (BUM traffic)
```
→ The ping TTL stayed **64**: no router between xA and xB as far as they can tell. Outer frame 148 = 14 + 20 + 8 + 8 + 98 (inner frame).

## Gotchas / things that surprised me
- **GRE and VXLAN are cleartext.** The capture shows inner addresses and payload. For the internet, run them inside IPsec or use WireGuard.
- Linux `ip link set a up` parses `a` as `address`! — don't name interfaces `a`, `b`, `br`… (cost me a lab run).
- A VXLAN device created without an underlay `dev` **keeps MTU 1500** → silent drops of full-size frames. Set 1450 (or raise the underlay MTU to 1550+; DC fabrics run 9000).
- PMTUD worked here because ICMP got through; MSS clamping is the belt-and-braces fix that doesn't depend on it.
- VXLAN's `00:00:00:00:00:00` FDB entry is the **flood list** — where broadcasts/unknown-unicast go. In big deployments that's replaced by multicast or an EVPN (BGP) control plane.

## Checkpoint answer
**Outer vs inner headers:**
- *Outer* (what the underlay routes): public src/dst IPs of the tunnel endpoints, protocol 47 (GRE) or UDP 4789 (VXLAN), their own TTL.
- *Inner* (what the sites see): private addresses 10.1.0.10 → 10.2.0.10 (GRE) or a full Ethernet frame with the hosts' MACs (VXLAN).
- *Cost*: 24 B (GRE) / 50 B (VXLAN) per packet → inner MTU 1476 / 1450, handled by PMTUD or MSS clamping (1460 → 1436).

## Open questions
- WireGuard lab (needs `wireguard-tools` for keys): capture would show UDP with an opaque payload — same shape as GRE, nothing readable inside.
- IPsec NAT-traversal: why ESP gets wrapped in UDP 4500 when a NAT is on the path ([B3](12-nat.md)).
