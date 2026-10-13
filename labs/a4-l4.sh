# A4 — L4: TCP handshake/teardown, states, refused vs timed out, UDP, loss.
# Topology:  client 10.0.0.1 ──veth── server 10.0.0.2
# Run with: ./labs/run.sh a4-l4
set -u
cap() { local ns=$1 secs=$2; shift 2; timeout "$secs" ip netns exec "$ns" tcpdump -i eth0 -t -n -l "$@" 2>/dev/null; }
sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
for n in client server; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done
ip link add eth0 netns client type veth peer name eth0 netns server
ip -n client addr add 10.0.0.1/24 dev eth0; ip -n client link set eth0 up
ip -n server addr add 10.0.0.2/24 dev eth0; ip -n server link set eth0 up
C="ip netns exec client"; S="ip netns exec server"
ms() { echo $(( ${EPOCHREALTIME/./} / 1000 )); }

# Server: answer "hello" on 7000, one process per connection
$S socat TCP-LISTEN:7000,reuseaddr,fork SYSTEM:'echo hello-from-server' 2>/dev/null &
sleep 1

echo "### 1. listening sockets on the server (ss -tlnp)"
$S ss -tln

echo; echo "### 2. full TCP life cycle: handshake, data, teardown"
cap server 4 tcp port 7000 & sleep 1
(echo hi; sleep 0.3) | $C socat - TCP:10.0.0.2:7000
wait $!

echo; echo "### 3. socket states right after: whoever sent the FIRST FIN holds TIME_WAIT"
echo "--- server:"; $S ss -tan | grep -E 'State|7000'
echo "--- client:"; $C ss -tan | grep -E 'State|7000' || echo "(no socket left)"

echo; echo "### 4. ephemeral port range the client picks from"
$C sysctl net.ipv4.ip_local_port_range

echo; echo "### 5. closed port → RST → 'Connection refused' (instant)"
cap server 3 tcp port 9999 & sleep 1
start=$(ms); $C socat - TCP:10.0.0.2:9999 </dev/null 2>&1 | sed 's/.*E //'
echo "took $(( $(ms)-start )) ms"; wait $!

echo; echo "### 6. firewall DROP → SYN retransmits → 'timed out' (-ttt = gap since previous packet)"
$C sysctl net.ipv4.tcp_syn_retries net.ipv4.tcp_syn_linear_timeouts 2>/dev/null
$S iptables -A INPUT -p tcp --dport 7000 -j DROP
timeout 17 $S tcpdump -i eth0 -ttt -n -l tcp port 7000 2>/dev/null | sed -E 's/, win.*//' & sleep 1
start=$(ms); $C socat - TCP:10.0.0.2:7000,connect-timeout=15 </dev/null 2>&1 | sed 's/.*E //'
echo "took $(( $(ms)-start )) ms"; wait $!
$S iptables -F INPUT

echo; echo "### 7. firewall REJECT variants — what the client is told"
for how in "tcp-reset" "icmp-port-unreachable" "icmp-host-prohibited"; do
  $S iptables -A INPUT -p tcp --dport 7000 -j REJECT --reject-with $how
  printf '%-24s → %s\n' "$how" "$($C socat - TCP:10.0.0.2:7000,connect-timeout=3 </dev/null 2>&1 | sed 's/.*E //')"
  $S iptables -F INPUT
done

echo; echo "### 8. UDP: no handshake; closed port answered by ICMP port unreachable"
$S socat UDP-RECVFROM:6000,fork SYSTEM:'echo udp-pong' 2>/dev/null &
sleep 1
cap server 4 'udp or icmp' & sleep 1
echo ping | $C socat -T1 - UDP:10.0.0.2:6000
echo ping | $C socat -T1 - UDP:10.0.0.2:6001 2>&1 | sed 's/.*E //'
wait $!

echo; echo "### 9. 20% packet loss on the link → TCP retransmits, the app never notices"
if $S tc qdisc add dev eth0 root netem loss 20% 2>/dev/null; then
  $S socat TCP-LISTEN:7001,reuseaddr SYSTEM:'head -c 200000 /dev/zero' 2>/dev/null &
  sleep 1
  bytes=$($C socat -u TCP:10.0.0.2:7001 - | wc -c)
  echo "client received $bytes bytes (expected 200000)"
  $S nstat -az TcpRetransSegs TcpExtTCPLostRetransmit 2>/dev/null | grep -v '^#'
  $S tc qdisc del dev eth0 root
else
  echo "(netem not available on this kernel — skipped)"
fi
