# A5 — L7: DNS, TLS, HTTP on a real request to example.com.
# Captures are filtered to example.com traffic only (no other browsing leaks
# into the public repo); IPv4 only. TLS is decrypted with curl's SSLKEYLOGFILE.
# Run with: ./labs/run.sh --host a5-l7
set -u
IF=${HOST_IF:-eth0}
PCAP=/tmp/a5.pcap; KEYS=/tmp/tls-keys.txt

echo "### 1. DNS: ask a public resolver directly"
dig -4 @1.1.1.1 example.com A +noall +comments +question +answer +stats | grep -vE '^;; (WHEN|MSG SIZE|SERVER)|^$'

echo; echo "### 2. DNS: walk the hierarchy ourselves (dig +trace): root → .com → example.com"
dig -4 +trace example.com A 2>/dev/null | grep -E 'IN\s+(NS|A)\s|Received' | grep -E '^\.|^com\.|^example\.com\.|Received' | awk '!seen[$1$4]++' | head -14

IP=$(dig -4 @1.1.1.1 +short example.com A | head -1)
echo; echo "### 3. one HTTPS request, captured end to end (target $IP)"
tcpdump -i "$IF" -n -U -w "$PCAP" "(host 1.1.1.1 and udp port 53) or (host $IP and tcp port 443)" 2>/dev/null &
sleep 2
dig -4 @1.1.1.1 +short example.com A >/dev/null
SSLKEYLOGFILE=$KEYS curl -4 -s -o /dev/null --resolve example.com:443:$IP \
  -w 'curl: %{http_version} %{http_code}  dns %{time_namelookup}s  tcp %{time_connect}s  tls %{time_appconnect}s  first-byte %{time_starttransfer}s\n' \
  https://example.com/
sleep 1; kill %1; wait 2>/dev/null

echo; echo "--- 3a. without keys: what the network can see"
tshark -n -r "$PCAP" -Y 'dns or tcp.flags.syn==1 or tls.handshake or tls.app_data' \
  -T fields -E separator='|' -e frame.number -e ip.src -e ip.dst -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null \
  | awk -F'|' '{printf "%-3s %-15s → %-15s %-8s %s\n",$1,$2,$3,$4,substr($5,1,90)}' | head -20

echo; echo "--- 3b. the ClientHello in clear: SNI and ALPN leak the site name and protocol"
tshark -n -r "$PCAP" -Y 'tls.handshake.type == 1' -T fields \
  -e tls.handshake.extensions_server_name -e tls.handshake.extensions_alpn_str -e tls.handshake.extensions.supported_version 2>/dev/null \
  | awk -F'\t' '{print "SNI=" $1 "   ALPN offered=" $2 "   versions=" $3}'
tshark -n -r "$PCAP" -Y 'tls.handshake.type == 2' -T fields -e tls.handshake.ciphersuite -e tls.handshake.extensions.supported_version 2>/dev/null \
  | awk -F'\t' '{print "ServerHello: cipher=" $1 "   chosen version=" $2}'

echo; echo "--- 3c. with the session keys: the HTTP/2 inside TLS"
tshark -n -r "$PCAP" -o tls.keylog_file:$KEYS -Y 'http2.type == 1' -T fields \
  -e http2.streamid -e http2.headers.method -e http2.headers.path -e http2.headers.authority -e http2.headers.status 2>/dev/null \
  | awk -F'\t' '{print "stream " $1 ": " ($2!="" ? $2" "$3" authority="$4 : "status "$5)}'

echo; echo "### 4. certificate chain the server presented"
echo | openssl s_client -connect $IP:443 -servername example.com 2>/dev/null \
  | grep -E '^ *[0-9] s:|^ *i:|Protocol|Cipher is|Verify return' | head -8

echo; echo "### 5. HTTP versions side by side"
for v in --http1.1 --http2 --http3; do
  out=$(curl -4 -s -o /dev/null $v -w '%{http_version} %{http_code} total %{time_total}s' https://example.com/ 2>&1) || out="not supported by this curl build"
  printf '%-9s → %s\n' "$v" "$out"
done

echo; echo "### 6. L7 headers (curl -sI)"
curl -4 -sI https://example.com/ | grep -iE '^(HTTP|content-type|cache-control|server|age|alt-svc)'
