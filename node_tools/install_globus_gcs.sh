#!/usr/bin/env bash
# install_globus_gcs.sh - install Globus Connect Server v5.4 on a Rocky 9 DTN and
# open the ports it needs on the public interface.
#
# This only installs and prepares the host. Endpoint registration is a separate
# step (setup_globus_endpoint.sh) because it needs Globus Auth credentials and
# creates cloud-side state that must not be re-created by accident.
#
# GCS prerequisites checked here, because each one fails late and confusingly:
#   - 8 GB RAM minimum
#   - working time sync (an unsynced clock breaks Globus Auth token validation;
#     note that `chronyc tracking` prints a healthy offset even when the last
#     real sync was weeks ago - only the reach column tells the truth)
#   - UTF-8 locale
#   - inbound TCP 443 (control + HTTPS transfer) and 50000-51000 (GridFTP data)
#
# Usage:
#   sudo ./install_globus_gcs.sh [--wan-iface eth2] [--no-firewall]
set -euo pipefail

WAN_IFACE=""; DO_FIREWALL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --wan-iface)   WAN_IFACE="$2"; shift 2;;
    --no-firewall) DO_FIREWALL=0; shift;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)" >&2; exit 2; }

RC=0

# ------------------------------------------------------------------ packages
echo "== installing Globus Connect Server 5.4"
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm || true
dnf install -y https://downloads.globus.org/globus-connect-server/stable/installers/repo/rpm/globus-repo-latest.noarch.rpm
dnf install -y 'dnf-command(config-manager)'
dnf install -y globus-connect-server54

echo "   installed: $(globus-connect-server --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------- memory
MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
if [ "$MEM_GB" -lt 8 ]; then
  echo "   WARN: ${MEM_GB}GB RAM, Globus requires at least 8GB"; RC=1
else
  echo "   memory: ${MEM_GB}GB"
fi

# ------------------------------------------------------------------- locale
if ! locale 2>/dev/null | grep -qi 'utf-\?8'; then
  echo "   setting a UTF-8 locale (GCS refuses to run without one)"
  dnf install -y glibc-langpack-en >/dev/null 2>&1 || true
  localectl set-locale LANG=en_US.UTF-8 2>/dev/null || echo 'LANG=en_US.UTF-8' > /etc/locale.conf
fi

# ---------------------------------------------------------------- time sync
dnf install -y chrony >/dev/null 2>&1 || true
systemctl enable --now chronyd >/dev/null 2>&1 || true
if command -v chronyc >/dev/null 2>&1; then
  # reach == 0 on every source means the clock is free-running no matter how
  # healthy `chronyc tracking` looks. Reach is column 5, not 4 - column 4 is Poll,
  # which is never 0, so testing it would call an unreachable source healthy.
  #   MS Name/IP  Stratum Poll Reach LastRx Last sample
  #   ^?  10.0.0.2      0    6     0      -   ...
  REACHED=$(chronyc -n sources 2>/dev/null | awk 'NR>2 && $5 != "0" {n++} END{print n+0}' || true)
  REACHED=${REACHED:-0}
  if [ "$REACHED" -eq 0 ]; then
    echo "   WARN: no NTP source has ever been reached - Globus Auth will reject tokens"
    chronyc -n sources 2>/dev/null || true
    RC=1
  else
    echo "   time sync: $REACHED source(s) reachable"
  fi
fi

# ----------------------------------------------------------------- firewall
if [ "$DO_FIREWALL" -eq 1 ]; then
  if systemctl is-active --quiet firewalld; then
    ZONES="$(firewall-cmd --get-default-zone)"
    if [ -n "$WAN_IFACE" ]; then
      WZ="$(firewall-cmd --get-zone-of-interface="$WAN_IFACE" 2>/dev/null || true)"
      case "$WZ" in ""|no\ zone*) :;; *) [ "$WZ" = "$ZONES" ] || ZONES="$ZONES $WZ";; esac
    fi
    for z in $ZONES; do
      echo "   opening 443/tcp and 50000-51000/tcp in firewalld zone '$z'"
      firewall-cmd --permanent --zone="$z" --add-port=443/tcp    >/dev/null
      firewall-cmd --permanent --zone="$z" --add-port=50000-51000/tcp >/dev/null
    done
    firewall-cmd --reload >/dev/null
    firewall-cmd --list-ports
  else
    echo "   firewalld is not running - nothing on this host blocks 443 or 50000-51000."
    echo "   Inbound filtering is then entirely upstream; confirm that both"
    echo "   ranges are permitted to this prefix."
  fi
fi

echo
echo "Host is ready. Register the endpoint next with setup_globus_endpoint.sh."
exit $RC
