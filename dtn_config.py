# dtn_config.py
#
# Every setting for globus_dtn_fabric.ipynb. Pick a profile, fill in the Globus
# section, and run the notebook top to bottom.
#
# Two ways to give a FABRIC VM a public address that Globus clients can reach:
#
#   "ext"  FABnetv4Ext - FABRIC's own publicly routable IPv4. FABRIC assigns the
#          address; nothing is needed from anyone outside FABRIC. Available at
#          most FABRIC sites.
#   "fp"   A partner's L3 facility port - FABRIC carries one VLAN between your
#          VM and the partner's router; the PARTNER owns the prefix, the
#          gateway and any filtering. FABRIC advertises only the VLAN range, so
#          you must get an address assignment from the partner. The notebook's
#          probe step shows what the port already offers before you ask.
#
# Both end up the same: a Rocky 9 VM with Globus Connect Server 5.4, a public
# address that is policy-routed so FABRIC management access survives, a
# firewall that admits only Globus on the public interface, and one mapped
# collection over a local directory.

from ipaddress import IPv4Interface, IPv6Interface, ip_address

# ------------------------------------------------------------------ profiles
PROFILES = {
    # FABnetv4Ext at STAR (StarLight, Chicago). Any site offering FABnetv4Ext works.
    "ext": dict(
        site="STAR",
        uplink="fabnetv4ext",
        slice="GLOBUS-DTN-STAR",
    ),

    # NCSA's L3 facility port. Other L3 facility ports seen in late 2026:
    # PSC-L3-PSC (PSC), EDUKY-L3-EDUKY (EDUKY), SDSC-L3-UCSD (UCSD),
    # AmLight-Layer3-FIU (FIU). The notebook lists the live ones.
    "fp": dict(
        site="NCSA",
        uplink="facility_port",
        slice="GLOBUS-DTN-NCSA",
        facility_port="NCSA-L3-NCSA",
        # The VLAN the partner assigned you, or "auto" to take the first free one
        # (enough to run the probe, but the partner must then know which you took).
        vlan="auto",
        # The partner's assignment, as CIDR on-link prefix + gateway. Fill in at
        # least one family; leave all four None until then. Shape only - these
        # documentation addresses route nowhere:
        #   addr4="192.0.2.18/28",       gw4="192.0.2.17",
        #   addr6="2001:db8:1011::18/64", gw6="2001:db8:1011::1",
        addr4=None, gw4=None,
        addr6=None, gw6=None,
        bw=10,          # Gbps reserved on the facility port
        mtu=None,       # None = 1500; use 9000 only if the partner path supports it
    ),
}

# Which profile the notebook builds.
profile = "ext"

# --------------------------------------------------------------------- VM
node_name = "globus-dtn"
cores = 16
ram = 32           # GB. GCS needs at least 8.
disk = 500         # GB. The collection lives on this disk unless you add storage.
image = "default_rocky_9"
nic_model = "NIC_Basic"   # NIC_ConnectX_6 / _7 for a dedicated 100G port
ext_net_name = "net-public"

# ------------------------------------------------------------------ Globus
# A Globus service credential registered for Globus Connect Server: at
# app.globus.org > Settings > Developers, create a project, then
# "Register a service account / application credential for Globus Connect
# Server", and put its client id and secret in globus_creds.env (see
# globus_creds.env.example). The endpoint is OWNED by that credential, so it
# outlives any one person; humans are added as administrators.
globus_creds_file = "globus_creds.env"
globus_project_id = None                 # Globus Auth project uuid, optional
display_name = "FABRIC DTN"              # the site is appended: "FABRIC DTN (STAR)"
organization = "Your Organization"
contact_email = "you@example.edu"
globus_admin = None                      # e.g. "you@example.edu"; needs a subscription

# Storage published by the collection.
data_base = "/data"
# Identity domains the gateway accepts: the part after @ in the Globus
# identities your users sign in with. Must have a Globus identity provider.
allowed_domains = ["example.edu"]
# Globus identity -> local account. Only these identities get in; each gets a
# private <data_base>/<account> directory.
users = {
    "alice@example.edu": "alice",
}
# Public = visible in Globus search. Access is still only for the identities in
# users{}. Private hides it from everyone without a role on it - including the
# mapped users, who then get "Not authorized for that endpoint". Leave True.
collection_public = True

state_dir = "/etc/globus-dtn"            # on the VM

# ------------------------------------------------------- derived, do not edit
_p = PROFILES[profile]
site = _p["site"]
uplink = _p["uplink"]
slice_name = _p["slice"]
facility_port = _p.get("facility_port")
vlan = _p.get("vlan")
addr4, gw4, addr6, gw6 = (_p.get(k) for k in ("addr4", "gw4", "addr6", "gw6"))
fp_bw = _p.get("bw", 10)
fp_mtu = _p.get("mtu")
endpoint_display_name = f"{display_name} ({site})"


def _read_creds():
    vals = {}
    try:
        for line in open(globus_creds_file):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                vals[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return vals


def owner_identity():
    """The service credential's own identity - the endpoint's owner."""
    cid = _read_creds().get("GCS_CLI_CLIENT_ID", "")
    return f"{cid}@clients.auth.globus.org" if cid else None


def addressing_problems():
    out = []
    for fam, a, g, cls in (("IPv4", addr4, gw4, IPv4Interface), ("IPv6", addr6, gw6, IPv6Interface)):
        if (a is None) != (g is None):
            out.append(f"{fam}: set both address and gateway, or neither.")
            continue
        if a is None:
            continue
        try:
            iface = cls(a)
            gw = ip_address(g)
        except ValueError as e:
            out.append(f"{fam}: {e}")
            continue
        if iface.network.prefixlen == iface.max_prefixlen:
            out.append(f"{fam} address {a} needs the on-link prefix, e.g. /28 or /64.")
        if gw not in iface.network and not (fam == "IPv6" and gw.is_link_local):
            out.append(f"{fam} gateway {g} is not inside {iface.network}.")
    return out


def validate(need_addressing=False):
    """Fail here, before a slice exists, rather than half way through."""
    p = []
    if profile not in PROFILES:
        p.append(f"profile '{profile}' is not one of {list(PROFILES)}.")
    if uplink not in ("fabnetv4ext", "facility_port"):
        p.append("uplink must be 'fabnetv4ext' or 'facility_port'.")
    if uplink == "facility_port":
        if not facility_port:
            p.append("a facility_port profile needs facility_port=<name>.")
        if vlan is None:
            p.append("set vlan to the partner's VLAN, or \"auto\" for the probe.")
        p += addressing_problems()
        if need_addressing and addr4 is None and addr6 is None:
            p.append(f"no addr4/gw4 or addr6/gw6 yet for {facility_port}: run the probe "
                     f"step, or ask the partner for a prefix and gateway on your VLAN.")
    creds = _read_creds()
    if not creds:
        p.append(f"{globus_creds_file} is missing - copy globus_creds.env.example and fill it in.")
    else:
        if len(creds.get("GCS_CLI_CLIENT_ID", "")) != 36:
            p.append("GCS_CLI_CLIENT_ID should be a 36-character uuid.")
        if not creds.get("GCS_CLI_CLIENT_SECRET"):
            p.append("GCS_CLI_CLIENT_SECRET is empty.")
    if not users:
        p.append("users{} is empty - nobody could sign in to the collection.")
    for ident in users:
        if "@" not in ident:
            p.append(f"users key '{ident}' must be a Globus identity like name@domain.")
        elif ident.split("@", 1)[1] not in allowed_domains:
            p.append(f"'{ident}' is not in allowed_domains {allowed_domains}.")
    if not data_base.startswith("/"):
        p.append("data_base must be an absolute path.")
    if p:
        raise ValueError("dtn_config is incomplete:\n  - " + "\n  - ".join(p))
    return True
