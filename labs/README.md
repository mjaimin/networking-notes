# Labs

Every lab is a self-contained bash script; the commands in it **are** the lesson, so read it top to bottom.

## How they run

`run.sh` starts a throwaway [`nicolaka/netshoot:v0.13`](https://github.com/nicolaka/netshoot) container
(tcpdump, tshark, iproute2, iptables, conntrack, socat, dig, curl, openssl…), runs the script inside it,
prints the output and saves it to `output/<lab>.txt`.

| Mode | Command | Container gets | Used for |
|---|---|---|---|
| **Isolated** (default) | `./labs/run.sh <lab>` | `--privileged`, its **own** network namespace | building topologies with `ip netns`, veth, bridges, iptables — the host network is never touched |
| **Host** | `./labs/run.sh --host <lab>` | `--net=host` + `NET_RAW`/`NET_ADMIN` | looking at / capturing on this machine's real NIC |

No `sudo` needed — only membership of the `docker` group. Set `HOST_IF=wlan0` (etc.) to capture on another interface.

## Lab list

| Lab | Mode | Note |
|---|---|---|
| `a0-encapsulation` | host | [A0](../notes/00-models-and-encapsulation.md) |
| `a1-physical` | host | [A1](../notes/01-l1-physical.md) |
| `a2-l2` | isolated | [A2](../notes/02-l2-data-link.md) |
| `a3-l3` | isolated | [A3](../notes/03-l3-network.md) |
| `a4-l4` | isolated | [A4](../notes/04-l4-transport.md) |
| `a5-l7` | host | [A5](../notes/05-l7-application.md) |
| `b1-bridged` | isolated | [B1](../notes/10-bridged.md) |
| `b2-routed` | isolated | [B2](../notes/11-routed.md) |
| `b3-nat` | isolated | [B3](../notes/12-nat.md) |
| `b4-isolated` | isolated | [B4](../notes/13-isolated.md) |
| `b5-tunneled` | isolated | [B5](../notes/14-tunneled.md) |
| `c0-capstone` | host | [Capstone](../notes/99-capstone-my-network.md) |

## Privacy — this repo is public

Host-mode output passes through [`sanitize.pl`](sanitize.pl) before it is printed or saved:

| Real value | Replaced with |
|---|---|
| this host's Ethernet MAC | `02:00:00:00:00:01` |
| default gateway (home router) MAC | `02:00:00:00:00:02` |
| this host's Wi-Fi MAC | `02:00:00:00:00:03` |
| any other unicast MAC | `02:00:00:00:00:10`, `:11`, … |
| this host's public IPv4 | `203.0.113.7` (RFC 5737 documentation range) |
| this host's IPv6 global prefix | `2001:db8:0` (RFC 3849 documentation prefix) |

MACs are also rewritten in hex dumps (and their ASCII column). Host labs additionally use IPv4 only,
filter captures to the lab's own traffic (example.com / 1.1.1.1), and print ISP hops as a category, never an address.
Isolated labs use made-up `02:…` MACs and private / documentation addresses only.

## Conventions & gotchas
- Every capture runs under `timeout` — a missing packet must not hang a lab.
- `wait $!`, never a bare `wait`, when a lab has a background server running.
- IPv6 is disabled inside labs to keep captures readable.
- Don't name interfaces `a`, `b`, … — `ip link set a up` parses `a` as `address`.
- Outputs differ slightly per run (ports, sequence numbers, IP IDs); notes quote one representative run.
