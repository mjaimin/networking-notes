# Capstone — map this machine's real network, layer by layer.
# Public-repo safe: MACs and this host's public IPs are replaced by run.sh's
# sanitizer; hops beyond the home router are reported as a *category*
# (CGNAT / public), never as an address. IPv6 addresses are not printed.
# Run with: ./labs/run.sh --host c0-capstone
set -u
private() { [[ $1 =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; }
cgnat()   { [[ $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; }

echo "### 1. interfaces (L1/L2 state + IPv4)"
ip -br -4 addr | grep -vE '^(veth|lo )'
echo; for i in $(ls /sys/class/net); do
  [[ $i == lo || $i == veth* ]] && continue
  printf '%-16s carrier=%s speed=%s mtu=%s master=%s\n' "$i" "$(cat /sys/class/net/$i/carrier 2>/dev/null)" \
    "$(cat /sys/class/net/$i/speed 2>/dev/null)" "$(cat /sys/class/net/$i/mtu)" "$(basename "$(readlink /sys/class/net/$i/master 2>/dev/null)" 2>/dev/null)"
done

echo; echo "### 2. routing table (L3)"
ip -4 route | grep -v veth

echo; echo "### 3. which interface actually wins for the internet?"
ip -4 route get 1.1.1.1 | head -1

echo; echo "### 4. gateway neighbour entries (L2 ↔ L3 glue)"
GW=$(ip -4 route show default | awk 'NR==1{print $3}')
ip -4 neigh show $GW

echo; echo "### 5. DNS configuration"
grep -E '^nameserver|^search' /etc/resolv.conf

echo; echo "### 6. software bridges on this host (B1) and their ports"
for b in $(ls /sys/class/net); do [[ -d /sys/class/net/$b/bridge ]] || continue
  printf '%-16s ports=%s  stp=%s\n' "$b" "$(ls /sys/class/net/$b/brif 2>/dev/null | wc -l)" "$(cat /sys/class/net/$b/bridge/stp_state)"; done

echo; echo "### 7. NAT rules on this host (B3) — Docker's masquerade"
iptables -t nat -S POSTROUTING 2>/dev/null | grep -iE 'MASQUERADE|SNAT' | head -6
echo "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"

echo; echo "### 8. the path out (first 4 hops, public hops shown as a category only)"
traceroute -n -q1 -w1 -m4 1.1.1.1 2>/dev/null | tail -n +2 | while read -r hop ip rest; do
  if [[ $ip == '*' ]]; then kind="(no reply)"; shown='*'
  elif private "$ip"; then kind="private (RFC 1918)"; shown=$ip
  elif cgnat "$ip"; then kind="CGNAT (100.64/10) — ISP-side NAT"; shown="100.64.x.x"
  elif [[ $ip == 1.1.1.1 ]]; then kind="destination"; shown=$ip
  else kind="public ISP router"; shown="<isp-public>"; fi
  printf '  %s  %-14s %s\n' "$hop" "$shown" "$kind"
done

echo; echo "### 9. does my router's WAN address equal my public address?  (CGNAT test, no addresses printed)"
PUB=$(dig -4 +short myip.opendns.com @resolver1.opendns.com | head -1)
HOP2=$(traceroute -n -q1 -w1 -f2 -m2 1.1.1.1 2>/dev/null | awk 'NR==2{print $2}')
if cgnat "$HOP2"; then echo "hop 2 is in 100.64/10 → behind ISP CGNAT (double NAT)"
elif private "$HOP2"; then echo "hop 2 is private → another NAT layer inside the ISP or a second home router"
else echo "hop 2 is a public ISP router → single NAT at my home router (public IP is mine)"; fi
