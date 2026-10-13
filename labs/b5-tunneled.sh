# B5 — Tunnels: GRE (L3 over IP), VXLAN (L2 over UDP), MTU and MSS clamping.
# Topology — two sites, joined only by "the internet" (which routes public IPs only):
#
#   a1 10.1.0.10 ── gwA 203.0.113.2 ══ inet ══ 198.51.100.2 gwB ── b1 10.2.0.10
#      site A                     (no routes to 10.x)                 site B
#
# Run with: ./labs/run.sh b5-tunneled
set -u
cap() { local ns=$1 ifc=$2 secs=$3; shift 3; timeout "$secs" ip netns exec "$ns" tcpdump -i "$ifc" -t -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
for n in a1 gwA inet gwB b1; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done
link() { ip link add $2 netns $1 type veth peer name $4 netns $3; ip -n $1 link set $2 up; ip -n $3 link set $4 up; }
link a1 eth0 gwA lan; link gwA wan inet ia; link inet ib gwB wan; link gwB lan b1 eth0
ip -n a1 addr add 10.1.0.10/24 dev eth0; ip -n a1 route add default via 10.1.0.1
ip -n gwA addr add 10.1.0.1/24 dev lan;  ip -n gwA addr add 203.0.113.2/24 dev wan;  ip -n gwA route add default via 203.0.113.1
ip -n inet addr add 203.0.113.1/24 dev ia; ip -n inet addr add 198.51.100.1/24 dev ib
ip -n gwB addr add 10.2.0.1/24 dev lan;  ip -n gwB addr add 198.51.100.2/24 dev wan; ip -n gwB route add default via 198.51.100.1
ip -n b1 addr add 10.2.0.10/24 dev eth0; ip -n b1 route add default via 10.2.0.1
for r in gwA inet gwB; do ip netns exec $r sysctl -qw net.ipv4.ip_forward=1; done
sleep 1

echo "### 1. no tunnel: the internet doesn't route private addresses"
ip netns exec a1 ping -c1 -W1 10.2.0.10 | grep -E 'From|loss'

echo; echo "### 2. GRE tunnel between the two public addresses (L3 inside L3)"
ip -n gwA tunnel add gre1 mode gre local 203.0.113.2 remote 198.51.100.2 ttl 64
ip -n gwB tunnel add gre1 mode gre local 198.51.100.2 remote 203.0.113.2 ttl 64
ip -n gwA addr add 169.254.0.1/30 dev gre1; ip -n gwA link set gre1 up
ip -n gwB addr add 169.254.0.2/30 dev gre1; ip -n gwB link set gre1 up
ip -n gwA route add 10.2.0.0/24 dev gre1
ip -n gwB route add 10.1.0.0/24 dev gre1
ip -n gwA link show gre1 | head -1 | grep -oE 'gre1.*mtu [0-9]+'
cap inet ia 4 -v -c 2 > /tmp/gre.txt & c=$!; sleep 1
ip netns exec a1 ping -c1 -W1 10.2.0.10 | grep 'bytes from'
wait $c; echo "--- on the internet link (what an ISP sees):"; cat /tmp/gre.txt
echo "--- traceroute: the whole internet looks like one hop"
ip netns exec a1 traceroute -n -q1 -w1 -I 10.2.0.10 | tail -n +2

echo; echo "### 3. MTU: inner packets must be 24 B smaller"
ip netns exec a1 ping -c1 -W1 -M do -s 1472 10.2.0.10 2>&1 | grep -iE 'mtu|frag|bytes from' | head -1
ip netns exec a1 ping -c1 -W1 -M do -s 1448 10.2.0.10 2>&1 | grep -E 'bytes from'

echo "--- a1 has now cached the smaller path MTU:"; ip -n a1 route get 10.2.0.10 | sed -n 2p

echo; echo "### 4. MSS clamping on the tunnel router"
ip netns exec b1 socat TCP-LISTEN:7000,reuseaddr,fork SYSTEM:'echo ok' 2>/dev/null &
sleep 1
mss() { ip -n a1 route flush cache                 # forget the PMTU learned in step 3
        cap b1 eth0 3 'tcp[tcpflags] & tcp-syn != 0 and dst port 7000' > /tmp/syn.txt & local c=$!; sleep 1
        ip netns exec a1 socat - TCP:10.2.0.10:7000 </dev/null >/dev/null 2>&1; wait $c; grep -oE 'mss [0-9]+' /tmp/syn.txt | head -1; }
echo "SYN mss arriving at b1, no clamping:  $(mss)"
ip netns exec gwA iptables -t mangle -A FORWARD -o gre1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
echo "SYN mss arriving at b1, with clamping: $(mss)"

echo; echo "### 5. VXLAN: stretch ONE L2 segment (10.9.0.0/24) across both sites"
ip -n gwA link add vx42 type vxlan id 42 local 203.0.113.2 remote 198.51.100.2 dstport 4789
ip -n gwB link add vx42 type vxlan id 42 local 198.51.100.2 remote 203.0.113.2 dstport 4789
for g in gwA gwB; do
  ip -n $g link add br42 type bridge; ip -n $g link set vx42 master br42
  ip -n $g link set vx42 mtu 1450                # 1500 − 50 B (outer IP 20 + UDP 8 + VXLAN 8 + inner Ethernet 14)
  ip -n $g link set vx42 up; ip -n $g link set br42 up
done
ip -n gwA link show vx42 | head -1 | grep -oE 'vx42.*mtu [0-9]+'
# one L2 host per site, both in 10.9.0.0/24, plugged into the stretched bridge
for s in A B; do
  ip netns add x$s; ip netns exec x$s sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  ip link add p-x$s netns gw$s type veth peer name eth0 netns x$s
  ip -n gw$s link set p-x$s master br42; ip -n gw$s link set p-x$s up; ip -n gw$s link set p-x$s mtu 1450
  ip -n x$s link set eth0 mtu 1450; ip -n x$s link set eth0 up
done
ip -n xA link set eth0 address 02:00:00:00:9a:01; ip -n xB link set eth0 address 02:00:00:00:9b:01
ip -n xA addr add 10.9.0.1/24 dev eth0; ip -n xB addr add 10.9.0.2/24 dev eth0
sleep 1
cap inet ia 4 -e -c 4 udp port 4789 > /tmp/vx.txt & c=$!; sleep 1
ip netns exec xA ping -c1 -W1 10.9.0.2 | grep 'bytes from'
wait $c; echo "--- on the internet link:"; cat /tmp/vx.txt
echo "--- xA's ARP cache: it learned xB's MAC directly, as if on the same switch"
ip -n xA neigh
echo "--- gwA's VXLAN forwarding table (remote MAC → remote tunnel endpoint)"
ip netns exec gwA bridge fdb show dev vx42 | grep -E '9b:01|^00:00:00:00:00:00' 
