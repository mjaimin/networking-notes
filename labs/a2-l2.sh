# A2 — L2: switching, ARP, flooding, VLANs.
# Topology (all inside the container):
#
#   h1 (10.0.0.1) ─┐
#   h2 (10.0.0.2) ─┼─ br0 (Linux bridge = software switch)
#   h3 (10.0.0.3) ─┘
#
# Run with: ./labs/run.sh a2-l2
set -u
q() { "$@" >/dev/null 2>&1; }
# Every capture runs under `timeout` so a missing packet can't hang the lab.
cap() { local ns=$1 secs=$2; shift 2; timeout "$secs" ip netns exec "$ns" tcpdump -i eth0 -e -n -l "$@" 2>/dev/null | cut -c17-; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1

ip link add br0 type bridge
ip link set br0 up
for i in 1 2 3; do
  ip netns add h$i
  ip netns exec h$i sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  # veth pair: "eth0" inside the host, "p$i" plugged into the bridge
  ip link add p$i type veth peer name eth0 netns h$i
  ip -n h$i link set eth0 address 02:00:00:00:00:0$i
  ip -n h$i addr add 10.0.0.$i/24 dev eth0
  ip -n h$i link set eth0 up; ip -n h$i link set lo up
  ip link set p$i master br0; ip link set p$i up
done
sleep 2

echo "### 1. h1 pings h2 — capture on h3 (a bystander on the same switch)"
cap h3 4 > /tmp/h3.txt & sleep 1
ip netns exec h1 ping -c2 -W1 10.0.0.2 | grep -E 'bytes from|loss'
wait
echo "--- what h3 saw:"; cat /tmp/h3.txt

echo; echo "### 2. the same exchange as seen by h2 (the target)"
ip netns exec h1 ip neigh flush all
ip netns exec h2 ip neigh flush all
cap h2 4 -c 4 & sleep 1
ip netns exec h1 ping -c2 -W1 10.0.0.2 >/dev/null; wait

echo; echo "### 3. h1's ARP cache (ip neigh)"
ip netns exec h1 ip neigh

echo; echo "### 4. the switch's MAC table (bridge fdb, learned entries only)"
bridge fdb show br br0 | grep -v permanent

echo; echo "### 5. gratuitous ARP: h3 announces itself unasked (arping -U)"
cap h1 4 -c 1 arp & sleep 1
q ip netns exec h3 arping -U -c1 -I eth0 10.0.0.3; wait

echo; echo "### 6. VLANs: h1+h2 in VLAN 10, h3 moved to VLAN 20 (same physical switch)"
ip link set br0 type bridge vlan_filtering 1
for p in p1 p2; do bridge vlan del dev $p vid 1; bridge vlan add dev $p vid 10 pvid untagged; done
bridge vlan del dev p3 vid 1; bridge vlan add dev p3 vid 20 pvid untagged
bridge vlan show | grep -E 'p[123]|port'
ip netns exec h1 ip neigh flush all
cap h3 5 > /tmp/h3v.txt & sleep 1
echo -n "h1 -> h2 (VLAN 10): "; ip netns exec h1 ping -c1 -W1 10.0.0.2 | grep -oE '[0-9]+% packet loss'
echo -n "h1 -> h3 (VLAN 20): "; ip netns exec h1 ping -c1 -W1 10.0.0.3 | grep -oE '[0-9]+% packet loss'
wait
echo "--- frames h3 saw: $(grep -c . /tmp/h3v.txt)"; cat /tmp/h3v.txt

echo; echo "### 7. a trunk: h4 is VLAN-aware (sub-interface eth0.10), p4 carries tagged VLAN 10"
ip netns add h4; ip netns exec h4 sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
ip link add p4 type veth peer name eth0 netns h4
ip -n h4 link set eth0 address 02:00:00:00:00:04; ip -n h4 link set eth0 up
ip -n h4 link add link eth0 name eth0.10 type vlan id 10
ip -n h4 addr add 10.0.0.4/24 dev eth0.10; ip -n h4 link set eth0.10 up
ip link set p4 master br0; ip link set p4 up
bridge vlan del dev p4 vid 1; bridge vlan add dev p4 vid 10     # tagged (no "untagged")
sleep 1
echo "--- on h4's physical eth0 (the trunk): frames carry an 802.1Q tag"
cap h4 4 -c 4 & sleep 1
ip netns exec h1 ping -c1 -W1 10.0.0.4 >/dev/null; wait
echo "--- on h1's port (access): same traffic, no tag"
cap h1 4 -c 2 icmp & sleep 1
ip netns exec h1 ping -c1 -W1 10.0.0.4 >/dev/null; wait
