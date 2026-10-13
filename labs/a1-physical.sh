# A1 — Physical layer: what the NIC negotiated and what it counted.
# Run with: ./labs/run.sh --host a1-physical
set -u
IF=${HOST_IF:-eth0}

echo "### 1. negotiated link (ethtool $IF)"
ethtool "$IF" 2>/dev/null | grep -E 'Supported link modes|Advertised link modes|Link partner advertised link modes|Speed|Duplex|Auto-negotiation|Port:|Link detected|^\s+[0-9]+base' 

echo; echo "### 2. same facts straight from the kernel (/sys/class/net/$IF)"
for f in carrier operstate speed duplex mtu; do
  printf '%-10s %s\n' "$f" "$(cat /sys/class/net/$IF/$f 2>/dev/null)"
done

echo; echo "### 3. L1/L2 counters (ip -s -s link)"
ip -s -s link show "$IF"

echo; echo "### 4. driver-level error counters (non-zero or interesting only)"
ethtool -S "$IF" 2>/dev/null | grep -iE 'crc|align|symbol|collision|carrier|fcs|length|drop|miss' | head -20

echo; echo "### 5. driver / firmware"
ethtool -i "$IF" 2>/dev/null | grep -E 'driver|version|bus-info'

echo; echo "### 6. a virtual NIC for comparison (veth has no physical layer)"
ip link add v1 type veth peer name v2 2>/dev/null && ip link set v1 up && ip link set v2 up
ethtool v1 2>/dev/null | grep -E 'Speed|Duplex|Link detected'
ip link del v1 2>/dev/null
