# A0 — Models & Encapsulation

## In one line
We **talk** in OSI layer numbers and **run** TCP/IP; every layer wraps the one above in its own header, and each header carries a "what's next" field so the receiver can unwrap it.

## How it actually works

### Two models

| # | OSI | TCP/IP | PDU | Addressed by | Device that works here |
|---|---|---|---|---|---|
| 7 | Application | **Application** | message | hostname / URL | L7 LB, proxy, WAF |
| 6 | Presentation | ↑ | ↑ | — | — |
| 5 | Session | ↑ | ↑ | — | — |
| 4 | Transport | **Transport** | segment (TCP) / datagram (UDP) | **port** | L4 LB, stateful firewall, PAT |
| 3 | Network | **Internet** | packet | **IP** | router |
| 2 | Data Link | **Link** | frame | **MAC** | switch, bridge, AP |
| 1 | Physical | ↑ | bits | — | hub, cable, PHY |

- **OSI** (ISO, 1984) — a reference model; its protocol stack lost, its *numbering* won as vocabulary ("L2 switch", "L7 LB").
- **TCP/IP** — the protocols came first, the model describes them. 4 layers (5 in textbooks that split Physical out).
- **L5/L6 have no header of their own.** Session (cookies, gRPC streams, TLS resumption) and presentation (TLS, gzip, JSON/Protobuf) are done *inside* the application or its libraries. So in practice: **L1, L2, L3, L4, L7.**

### Responsibility in one line each
- **L2** — get it to the **next box** (one link, one broadcast domain).
- **L3** — get it to the **right machine** (end-to-end, across networks).
- **L4** — get it to the **right process** (ports) + reliability (TCP) or not (UDP).
- **L7** — what the program actually says.

### The "what's next" chain (demultiplexing)

| Header | Field | Values |
|---|---|---|
| Ethernet | **EtherType** | `0x0800` IPv4 · `0x86DD` IPv6 · `0x0806` ARP · `0x8100` VLAN tag |
| IP | **Protocol** (v4) / **Next Header** (v6) | `6` TCP · `17` UDP · `1` ICMP · `47` GRE |
| TCP/UDP | **Destination port** | `80` HTTP · `443` HTTPS · `53` DNS · `22` SSH |

The receiver reads each of these to decide which handler gets the rest of the bytes.

### Header sizes → MTU / MSS

| Header | Size |
|---|---|
| Ethernet | 14 B (+4 FCS trailer, +4 if 802.1Q-tagged) |
| IPv4 | 20 B (up to 60 with options) · IPv6: 40 B fixed |
| TCP | 20 B (up to 60 with options; 32 B is typical with timestamps) |
| UDP | 8 B |

- **MTU** = largest L3 packet a link carries. Ethernet: **1500**.
- **MSS** = largest TCP payload = MTU − IP − TCP = 1500 − 20 − 20 = **1460**.
- Every extra wrapper (VPN, VXLAN, PPPoE) eats into this → "MTU problems". See [B5](14-tunneled.md).

### What changes hop-by-hop vs end-to-end

| Field | Per hop? | Changed by |
|---|---|---|
| src/dst **MAC** | ✅ every hop | every router re-frames for the next link |
| **TTL** | ✅ −1 | every router (0 → drop + ICMP Time Exceeded → that's how `traceroute` works) |
| IP header checksum | ✅ | recomputed because TTL changed |
| src/dst **IP** | ❌ end-to-end | …except **NAT** (src on the way out) |
| src/dst **port** | ❌ end-to-end | …except **PAT** |
| payload | ❌ | never (and with TLS, unreadable anyway) |

> **L2 is hop-by-hop. L3/L4 are end-to-end.** Anything that breaks end-to-end (NAT, proxy, LB) is a *middlebox* — where most debugging happens.

## Diagram

```
 L7  [                    GET / HTTP/1.1 ... (74 B)                 ]
 L4  [TCP 32 B: sport 55584 dport 80 seq ack flags | ...L7...       ]
 L3  [IPv4 20 B: src 192.168.1.9 dst 104.20.23.154 TTL 64 proto 6 | ...L4... ]
 L2  [Eth 14 B: dst 02:00:00:00:00:02 src 02:00:00:00:00:01 type 0x0800 | ...L3... | FCS]
     14 + 20 + 32 + 74 = 140 bytes on the wire (FCS stripped by the NIC before capture)
```

## What I saw in the lab

> MAC addresses in all host captures are replaced with fake `02:00:00:00:00:NN` values by [`labs/sanitize.pl`](../labs/sanitize.pl) (`:01` = my laptop, `:02` = my router). `02:` = "locally administered" bit set, so these can never collide with a real vendor MAC.

Lab: [`labs/a0-encapsulation.sh`](../labs/a0-encapsulation.sh) — run `./labs/run.sh --host a0-encapsulation`. Full output: [`labs/output/a0-encapsulation.txt`](../labs/output/a0-encapsulation.txt).

### The whole conversation (`tcpdump -e -n`)
```
02:00:00:00:00:01 > 02:00:00:00:00:02, IPv4, length 74:  192.168.1.9.55584 > 104.20.23.154.80: Flags [S],  options [mss 1460,...]
02:00:00:00:00:02 > 02:00:00:00:00:01, IPv4, length 74:  104.20.23.154.80 > 192.168.1.9.55584: Flags [S.], options [mss 1400,...]
02:00:00:00:00:01 > 02:00:00:00:00:02, IPv4, length 66:  ... Flags [.],  ack 1
02:00:00:00:00:01 > 02:00:00:00:00:02, IPv4, length 140: ... Flags [P.], seq 1:75,  length 74:  HTTP: GET / HTTP/1.1
02:00:00:00:00:02 > 02:00:00:00:00:01, IPv4, length 997: ... Flags [P.], seq 1:932, length 931: HTTP: HTTP/1.1 200 OK
...                                                          Flags [F.] ... Flags [F.] ... Flags [.]
```
L4 story at a glance: **SYN → SYN-ACK → ACK** (handshake), **PSH GET → PSH 200 OK** (data), **FIN/FIN/ACK** (teardown). Details in [A4](04-l4-transport.md).

### The GET frame, byte by byte
```
0000  02 00 00 00 00 02 | 02 00 00 00 00 01 | 08 00 | 45 00
0010  00 7e cc a0 40 00 40 06 2c 7a c0 a8 01 09 68 14
0020  17 9a | d9 20 00 50 1f ab 65 7b 45 0b 99 29 80 18
0030  00 3f 41 d0 00 00 01 01 08 0a 48 a2 71 d5 8b c2
0040  e1 47 | 47 45 54 20 2f 20 48 54 54 50 2f 31 2e 31   GET / HTTP/1.1
```

| Bytes | Value | Layer · meaning |
|---|---|---|
| `02 00 00 00 00 02` | dst MAC | **L2** — my **router**, not example.com |
| `02 00 00 00 00 01` | src MAC | L2 — my NIC |
| `08 00` | EtherType | L2 → "next is IPv4" |
| `45` | ver 4, IHL 5 | **L3** — 5 × 4 = 20 B header |
| `00 7e` | total length 126 | L3 = 20 IP + 32 TCP + 74 HTTP |
| `40 00` | flags DF | L3 — don't fragment (PMTUD on) |
| `40` | TTL 64 | L3 — Linux default |
| `06` | protocol | L3 → "next is TCP" |
| `c0 a8 01 09` | src IP | 192.168.1.9 (private — will be NATed by the router) |
| `68 14 17 9a` | dst IP | 104.20.23.154 (example.com, on Cloudflare) |
| `d9 20` / `00 50` | ports | **L4** — 55584 (ephemeral) → **80** (→ "next is HTTP") |
| `80 18` | data offset 8, flags | L4 — 8 × 4 = 32 B header; `0x018` = PSH+ACK |
| `47 45 54 20 …` | "GET " | **L7** — HTTP, plain ASCII |

## Gotchas / things that surprised me
- **The destination MAC is the gateway's, not the server's.** The IP header says "example.com", the Ethernet header says "router". That split *is* the L2/L3 boundary.
- **MSS is negotiated, not fixed.** I offered 1460, Cloudflare offered **1400** — each side sends at most what the *other* advertised. CDNs lower it on purpose to survive tunnels on the path.
- **The source IP in my capture is private (192.168.1.9).** The server never sees it — my router rewrites it (NAT, [B3](12-nat.md)).
- **TCP header was 32 B, not 20** — the 12 B of options are timestamps (`TS val/ecr`) + 2 NOPs for alignment.
- `curl` without `-4` tried **IPv6 first** (Happy Eyeballs) — same layers, but EtherType `0x86DD` and a 40 B IP header.
- 140 B captured, but the wire also carried preamble (8 B) + FCS (4 B) + inter-frame gap — L1 overhead the NIC handles and `tcpdump` never shows.

## Checkpoint answer
1. **HTTPS packet stack:** `Eth[dst=gateway MAC, src=my MAC, EtherType 0x0800]` → `IPv4[src=my IP, dst=server IP, TTL 64, Protocol 6]` → `TCP[sport ephemeral, dport 443, seq/ack, flags]` → `TLS record[content type 23 = application data, version, length]` → encrypted HTTP. Pointers up: EtherType → Protocol → dport (+ TLS content type).
2. **Laptop → NAT router → 3 ISP routers → server; what changed?**
   - MACs: rewritten at **every** hop (5 times: router + 3 ISP routers + final delivery link).
   - TTL: 64 → 60 (−1 at each of 4 routers) + IP checksum each time.
   - src IP: private → router's public IP (**home router, NAT**).
   - src port: possibly changed (**home router, PAT**) — only if it collides with another flow.
   - dst IP, dst port, payload: unchanged.
3. **MSS 1460** = 1500 − 20 (IPv4) − 20 (TCP). Over a VPN adding 60 B: inner MTU 1440 → MSS **1400**. (Which is likely why Cloudflare advertises 1400.)

## Open questions
- Who exactly lowers MSS on a path — endpoints only, or can routers clamp it? → *Routers can ("MSS clamping"), revisit in B5.*
- How does the NIC know the frame ended if FCS/preamble are hidden from tcpdump? → L1, [A1](01-l1-physical.md).
