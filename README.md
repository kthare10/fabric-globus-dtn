# A Globus endpoint on FABRIC

A notebook that builds a **Globus Connect Server 5.4** endpoint on a FABRIC VM and publishes a
directory on it as a Globus mapped collection. Two ways to give the VM a public address:

| profile | uplink | public address from | needs |
|---|---|---|---|
| `ext` | **FABnetv4Ext** | FABRIC - its own routable IPv4 pool | nothing outside FABRIC |
| `fp` | a partner's **L3 facility port** | the partner's routed prefix, on one VLAN | an address assignment from the partner |

Both have been run end to end on FABRIC: `ext` at WASH (IPv4), and `fp` at PSC
(`PSC-L3-PSC`, IPv6-only). The network steps were also proven dual-stack at NCSA.

## Contents

| file | what |
|---|---|
| `globus_dtn_fabric.ipynb` | the walkthrough - run it top to bottom |
| `dtn_config.py` | every setting; pick `profile = "ext"` or `"fp"` |
| `globus_creds.env.example` | template for the Globus service credential |
| `node_tools/setup_globus_dtn_net.sh` | public uplink, IPv4 and/or IPv6, policy-routed so management survives |
| `node_tools/probe_facility_port.sh` | what a facility port hands out (DHCP, RA, NAT) without touching management |
| `node_tools/install_globus_gcs.sh` | GCS 5.4 install and prerequisite checks |
| `node_tools/setup_globus_wan_firewall.sh` | public interface accepts only 443 and 50000-51000 |
| `node_tools/setup_globus_endpoint.sh` | `endpoint setup` + `node setup` at the public address |
| `node_tools/setup_globus_storage.sh` | local accounts, identity map, POSIX gateway, mapped collection |
| `node_tools/host_tune.sh` | ESnet TCP tuning; jumbo MTU only on the NIC you name |

## Before you run it

1. **FABRIC** - a project and a working FABlib configuration, as for any FABRIC notebook.
2. **Globus service credential** - at app.globus.org > Settings > Developers, create a project,
   then *Register a service account / application credential for Globus Connect Server*.
   `cp globus_creds.env.example globus_creds.env`, `chmod 600 globus_creds.env`, and fill in
   the id and secret. The endpoint is owned by this credential, so it does not depend on any
   one person's account.
3. **`dtn_config.py`** - set `profile`, `organization`, `contact_email`, `allowed_domains`
   (the domain part of your users' Globus identities) and `users` (which Globus identities get
   in, and as which local account).
4. **For `fp`** - get a VLAN, a routed prefix and a gateway from the partner; or set
   `vlan="auto"`, build the slice, and run the probe step to see what the port offers first.

## Things worth knowing

- **Management is never touched.** The public address gets its own routing table and source
  rule. Where FABRIC management has no default route in a family (it is often IPv6-only), the
  uplink takes that family's default - otherwise outbound IPv4 has nowhere to go.
- **The firewall matches only the public NIC.** Without it, sshd answers on the public address.
- **Keep `deployment-key-<site>.json` safe.** The notebook copies it off the VM. It *is* the
  endpoint: with it, a replacement VM rejoins the same endpoint and collections; without it, a
  lost VM means a new endpoint, and the old one can only be removed by Globus support.
- **Delete the endpoint before the slice** (last cell), for the same reason.
- **No subscription needed** for endpoint-to-endpoint transfers. Browser upload/download,
  guest collections (sharing with people outside your `users` list) and administrator roles
  for people need a Globus subscription.
- **NAT breaks inbound Globus.** The probe and the egress check both report the address the
  outside world sees; it must be the address on the VM.
- **IPv6-only works** with GCS 5.4, but IPv4-only clients cannot reach it - prefer dual stack.
  GCS takes `--data-interface` as IPv4 only, so an IPv6-only node is set up without it:
  inbound data connections use the public address, but connections GCS opens itself follow
  the host's default IPv6 route (FABRIC management). Verify an IPv6-only endpoint from an
  IPv6-capable host; the notebook says so if the machine running it has no IPv6 route.
- **Partner router advertisements may be slow.** Some routers only send RAs periodically and
  ignore solicitations, so the probe's 45 s window can miss them (`--wait 300` helps). If you
  already know the prefix and the router's link-local address, the address IPv6
  autoconfiguration would pick (EUI-64 of the NIC's MAC) can be configured statically.
- **NetworkManager grabs new NICs.** On a port with router advertisements, its automatic
  "Wired connection N" profile adds a second default route beside management's. The probe and
  uplink scripts remove that profile and stop it being recreated for the public NIC.
- **Display names are identities.** The storage script finds the gateway and collection by
  name; renaming a live one creates a second set.
