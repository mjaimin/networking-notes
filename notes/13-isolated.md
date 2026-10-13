# B4 — Isolated

## In one line
An isolated network is an L2 segment with **no path off it** — members talk to each other (ARP, broadcasts, unicast all work), but there is no gateway, or the gateway refuses to forward.

## How it actually works
Isolation is the **absence** of something. Any one of these is enough:

| Missing piece | Symptom from inside |
|---|---|
| **No default/other route** on the hosts | `connect: Network unreachable` instantly — nothing is sent |
| A gateway that **doesn't forward** (`ip_forward=0`) | packets reach the gateway and die there; 100 % loss, no ICMP |
| A gateway with **policy** (`FORWARD DROP`, ACLs, security groups) | same, but counted and auditable |
| **No physical/virtual link** at all (air gap) | the network simply doesn't exist from outside |

Broadcasts never cross a router, so an isolated segment is also an isolated **broadcast domain**: nothing it ARPs or DHCPs leaks out.

### Flavours

| Flavour | Who's on the segment | Real-world | *VM example* |
|---|---|---|---|
| **Host-only** | members + the host machine | management networks, lab benches | VirtualBox *Host-only Adapter* (`vboxnet0`, 192.168.56.0/24), VMware *VMnet1* |
| **Internal** | members only | backend tiers, cluster interconnects | VirtualBox *Internal Network* (named `intnet`) |
| **Air-gapped** | members only, physically separate | OT/SCADA, classified networks, offline CAs | — |
| **Private subnet** (cloud) | members; egress only via explicit NAT GW/endpoints | DB subnets in a VPC | — |

### Why isolation fails in practice
- Somebody **enables forwarding** on a dual-homed host (one leg inside, one outside) — it becomes a router (+ NAT = "VirtualBox NAT mode").
- **Multi-homed** devices (a laptop on Wi-Fi + the lab cable, a VM with two NICs) bridge the gap at L3 by accident.
- **Removable media, updates, DNS**: air gaps are crossed by people and side-channels (Stuxnet travelled on USB sticks).
- **Default-allow** policies: isolation that matters is an explicit `DROP` you can audit, not "we didn't add a route".

## Diagram

```
   i1 .11 ─┐                                              ┌──────────────┐
   i2 .12 ─┼── br-iso ── host .1   [ip_forward=0] ── uplink ──  "internet"   │
           │             (host-only: host is a member)    │ 198.51.100.10│
           └── "internal": unplug the host → members only └──────────────┘
```

## What I saw in the lab

Lab: [`labs/b4-isolated.sh`](../labs/b4-isolated.sh) — `./labs/run.sh b4-isolated`. Output: [`labs/output/b4-isolated.txt`](../labs/output/b4-isolated.txt).

```
i1 route:              10.50.0.0/24 dev eth0 proto kernel scope link        ← no default
i1 → i2 / host:        0% packet loss                                       ← host-only works
i1 → 198.51.100.10:    ping: connect: Network unreachable · packets on i1's wire: 0
```
→ With no route the kernel fails the `connect()` itself — **nothing is transmitted**.

```
+ default via host, host ip_forward=0:
    100% packet loss · arrived at host (segment side): 1 · left host (uplink side): 0
+ ip_forward=1 + MASQUERADE on host:
    i1 → internet  0% packet loss                                           ← now it's "NAT mode"
+ iptables -I FORWARD -i eth0 -o uplink -j DROP:
    i1 → internet  100% packet loss
    pkts 1  bytes 84  DROP  in eth0  out uplink                            ← counted, auditable
```

```
"internal" (host unplugged):  i1 → i2  0% loss · i1 → host  100% loss
ARP flood from i1, watched from the internet side: 0 frames
```

## Gotchas / things that surprised me
- "Network unreachable" (immediate, local) vs 100 % loss (sent, dropped later) tells you **where** the isolation is: on the host's own routing table, or at a gateway.
- The difference between *host-only* and *NAT* is literally `ip_forward=1` + one MASQUERADE rule on the host — the same two settings that turn any Linux box into a router.
- `ip_forward=0` drops silently and isn't counted anywhere obvious; a `FORWARD DROP` rule has counters — prefer policy you can see.
- Isolated ≠ unreachable from the host in *host-only* mode: the host is a member and can be a pivot.

## Checkpoint answer
**Prove a segment is isolated:**
1. On a member: `ip route` — only connected routes, no default.
2. `ping` an outside address → `Network unreachable`, and a capture on the member's interface shows **0 packets**.
3. If there *is* a gateway: capture both of its legs during a test — packets arrive on the inside leg, **none** leave the outside leg; FORWARD policy/counters show the drop.
4. Capture on the outside: no ARP/broadcast/DHCP from the segment ever appears.

## Open questions
- Data diodes — one-way links for OT networks (physically TX-only fibre).
- Cloud: is a private subnet with a VPC endpoint to S3 still "isolated"?
