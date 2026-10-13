# A3 — L3: routing, TTL, ICMP, longest-prefix match, PMTUD.
# Topology (two subnets joined by a router namespace):
#
#   A 10.0.1.10/24 ──[eth0]── R ──[eth1]── C 10.0.2.10/24
#                    10.0.1.1     10.0.2.1
#
# Run with: ./labs/run.sh a3-l3
set -u
cap() { local ns=$1 ifc=$2 secs=$3; shift 3; timeout "$secs" ip netns exec "$ns" tcpdump -i "$ifc" -t -e -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
for n in A R C; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done

ip link add eth0 netns A type veth peer name eth0 netns R
ip link add eth1 netns R type veth peer name eth0 netns C
ip -n A link set eth0 address 02:00:00:00:0a:00; ip -n R link set eth0 address 02:00:00:00:01:01
ip -n R link set eth1 address 02:00:00:00:01:02; ip -n C link set eth0 address 02:00:00:00:0c:00
ip -n A addr add 10.0.1.10/24 dev eth0; ip -n A link set eth0 up
ip -n R addr add 10.0.1.1/24 dev eth0;  ip -n R link set eth0 up
ip -n R addr add 10.0.2.1/24 dev eth1;  ip -n R link set eth1 up
ip -n C addr add 10.0.2.10/24 dev eth0; ip -n C link set eth0 up
ip -n A route add default via 10.0.1.1
ip -n C route add default via 10.0.2.1
ip netns exec R sysctl -qw net.ipv4.ip_forward=1
sleep 1

echo "### 1. routing tables"
for n in A R C; do echo "--- $n"; ip -n $n route; done

echo; echo "### 2. A pings C — same packet captured on both sides of R (-v shows TTL)"
cap R eth0 4 -v -c 2 icmp > /tmp/left.txt &
cap R eth1 4 -v -c 2 icmp > /tmp/right.txt & sleep 1
ip netns exec A ping -c1 -W1 10.0.2.10 | grep -E 'bytes from'
wait
echo "--- link A<->R (R eth0)"; cat /tmp/left.txt
echo "--- link R<->C (R eth1)"; cat /tmp/right.txt

echo; echo "### 3. A's ARP cache: it knows the router's MAC, never C's"
ip -n A neigh

echo; echo "### 4. traceroute from A to C (TTL 1, 2, ...)"
ip netns exec A traceroute -n -q1 -w1 -I 10.0.2.10

echo; echo "### 5. how TTL expiry looks on the wire (ping with TTL=1)"
cap A eth0 4 -v -c 2 icmp & sleep 1
ip netns exec A ping -c1 -W1 -t1 10.0.2.10 | grep -iE 'exceeded|from' ; wait

echo; echo "### 6. no route: A pings 10.0.9.9 — R has no route for it"
ip netns exec A ping -c1 -W1 10.0.9.9 | grep -iE 'unreachable|loss'

echo; echo "### 7. longest-prefix match: add a /32 blackhole on A for C only"
ip -n A route add blackhole 10.0.2.10/32
ip -n A route | grep -E 'blackhole|default'
echo "route get 10.0.2.10 (/32 blackhole wins): $(ip -n A route get 10.0.2.10 2>&1 | head -1)"
echo "ping 10.0.2.10: $(ip netns exec A ping -c1 -W1 10.0.2.10 2>&1 | head -1)"
echo "route get 10.0.2.11 (only default matches): $(ip -n A route get 10.0.2.11 | head -1)"
ip -n A route del blackhole 10.0.2.10/32

echo; echo "### 8. asymmetric failure: delete C's default route (no way back)"
ip -n C route del default
cap C eth0 4 -c 2 icmp & sleep 1
ip netns exec A ping -c1 -W1 10.0.2.10 | grep -E 'loss'; wait
echo "(C received the request but had no route to 10.0.1.10 — it could not reply)"
ip -n C route add default via 10.0.2.1

echo; echo "### 9. router stops forwarding (ip_forward=0)"
ip netns exec R sysctl -qw net.ipv4.ip_forward=0
ip netns exec A ping -c1 -W1 10.0.2.10 | grep -E 'loss'
ip netns exec R sysctl -qw net.ipv4.ip_forward=1

echo; echo "### 10. Path MTU: R<->C link shrunk to 1400, A sends 1472+28=1500 B with DF set"
ip -n R link set eth1 mtu 1400; ip -n C link set eth0 mtu 1400
cap A eth0 4 -v -c 2 icmp & sleep 1
ip netns exec A ping -c1 -W1 -M do -s 1472 10.0.2.10 | grep -iE 'mtu|frag|loss'; wait
echo "--- A's route cache now remembers the smaller path MTU:"
ip -n A route get 10.0.2.10 | head -2
