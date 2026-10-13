# B2 — Routed (L3 join)

## In one line
Routing **connects separate subnets while keeping them separate**: each keeps its own broadcast domain, packets cross via routers that look at the destination IP — and **both directions need a route**, because the return trip is an independent decision.

## How it actually works
- Each network is its own subnet / broadcast domain / (usually) VLAN. ARP and DHCP don't cross; IP packets do.
- Hosts send anything off-subnet to their **default gateway**. Routers forward by **longest-prefix match** ([A3](03-l3-network.md)).
- **Addresses are untouched end to end** — the server sees the client's real IP. That's the key difference from NAT ([B3](12-nat.md)).
- Every router on the path must know how to reach the destination **and** every router on the way back must know how to reach the source. Forward and return paths may even differ (*asymmetric routing*).

### Where routes come from

| Source | How | Used where |
|---|---|---|
| **Connected** | appears when you assign an address | every interface |
| **Static** | `ip route add 10.2.0.0/24 via 10.255.0.2` | small networks, defaults, cloud route tables |
| **Default** | `0.0.0.0/0 via <gateway>` | "everything else goes upstream" |
| **OSPF / IS-IS** (IGP) | routers flood link state, each computes shortest paths | inside one organisation |
| **BGP** (EGP) | routers exchange reachable prefixes + policy with neighbours | between ISPs/clouds; also inside DCs and Kubernetes (Calico, MetalLB) |
| DHCP | hands out the default gateway | hosts |

Dynamic protocols only **fill the same routing table** automatically and react to failures — the forwarding logic is identical.

### Reverse-path filtering (rp_filter)
- Anti-spoofing check on input: "would I route a reply to this **source** back out of the interface it came in on?"
- `0` off · `1` **strict** (must be the same interface) · `2` **loose** (any route to the source is enough).
- Effect: a router with **no route back** to the source drops the packet **on arrival**, silently — before forwarding it. Strict mode also breaks legitimate *asymmetric* routing (multi-homing, ECMP).

### Inter-VLAN routing
- VLANs separate broadcast domains on one switch ([A2](02-l2-data-link.md)); getting **between** them needs L3.
- **Router-on-a-stick**: one trunk to the router, a VLAN sub-interface per VLAN (`trunk.10`, `trunk.20`), each the gateway of its subnet. Frames go in tagged VLAN 10, come out tagged VLAN 20.
- **L3 switch**: the same thing in switch hardware (SVIs, `interface vlan 10`), at wire speed — the normal design in offices and DCs.

### Where routed mode shows up
| Place | |
|---|---|
| Office / campus | one subnet per floor/department/VLAN, an L3 switch routing between them |
| ISPs & the internet core | BGP between autonomous systems |
| Cloud VPCs | route tables per subnet; VPC peering / transit gateways |
| Kubernetes | node routes / BGP per pod CIDR (no NAT between pods) |
| Linux host | `ip_forward=1` + routes |
| *VM example* | not a VirtualBox checkbox — you make the host a router (host-only net + `ip_forward` + a route on the LAN router) |

## Diagram

```
        LAN-A 10.1.0.0/24                 transit 10.255.0.0/30                LAN-B 10.2.0.0/24
 a1 .10 ───────── lan .1 [ R1 ] wan .1 ═══════════════ .2 wan [ R2 ] lan .1 ───────── b1 .10
 default→.1       10.2.0.0/24 via 10.255.0.2    10.1.0.0/24 via 10.255.0.1              default→.1
                  └──── forward path ────▶                ◀──── return path ────┘
```

## What I saw in the lab

Lab: [`labs/b2-routed.sh`](../labs/b2-routed.sh) — `./labs/run.sh b2-routed`. Output: [`labs/output/b2-routed.txt`](../labs/output/b2-routed.txt).

### 1. Connected routes only
```
R1: 10.1.0.0/24 dev lan · 10.255.0.0/30 dev wan        ← nothing about 10.2.0.0/24
a1 → b1:  From 10.1.0.1 icmp_seq=1 Destination Net Unreachable
```

### 2. Route on R1 only (no way back on R2)
**2a — with rp_filter = 2 (loose, the default here):**
```
arriving at R2 (wan):  IP 10.1.0.10 > 10.2.0.10: ICMP echo request
at b1:                 (nothing)
R2 reverse-path drops: 1
```
→ R2 dropped the request **on input**: no route back to 10.1.0.10, so it looked spoofed. No ICMP error, no log by default.

**2b — rp_filter off on R2:**
```
at b1:  10.1.0.10 > 10.2.0.10: ICMP echo request          ← request delivered
        10.2.0.10 > 10.1.0.10: ICMP echo reply            ← b1 replies to its gateway
        10.2.0.1 > 10.2.0.10: ICMP net 10.1.0.10 unreachable   ← R2 can't route the reply
R2: route get 10.1.0.10 → Network unreachable
```
→ The classic **one-way** failure: from a1's side it's just 100 % loss; only a capture on the *far* side shows the request arriving.

### 3. Both directions
```
64 bytes from 10.2.0.10: ttl=62                   ← 64 − 2 routers
 1  10.1.0.1
 2  10.255.0.2
 3  10.2.0.10
```

### 4. No NAT → real client address
```
b1's server says:  you are 10.1.0.10:46338
```

### 6. Router-on-a-stick (R1's trunk, `-e`)
```
02:..:00:10 > 02:..:01:ff  802.1Q vlan 10  172.16.10.10 > 172.16.20.10: echo request   ← in on VLAN 10
02:..:01:ff > 02:..:00:20  802.1Q vlan 20  172.16.10.10 > 172.16.20.10: echo request   ← out on VLAN 20
02:..:00:20 > 02:..:01:ff  802.1Q vlan 20  172.16.20.10 > 172.16.10.10: echo reply
02:..:01:ff > 02:..:00:10  802.1Q vlan 10  172.16.20.10 > 172.16.10.10: echo reply
```
→ The same packet hairpins on one cable: arrives tagged 10, leaves tagged 20, with the router's MAC as the new source. ping reports `ttl=63` — one routed hop.

## Gotchas / things that surprised me
- **rp_filter turned my one-way failure into a silent drop *at the wrong router*.** Without knowing about it, you'd capture on R2's LAN side, see nothing, and blame R1. Check `nstat -az TcpExtIPReversePathFilter` (and `net.ipv4.conf.*.log_martians=1` to log them).
- The transit link is a **/30** — just two usable addresses, one per router. (/31 works too on Linux.)
- From the source, "no route on the far router" and "firewall DROP" look identical. The far-side capture is the only tie-breaker.
- In routed designs the **edge router** needs routes for every internal subnet *or* a summary (`10.0.0.0/8 via …`) — summarisation keeps tables small.
- Inter-VLAN traffic through a router-on-a-stick crosses the trunk **twice** — the trunk's bandwidth is shared by both directions of every inter-VLAN flow.

## Checkpoint answer
**Ping works one way but not the other — finding the missing route:**
1. Capture on the destination: does the request arrive? Does a reply leave?
   - Arrives + reply leaves → the problem is on the **return path**.
   - Doesn't arrive → forward path (or rp_filter / firewall on the way in).
2. Walk the return path hop by hop with `ip route get <source IP>` on each router (or `traceroute` *from the far side*). The first router that answers *Network unreachable* — or sends the reply somewhere unexpected — is missing the route.
3. Also check reverse-path counters (`nstat -az TcpExtIPReversePathFilter`) and `rp_filter` on routers where the forward path enters: an asymmetric or missing return route can drop the *forward* packet.
4. Fix with a specific route, a summary route, or a correct default — on the router that lacks it.

## Open questions
- Run FRR with OSPF between R1 and R2 and watch the routes appear and withdraw on link failure.
- ECMP: two equal-cost paths — how the kernel hashes flows (`fib_multipath_hash_policy`).
