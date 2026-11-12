#!/usr/bin/env bash
# setup_globus_dtn_net.sh - give the Globus DTN a working public path over a
# partner's L3 facility port without losing the FABRIC management path.
#
# The DTN is triple-homed:
#   eth0   FABRIC management (DHCP, default route, bastion/ssh)   - must not change
#   <wan>  facility port, publicly routed prefix from the partner - Globus data plane
#          (IPv4, IPv6, or both - each family gets its own table route and rule)
#   <fab>  optional FABNet, if the DTN also reaches storage inside FABRIC
#
# A second default route in the main table would black-hole management traffic, so
# the uplink gets its own routing table plus a source rule: packets whose source
# is the partner address leave via the partner, everything else keeps using eth0.
# This matters as much for IPv6 as IPv4: FABRIC management is often IPv6, and a
# second IPv6 default would black-hole it just the same.
# Inbound Globus connections arrive on the partner address, so their replies match the
# rule and return symmetrically - which is what Globus Auth and the remote GridFTP
# side require.
#
# Persistence is done twice on purpose:
#   1. the NetworkManager profile carries the address, MTU and (where the installed
#      NM understands route table attributes) the table routes and the rule;
#   2. a systemd oneshot re-asserts table + rule after every boot, because a route
#      that lives only in the running kernel is exactly what disappears after a
#      FABRIC maintenance reboot.
#
# Safe to re-run: every step replaces rather than appends.
#
# Usage:
#   sudo ./setup_globus_dtn_net.sh --iface eth2 \
#        [--addr 198.51.100.10/29 --gw 198.51.100.9] \
#        [--addr6 2001:db8:1::10/64 --gw6 fe80::1] \
#        [--mtu 9000] [--table 100] [--priority 1000] [--profile globus-wan]
# At least one family is required.
set -euo pipefail

IFACE=""; ADDR=""; GW=""; ADDR6=""; GW6=""; TABLE=100; PRIO=1000; MTU=""; PROFILE="globus-wan"

while [ $# -gt 0 ]; do
  case "$1" in
    --iface)    IFACE="$2"; shift 2;;
    --addr)     ADDR="$2"; shift 2;;
    --gw)       GW="$2"; shift 2;;
    --addr6)    ADDR6="$2"; shift 2;;
    --gw6)      GW6="$2"; shift 2;;
    --table)    TABLE="$2"; shift 2;;
    --priority) PRIO="$2"; shift 2;;
    --mtu)      MTU="$2"; shift 2;;
    --profile)  PROFILE="$2"; shift 2;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)" >&2; exit 2; }
[ -n "$IFACE" ] || { echo "ERROR: --iface is required" >&2; exit 2; }
if { [ -n "$ADDR" ] && [ -z "$GW" ]; } || { [ -z "$ADDR" ] && [ -n "$GW" ]; }; then
  echo "ERROR: --addr and --gw go together" >&2; exit 2; fi
if { [ -n "$ADDR6" ] && [ -z "$GW6" ]; } || { [ -z "$ADDR6" ] && [ -n "$GW6" ]; }; then
  echo "ERROR: --addr6 and --gw6 go together" >&2; exit 2; fi
[ -n "$ADDR$ADDR6" ] || { echo "ERROR: give --addr/--gw, --addr6/--gw6, or both" >&2; exit 2; }
[ -z "$ADDR" ]  || case "$ADDR"  in */*) :;; *) echo "ERROR: --addr must be CIDR, e.g. 198.51.100.10/29" >&2; exit 2;; esac
[ -z "$ADDR6" ] || case "$ADDR6" in */*) :;; *) echo "ERROR: --addr6 must be CIDR, e.g. 2001:db8::10/64" >&2; exit 2;; esac

# FABRIC hands the facility port to the VM either untagged (eth2) or VLAN-tagged
# (eth2.4030, which is what Interface.get_device_name() returns in that case). The
# tagged device may not exist yet, so validate the parent and build it if needed.
PARENT=""; VID=""
case "$IFACE" in
  *.*) PARENT="${IFACE%.*}"; VID="${IFACE##*.}";;
esac
if [ -n "$PARENT" ]; then
  ip link show "$PARENT" >/dev/null 2>&1 || { echo "ERROR: no parent interface $PARENT" >&2; exit 2; }
  ip link set dev "$PARENT" up
  ip link show "$IFACE" >/dev/null 2>&1 || \
    ip link add link "$PARENT" name "$IFACE" type vlan id "$VID"
else
  ip link show "$IFACE" >/dev/null 2>&1 || { echo "ERROR: no interface $IFACE" >&2; exit 2; }
fi

net_of() { python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$1"; }
IP=""; SUBNET=""; IP6=""; SUBNET6=""
[ -n "$ADDR" ]  && { IP="${ADDR%/*}";   SUBNET="$(net_of "$ADDR")"; }
[ -n "$ADDR6" ] && { IP6="${ADDR6%/*}"; SUBNET6="$(net_of "$ADDR6")"; }

# Per family: does management already own the main-table default? On FABRIC
# it often does for one family only - at NCSA, management is IPv6 and eth0's
# IPv4 has no gateway at all. Where management has a default, the public side
# is policy-routed only, so management is untouched. Where it has none, nothing
# would be lost by the public uplink taking that family's main default, and
# without it every unbound IPv4 connection - package installs, Globus API
# calls, GridFTP reaching an IPv4-only peer - fails with "Network is unreachable".
# The same rule setup-multihomed.sh applies. Decided once here and persisted,
# so a boot that races the management DHCP cannot flip it.
mgmt_default() { ip "$1" route show default 2>/dev/null | grep -v " dev $IFACE\b" | grep -q .; }
MAIN4=0; MAIN6=0
[ -n "$ADDR" ]  && ! mgmt_default -4 && MAIN4=1
[ -n "$ADDR6" ] && ! mgmt_default -6 && MAIN6=1

echo "== Globus DTN uplink on $IFACE  (table $TABLE, rule priority $PRIO)"
[ -n "$ADDR" ]  && echo "   IPv4 $ADDR via $GW  subnet $SUBNET" \
  "$([ $MAIN4 = 1 ] && echo '- also the main IPv4 default (management has none)')"
[ -n "$ADDR6" ] && echo "   IPv6 $ADDR6 via $GW6  subnet $SUBNET6" \
  "$([ $MAIN6 = 1 ] && echo '- also the main IPv6 default (management has none)')"

# --------------------------------------------------------------- NetworkManager
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
    # Diagnostic only. Under `set -euo pipefail` a grep that matches nothing (a
    # port with no RA leaves only fe80) would otherwise abort the whole script.
    { ip -o addr show dev "$dev" | grep -v " fe80:" || true
      ip route show dev "$dev" || true; ip -6 route show dev "$dev" || true; } \
      2>/dev/null | sed 's/^/     /' || true
    if nmcli connection delete "$name" >/dev/null 2>&1; then
      echo "   removed it (no-auto-default set for $dev)"
    else
      echo "   WARNING: could not delete '$name'; delete it by hand before rebooting" >&2
    fi
  done
}
release_nm_auto_profile "${PARENT:-$IFACE}"

# fablib leaves data-plane NICs unmanaged so it can address them with iproute2.
# An unmanaged device cannot carry a profile, so nothing would survive a reboot.
if command -v nmcli >/dev/null 2>&1; then
  # The profile is created BEFORE the device is handed to NetworkManager. Marking
  # a device managed while it has no profile invites NM to autoconnect a default
  # DHCP one, and a DHCP lease on the public NIC would put a second default route
  # in the main table - the exact lockout this script exists to avoid.
  if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$PROFILE"; then
    echo "   profile '$PROFILE' exists, updating"
  else
    echo "   creating profile '$PROFILE'"
    if [ -n "$PARENT" ]; then
      nmcli connection add type vlan con-name "$PROFILE" ifname "$IFACE" \
        dev "$PARENT" id "$VID" autoconnect no >/dev/null
    else
      nmcli connection add type ethernet con-name "$PROFILE" ifname "$IFACE" \
        autoconnect no >/dev/null
    fi
  fi

  # never-default keeps this connection from ever installing a default route in the
  # main table; that is what protects the management path.
  nmcli connection modify "$PROFILE" \
    connection.interface-name "$IFACE" \
    connection.autoconnect yes >/dev/null
  if [ -n "$ADDR" ]; then
    if [ "$MAIN4" = 1 ]; then
      nmcli connection modify "$PROFILE" ipv4.method manual ipv4.addresses "$ADDR" \
        ipv4.gateway "$GW" ipv4.never-default no ipv4.may-fail no >/dev/null
    else
      nmcli connection modify "$PROFILE" ipv4.method manual ipv4.addresses "$ADDR" \
        ipv4.gateway "" ipv4.never-default yes ipv4.may-fail no >/dev/null
    fi
  else
    nmcli connection modify "$PROFILE" ipv4.method disabled ipv4.addresses "" >/dev/null
  fi
  if [ -n "$ADDR6" ]; then
    # manual, not auto: a router advertisement would otherwise add a second
    # address and a default route the rule below does not cover.
    if [ "$MAIN6" = 1 ]; then
      nmcli connection modify "$PROFILE" ipv6.method manual ipv6.addresses "$ADDR6" \
        ipv6.gateway "$GW6" ipv6.never-default no ipv6.may-fail no >/dev/null
    else
      nmcli connection modify "$PROFILE" ipv6.method manual ipv6.addresses "$ADDR6" \
        ipv6.gateway "" ipv6.never-default yes ipv6.may-fail no >/dev/null
    fi
  else
    nmcli connection modify "$PROFILE" ipv6.method disabled ipv6.addresses "" >/dev/null
  fi

  if [ -n "$MTU" ]; then
    # 802-3-ethernet.mtu applies to VLAN profiles as well; there is no vlan.mtu.
    # A tagged child also cannot exceed its parent, so raise the parent first -
    # otherwise the kernel rejects the child MTU and jumbo frames are dropped
    # later, under load, where it is hardest to diagnose.
    if [ -n "$PARENT" ]; then
      ip link set dev "$PARENT" mtu "$MTU" 2>/dev/null || \
        echo "   WARN: parent $PARENT would not take MTU $MTU; the tagged device cannot exceed it"
    fi
    nmcli connection modify "$PROFILE" 802-3-ethernet.mtu "$MTU" >/dev/null 2>&1 || \
      echo "   WARN: could not store MTU $MTU in the profile"
  fi

  # Route table attributes and routing-rules need NetworkManager >= 1.24 / 1.18.
  # Where they are not understood the systemd unit below is the one that counts,
  # so a failure here is a warning, not an error.
  if [ -n "$ADDR" ]; then
    if nmcli connection modify "$PROFILE" \
          ipv4.routes "$SUBNET 0.0.0.0 table=$TABLE, 0.0.0.0/0 $GW table=$TABLE" >/dev/null 2>&1; then
      echo "   profile IPv4 routes set (table $TABLE)"
    else
      echo "   WARN: this NetworkManager will not store table routes; systemd unit covers it"
    fi
    if nmcli connection modify "$PROFILE" \
          ipv4.routing-rules "priority $PRIO from $IP/32 table $TABLE" >/dev/null 2>&1; then
      echo "   profile IPv4 routing rule set"
    else
      echo "   WARN: this NetworkManager will not store routing rules; systemd unit covers it"
    fi
  fi
  if [ -n "$ADDR6" ]; then
    if nmcli connection modify "$PROFILE" \
          ipv6.routes "$SUBNET6 :: table=$TABLE, ::/0 $GW6 table=$TABLE" >/dev/null 2>&1; then
      echo "   profile IPv6 routes set (table $TABLE)"
    else
      echo "   WARN: this NetworkManager will not store IPv6 table routes; systemd unit covers it"
    fi
    if nmcli connection modify "$PROFILE" \
          ipv6.routing-rules "priority $PRIO from $IP6/128 table $TABLE" >/dev/null 2>&1; then
      echo "   profile IPv6 routing rule set"
    else
      echo "   WARN: this NetworkManager will not store IPv6 routing rules; systemd unit covers it"
    fi
  fi

  nmcli connection modify "$PROFILE" connection.autoconnect yes >/dev/null 2>&1 || true
  [ -n "$PARENT" ] && nmcli device set "$PARENT" managed yes >/dev/null 2>&1 || true
  nmcli device set "$IFACE" managed yes >/dev/null 2>&1 || true
  nmcli connection up "$PROFILE" >/dev/null 2>&1 || \
    echo "   WARN: 'nmcli connection up $PROFILE' failed; applying with iproute2 only"
fi

# ------------------------------------------------------- boot-time re-assertion
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/globus-dtn-pbr.sh <<EOF
#!/usr/bin/env bash
# Generated by setup_globus_dtn_net.sh - re-assert policy routing for the
# facility-port uplink. Idempotent; run at boot by globus-dtn-pbr.service.
#
# Exits non-zero if the address, the table routes or the rule could not be
# installed. Reporting success here would let systemd mark the network
# configured while nothing routes.
set -u
RC=0
IFACE="$IFACE"; IP="$IP"; ADDR="$ADDR"; SUBNET="$SUBNET"; GW="$GW"
IP6="$IP6"; ADDR6="$ADDR6"; SUBNET6="$SUBNET6"; GW6="$GW6"
TABLE="$TABLE"; PRIO="$PRIO"; MTU="${MTU:-}"; PARENT="${PARENT:-}"; VID="${VID:-}"
MAIN4="$MAIN4"; MAIN6="$MAIN6"

if [ -n "\$PARENT" ]; then
  ip link set dev "\$PARENT" up 2>/dev/null
  ip link show "\$IFACE" >/dev/null 2>&1 || \
    ip link add link "\$PARENT" name "\$IFACE" type vlan id "\$VID" 2>/dev/null
fi
ip link set dev "\$IFACE" up 2>/dev/null
[ -n "\$MTU" ] && ip link set dev "\$IFACE" mtu "\$MTU" 2>/dev/null
if [ -n "\$ADDR" ]; then
  ip -4 addr show dev "\$IFACE" | grep -q "inet \$IP/" || ip addr add "\$ADDR" dev "\$IFACE" 2>/dev/null
  ip -4 addr show dev "\$IFACE" | grep -q "inet \$IP/" || RC=1

  ip route replace "\$SUBNET" dev "\$IFACE" scope link table "\$TABLE" || RC=1
  ip route replace default via "\$GW" dev "\$IFACE" table "\$TABLE" || RC=1

  # Match the priority too. A stale rule for the same source at some other priority
  # would otherwise satisfy this test while losing to the main table at 32766.
  ip rule list | grep -qE "^\$PRIO:[[:space:]]+from \$IP(/32)? lookup \$TABLE\$" || {
    ip rule del from "\$IP/32" table "\$TABLE" 2>/dev/null
    ip rule add from "\$IP/32" table "\$TABLE" priority "\$PRIO" || RC=1
  }
  # Only when setup found no management IPv4 default (see setup_globus_dtn_net.sh).
  [ "\$MAIN4" = 1 ] && { ip route replace default via "\$GW" dev "\$IFACE" || RC=1; }
fi

if [ -n "\$ADDR6" ]; then
  # nodad: the address is ours by assignment, and DAD would hold it "tentative"
  # - unusable as a source - for the first seconds after boot.
  ip -6 addr show dev "\$IFACE" | grep -q "inet6 \$IP6/" || \
    ip -6 addr add "\$ADDR6" dev "\$IFACE" nodad 2>/dev/null
  ip -6 addr show dev "\$IFACE" | grep -q "inet6 \$IP6/" || RC=1

  ip -6 route replace "\$SUBNET6" dev "\$IFACE" table "\$TABLE" || RC=1
  # A link-local gateway is only meaningful with the device, which is given.
  ip -6 route replace default via "\$GW6" dev "\$IFACE" table "\$TABLE" || RC=1

  ip -6 rule list | grep -qE "^\$PRIO:[[:space:]]+from \$IP6(/128)? lookup \$TABLE\$" || {
    ip -6 rule del from "\$IP6/128" table "\$TABLE" 2>/dev/null
    ip -6 rule add from "\$IP6/128" table "\$TABLE" priority "\$PRIO" || RC=1
  }
  [ "\$MAIN6" = 1 ] && { ip -6 route replace default via "\$GW6" dev "\$IFACE" || RC=1; }
fi
exit \$RC
EOF
chmod 0755 /usr/local/sbin/globus-dtn-pbr.sh

cat > /etc/systemd/system/globus-dtn-pbr.service <<'EOF'
[Unit]
Description=Policy routing for the Globus DTN facility-port uplink
After=network-online.target NetworkManager-wait-online.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/globus-dtn-pbr.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now globus-dtn-pbr.service >/dev/null 2>&1 || \
  /usr/local/sbin/globus-dtn-pbr.sh
/usr/local/sbin/globus-dtn-pbr.sh   # apply now, regardless of unit state

# ------------------------------------------------------------------- rp_filter
# Strict reverse-path filtering drops inbound Globus packets on a host whose
# default route points somewhere else. Loose mode (2) is the standard fix for a
# policy-routed multihomed DTN.
cat > /etc/sysctl.d/90-globus-dtn.conf <<EOF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${IFACE}.rp_filter = 2
EOF
sysctl -q --system || true

# ---------------------------------------------------------------- verification
echo
# Report only. Each family's table exists only if that family is configured -
# `ip route show table N` errors on a table that does not exist, and under
# set -e that would turn a successful IPv6-only setup into a failure.
echo "-- address"
ip -br addr show dev "$IFACE"
echo "-- table $TABLE"
[ -n "$ADDR" ]  && { ip route show table "$TABLE" 2>/dev/null || true; }
[ -n "$ADDR6" ] && { ip -6 route show table "$TABLE" 2>/dev/null || true; }
echo "-- rules"
[ -n "$ADDR" ]  && { ip rule list | grep -E "lookup $TABLE" || true; }
[ -n "$ADDR6" ] && { ip -6 rule list | grep -E "lookup $TABLE" || true; }
echo "-- main default routes (management's must be unchanged; the uplink's only where management had none)"
ip route show default
ip -6 route show default
echo
echo "Next: confirm the partner routes ${SUBNET}${SUBNET:+ }${SUBNET6} to this VLAN, then from off-site run"
for A in $IP $IP6; do echo "  ping -c3 $A   and   nc -vz $A 443"; done
