# B1 — Bridged mode: one L2 segment, one subnet, one DHCP server for everyone.
# Topology — a "home router" and three hosts on one Linux bridge:
#
#   rtr 192.168.50.1 (DHCP server) ─┐
#   h1 (DHCP client) ───────────────┼── br0
#   h2 (DHCP client) ───────────────┤
#   h3 (DHCP client) ───────────────┘
#
# Then: a loop between two bridges, without and with STP.
# Run with: ./labs/run.sh b1-bridged
set -u
cap() { local ns=$1 secs=$2; shift 2; timeout "$secs" ip netns exec "$ns" tcpdump -i eth0 -t -e -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1

ip link add br0 type bridge; ip link set br0 up
i=0
for n in rtr h1 h2 h3; do
  i=$((i+1))
  ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  ip link add p-$n type veth peer name eth0 netns $n
  ip -n $n link set eth0 address 02:00:00:00:50:0$i
  ip -n $n link set eth0 up; ip -n $n link set lo up
  ip link set p-$n master br0; ip link set p-$n up
done
ip -n rtr addr add 192.168.50.1/24 dev eth0

# DHCP server on the "router"
cat > /tmp/udhcpd.conf <<CONF
start 192.168.50.100
end   192.168.50.150
interface eth0
option subnet 255.255.255.0
option router 192.168.50.1
option dns    192.168.50.1
option lease  3600
lease_file /tmp/udhcpd.leases
CONF
touch /tmp/udhcpd.leases
ip netns exec rtr udhcpd -f /tmp/udhcpd.conf >/dev/null 2>&1 &
# Minimal udhcpc hook: apply the leased address + default route
cat > /tmp/dhcp-hook.sh <<'HOOK'
#!/bin/sh
[ "$1" = bound ] || exit 0
ip addr add "$ip/$mask" dev "$interface"
[ -n "$router" ] && ip route add default via "$router"
HOOK
chmod +x /tmp/dhcp-hook.sh
sleep 2

echo "### 1. h1 asks for an address (DORA) — captured on h3, a bystander"
timeout 6 ip netns exec h3 tshark -l -i eth0 -f 'udp port 67 or udp port 68' -T fields -E separator='|' \
  -e eth.src -e eth.dst -e ip.src -e ip.dst -e dhcp.option.dhcp -e dhcp.ip.your 2>/dev/null > /tmp/h3dhcp.txt & sleep 2
ip netns exec h1 udhcpc -i eth0 -n -q -s /tmp/dhcp-hook.sh >/dev/null 2>&1
wait $!
awk -F'|' 'BEGIN{t[1]="DISCOVER";t[2]="OFFER";t[3]="REQUEST";t[5]="ACK"}
  {printf "%-9s %s > %s   %s > %s%s\n", t[$5], $1, $2, $3, $4, ($6!="0.0.0.0" && $6!="" ? "   yiaddr=" $6 : "")}' /tmp/h3dhcp.txt

echo; echo "### 2. h2 and h3 too — everyone leases from the same server, same subnet"
for n in h2 h3; do ip netns exec $n udhcpc -i eth0 -n -q -s /tmp/dhcp-hook.sh >/dev/null 2>&1; done
for n in h1 h2 h3; do printf '%-3s %s   gw: %s\n' $n "$(ip -n $n -4 -o addr show eth0 | awk '{print $4}')" "$(ip -n $n route | awk '/default/{print $3}')"; done

echo; echo "### 3. h1 reaches h3 directly — no router hop (TTL stays 64)"
H3=$(ip -n h3 -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
ip netns exec h1 ping -c1 -W1 $H3 | grep 'bytes from'

echo; echo "### 4. the bridge's view: ports and learned MACs"
bridge link show | awk '{print $2, $6, $7, $8, $9, $10}'
bridge fdb show br br0 | grep -v permanent
echo "MAC ageing time: $(( $(cat /sys/class/net/br0/bridge/ageing_time) / 100 )) s"

echo; echo "### 5. a loop WITHOUT STP: brA and brB joined by two cables"
ip link del br0
ip link add brA type bridge; ip link add brB type bridge
ip link set brA type bridge stp_state 0; ip link set brB type bridge stp_state 0
ip link add l1a type veth peer name l1b; ip link add l2a type veth peer name l2b
ip link set l1a master brA; ip link set l2a master brA
ip link set l1b master brB; ip link set l2b master brB
ip netns add x; ip link add px type veth peer name eth0 netns x
ip -n x link set eth0 up; ip -n x addr add 10.9.9.1/24 dev eth0; ip link set px master brA
for d in brA brB l1a l1b l2a l2b px; do ip link set $d up; done
sleep 1
before=$(cat /sys/class/net/l1a/statistics/tx_packets)
ip netns exec x arping -c1 -w1 -I eth0 10.9.9.9 >/dev/null 2>&1   # ONE broadcast frame
sleep 1
after=$(cat /sys/class/net/l1a/statistics/tx_packets)
echo "one broadcast in → $((after-before)) frames out of l1a in ~1 s  (broadcast storm)"
ip link set l2a down   # stop the storm

echo; echo "### 6. same loop WITH STP (forward delay shortened to 4 s)"
for b in brA brB; do ip link set $b type bridge stp_state 1 forward_delay 400 hello_time 100; done
ip link set l2a up
sleep 10
echo "port states:"
bridge link show | grep -E 'l1|l2' | awk '{print "  " $2, $NF=="" ? "" : "", $0}' | sed -E 's/.*(l[12][ab])[^ ]* .*state ([a-z]+).*/  \1  \2/'
before=$(cat /sys/class/net/l1a/statistics/tx_packets)
ip netns exec x arping -c1 -w1 -I eth0 10.9.9.9 >/dev/null 2>&1
sleep 1
after=$(cat /sys/class/net/l1a/statistics/tx_packets)
echo "one broadcast in → $((after-before)) frames out of l1a in ~1 s  (BPDUs + the one ARP)"
