# A3 — L3 Network

## In one line
L3 gets a packet **from one host to another across networks**: each router looks up the destination IP (longest prefix wins), decrements TTL, and re-frames it for the next link — the IPs themselves stay the same end-to-end.

## How it actually works

### IPv4 header — the fields that matter

| Field | Why you care |
|---|---|
| Version / IHL | `0x45` = v4, 20 B header |
| Total length | header + payload; ≤ MTU unless fragmented |
| Identification / Flags / Fragment offset | fragmentation; **DF** (don't fragment) is set by Linux for TCP and ping → Path MTU Discovery |
| **TTL** | −1 per router; 0 → dropped + ICMP *Time Exceeded*. Linux starts at 64, Windows 128, many routers 255 |
| **Protocol** | 6 TCP, 17 UDP, 1 ICMP, 47 GRE, 50 ESP |
| Header checksum | recomputed every hop (because TTL changed) |
| **Src / Dst IP** | end-to-end — only NAT rewrites them |

### CIDR & subnetting

| Prefix | Mask | Addresses | Usable hosts |
|---|---|---|---|
| /8 | 255.0.0.0 | 16 777 216 | 16 777 214 |
| /16 | 255.255.0.0 | 65 536 | 65 534 |
| /24 | 255.255.255.0 | 256 | 254 |
| /25 | 255.255.255.128 | 128 | 126 |
| /26 | …192 | 64 | 62 |
| /27 | …224 | 32 | 30 |
| /28 | …240 | 16 | 14 |
| /30 | …252 | 4 | 2 (classic point-to-point) |
| /31 | …254 | 2 | 2 (RFC 3021 point-to-point, no network/broadcast) |
| /32 | …255 | 1 | a single host route |

- Hosts = 2^(32−prefix) − 2 (network + broadcast addresses).
- `10.0.1.10/24` → network `10.0.1.0`, broadcast `10.0.1.255`.
- A host decides "local or remote?" by masking: `dst & mask == my_net & mask` → ARP for dst directly; else → send to **gateway**.

Special ranges worth recognising:

| Range | Meaning |
|---|---|
| `10/8`, `172.16/12`, `192.168/16` | RFC 1918 private |
| `100.64/10` | CGNAT shared space (ISP-side NAT) |
| `127/8` | loopback |
| `169.254/16` | link-local (no DHCP answer → self-assigned) |
| `224/4` | multicast |
| `0.0.0.0/0` | "everything" = default route |

### Routing table & longest-prefix match
- Every host and router has one (`ip route`). Each entry: *prefix → next hop (via) / interface (dev)*.
- For each packet, the **most specific matching prefix wins** (`/32` beats `/24` beats `/0`).
- `default` (`0.0.0.0/0`) matches everything — used only when nothing more specific does.
- Connected routes (`proto kernel scope link`) appear automatically when you assign an address.
- Static routes are typed by hand; dynamic ones come from **OSPF** (inside an org) or **BGP** (between ISPs/clouds). Same table either way.
- Special targets: `blackhole` (silently drop), `unreachable` (drop + ICMP), `prohibit`.

### What a router does per packet
1. Receive frame addressed to **its own MAC** → strip L2.
2. Check dst IP — for me? no → **forward** (only if `ip_forward=1`; otherwise drop).
3. Longest-prefix lookup → next hop + egress interface.
4. TTL −1 (0 → drop, send ICMP Time Exceeded to src). Recompute checksum.
5. Packet bigger than egress MTU? DF set → drop + ICMP *Frag Needed (mtu N)*; DF clear → fragment.
6. ARP for the **next hop's** MAC, build a new frame, send.

### ICMP — L3's error & diagnostics channel

| Type | Message | Seen when |
|---|---|---|
| 0 / 8 | Echo reply / request | `ping` |
| 3 | Destination unreachable — code 0 *net*, 1 *host*, 3 *port*, 4 *frag needed* | no route, ARP fails at last hop, closed UDP port, PMTUD |
| 11 | Time exceeded | TTL hit 0 → `traceroute` |
| 5 | Redirect | router tells you a better gateway exists on your subnet |

- **traceroute** sends probes with TTL 1, 2, 3 … each router that drops one replies *Time Exceeded* from **its own address** → you learn the path hop by hop.
- **Path MTU Discovery** relies on ICMP *Frag Needed* getting back. Firewalls that drop all ICMP cause the classic **PMTU black hole**: small requests work, large responses hang.

### IPv6 essentials (just enough)
- 128-bit, written in hex groups; `::` compresses zeros. Header is fixed 40 B, no checksum, **no fragmentation by routers** (only the source fragments → PMTUD is mandatory).
- Every interface has a **link-local** `fe80::/64` address, always.
- **NDP** (ICMPv6) replaces ARP: neighbor solicitation goes to a *solicited-node multicast* group, not broadcast.
- **SLAAC**: hosts build their own address from the router's advertised /64 prefix (+ random or EUI-64 interface ID). DHCPv6 optional.
- No NAT needed in principle — every device can have a global address; a stateful firewall provides the "nothing comes in" behaviour instead.

## Diagram

```
   A 10.0.1.10/24 ───────────── R ───────────── C 10.0.2.10/24
   02:..:0a:00        eth0 02:..:01:01   eth1 02:..:01:02       02:..:0c:00
                      10.0.1.1           10.0.2.1

   link 1:  L2  02:..:0a:00 → 02:..:01:01   L3 10.0.1.10 → 10.0.2.10  TTL 64
   link 2:  L2  02:..:01:02 → 02:..:0c:00   L3 10.0.1.10 → 10.0.2.10  TTL 63
            └─ rewritten every hop ─┘        └─ untouched ─┘          └─ −1 ─┘
```

## What I saw in the lab

Lab: [`labs/a3-l3.sh`](../labs/a3-l3.sh) — `./labs/run.sh a3-l3`. Output: [`labs/output/a3-l3.txt`](../labs/output/a3-l3.txt).

### Routing tables
```
A:  default via 10.0.1.1 dev eth0
    10.0.1.0/24 dev eth0 proto kernel scope link src 10.0.1.10
R:  10.0.1.0/24 dev eth0 proto kernel scope link src 10.0.1.1
    10.0.2.0/24 dev eth1 proto kernel scope link src 10.0.2.1     ← R needs only connected routes
```

### One ping, two links
```
R eth0 (A side): 02:..:0a:00 > 02:..:01:01  (ttl 64, id 2680, DF)  10.0.1.10 > 10.0.2.10: echo request
R eth1 (C side): 02:..:01:02 > 02:..:0c:00  (ttl 63, id 2680, DF)  10.0.1.10 > 10.0.2.10: echo request
```
→ **Same packet** (same IP `id 2680`), **different frame** on each link, TTL 64 → 63. The `ping` output says `ttl=63` for the reply — one router in the path.

```
A ip neigh:  10.0.1.1 dev eth0 lladdr 02:00:00:00:01:01 REACHABLE      ← only the gateway, never C
```

### traceroute & TTL expiry
```
 1  10.0.1.1   0.004 ms
 2  10.0.2.10  0.001 ms
```
With `ping -t1` (TTL 1):
```
A → R:  (ttl 1)  10.0.1.10 > 10.0.2.10: ICMP echo request
R → A:  10.0.1.1 > 10.0.1.10: ICMP time exceeded in-transit
        (tos 0x0, ttl 1, ...) 10.0.1.10 > 10.0.2.10: ICMP echo request    ← the original header, quoted inside
```
→ ICMP errors **carry the offending packet's header** — that's how the sender matches the error to the probe.

### Failure modes
| Experiment | Result |
|---|---|
| A → `10.0.9.9` (R has no route) | `From 10.0.1.1 Destination Net Unreachable` |
| `/32 blackhole` for 10.0.2.10 on A | `route get` → blackhole wins over default; `10.0.2.11` still goes via 10.0.1.1 (LPM) |
| delete C's default route | request **arrives at C** (captured), no reply — C has no route back. Silent 100 % loss |
| `ip_forward=0` on R | 100 % loss, no ICMP — R just drops |
| R↔C MTU 1400, `ping -M do -s 1472` | `From 10.0.1.1 Frag needed and DF set (mtu = 1400)`; A caches `mtu 1400` for 10.0.2.10 for 600 s |

## Gotchas / things that surprised me
- **A router doesn't need a default route to route** — connected routes were enough for R. But anything outside them → *Net Unreachable*.
- **Return path is a separate decision.** Breaking C's route back looked exactly like a firewall drop from A's side — that's why "ping works one way" debugging needs a capture on *both* ends.
- ICMP replies come from the **router's** IP, not the destination — "From 10.0.1.1 …" tells you *where* it broke.
- Router-generated ICMP has `tos 0xc0` (network control priority).
- The PMTU is **cached per destination** (`ip route get` shows `cache expires … mtu 1400`) — once learned, the host sends smaller packets automatically.
- Ping's `-s 1472` + 8 (ICMP) + 20 (IP) = 1500: the standard way to probe an exact MTU.

## Checkpoint answer
**A pings C on another subnet — MACs and IPs on each link:**

| Link | src MAC → dst MAC | src IP → dst IP | TTL |
|---|---|---|---|
| A → R | A → R(eth0) | 10.0.1.10 → 10.0.2.10 | 64 |
| R → C | R(eth1) → C | 10.0.1.10 → 10.0.2.10 | 63 |
| C → R | C → R(eth1) | 10.0.2.10 → 10.0.1.10 | 64 |
| R → A | R(eth0) → A | 10.0.2.10 → 10.0.1.10 | 63 |

(Plus ARP on each link if caches are cold: A ARPs for **10.0.1.1**, R ARPs for 10.0.2.10, C ARPs for **10.0.2.1**.)

## Open questions
- How does R choose the source IP of its ICMP errors when it has several interfaces? (Lab: the ingress interface's address.)
- Policy routing (`ip rule`) — choosing a table by source address, used for multi-WAN. Later.
