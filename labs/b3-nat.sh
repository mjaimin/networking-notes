# B3 — NAT: SNAT/masquerade, PAT, conntrack, DNAT port-forward, hairpin.
# Topology (public side uses documentation ranges RFC 5737):
#
#   l1 192.168.1.10 ─┐                     WAN 203.0.113.2          198.51.100.1
#                    ├─ lan [ gw ] wan ════════════════════ [ isp ] ───────── srv 198.51.100.10
#   l2 192.168.1.20 ─┘  .1               203.0.113.1                      ("the internet")
#
# Run with: ./labs/run.sh b3-nat
set -u
cap() { local ns=$1 ifc=$2 secs=$3; shift 3; timeout "$secs" ip netns exec "$ns" tcpdump -i "$ifc" -t -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
for n in l1 l2 gw isp srv; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done
# LAN switch
ip link add sw type bridge; ip link set sw up
for n in l1 l2 gw; do ip link add p-$n type veth peer name lan netns $n; ip link set p-$n master sw; ip link set p-$n up; ip -n $n link set lan up; done
ip link add wan netns gw type veth peer name wan netns isp; ip -n gw link set wan up; ip -n isp link set wan up
ip link add srv netns isp type veth peer name eth0 netns srv; ip -n isp link set srv up; ip -n srv link set eth0 up
ip -n l1 addr add 192.168.1.10/24 dev lan; ip -n l1 route add default via 192.168.1.1
ip -n l2 addr add 192.168.1.20/24 dev lan; ip -n l2 route add default via 192.168.1.1
ip -n gw addr add 192.168.1.1/24 dev lan; ip -n gw addr add 203.0.113.2/24 dev wan; ip -n gw route add default via 203.0.113.1
ip -n isp addr add 203.0.113.1/24 dev wan; ip -n isp addr add 198.51.100.1/24 dev srv     # isp knows nothing about 192.168.x
ip -n srv addr add 198.51.100.10/24 dev eth0; ip -n srv route add default via 198.51.100.1
for r in gw isp; do ip netns exec $r sysctl -qw net.ipv4.ip_forward=1; done
G="ip netns exec gw"
# A web server on the internet that tells you who it thinks you are
ip netns exec srv socat TCP-LISTEN:80,reuseaddr,fork SYSTEM:'echo "srv sees you as $SOCAT_PEERADDR:$SOCAT_PEERPORT"' 2>/dev/null &
sleep 1

echo "### 1. no NAT: private source leaves the house — the reply has nowhere to go"
echo "(isp's rp_filter off for this step, so we can watch the packet reach srv)"
ip netns exec isp sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.wan.rp_filter=0
cap srv eth0 4 icmp & sleep 1
ip netns exec l1 ping -c1 -W1 198.51.100.10 | grep loss; wait $!
echo "isp: route to 192.168.1.10? → $(ip -n isp route get 192.168.1.10 2>&1 | head -1)"
ip netns exec isp sysctl -qw net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.wan.rp_filter=2

echo; echo "### 2. turn on masquerade (SNAT to the WAN address)"
$G iptables -t nat -A POSTROUTING -o wan -j MASQUERADE
$G iptables -t nat -S POSTROUTING | tail -1
cap gw lan 4 icmp > /tmp/lan.txt & c1=$!
cap gw wan 4 icmp > /tmp/wan.txt & c2=$!; sleep 1
ip netns exec l1 ping -c1 -W1 198.51.100.10 | grep 'bytes from'; wait $c1 $c2
echo "--- gw LAN side:"; cat /tmp/lan.txt
echo "--- gw WAN side:"; cat /tmp/wan.txt

echo; echo "### 3. the conntrack table that makes the reply find its way home"
$G conntrack -L -p icmp 2>/dev/null | sed -E 's/ +mark=0.*//'

echo; echo "### 4. PAT: l1 and l2 both use source port 40000 to srv:80"
echo "l1: $(ip netns exec l1 socat - TCP:198.51.100.10:80,sourceport=40000,reuseaddr </dev/null)"
echo "l2: $(ip netns exec l2 socat - TCP:198.51.100.10:80,sourceport=40000,reuseaddr </dev/null)"
$G conntrack -L -p tcp --dport 80 2>/dev/null | sed -E 's/ +mark=0.*//; s/^tcp +6 +[0-9]+ //'

echo; echo "### 5. unsolicited inbound: srv → 203.0.113.2:8080 (no forward rule)"
ip netns exec l1 socat TCP-LISTEN:8080,reuseaddr,fork SYSTEM:'echo "l1 web server - you are $SOCAT_PEERADDR"' 2>/dev/null &
sleep 1
echo "srv: $(ip netns exec srv socat - TCP:203.0.113.2:8080,connect-timeout=2 </dev/null 2>&1 | sed 's/.*E //')"

echo; echo "### 6. DNAT port-forward 203.0.113.2:8080 → 192.168.1.10:8080"
$G iptables -t nat -A PREROUTING -i wan -p tcp --dport 8080 -j DNAT --to-destination 192.168.1.10:8080
$G iptables -t nat -S PREROUTING | tail -1
echo "srv: $(ip netns exec srv socat - TCP:203.0.113.2:8080 </dev/null 2>&1)"
$G conntrack -L -p tcp --dport 8080 2>/dev/null | sed -E 's/ +mark=0.*//; s/^tcp +6 +[0-9]+ //'

echo; echo "### 7. hairpin: l2 (inside) uses the PUBLIC address 203.0.113.2:8080"
echo "l2: $(ip netns exec l2 socat - TCP:203.0.113.2:8080,connect-timeout=2 </dev/null 2>&1 | sed 's/.*E //')"
echo "--- 7a. add DNAT for LAN-side traffic only"
$G iptables -t nat -A PREROUTING -i lan -d 203.0.113.2 -p tcp --dport 8080 -j DNAT --to-destination 192.168.1.10:8080
cap l2 lan 4 tcp port 8080 > /tmp/l2.txt & c=$!; sleep 1
echo "l2: $(ip netns exec l2 socat - TCP:203.0.113.2:8080,connect-timeout=2 </dev/null 2>&1 | sed 's/.*E //')"
wait $c; echo "--- what l2 saw:"; sed -E 's/, (win|options).*//' /tmp/l2.txt | head -4
echo "--- 7b. add SNAT so l1 replies through gw instead of straight to l2"
$G iptables -t nat -A POSTROUTING -o lan -s 192.168.1.0/24 -d 192.168.1.10 -p tcp --dport 8080 -j MASQUERADE
echo "l2: $(ip netns exec l2 socat - TCP:203.0.113.2:8080,connect-timeout=2 </dev/null 2>&1)"
