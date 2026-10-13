# B1 — Bridged (L2 join)

## In one line
Bridging **merges segments into one L2 network**: one broadcast domain, one subnet, one DHCP server, everyone reachable directly — no addresses change, nothing is hidden.

## How it actually works
- A bridge is a **switch** — software (Linux `br0`, `docker0`, OVS) or hardware. It forwards by MAC using an FDB it learns from source addresses ([A2](02-l2-data-link.md)).
- Anything plugged into it — a physical NIC, a veth from a container, a VM's tap device, a Wi-Fi radio — becomes **just another port on the same LAN**.
- Consequences of "one L2 network":
  - **Same subnet** for every member; **one DHCP server** answers all of them (DHCP is broadcast-based, so it works only inside a broadcast domain — or through a relay).
  - **Direct reachability** — members talk without a router hop (TTL unchanged).
  - **Every broadcast reaches everyone** — ARP, DHCP, mDNS, NetBIOS… the cost grows with the number of hosts.
  - **No isolation** — any member can ARP-spoof, flood or scan the others.
  - **Loops are fatal** without STP (no TTL at L2).

### DHCP (needs one broadcast domain)
| Step | From → To | L2 dst | L3 src → dst |
|---|---|---|---|
| **D**iscover | client → everyone | `ff:ff:…` | `0.0.0.0 → 255.255.255.255` |
| **O**ffer | server → client | broadcast (or unicast) | `server → 255.255.255.255` (yiaddr = offered IP) |
| **R**equest | client → everyone | broadcast | `0.0.0.0 → 255.255.255.255` (so *other* servers see it was declined) |
| **A**CK | server → client | broadcast (or unicast) | lease confirmed + options (mask, router, DNS, lease time) |

### Where bridged mode shows up
| Place | What's bridged |
|---|---|
| Home router | its LAN switch ports + Wi-Fi radio are one bridge (`br-lan`) |
| Wi-Fi AP / extender in "bridge/AP mode" | wireless clients ↔ wired LAN |
| Linux host | `ip link add br0 type bridge` + `ip link set eth0 master br0` |
| Docker | `docker0` bridge — containers' veths are its ports (then NAT to outside, [B3](12-nat.md)) |
| Kubernetes (many CNIs) | `cni0` bridge per node |
| *VM example* | VirtualBox/VMware **"Bridged Adapter"** — the VM's vNIC joins the host's physical LAN, gets an IP **from your home router's DHCP** |

> Wi-Fi caveat: an 802.11 client normally can't bridge other MACs (the AP only accepts frames from associated MACs). Hypervisors work around it with MAC-NAT; real bridging over Wi-Fi needs WDS / 4-address mode.

### STP — making redundancy safe
- Redundant links = a loop. **STP/RSTP** elects a root bridge (lowest bridge ID), computes shortest paths to it, and puts one port of every loop into **blocking**.
- Port states: blocking → listening → learning → **forwarding** (classic STP: 2 × 15 s forward delay ≈ 30 s before a new port forwards — why a freshly plugged PC can wait for DHCP).
- RSTP converges in ~1 s; switches mark host ports as "edge/portfast" to skip the wait.

## Diagram

```
                 ┌───────────────────── br0 ─────────────────────┐
                 │ FDB: :01→p-rtr  :02→p-h1  :03→p-h2  :04→p-h3   │
                 └───┬───────────┬───────────┬───────────┬───────┘
                   rtr          h1          h2          h3
              192.168.50.1   .126 (DHCP)  .127 (DHCP)  .128 (DHCP)
              DHCP server     ◀────────── one broadcast domain ──────────▶

 Loop:   brA ══ l1 ══ brB        without STP: 1 broadcast → millions of copies/s
             ╲═ l2 ═╱            with STP:    l2b blocking → a tree, 1 copy
```

## What I saw in the lab

Lab: [`labs/b1-bridged.sh`](../labs/b1-bridged.sh) — `./labs/run.sh b1-bridged`. Output: [`labs/output/b1-bridged.txt`](../labs/output/b1-bridged.txt).

### DORA, seen by a bystander (h3) while h1 asks
```
DISCOVER  02:..:50:02 > ff:ff:ff:ff:ff:ff   0.0.0.0      > 255.255.255.255
OFFER     02:..:50:01 > ff:ff:ff:ff:ff:ff   192.168.50.1 > 255.255.255.255   yiaddr=192.168.50.126
REQUEST   02:..:50:02 > ff:ff:ff:ff:ff:ff   0.0.0.0      > 255.255.255.255
ACK       02:..:50:01 > ff:ff:ff:ff:ff:ff   192.168.50.1 > 255.255.255.255   yiaddr=192.168.50.126
```
→ All four are **broadcast** — that's why every host on the bridge sees every DHCP exchange.

### Everyone shares one subnet and one gateway
```
h1  192.168.50.126/24   gw: 192.168.50.1
h2  192.168.50.127/24   gw: 192.168.50.1
h3  192.168.50.128/24   gw: 192.168.50.1
h1 → h3: 64 bytes from 192.168.50.128: ttl=64        ← direct, no router hop
```

### Bridge state
```
p-rtr / p-h1 / p-h2 / p-h3: master br0 state forwarding
FDB: 02:..:50:01 → p-rtr   02:..:50:02 → p-h1   02:..:50:03 → p-h2   02:..:50:04 → p-h3
MAC ageing time: 300 s
```

### Loop without vs with STP
```
WITHOUT STP: one broadcast in → 3 563 987 frames out of l1a in ~1 s   (broadcast storm)
WITH STP:    l1a forwarding · l1b forwarding · l2a forwarding · l2b blocking
             one broadcast in → 2 frames out of l1a in ~1 s           (the ARP + a BPDU)
```
→ A **single ARP** turned into 3.5 million frames per second on one link — and that's in memory; on real hardware it saturates every port and the switch CPU. STP blocked exactly one port (`l2b`) and the problem vanished.

## Gotchas / things that surprised me
- DHCP **REQUEST is broadcast too**, even though the client already knows the server — so competing servers learn their offer was declined.
- The bridge's own `br0` interface can have an IP (then the host is a member of the LAN) or not (pure switch). In the lab it had none.
- Default **ageing 300 s**: a device that moves ports (VM migration, Wi-Fi roaming) is unreachable until it sends a frame or the entry ages — hence **gratuitous ARP** after migration.
- STP is **off by default** on Linux bridges (`stp_state 0`) — a cabled loop between two Linux bridges is an instant storm.
- Bridged mode is "zero config" for reachability but **zero isolation** — use VLANs ([A2](02-l2-data-link.md)) or routing ([B2](11-routed.md)) to split it.

## Checkpoint answer
**Why does adding hosts to a bridge eventually hurt? What does STP prevent?**
- Every host adds broadcast/multicast traffic (ARP, DHCP, mDNS, IPv6 ND…) that **every other host must receive and process**, plus FDB entries; a fault or loop affects *all* of them. Large flat L2 networks also mean one big failure and security domain. Fix: split into VLANs/subnets and route between them.
- **STP prevents loops from becoming broadcast storms**: Ethernet frames have no TTL, so without STP a single broadcast circulates and multiplies forever (3.5 M frames/s from one ARP in the lab). STP turns any meshed topology into a loop-free tree by blocking redundant ports, and re-opens them if the active path fails.

## Open questions
- How does VXLAN stretch "one bridge" across data centres — and why does that make people nervous about L2 failure domains? → [B5](14-tunneled.md).
- Proxy ARP / ARP suppression on big bridges (EVPN) — later.
