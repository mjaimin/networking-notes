# A4 — L4 Transport

## In one line
L4 gets data to the **right process** (ports). **TCP** adds a connection, ordering, retransmission and flow/congestion control; **UDP** adds nothing but ports and a checksum.

## How it actually works

### Ports & sockets
- A connection is identified by the **5-tuple**: `protocol, src IP, src port, dst IP, dst port`. Change any one → a different connection.
- **Well-known** ports 0–1023 (root to bind on Linux), registered 1024–49151, **ephemeral** (client side, picked by the OS): Linux `32768–60999` (`net.ipv4.ip_local_port_range`).
- A **listening** socket (`LISTEN`, `0.0.0.0:7000`) spawns one **connected** socket per client — that's why one server port can serve thousands of clients.

### TCP header — what matters

| Field | Meaning |
|---|---|
| src/dst port | the process on each end |
| **seq** | byte number of the first payload byte (random initial value, ISN) |
| **ack** | "I've received everything up to this byte, send me the next one" |
| flags | `S` SYN · `.` ACK · `P` PSH · `F` FIN · `R` RST (tcpdump notation; `S.` = SYN+ACK) |
| window | how many bytes I can still buffer (flow control), scaled by `wscale` |
| options | MSS, SACK, timestamps, window scale — negotiated only in SYN/SYN-ACK |

### Connection life cycle

```
 client                                        server (LISTEN)
   │ ── SYN  seq=x ───────────────────────────▶ │   SYN_SENT → / SYN_RECV
   │ ◀────────────── SYN-ACK  seq=y ack=x+1 ─── │
   │ ── ACK  ack=y+1 ─────────────────────────▶ │   ESTABLISHED (both)
   │ ══ data ⇄ ACKs ═══════════════════════════ │
   │ ◀──────────────────────────── FIN ──────── │   server closes first → FIN_WAIT_1
   │ ── ACK ──────────────────────────────────▶ │   CLOSE_WAIT (client) / FIN_WAIT_2
   │ ── FIN ──────────────────────────────────▶ │   LAST_ACK
   │ ◀──────────────────────────── ACK ──────── │   server: TIME_WAIT (2×MSL, 60 s on Linux)
```
- SYN and FIN each consume **one sequence number** (that's why `ack = seq + 1` with no data).
- **TIME_WAIT** sits on whoever sent the **first FIN** — it absorbs late duplicates and re-sends the final ACK if lost. Lots of TIME_WAIT on a server = the *server* is closing connections (common with HTTP/1.0 or `Connection: close`).
- **CLOSE_WAIT** that never goes away = the app received FIN but **never called close()** — an application bug, not a network one.
- **RST** = abort: "no such connection / nobody listening / go away". No handshake, no TIME_WAIT.

### Reliability & speed
- **Retransmission**: no ACK within RTO → resend. Fast retransmit after 3 duplicate ACKs; **SACK** lets the receiver say exactly which ranges arrived.
- **Flow control**: receiver advertises *window* — sender may not have more than that in flight.
- **Congestion control** (CUBIC default on Linux, BBR optional): sender also limits itself to a *congestion window* that grows until loss/delay is detected. Throughput ≈ window / RTT → high-latency links need big windows.
- **Nagle / delayed ACK** — batching small writes; `TCP_NODELAY` turns Nagle off for latency-sensitive apps.

### "Refused" vs "timed out" vs "unreachable"

| Client sees | What happened on the wire | Usual cause |
|---|---|---|
| **Connection refused** (instant) | SYN → **RST** | host up, nothing listening — or firewall `REJECT --reject-with tcp-reset` |
| **Connection refused** | SYN → ICMP *port unreachable* | firewall `REJECT` default |
| **No route to host / Host is unreachable** | SYN → ICMP *host unreachable / prohibited* | firewall `REJECT icmp-host-prohibited`, or ARP failed at the last hop |
| **Connection timed out** (slow) | SYN, SYN, SYN… **no answer** | firewall `DROP`, host down, routing black hole, wrong IP |
| Connection reset by peer (mid-stream) | **RST** after ESTABLISHED | app crashed/closed with unread data, LB/firewall idle-timeout, middlebox |

### UDP
- Header: src port, dst port, length, checksum — **8 bytes, that's all**.
- No connection, no ordering, no retransmit, no flow control. Each `send` = one datagram.
- Used where latency matters more than completeness or the app does its own reliability: **DNS, DHCP, NTP, VoIP/video (RTP), games, QUIC/HTTP-3, WireGuard, VXLAN**.
- Closed UDP port → the host answers with ICMP *port unreachable*; a *connected* UDP socket surfaces that as `ECONNREFUSED` on the next read.

### QUIC (where L4 gets fuzzy)
QUIC runs **over UDP** and re-implements TCP's job (streams, reliability, congestion control) **plus TLS 1.3**, in user space. Benefits: 1-RTT (or 0-RTT) setup, no head-of-line blocking between streams, connection survives IP change (Wi-Fi → 4G). It's the transport of **HTTP/3**.

## Diagram

```
 TCP:  [src port|dst port|   seq   |   ack   |off|flags| window |cksum|urg| options... ]  20–60 B
 UDP:  [src port|dst port| length  | checksum]                                            8 B
```

## What I saw in the lab

Lab: [`labs/a4-l4.sh`](../labs/a4-l4.sh) — `./labs/run.sh a4-l4`. Output: [`labs/output/a4-l4.txt`](../labs/output/a4-l4.txt).
Client `10.0.0.1` ↔ server `10.0.0.2`, server is `socat` replying `hello-from-server` on port 7000.

### Whole life cycle (options trimmed)
```
10.0.0.1.48022 > 10.0.0.2.7000: [S],  seq 316443296                      ← SYN (client ISN)
10.0.0.2.7000 > 10.0.0.1.48022: [S.], seq 1797968601, ack 316443297      ← SYN-ACK (server ISN, ack = ISN+1)
10.0.0.1.48022 > 10.0.0.2.7000: [.],  ack 1                              ← ACK  → ESTABLISHED
10.0.0.1.48022 > 10.0.0.2.7000: [P.], seq 1:4,  length 3                 ← "hi\n"
10.0.0.2.7000 > 10.0.0.1.48022: [.],  ack 4
10.0.0.2.7000 > 10.0.0.1.48022: [P.], seq 1:19, length 18                ← "hello-from-server\n"
10.0.0.1.48022 > 10.0.0.2.7000: [.],  ack 19
10.0.0.2.7000 > 10.0.0.1.48022: [F.], seq 19                             ← server closes first
10.0.0.1.48022 > 10.0.0.2.7000: [.],  ack 20                             ← FIN counted as 1 byte
10.0.0.1.48022 > 10.0.0.2.7000: [F.], seq 4, ack 20                      ← client closes
10.0.0.2.7000 > 10.0.0.1.48022: [.],  ack 5
```
(tcpdump shows seq/ack **relative** to the ISN after the handshake — `seq 1:4` = bytes 1–3.)

### TIME_WAIT lands on the closer
```
server:  LISTEN     0.0.0.0:7000
         TIME-WAIT  10.0.0.2:7000  10.0.0.1:48022      ← server sent the first FIN
client:  (no socket left)
```

### Refused — instant
```
10.0.0.1.52924 > 10.0.0.2.9999: [S]
10.0.0.2.9999 > 10.0.0.1.52924: [R.], seq 0, ack 266527065, win 0
connect(...10.0.0.2:9999): Connection refused        took 2 ms
```

### Timed out — DROP, gaps between SYN retransmissions (`-ttt`)
```
net.ipv4.tcp_syn_retries = 6     net.ipv4.tcp_syn_linear_timeouts = 4
 +0.000  [S] seq 306941940
 +1.04   [S] seq 306941940        ← same seq: a retransmit, not a new attempt
 +1.02   [S]
 +1.02   [S]
 +1.02   [S]
 +1.02   [S]
 +2.05   [S]                      ← then exponential backoff
 +4.03   [S]
Operation timed out              took 15018 ms (socat's 15 s limit)
```

### REJECT variants
```
tcp-reset              → Connection refused
icmp-port-unreachable  → Connection refused
icmp-host-prohibited   → Host is unreachable
```

### UDP
```
10.0.0.1.38802 > 10.0.0.2.6000: UDP, length 5        ← "ping\n", no handshake
10.0.0.2.6000 > 10.0.0.1.38802: UDP, length 9        ← "udp-pong\n"
10.0.0.1.44306 > 10.0.0.2.6001: UDP, length 5        ← closed port
10.0.0.2 > 10.0.0.1: ICMP 10.0.0.2 udp port 6001 unreachable
client: read(...): Connection refused
```

### 20 % loss with `tc netem`
```
client received 200000 bytes (expected 200000)
TcpRetransSegs           45
TcpExtTCPLostRetransmit  12
```
→ The application got every byte; TCP silently retransmitted 45 segments (some of them twice).

## Gotchas / things that surprised me
- **Modern Linux SYN backoff starts linear** (`tcp_syn_linear_timeouts = 4`, added in kernel 6.x) — 1 s, 1 s, 1 s, 1 s… then 2 s, 4 s. Older kernels doubled from the start (1, 2, 4, 8, 16, 32 → ~127 s total).
- A firewall that **DROPs** makes your app hang for the whole connect timeout; **REJECT** fails fast. DROP hides the host, REJECT is kinder to legitimate clients.
- `tcpdump` guesses the protocol from the port (8080 → "HTTP", 5353 → mDNS) — it's a label, not a decode guarantee.
- "Connection refused" for **UDP** exists — it's ICMP port unreachable surfaced on a connected socket.
- TIME_WAIT isn't a leak; CLOSE_WAIT usually is.

## Checkpoint answer
**"Connection refused" vs "connection timed out":**
- *Refused* — something **answered**: the host's TCP stack (RST, "no listener") or a firewall REJECT (RST/ICMP). Instant. Layer 4 (or L3 ICMP carrying an L4 verdict). Fix: start the service / bind the right address (`0.0.0.0` vs `127.0.0.1`) / fix the REJECT rule.
- *Timed out* — **nothing answered**: SYN retransmitted with backoff until the client gave up. A firewall DROP, host down, wrong IP, or a routing black hole (including a missing return route, [A3](03-l3-network.md)). Debug: capture on the server — do SYNs arrive? Arrive but no SYN-ACK leaves → host firewall/listener; SYN-ACK leaves but client never sees it → return path.

## Open questions
- How do SYN cookies let a server survive a SYN flood without keeping SYN_RECV state?
- BBR vs CUBIC on a lossy link — try with `tc netem delay 100ms loss 1%` and `sysctl net.ipv4.tcp_congestion_control=bbr`.
