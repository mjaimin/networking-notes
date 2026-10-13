# A0 — Encapsulation on a real request.
# Captures one plain-HTTP request to example.com on the host NIC and shows
# the same frame as one-line summary, per-layer decode and raw hex.
# IPv4 only: the repo is public and IPv6 addresses would expose the ISP prefix.
# Run with: ./labs/run.sh --host a0-encapsulation
set -u
IF=${HOST_IF:-eth0}
PCAP=/tmp/a0.pcap

echo "### capture on $IF: ip host example.com and tcp port 80"
tcpdump -i "$IF" -n -U -w "$PCAP" 'ip and host example.com and tcp port 80' 2>/dev/null &
sleep 1
curl -4 -s -o /dev/null -w 'curl: HTTP %{http_code} from %{remote_ip}\n' http://example.com
sleep 1; kill %1; wait 2>/dev/null

echo; echo "### 1. one line per frame (-e adds the L2 header)"
tcpdump -r "$PCAP" -e -n 2>/dev/null | cut -c17-

echo; echo "### 2. the HTTP GET frame, decoded layer by layer"
tshark -n -r "$PCAP" -Y http.request -O eth,ip,tcp,http 2>/dev/null \
  | grep -vE '^\s*\[|Status|Stream index|completeness|: (Absent|Present)|LG bit|IG bit|Address: |Timestamp|Kind: |Length: 10|Reserved|Accurate|Congestion|ECN-Echo|Urgent|Option|raw|Explicit|Codepoint|Reserved bit|More fragments|Don.t fragment: '

echo; echo "### 3. same frame as raw bytes (eth | ip | tcp | http)"
tshark -n -r "$PCAP" -Y http.request -x 2>/dev/null | head -9
