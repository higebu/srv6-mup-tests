# frr_mup_intra_node_xvrf_gobgp

Verifies FRR's BGP-MUP loop guard (`bgp_mup_isd_is_self`) suppresses
T1ST install when the endpoint is covered by a self-originated ISD on
a sibling VRF.  The N3 VRF (`vrf-red`) and the N6 VRF (`vrf-blue`)
co-locate on a single FRR node; vrf-red originates the ISD,
vrf-blue's RT-import would otherwise resolve the gobgp-injected T1ST
against vrf-red's own SID and create an encap-then-immediate-decap
self-loop.

The data plane still works: vrf-red's seg6local action lives in the
default-vrf IPv6 FIB and any locally-emitted SRv6 packet whose outer
dst hits the locator gets transformed there.  The vrf-blue install is
unnecessary and would loop, so it is correctly omitted.

Inter-node cross-VRF resolve (one PE originates the ISD, a different
PE imports the T1ST) is a separate scenario, covered by:

- `tests/scenarios/frr_mup_e2e_gobgp_scapy/` — single PE-GW pair.
- `tests/scenarios/frr_mup_multi_vrf_gobgp_scapy/` — RT-split per-vrf import.

## Topology

```
+-------+ 2001:db8:1::/64 +-----------------+
| gbgp  |-----------------|       gw1       |
| 65000 | BGP-MUP eBGP    | 65001           |
+-------+                 |  + vrf-red  100 |  ISD origin (rt 10:10)
 gobgpd                   |  + vrf-blue 200 |  rt import 10:10
                          +-----------------+
```

| netns  | Role                                                       |
|--------|------------------------------------------------------------|
| `gbgp` | gobgpd MUP-Controller, only BGP peer (no inter-node leak)  |
| `gw1`  | FRR with two co-located VRFs (`vrf-red` N3, `vrf-blue` N6) |

`vrf-red` advertises its ISD on the session, but gobgpd has no other
peer to forward to, so the ISD never bounces back over BGP.  This
isolates the test from any inter-node receive path — every BGP-MUP RIB
transition is either local origination (vrf-red's ISD) or a directly
received T1ST (from gobgpd injector).

## Address plan

| Element                          | Value                                |
|----------------------------------|--------------------------------------|
| `gbgp` <-> `gw1` BGP-MUP session | `2001:db8:1::2 / ::1`                |
| gw1 SRv6 locator                 | `2001:db8:f::/48` (block 24/node 24/func 8) |
| `vrf-red` table                  | 100                                  |
| `vrf-blue` table                 | 200                                  |
| ISD prefix (vrf-red)             | `10.99.0.0/24` — T1ST endpoint inside |
| T1ST UE prefix                   | `192.168.10.5/32`                    |
| T1ST endpoint                    | `10.99.0.5`                          |
| T1ST RT extcomm                  | `10:10` (matches vrf-red export, vrf-blue import) |
| T1ST RD                          | `100:100`                            |

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
script -q -c "vng -m 4G --rwdir=/tmp \
  --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_intra_node_xvrf_gobgp/frr_mup_intra_node_xvrf_gobgp.sh" \
  /tmp/run.log
grep -E '===VERDICT|FRR-MUP-INTRA-NODE-XVRF' /tmp/run.log
```

## Pass criteria

`FRR-MUP-INTRA-NODE-XVRF: PASS` is printed iff:

1. Global MUP RIB carries vrf-red's locally-originated ISD AND the
   gobgpd-injected T1ST (BGP session functioning).
2. vrf-red's ISD installs the `End.M.GTP4.E` SID into the default-vrf
   IPv6 FIB (`oif vrf-red`).
3. bgpd log records the loop guard firing for the T1ST:
   `BGP-MUP: T1ST endpoint matches self-originated ISD`.
4. No T1ST install lands in either vrf-red (table 100) or vrf-blue
   (table 200) IPv4 FIB — the loop guard prevented it.

## See also

- `tests/scenarios/frr_mup_multi_vrf_gobgp_scapy/` — inter-node multi-VRF
  RT-split companion.
- `bgpd/bgp_mup.c:bgp_mup_isd_is_self` — the loop guard under test.
