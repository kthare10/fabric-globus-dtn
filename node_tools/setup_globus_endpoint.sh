#!/usr/bin/env bash
# setup_globus_endpoint.sh - register the GCS endpoint with Globus and turn this
# VM into its Data Transfer Node. Non-interactive: authentication uses a Globus
# Auth service credential, so nothing here waits for a browser.
#
# Run it ONCE per endpoint. `endpoint setup` creates cloud-side state; running it
# twice creates a second endpoint that still bills against your subscription and
# has to be cleaned up by hand. The script therefore refuses to re-register when
# it finds existing state in /etc/globus-dtn, and only re-runs `node setup`.
#
# --owner is a Globus Auth identity username, not a FABRIC account: either a
# person (app.globus.org/settings/identities shows yours) or, for an endpoint that
# should outlive any one person, the service identity
# <GCS_CLI_CLIENT_ID>@clients.auth.globus.org. In that second case pass
# --dont-set-advertised-owner, or collection listings advertise the endpoint as
# owned by "...@clients.auth.globus.org", and grant a human the administrator role
# with setup_globus_collection.sh --admin.
#
# Credentials (never passed on the command line - argv is world-readable in ps):
#   GCS_CLI_CLIENT_ID      service credential UUID from
#   GCS_CLI_CLIENT_SECRET  https://app.globus.org/settings/developers
# Either export them, or put them in a file and pass --creds-file.
# The service identity <CLIENT_ID>@clients.auth.globus.org must be an admin of the
# Globus Auth project given by --project-id.
#
# DNS: none required. `endpoint setup` allocates a gaccess.io subdomain for the
# endpoint and manages its DNS record and Let's Encrypt certificate. The record
# points at whatever --ip-address node setup registers, which is why that address
# must be the public uplink address and not the FABRIC management address that GCS
# would otherwise discover on its own.
#
# Usage:
#   sudo GCS_CLI_CLIENT_ID=... GCS_CLI_CLIENT_SECRET=... ./setup_globus_endpoint.sh \
#        --display-name "My FABRIC DTN (STAR)" \
#        --organization "FABRIC" --contact-email support@fabric-testbed.net \
#        --owner  someone@example.edu \
#        [--dont-set-advertised-owner] \
#        --project-id <globus-auth-project-uuid> \
#        --public-ip 198.51.100.10 [--public-ip6 2001:db8::10] \
#        [--state-dir /etc/globus-dtn] [--force-setup]
# --public-ip may itself be IPv6 for an IPv6-only DTN. With both families, the
# node advertises both and GridFTP data connections use the IPv4 one.
set -euo pipefail

STATE_DIR="/etc/globus-dtn"
DISPLAY_NAME=""; ORGANIZATION=""; CONTACT_EMAIL=""; OWNER=""; PROJECT_ID=""
PUBLIC_IP=""; PUBLIC_IP6=""; CREDS_FILE=""; FORCE_SETUP=0; HIDE_ADVERTISED_OWNER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --display-name)  DISPLAY_NAME="$2"; shift 2;;
    --organization)  ORGANIZATION="$2"; shift 2;;
    --contact-email) CONTACT_EMAIL="$2"; shift 2;;
    --owner)         OWNER="$2"; shift 2;;
    --project-id)    PROJECT_ID="$2"; shift 2;;
    --public-ip)     PUBLIC_IP="$2"; shift 2;;
    --public-ip6)    PUBLIC_IP6="$2"; shift 2;;
    --state-dir)     STATE_DIR="$2"; shift 2;;
    --creds-file)    CREDS_FILE="$2"; shift 2;;
    --force-setup)   FORCE_SETUP=1; shift;;
    --dont-set-advertised-owner) HIDE_ADVERTISED_OWNER=1; shift;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (node setup requires it)" >&2; exit 2; }
# shellcheck disable=SC1090
if [ -n "$CREDS_FILE" ]; then . "$CREDS_FILE"; fi
: "${GCS_CLI_CLIENT_ID:?set GCS_CLI_CLIENT_ID (service credential UUID)}"
: "${GCS_CLI_CLIENT_SECRET:?set GCS_CLI_CLIENT_SECRET (service credential secret)}"
export GCS_CLI_CLIENT_ID GCS_CLI_CLIENT_SECRET
[ -n "$PUBLIC_IP" ] || { echo "ERROR: --public-ip is required" >&2; exit 2; }
command -v globus-connect-server >/dev/null || {
  echo "ERROR: globus-connect-server not installed; run install_globus_gcs.sh first" >&2; exit 2; }

# 0755, not 0700: the identity mapping program runs as gcsweb and has to traverse
# this directory to read identity-map.csv. Every secret in here is 0600 in its own
# right. Re-running this script must not undo that, or mapping breaks silently.
install -d -m 0755 "$STATE_DIR"
# Make it absolute BEFORE the cd: a relative --state-dir would otherwise be
# re-prefixed after the chdir and the key would be written to state/state/.
STATE_DIR="$(cd "$STATE_DIR" && pwd)"
cd "$STATE_DIR"
KEY="$STATE_DIR/deployment-key.json"
ID_FILE="$STATE_DIR/endpoint-id.txt"

# The DTN must actually own the address it is about to advertise, or every inbound
# transfer will be sent to a host that cannot answer.
for A in $PUBLIC_IP $PUBLIC_IP6; do
  ip -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qxi "$A" || {
    echo "ERROR: $A is not configured on this host." >&2
    echo "       Run setup_globus_dtn_net.sh first." >&2
    exit 2; }
done

# ------------------------------------------------------------- endpoint setup
if [ -s "$KEY" ] && [ "$FORCE_SETUP" -eq 0 ]; then
  echo "== endpoint already registered ($KEY exists) - skipping 'endpoint setup'"
else
  [ -n "$DISPLAY_NAME" ] && [ -n "$ORGANIZATION" ] && [ -n "$CONTACT_EMAIL" ] && [ -n "$OWNER" ] || {
    echo "ERROR: --display-name, --organization, --contact-email and --owner are" >&2
    echo "       required when registering a new endpoint" >&2; exit 2; }

  ADV_FLAG=""
  [ "$HIDE_ADVERTISED_OWNER" -eq 1 ] && ADV_FLAG="--dont-set-advertised-owner"

  echo "== registering endpoint '$DISPLAY_NAME'"
  set +e
  OUT=$(globus-connect-server endpoint setup "$DISPLAY_NAME" \
          --organization "$ORGANIZATION" \
          --contact-email "$CONTACT_EMAIL" \
          --owner "$OWNER" \
          ${PROJECT_ID:+--project-id "$PROJECT_ID"} \
          ${ADV_FLAG} \
          --deployment-key "$KEY" \
          --agree-to-letsencrypt-tos 2>&1)
  RC=$?
  set -e
  echo "$OUT"
  [ $RC -eq 0 ] || { echo "ERROR: endpoint setup failed" >&2; exit $RC; }
  chmod 0600 "$KEY"
fi

# The endpoint UUID is printed by setup; deployment-key.json carries the same value
# as its client_id, which is the copy that survives a re-run of this script.
EP_ID="$(grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"${OUT:-}" | head -1 || true)"
if [ -z "$EP_ID" ] && [ -s "$KEY" ]; then
  EP_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("client_id",""))' "$KEY" 2>/dev/null || true)"
fi
[ -n "$EP_ID" ] || { echo "ERROR: could not determine the endpoint UUID" >&2; exit 1; }
printf '%s\n' "$EP_ID" > "$ID_FILE"
chmod 0600 "$ID_FILE"
echo "   endpoint id: $EP_ID  (saved to $ID_FILE)"

# ----------------------------------------------------------------- node setup
# --ip-address pins the advertised address(es) to the uplink prefix. --data-interface
# pins GridFTP data connections to the same address, so they are policy-routed out
# through the public uplink rather than the management NIC.
echo "== configuring this VM as a Data Transfer Node ($PUBLIC_IP${PUBLIC_IP6:+ $PUBLIC_IP6})"
# --data-interface takes an IPv4 address only (GCS 5.4 rejects IPv6 there with
# "Invalid address"), so it is set to the IPv4 public address when there is
# one. An IPv6-only node is set up without it: inbound data connections still
# land on - and reply from - the public address, but connections GCS opens
# itself follow the host's default IPv6 route.
DATA_IF=""
for A in $PUBLIC_IP $PUBLIC_IP6; do case "$A" in *:*) ;; *) DATA_IF="$A"; break;; esac; done
[ -n "$DATA_IF" ] || echo "   IPv6-only node: no --data-interface (GCS accepts IPv4 there only)"
globus-connect-server node setup \
  --deployment-key "$KEY" \
  --ip-address "$PUBLIC_IP" \
  ${PUBLIC_IP6:+--ip-address "$PUBLIC_IP6"} \
  ${DATA_IF:+--data-interface "$DATA_IF"}

systemctl reload apache2 2>/dev/null || systemctl reload httpd 2>/dev/null || true

echo
echo "== endpoint"
# Globus creates the gaccess.io DNS record during setup, and it does not resolve
# instantly. Querying straight away prints "Error resolving <domain>", which reads
# like a failed deploy when the endpoint is in fact fine - so wait for the name
# before reporting anything.
DOMAIN="$(python3 -c '
import json,sys
try: print(json.load(open(sys.argv[1])).get("domain_name",""))
except Exception: pass' "$KEY" 2>/dev/null || true)"
if [ -n "$DOMAIN" ]; then
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if getent hosts "$DOMAIN" >/dev/null 2>&1; then
      echo "   $DOMAIN resolves (after ${i}0s)"
      break
    fi
    [ "$i" = 10 ] && echo "   $DOMAIN still not resolving after 100s - DNS propagation is" \
                          "usually minutes; the endpoint itself is registered."
    sleep 10
  done
fi
GCS_CLI_ENDPOINT_ID="$EP_ID" globus-connect-server endpoint show || \
  echo "   (endpoint show failed - if this is a fresh setup it is almost certainly" \
       "DNS propagation, not a broken endpoint; re-run it in a few minutes)"
echo
echo "Endpoint UUID $EP_ID"
echo "Next: create the storage gateway and collection with setup_globus_collection.sh"
