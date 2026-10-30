#!/usr/bin/env bash
# setup_globus_storage.sh - publish a local directory through Globus: one POSIX
# storage gateway, one mapped collection, and an identity map saying which
# Globus identity is which local account.
#
# Run AFTER setup_globus_endpoint.sh, on the DTN, as root. Safe to re-run: the
# gateway and collection are found by display name and updated, not duplicated.
# (That also means: never change a display name on a live endpoint - a new name
# creates a second gateway and collection beside the first.)
#
# How access works with a mapped collection:
#   1. A user signs in to Globus with an identity, e.g. alice@example.edu.
#   2. The identity map turns that into a local account, e.g. alice. An
#      identity with no line in the map is refused.
#   3. Transfers run as that local account, so ordinary POSIX permissions
#      decide what it can read and write. Each mapped user gets a private
#      <base>/<account> directory (0700).
#
# --domain names the identity domains the gateway accepts (the part after @).
# GCS requires at least one, and refuses domains that have no Globus identity
# provider - so it must be a real institution domain that users log in with.
#
# Usage:
#   sudo ./setup_globus_storage.sh --base /data \
#        --gateway-name "My DTN storage" --collection-name "My DTN" \
#        --domain example.edu --map alice@example.edu=alice [--map ...] \
#        [--creds-file /etc/globus-dtn/creds.env] [--state-dir /etc/globus-dtn] \
#        [--admin you@example.edu] [--private]
#
# --private hides the collection from everyone without a role on it - and a
# mapped user has no role, so they get "Not authorized for that endpoint"
# before the identity map is even consulted. Public (the default) only means
# visible in Globus search; who gets IN is still decided by --map and --domain.
set -euo pipefail

BASE="/data"; GW_NAME=""; COLL_NAME=""; STATE_DIR="/etc/globus-dtn"
CREDS_FILE="/etc/globus-dtn/creds.env"; ADMIN=""; PUBLIC="--public"
DOMAINS=(); MAPS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base)            BASE="$2"; shift 2;;
    --gateway-name)    GW_NAME="$2"; shift 2;;
    --collection-name) COLL_NAME="$2"; shift 2;;
    --domain)          DOMAINS+=("$2"); shift 2;;
    --map)             MAPS+=("$2"); shift 2;;
    --creds-file)      CREDS_FILE="$2"; shift 2;;
    --state-dir)       STATE_DIR="$2"; shift 2;;
    --admin)           ADMIN="$2"; shift 2;;
    --public)          PUBLIC="--public"; shift;;
    --private)         PUBLIC="--private"; shift;;
    -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)" >&2; exit 2; }
[ -n "$GW_NAME" ] && [ -n "$COLL_NAME" ] || { echo "ERROR: --gateway-name and --collection-name are required" >&2; exit 2; }
[ "${#DOMAINS[@]}" -gt 0 ] || { echo "ERROR: at least one --domain is required" >&2; exit 2; }
[ "${#MAPS[@]}" -gt 0 ]    || { echo "ERROR: at least one --map identity=account is required" >&2; exit 2; }
case "$BASE" in /*) :;; *) echo "ERROR: --base must be an absolute path" >&2; exit 2;; esac
command -v globus-connect-server >/dev/null || { echo "ERROR: run install_globus_gcs.sh first" >&2; exit 2; }
[ -s "$STATE_DIR/endpoint-id.txt" ] || { echo "ERROR: no $STATE_DIR/endpoint-id.txt - run setup_globus_endpoint.sh first" >&2; exit 2; }

# shellcheck disable=SC1090
. "$CREDS_FILE"
export GCS_CLI_CLIENT_ID GCS_CLI_CLIENT_SECRET
GCS_CLI_ENDPOINT_ID="$(cat "$STATE_DIR/endpoint-id.txt")"; export GCS_CLI_ENDPOINT_ID

# ------------------------------------------------------------ local accounts
echo "== local accounts and directories under $BASE"
install -d -m 0755 "$BASE"
for m in "${MAPS[@]}"; do
  ident="${m%%=*}"; acct="${m#*=}"
  case "$ident" in *@*) :;; *) echo "ERROR: --map '$m': identity must look like user@domain" >&2; exit 2;; esac
  [[ "$acct" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "ERROR: --map '$m': '$acct' is not a valid account name" >&2; exit 2; }
  id -u "$acct" >/dev/null 2>&1 || useradd --create-home --shell /sbin/nologin "$acct"
  install -d -m 0700 -o "$acct" -g "$acct" "$BASE/$acct"
  echo "   $ident -> $acct  ($BASE/$acct)"
done

# ------------------------------------------------------------- identity map
# Exact, case-insensitive matches only: a pattern like ".*@example.edu" would
# let every identity at that institution in as someone.
python3 - "$STATE_DIR/identity-map.json" "${MAPS[@]}" <<'EOF'
import json, re, sys
out, maps = sys.argv[1], sys.argv[2:]
rules = []
for m in maps:
    ident, acct = m.split("=", 1)
    rules.append({"source": "{username}", "match": re.escape(ident),
                  "output": acct, "ignore_case": True})
json.dump({"DATA_TYPE": "expression_identity_mapping#1.0.0", "mappings": rules},
          open(out, "w"), indent=1)
EOF
chmod 0644 "$STATE_DIR/identity-map.json"

# Path restriction: nothing outside the base directory is reachable, whatever
# the account could read on the host.
printf '{ "DATA_TYPE": "path_restrictions#1.0.0", "none": ["/"], "read_write": ["%s"] }\n' \
  "$BASE" > "$STATE_DIR/path-restrictions.json"

DOMAIN_ARGS=(); for d in "${DOMAINS[@]}"; do DOMAIN_ARGS+=(--domain "$d"); done

# --------------------------------------------------------------- GCS helpers
# Find a gateway or collection id by its exact display name, or print nothing.
gcs_find() {
  globus-connect-server "$1" list -F json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
def walk(n):
    if isinstance(n, dict):
        if n.get("display_name") == want and n.get("id"):
            yield n["id"]
        for v in n.values(): yield from walk(v)
    elif isinstance(n, list):
        for v in n: yield from walk(v)
try: doc = json.load(sys.stdin)
except Exception: sys.exit(0)
for i in walk(doc): print(i); break
' "$2" 2>/dev/null || true
}

# ------------------------------------------------------------------ gateway
echo "== storage gateway '$GW_NAME'"
GW_ID="$(gcs_find storage-gateway "$GW_NAME")"
if [ -n "$GW_ID" ]; then
  globus-connect-server storage-gateway update posix "$GW_ID" "${DOMAIN_ARGS[@]}" \
    --identity-mapping "file:$STATE_DIR/identity-map.json" \
    --restrict-paths "file:$STATE_DIR/path-restrictions.json"
else
  if ! OUT="$(globus-connect-server storage-gateway create posix "$GW_NAME" "${DOMAIN_ARGS[@]}" \
         --identity-mapping "file:$STATE_DIR/identity-map.json" \
         --restrict-paths "file:$STATE_DIR/path-restrictions.json" 2>&1)"; then
    echo "$OUT" >&2
    if printf '%s' "$OUT" | grep -q 'identity provider'; then
      echo "ERROR: GCS refused a --domain with no Globus identity provider. Use the domain" >&2
      echo "       your users actually sign in with (see app.globus.org/account/identities)." >&2
    fi
    exit 1
  fi
  echo "$OUT"
  GW_ID="$(gcs_find storage-gateway "$GW_NAME")"
fi
[ -n "$GW_ID" ] || { echo "ERROR: gateway '$GW_NAME' not found after create" >&2; exit 1; }
echo "   gateway id: $GW_ID"

# --------------------------------------------------------------- collection
echo "== mapped collection '$COLL_NAME' on $BASE"
COLL_ID="$(gcs_find collection "$COLL_NAME")"
if [ -n "$COLL_ID" ]; then
  globus-connect-server collection update "$COLL_ID" $PUBLIC
else
  globus-connect-server collection create "$GW_ID" "$BASE" "$COLL_NAME" $PUBLIC
  COLL_ID="$(gcs_find collection "$COLL_NAME")"
fi
[ -n "$COLL_ID" ] || { echo "ERROR: collection '$COLL_NAME' not found after create" >&2; exit 1; }
printf '%s\n' "$COLL_ID" > "$STATE_DIR/collection-id.txt"

# --------------------------------------------------------------------- role
# Without a Globus subscription, endpoint roles for people are not available;
# the endpoint still works, administered by the service credential.
if [ -n "$ADMIN" ]; then
  if ROLE_OUT="$(globus-connect-server endpoint role create administrator "$ADMIN" 2>&1)"; then
    echo "== granted administrator to $ADMIN"
  elif printf '%s' "$ROLE_OUT" | grep -q subscription_required; then
    echo "== NOTE: administrator role for $ADMIN needs a Globus subscription - skipped"
  else
    echo "== WARN: could not grant administrator to $ADMIN:"; printf '%s\n' "$ROLE_OUT" | sed 's/^/     /'
  fi
fi

echo
echo "Collection $COLL_ID"
echo "  https://app.globus.org/file-manager?origin_id=$COLL_ID"
