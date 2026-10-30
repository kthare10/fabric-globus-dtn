#!/usr/bin/env bash
# host_tune.sh - TCP tuning for a data transfer node (ESnet fasterdata
# recommendations), and jumbo frames on the data interface ONLY.
#
# The MTU is set on the interfaces you name and nowhere else. Raising it on the
# management NIC breaks the path to the host whenever anything between you and
# it is at 1500. Persisted in the NetworkManager profile where there is one;
# setup_globus_dtn_net.sh --mtu does the same for the public uplink.
#
# Usage:
#   sudo ./host_tune.sh [--mtu-iface eth1 [--mtu 9000]]
set -euo pipefail

IFACES=(); MTU=9000
while [ $# -gt 0 ]; do
  case "$1" in
    --mtu-iface) IFACES+=("$2"); shift 2;;
    --mtu)       MTU="$2"; shift 2;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)" >&2; exit 2; }

# A drop-in, not an append to /etc/sysctl.conf: re-running replaces it.
cat > /etc/sysctl.d/90-dtn-tuning.conf <<'EOF'
# https://fasterdata.es.net/host-tuning/linux/
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
net.ipv4.tcp_rmem = 4096 87380 536870912
net.ipv4.tcp_wmem = 4096 65536 536870912
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
EOF
sysctl -q --system
echo "== TCP tuning applied ($(sysctl -n net.ipv4.tcp_congestion_control), rmem_max $(sysctl -n net.core.rmem_max))"

for dev in ${IFACES+"${IFACES[@]}"}; do
  ip link show "$dev" >/dev/null 2>&1 || { echo "   WARN: no interface $dev"; continue; }
  ip link set dev "$dev" mtu "$MTU" && echo "   $dev mtu $MTU"
  prof="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null || true)"
  [ -n "$prof" ] && [ "$prof" != "--" ] && nmcli connection modify "$prof" 802-3-ethernet.mtu "$MTU" >/dev/null 2>&1 || true
done
