# B4 — Isolated networks: a segment with no path out.
# Topology:
#
#   i1 10.50.0.11 ─┐
#   i2 10.50.0.12 ─┼─ br-iso ── host 10.50.0.1   host ── uplink ── net 198.51.100.10 ("internet")
#                  │            (like VirtualBox host-only)
#
# Run with: ./labs/run.sh b4-isolated
set -u
cap() { local ns=$1 ifc=$2 secs=$3; shift 3; timeout "$secs" ip netns exec "$ns" tcpdump -i "$ifc" -t -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
for n in i1 i2 host net; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done
ip link add br-iso type bridge; ip link set br-iso up
for n in i1 i2 host; do ip link add p-$n type veth peer name eth0 netns $n; ip link set p-$n master br-iso; ip link set p-$n up; ip -n $n link set eth0 up; done
ip -n i1 addr add 10.50.0.11/24 dev eth0; ip -n i2 addr add 10.50.0.12/24 dev eth0; ip -n host addr add 10.50.0.1/24 dev eth0
ip link add uplink netns host type veth peer name eth0 netns net
ip -n host link set uplink up; ip -n net link set eth0 up
ip -n host addr add 198.51.100.2/24 dev uplink; ip -n net addr add 198.51.100.10/24 dev eth0
ip netns exec host sysctl -qw net.ipv4.ip_forward=0
sleep 1

echo "### 1. i1's routing table: connected route only, no default"
ip -n i1 route

echo; echo "### 2. inside the segment everything works (members + host = 'host-only')"
for t in 10.50.0.12 10.50.0.1; do printf 'i1 → %-12s %s\n' $t "$(ip netns exec i1 ping -c1 -W1 $t | grep -oE '[0-9]+% packet loss')"; done

echo; echo "### 3. outside: no route → the kernel refuses before anything hits the wire"
cap i1 eth0 3 icmp > /tmp/i1.txt & c=$!; sleep 1
ip netns exec i1 ping -c1 -W1 198.51.100.10 2>&1 | head -1
wait $c; echo "packets on i1's wire: $(grep -c . /tmp/i1.txt)"

echo; echo "### 4. give i1 a default route via host — host still doesn't forward (ip_forward=0)"
ip -n i1 route add default via 10.50.0.1
cap host eth0 3 icmp > /tmp/h_in.txt & c1=$!
cap host uplink 3 icmp > /tmp/h_out.txt & c2=$!; sleep 1
ip netns exec i1 ping -c1 -W1 198.51.100.10 | grep -oE '[0-9]+% packet loss'
wait $c1 $c2
echo "arrived at host (segment side): $(grep -c . /tmp/h_in.txt)   left host (uplink side): $(grep -c . /tmp/h_out.txt)"

echo; echo "### 5. the only thing standing between 'isolated' and 'NAT mode' is two settings"
ip netns exec host sysctl -qw net.ipv4.ip_forward=1
ip netns exec host iptables -t nat -A POSTROUTING -o uplink -j MASQUERADE
printf 'i1 → internet  %s\n' "$(ip netns exec i1 ping -c1 -W1 198.51.100.10 | grep -oE '[0-9]+% packet loss')"
echo "--- …so isolation that matters is enforced with policy, not by hoping nobody turns forwarding on:"
ip netns exec host iptables -I FORWARD -i eth0 -o uplink -j DROP
printf 'i1 → internet  %s   (FORWARD DROP)\n' "$(ip netns exec i1 ping -c1 -W1 198.51.100.10 | grep -oE '[0-9]+% packet loss')"
ip netns exec host iptables -L FORWARD -v -n | sed -n '1,3p'
ip netns exec host iptables -F FORWARD; ip netns exec host iptables -t nat -F; ip netns exec host sysctl -qw net.ipv4.ip_forward=0
ip -n i1 route del default

echo; echo "### 6. 'internal network': take the host off the segment"
ip link set p-host nomaster
printf 'i1 → i2    %s\n' "$(ip netns exec i1 ping -c1 -W1 10.50.0.12 | grep -oE '[0-9]+% packet loss')"
printf 'i1 → host  %s\n' "$(ip netns exec i1 ping -c1 -W1 10.50.0.1 | grep -oE '[0-9]+% packet loss')"

echo; echo "### 7. broadcasts stay inside: i1's ARP flood, watched from the 'internet'"
cap net eth0 3 > /tmp/net.txt & c=$!; sleep 1
ip netns exec i1 arping -c2 -w2 -I eth0 10.50.0.99 >/dev/null 2>&1
wait $c; echo "frames seen on the internet side: $(grep -c . /tmp/net.txt)"
