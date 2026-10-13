# Learning Plan — Layers & Connection Modes

Goal: be able to look at any network setup and say **which layer each device works at**, **which connection mode joins each segment**, and **prove it with a packet capture**.

Method per module: **read → lab → capture → write note in my own words → answer checkpoint**.
Labs use Linux network namespaces (`ip netns`) — real kernel networking, no VMs needed. VM/Docker examples appear only as "seen in the wild".

## At a glance

**Part A — Layers (bottom-up)**

| # | Module | Key lab |
|---|---|---|
| A0 | OSI vs TCP/IP, encapsulation | Label every header field in a `tcpdump -e` capture |
| A1 | L1 Physical | `ethtool`, link error counters |
| A2 | L2 — frames, switching, ARP, VLAN, STP | Two namespaces + veth, watch ARP on the wire |
| A3 | L3 — IP, subnetting, routing, ICMP, IPv6 basics | Router namespace, break the return route |
| A4 | L4 — TCP states/handshake, UDP, QUIC | "Refused" vs "timed out" in a capture |
| A5 | L7 — DNS, HTTP, TLS, L4 vs L7 LB | Trace one `curl https://` from DNS to HTTP |

**Part B — Connection modes (built on A)**

| # | Mode | Key lab |
|---|---|---|
| B1 | Bridged | Linux bridge with 3 namespaces, watch FDB learn |
| B2 | Routed | Two subnets + router, induce one-way failure |
| B3 | NAT | MASQUERADE + port-forward, inspect `conntrack -L` |
| B4 | Isolated | Gateway-less segment, prove no egress |
| B5 | Tunneled (bonus) | WireGuard/GRE, outer vs inner headers |

**Capstone:** map my own home network end-to-end — every device's layer, every segment's mode, where NAT happens.

---

## Part A — Layers (bottom-up)

### A0. The models
- OSI (7) vs TCP/IP (4/5); why L5/L6 collapse into L7
- PDUs: bits → frame → packet → segment/datagram → message
- Encapsulation / decapsulation; which headers change per hop
- **Lab:** `tcpdump -i any -e -n -c 5` while running `curl`; label every field per layer
- **Checkpoint:** Draw the header stack of one HTTPS packet from memory.
- **Note:** `notes/00-models-and-encapsulation.md`

### A1. L1 — Physical
- Link, speed, duplex, autoneg; copper vs fiber vs radio; hub vs switch
- **Lab:** `ethtool <iface>`, `ip -s link` (errors/drops counters)
- **Checkpoint:** A link shows "up" but throughput is terrible — what L1 things do you check?
- **Note:** `notes/01-l1-physical.md`

### A2. L2 — Data Link
- Ethernet frame format, MAC (unicast/broadcast/multicast), FCS, MTU
- Switching: MAC learning, FDB/CAM table, flooding
- Broadcast domain vs collision domain
- ARP: request/reply, ARP cache, gratuitous ARP
- VLANs (802.1Q), access vs trunk ports
- STP — why loops kill L2
- **Lab:** two namespaces + veth pair; `ping`; watch ARP in `tcpdump -e`; `ip neigh`; flush and repeat
- **Checkpoint:** Host A pings B on the same subnet — list every frame on the wire, in order.
- **Note:** `notes/02-l2-data-link.md`

### A3. L3 — Network
- IPv4 header (TTL, protocol, fragmentation), CIDR & subnetting
- Routing table, longest-prefix match, default gateway
- ICMP: ping, traceroute (how TTL makes it work), "unreachable"
- IPv6 essentials (NDP replaces ARP, link-local, SLAAC)
- **Lab:** three namespaces, middle one routes (`sysctl net.ipv4.ip_forward=1`); break the return route and observe
- **Checkpoint:** A pings C on another subnet — which MACs and IPs appear on each link?
- **Note:** `notes/03-l3-network.md`

### A4. L4 — Transport
- Ports, sockets, ephemeral ports
- TCP: 3-way handshake, seq/ack, windows, retransmission, FIN/RST, states (`TIME_WAIT`…)
- UDP: when and why; QUIC as UDP + reliability + TLS
- **Lab:** `ss -tan` while connecting; capture a handshake + teardown; `nc` a closed port → RST
- **Checkpoint:** "Connection refused" vs "connection timed out" — which layer, what packets?
- **Note:** `notes/04-l4-transport.md`

### A5. L7 — Application (+ the fuzzy middle)
- DNS resolution path; HTTP/1.1 vs 2 vs 3
- TLS handshake: where it sits, what it hides from the network
- L4 vs L7 load balancers / proxies
- **Lab:** `dig +trace`, `curl -v`, `openssl s_client`; capture DNS + TLS ClientHello (SNI)
- **Checkpoint:** Trace one `curl https://example.com` end-to-end: DNS → ARP → TCP → TLS → HTTP.
- **Note:** `notes/05-l7-application.md`

---

## Part B — Connection modes (built on Part A)

### B1. Bridged (L2 join)
- Bridge = software switch; one broadcast domain, one subnet
- Linux bridge (`br0`), veth, `bridge fdb`; Wi-Fi AP as a bridge
- **Lab:** 3 namespaces on one Linux bridge; watch FDB learn; DHCP/ARP reach all
- **Seen in the wild:** home switch/AP, VirtualBox "Bridged", Docker `docker0`
- **Checkpoint:** Why does adding hosts to a bridge eventually hurt? What does STP prevent?
- **Note:** `notes/10-bridged.md`

### B2. Routed (L3 join)
- Separate subnets, routes on both sides, static vs dynamic (OSPF/BGP — concept only)
- Inter-VLAN routing, L3 switch
- **Lab:** two bridges (two subnets) joined by a router namespace; remove one route → asymmetric failure
- **Seen in the wild:** office subnets, ISP peering
- **Checkpoint:** Ping works one way but not the other — how do you find which route is missing?
- **Note:** `notes/11-routed.md`

### B3. NAT (L3/L4 rewrite)
- SNAT/masquerade, PAT, DNAT/port-forward, 1:1 NAT, CGNAT
- conntrack table; why inbound is blocked by default
- What NAT breaks (P2P, SIP, FTP active) and workarounds (STUN/TURN, UPnP, ALG)
- **Lab:** router namespace with `iptables -t nat -A POSTROUTING -j MASQUERADE`; inspect `conntrack -L`; add a DNAT port-forward
- **Seen in the wild:** home router, VirtualBox "NAT", Docker port publishing (`-p 8080:80`)
- **Checkpoint:** Capture the same flow before and after NAT — which fields changed?
- **Note:** `notes/12-nat.md`

### B4. Isolated
- No gateway; L2-only segments; air-gapped / OT networks
- **Lab:** namespace on a bridge with no route out — prove it with ping + `ip route`
- **Seen in the wild:** VirtualBox host-only / internal, lab networks
- **Note:** `notes/13-isolated.md`

### B5. Tunneled (bonus)
- Overlay idea: encapsulate L2/L3 inside L3/L4 (GRE, VXLAN, WireGuard/VPN)
- MTU impact of extra headers
- **Lab:** WireGuard or GRE between two namespaces; capture outer vs inner headers
- **Note:** `notes/14-tunneled.md`

---

## Capstone
Diagram my **own home network** end-to-end (and optionally one work gateway setup):
every device → its layer → every segment's connection mode → where NAT happens → how a packet from my laptop reaches the internet and back.
**Note:** `notes/99-capstone-my-network.md`

---

## Note template (each `notes/*.md`)

```markdown
# <Topic>
## In one line
## How it actually works (mechanism)
## Diagram
## What I saw in the lab (commands + trimmed output)
## Gotchas / things that surprised me
## Checkpoint answer
## Open questions
```

## Progress

| Module | Lab done | Note written | Checkpoint |
|---|---|---|---|
| A0 Models | ☐ | ☐ | ☐ |
| A1 L1 | ☐ | ☐ | ☐ |
| A2 L2 | ☐ | ☐ | ☐ |
| A3 L3 | ☐ | ☐ | ☐ |
| A4 L4 | ☐ | ☐ | ☐ |
| A5 L7 | ☐ | ☐ | ☐ |
| B1 Bridged | ☐ | ☐ | ☐ |
| B2 Routed | ☐ | ☐ | ☐ |
| B3 NAT | ☐ | ☐ | ☐ |
| B4 Isolated | ☐ | ☐ | ☐ |
| B5 Tunneled | ☐ | ☐ | ☐ |
| Capstone | ☐ | ☐ | ☐ |
