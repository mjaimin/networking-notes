#!/usr/bin/env bash
# Run a lab inside a throwaway privileged container (nicolaka/netshoot).
# Labs build their own network namespaces *inside* the container, so the
# host network is never touched. Output is printed and saved to labs/output/.
#
#   ./labs/run.sh a2-l2-arp          # isolated namespace lab
#   ./labs/run.sh --host a0-capture  # lab that captures on the host's real NIC
set -euo pipefail

IMAGE=nicolaka/netshoot:v0.13
HERE=$(cd "$(dirname "$0")" && pwd)

net_args=(--privileged)
filter=(cat)
if [[ ${1:-} == --host ]]; then
  # Host mode: share the host's network stack, read-only capture rights only.
  net_args=(--net=host --cap-add NET_RAW --cap-add NET_ADMIN)
  # Real MACs and this host's public IPs never reach the (public) repo.
  pub4=$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1)
  filter=("$HERE/sanitize.pl" --pub4 "$pub4")
  for p6 in $(ip -6 addr show scope global 2>/dev/null | grep -oE '([0-9a-f]{1,4}:){3}[0-9a-f]{1,4}' | cut -d: -f1-3 | sort -u); do
    filter+=(--pub6 "$p6")
  done
  shift
fi

lab=${1:?usage: run.sh [--host] <lab-name>}
script="$HERE/$lab.sh"
[[ -f $script ]] || { echo "no such lab: $script" >&2; exit 1; }

mkdir -p "$HERE/output"
docker run --rm "${net_args[@]}" -e HOST_IF="${HOST_IF:-eth0}" \
  -v "$HERE:/labs:ro" "$IMAGE" bash "/labs/$lab.sh" 2>&1 \
  | "${filter[@]}" | tee "$HERE/output/$lab.txt"
