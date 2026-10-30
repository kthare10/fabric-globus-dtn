#!/usr/bin/env bash
# probe_facility_port.sh - find out what a partner's L3 facility port hands out,
# without touching the management path.
#
# FABRIC advertises a facility port's VLAN range and nothing else: the prefix, the
# gateway and whether the partner NATs are all on the partner's side. Before
# asking them, see what the port already offers. This brings the interface up on
# a throwaway NetworkManager profile that asks for DHCPv4 and IPv6 autoconf, with
# every route it learns - default routes included - put in a side table, so the
# main table and eth0 never change. It then reports:
#
#   - what DHCPv4 / router advertisements assigned, and the gateways
#   - whether that address reaches the internet, and the address the far side
#     sees (a different one means NAT, and Globus cannot be reached inbound
#     through NAT)
#   - with --sniff, what is on the wire when nothing answered
#
# Everything is removed afterwards: profile, side table, rules, and the VLAN
# device if this script created it. The last line is machine-readable:
#   PROBE iface=... addr4=... gw4=... seen4=... addr6=... gw6=... seen6=...
#
# A DHCP lease is not an assignment. Use what this finds only once the partner
# confirms it is yours to keep (a static lease or a reserved address).
#
# Usage:
#   sudo ./probe_facility_port.sh --iface eth2 [--wait 45] [--table 199] [--sniff 20]
set -uo pipefail

IFACE=""; WAIT=45; TABLE=199; PRIO=999; SNIFF=0; PROFILE="fp-probe"

while [ $# -gt 0 ]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2;;
    --wait)  WAIT="$2"; shift 2;;
    --table) TABLE="$2"; shift 2;;
    --sniff) SNIFF="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)" >&2; exit 2; }
[ -n "$IFACE" ] || { echo "ERROR: --iface is required" >&2; exit 2; }
command -v nmcli >/dev/null || { echo "ERROR: needs NetworkManager (nmcli)" >&2; exit 2; }

PARENT=""; VID=""; CREATED=0
case "$IFACE" in *.*) PARENT="${IFACE%.*}"; VID="${IFACE##*.}";; esac
if [ -n "$PARENT" ]; then
  ip link show "$PARENT" >/dev/null 2>&1 || { echo "ERROR: no parent interface $PARENT" >&2; exit 2; }
  ip link show "$IFACE" >/dev/null 2>&1 || CREATED=1
else
  ip link show "$IFACE" >/dev/null 2>&1 || { echo "ERROR: no interface $IFACE" >&2; exit 2; }
fi

# NetworkManager auto-creates a "Wired connection N" profile for a new NIC and
# brings it up with DHCPv4 + IPv6 autoconf. On a facility port whose partner
# sends router advertisements, that silently puts a SECOND default route in the
# main table - next to management's - and holds the interface. That profile is
# NetworkManager's guess, not anyone's configuration, so it is removed here and
# NetworkManager is told not to recreate one for this NIC.
release_nm_auto_profile() {
  local dev="$1" mac name
  command -v nmcli >/dev/null 2>&1 || return 0
  mac="$(cat "/sys/class/net/$dev/address" 2>/dev/null || true)"
  install -d -m 0755 /etc/NetworkManager/conf.d
  printf '[main]\nno-auto-default=interface-name:%s%s\n' "$dev" "${mac:+,mac:$mac}" \
    > "/etc/NetworkManager/conf.d/90-no-auto-default-$dev.conf"
  nmcli general reload conf >/dev/null 2>&1 || true
  # Match on the bound interface name as well as the active device: an inactive
  # auto profile shows no device, yet is bound to this NIC and can still win
  # the race for it at the next boot.
  nmcli -t -f NAME,DEVICE connection show 2>/dev/null | while IFS=: read -r name d; do
    case "$name" in "Wired connection "[0-9]*) ;; *) continue;; esac
    [ "$d" = "$dev" ] || \
      [ "$(nmcli -g connection.interface-name connection show "$name" 2>/dev/null)" = "$dev" ] || continue
    echo "   NetworkManager's automatic profile '$name' had configured $dev:"
    { ip -o addr show dev "$dev" | grep -v " fe80:"; ip route show dev "$dev"; ip -6 route show dev "$dev"; } \
      2>/dev/null | sed 's/^/     /'
    nmcli connection delete "$name" >/dev/null 2>&1 && echo "   removed it (no-auto-default set for $dev)"
  done
}
release_nm_auto_profile "$IFACE"
sleep 2   # let NetworkManager finish removing what that profile configured

# Refuse to probe an interface something else already configured: taking it over
# would drop that configuration, and if it is the live uplink, the endpoint.
if ip -o addr show dev "$IFACE" 2>/dev/null | grep -E "inet6? " | grep -vq " fe80:"; then
  echo "ERROR: $IFACE already has addresses - probing would replace them:" >&2
  ip -o addr show dev "$IFACE" | sed 's/^/       /' >&2
  exit 2
fi

# RA-learned routes carry an "expires Nsec" countdown that changes every second;
# strip it so only a real change to the management defaults is reported.
mgmt_defaults() { { ip -4 route show default; ip -6 route show default; } | sed -E 's/ expires [0-9]+sec//'; }
MGMT_BEFORE="$(mgmt_defaults)"

cleanup() {
  nmcli connection delete "$PROFILE" >/dev/null 2>&1 || true
  while ip rule del priority "$PRIO" 2>/dev/null; do :; done
  while ip -6 rule del priority "$PRIO" 2>/dev/null; do :; done
  ip route flush table "$TABLE" 2>/dev/null || true
  ip -6 route flush table "$TABLE" 2>/dev/null || true
  [ "$CREATED" -eq 1 ] && ip link del "$IFACE" 2>/dev/null || true
  # Leave the device unmanaged, as fablib had it.
  nmcli device set "$IFACE" managed no >/dev/null 2>&1 || true
  local after; after="$(mgmt_defaults)"
  if [ "$after" != "$MGMT_BEFORE" ]; then
    echo "WARN: main-table default routes changed during the probe:" >&2
    echo "  before: $MGMT_BEFORE" >&2
    echo "  after:  $after" >&2
  fi
}
trap cleanup EXIT

echo "== probing $IFACE (wait ${WAIT}s, side table $TABLE)"
nmcli connection delete "$PROFILE" >/dev/null 2>&1 || true
if [ -n "$PARENT" ]; then
  nmcli connection add type vlan con-name "$PROFILE" ifname "$IFACE" dev "$PARENT" id "$VID" \
    autoconnect no >/dev/null
else
  nmcli connection add type ethernet con-name "$PROFILE" ifname "$IFACE" autoconnect no >/dev/null
fi
# route-table puts EVERY learned route, default included, in the side table.
# That is what keeps the main table - and so management - exactly as it was.
# NOT never-default: that makes NetworkManager discard the learned default
# route altogether, and the gateway is half of what the probe is for. The side
# table is what keeps it out of the main table. Fail closed: if NetworkManager
# will not take the table setting, or drops it, do not bring the interface up;
# and if a main-table default via this interface appears anyway (checked below
# once it is up), abort.
if ! nmcli connection modify "$PROFILE" \
      ipv4.method auto ipv4.route-table "$TABLE" ipv4.never-default no ipv4.may-fail yes \
      ipv4.dhcp-timeout "$WAIT" \
      ipv6.method auto ipv6.route-table "$TABLE" ipv6.never-default no ipv6.may-fail yes \
      ipv6.addr-gen-mode eui64 ipv6.ra-timeout "$WAIT" >/dev/null; then
  echo "ERROR: NetworkManager rejected the isolation settings - not probing" >&2
  exit 3
fi
for k in ipv4.route-table ipv6.route-table; do
  [ "$(nmcli -g "$k" connection show "$PROFILE")" = "$TABLE" ] || {
    echo "ERROR: $k did not stick on profile $PROFILE - not probing" >&2; exit 3; }
done
[ -n "$PARENT" ] && nmcli device set "$PARENT" managed yes >/dev/null 2>&1
nmcli device set "$IFACE" managed yes >/dev/null 2>&1 || true

# "up" returns as soon as either family is ready, or fails when neither is.
# Neither is still a result worth reporting, so do not stop on it.
nmcli -w "$((WAIT + 15))" connection up "$PROFILE" >/dev/null 2>&1 || \
  echo "   nothing configured the interface within ${WAIT}s"
# Give the slower family a moment after the first one completes.
sleep 5

# Last line of defence: if anything still put a main-table default (or any
# main-table route) through the probed interface, tear down now - cleanup runs
# on exit - rather than leave management to chance while the probe continues.
# Captured first: piped straight into grep -q under pipefail, an early match
# SIGPIPEs the writer and the pipeline reports failure - hiding the very leak
# this looks for.
MAIN_ROUTES="$({ ip -4 route show table main; ip -6 route show table main; } 2>/dev/null)"
if grep -qE "^default .*dev $IFACE( |$)" <<<"$MAIN_ROUTES"; then
  echo "ERROR: a main-table default route appeared via $IFACE - aborting the probe" >&2
  exit 3
fi

ADDR4="$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')"
ADDR6="$(ip -6 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')"
GW4="$(ip -4 route show table "$TABLE" default 2>/dev/null | awk '{print $3; exit}')"
GW6="$(ip -6 route show table "$TABLE" default 2>/dev/null | awk '{print $3; exit}')"

echo "   IPv4  address ${ADDR4:-none}  gateway ${GW4:-none}"
nmcli -f DHCP4 device show "$IFACE" 2>/dev/null | grep -E "routers|domain_name_servers|dhcp_lease_time|subnet_mask" \
  | sed 's/^/         /'
echo "   IPv6  address ${ADDR6:-none}  gateway ${GW6:-none}"
echo "   side table $TABLE:"
{ ip -4 route show table "$TABLE"; ip -6 route show table "$TABLE"; } 2>/dev/null | sed 's/^/         /'

# What the outside world sees. Source-bound traffic is steered into the side
# table with a temporary rule, so it leaves through the facility port.
SEEN4=""; SEEN6=""
if [ -n "$ADDR4" ] && [ -n "$GW4" ]; then
  if ! ip rule add from "${ADDR4%/*}/32" table "$TABLE" priority "$PRIO"; then
    echo "   IPv4 egress: not tested - could not add the source rule, so the test would use management"
  else
    ping -c3 -W2 -I "${ADDR4%/*}" 8.8.8.8 >/dev/null 2>&1 \
      && echo "   IPv4 egress: ok" || echo "   IPv4 egress: no reply from 8.8.8.8"
    SEEN4="$(curl -4 -s --max-time 8 --interface "${ADDR4%/*}" https://ifconfig.me 2>/dev/null || true)"
  fi
fi
if [ -n "$ADDR6" ] && [ -n "$GW6" ]; then
  if ! ip -6 rule add from "${ADDR6%/*}/128" table "$TABLE" priority "$PRIO"; then
    echo "   IPv6 egress: not tested - could not add the source rule, so the test would use management"
  else
    ping -6 -c3 -W2 -I "${ADDR6%/*}" 2001:4860:4860::8888 >/dev/null 2>&1 \
      && echo "   IPv6 egress: ok" || echo "   IPv6 egress: no reply from 2001:4860:4860::8888"
    SEEN6="$(curl -6 -s --max-time 8 --interface "${ADDR6%/*}" https://ifconfig.me 2>/dev/null || true)"
  fi
fi
for fam in 4 6; do
  a="ADDR$fam"; s="SEEN$fam"; a="${!a%/*}"; s="${!s}"
  [ -n "$a" ] || continue
  if [ -z "$s" ]; then
    echo "   IPv$fam as seen outside: unknown (no HTTPS reply)"
  elif [ "$s" = "$a" ]; then
    echo "   IPv$fam as seen outside: $s - same address, no NAT. Usable for Globus."
  else
    echo "   IPv$fam as seen outside: $s - NOT $a. The partner NATs this; inbound Globus will not work."
  fi
done

if [ "$SNIFF" -gt 0 ] && [ -z "$ADDR4$ADDR6" ]; then
  if command -v tcpdump >/dev/null; then
    echo "== nothing assigned - ${SNIFF}s of what is on the wire (ARP, RA, DHCP, LLDP):"
    timeout "$SNIFF" tcpdump -nni "$IFACE" -c 40 \
      'arp or icmp6 or port 67 or port 68 or ether proto 0x88cc' 2>&1 | sed 's/^/   /'
  else
    echo "== --sniff needs tcpdump (dnf install -y tcpdump)"
  fi
fi

echo "PROBE iface=$IFACE addr4=${ADDR4:-} gw4=${GW4:-} seen4=${SEEN4:-} addr6=${ADDR6:-} gw6=${GW6:-} seen6=${SEEN6:-}"
