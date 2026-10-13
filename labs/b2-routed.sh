# B2 — Routed mode: separate subnets, connected by routers, addresses untouched.
# Topology:
#
#   a1 10.1.0.10 ── R1 ══ transit 10.255.0.0/30 ══ R2 ── b1 10.2.0.10
#      LAN-A 10.1.0.0/24  .1   .2                  LAN-B 10.2.0.0/24
#
# Plus router-on-a-stick: R1 routes between VLAN 10 and VLAN 20 over one trunk.
# Run with: ./labs/run.sh b2-routed
set -u
cap() { local ns=$1 ifc=$2 secs=$3; shift 3; timeout "$secs" ip netns exec "$ns" tcpdump -i "$ifc" -t -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
for n in a1 R1 R2 b1 v10 v20; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done
link() { ip link add $2 netns $1 type veth peer name $4 netns $3; ip -n $1 link set $2 up; ip -n $3 link set $4 up; }
link a1 eth0 R1 lan;   link R1 wan R2 wan;   link R2 lan b1 eth0
ip -n a1 addr add 10.1.0.10/24 dev eth0;  ip -n a1 route add default via 10.1.0.1
ip -n R1 addr add 10.1.0.1/24 dev lan;    ip -n R1 addr add 10.255.0.1/30 dev wan
ip -n R2 addr add 10.255.0.2/30 dev wan;  ip -n R2 addr add 10.2.0.1/24 dev lan
ip -n b1 addr add 10.2.0.10/24 dev eth0;  ip -n b1 route add default via 10.2.0.1
for r in R1 R2; do ip netns exec $r sysctl -qw net.ipv4.ip_forward=1; done
sleep 1

echo "### 1. only connected routes — R1 has never heard of 10.2.0.0/24"
echo "--- R1:"; ip -n R1 route
ip netns exec a1 ping -c1 -W1 10.2.0.10 | grep -E 'From|loss'

echo; echo "### 2. half the job: R1 learns LAN-B, R2 still has no route back to LAN-A"
ip -n R1 route add 10.2.0.0/24 via 10.255.0.2
half() {
  cap b1 eth0 4 icmp > /tmp/b1.txt &
  cap R2 wan 4 icmp > /tmp/r2wan.txt & sleep 1
  ip netns exec a1 ping -c1 -W1 10.2.0.10 | grep -E 'loss'
  wait
  echo "--- arriving at R2 (wan):"; cat /tmp/r2wan.txt
  echo "--- at b1 (destination):"; grep . /tmp/b1.txt || echo "(nothing)"
}
echo "2a. R2 rp_filter = $(ip netns exec R2 sysctl -n net.ipv4.conf.wan.rp_filter) (all=$(ip netns exec R2 sysctl -n net.ipv4.conf.all.rp_filter))"
half
echo "R2 reverse-path drops: $(ip netns exec R2 nstat -az TcpExtIPReversePathFilter | awk '/IPReverse/{print $2}')"
echo
echo "2b. same, with rp_filter off on R2"
ip netns exec R2 sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.wan.rp_filter=0
half
echo "--- R2 deciding on b1's reply: $(ip -n R2 route get 10.1.0.10 2>&1 | head -1)"
ip netns exec R2 sysctl -qw net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.wan.rp_filter=2

echo; echo "### 3. both directions routed"
ip -n R2 route add 10.1.0.0/24 via 10.255.0.1
ip netns exec a1 ping -c1 -W1 10.2.0.10 | grep -E 'bytes from'
ip netns exec a1 traceroute -n -q1 -w1 -I 10.2.0.10 | tail -n +2

echo; echo "### 4. the server sees the client's REAL address (no NAT anywhere)"
ip netns exec b1 socat TCP-LISTEN:8000,reuseaddr SYSTEM:'echo "you are $SOCAT_PEERADDR:$SOCAT_PEERPORT"' 2>/dev/null &
sleep 1
ip netns exec a1 socat - TCP:10.2.0.10:8000 </dev/null

echo; echo "### 5. routing tables at the end"
for n in a1 R1 R2 b1; do echo "--- $n"; ip -n $n route | grep -v 'proto kernel'; done

echo; echo "### 6. router-on-a-stick: one trunk, two VLANs, R1 routes between them"
ip link add sw type bridge vlan_filtering 1; ip link set sw up
ip link add trunk netns R1 type veth peer name p-trunk; ip link set p-trunk master sw; ip link set p-trunk up
ip -n R1 link set trunk address 02:00:00:00:01:ff; ip -n R1 link set trunk up
for v in 10 20; do
  ip -n R1 link add link trunk name trunk.$v type vlan id $v
  ip -n R1 addr add 172.16.$v.1/24 dev trunk.$v; ip -n R1 link set trunk.$v up
  bridge vlan add dev p-trunk vid $v                               # tagged on the trunk
  ip link add p-v$v type veth peer name eth0 netns v$v
  ip link set p-v$v master sw; ip link set p-v$v up
  bridge vlan del dev p-v$v vid 1; bridge vlan add dev p-v$v vid $v pvid untagged   # access port
  ip -n v$v link set eth0 address 02:00:00:00:00:$v
  ip -n v$v addr add 172.16.$v.10/24 dev eth0; ip -n v$v link set eth0 up
  ip -n v$v route add default via 172.16.$v.1
done
bridge vlan del dev p-trunk vid 1
sleep 1
bridge vlan show | grep -vE '^(sw|lan|wan)' | grep .
cap R1 trunk 4 -e icmp & sleep 1
ip netns exec v10 ping -c1 -W1 172.16.20.10 | grep 'bytes from'
wait
