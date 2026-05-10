# frr_mup_self_origin_resolve_gobgp

Verifies FRR's BGP-MUP T1ST resolver installs an SRv6 H.Encaps
route on the speaker that itself originated the covering ISD.  A
single FRR node hosts two VRFs — `vrf-red` (N3, originates the ISD)
and `vrf-blue` (N6, imports the T1ST received from gobgpd).  Per
`draft-ietf-bess-mup-safi-00` Section 3.3.9 there is no carve-out
for ISDs originated by another VRF on the same speaker, and the
synthesized End.M.GTP4.E SID is a kernel `seg6_local` local action
(consumes the SRH, emits GTP-U toward the gNB) rather than an
L3VPN-style loopback label, so the cross-vrf install on the
originating speaker is an SR hairpin and must proceed.

## Topology

```
+-------+ 2001:db8:1::/64 +-----------------+
| gbgp  |-----------------|       gw1       |
| 65000 | BGP-MUP eBGP    | 65001           |
+-------+                 |  + vrf-red  100 |  ISD origin (rt export 10:10)
 gobgpd                   |  + vrf-blue 200 |  rt import 10:10
                          +-----------------+
```

| netns  | Role                                                       |
|--------|------------------------------------------------------------|
| `gbgp` | gobgpd MUP-Controller, only BGP peer                       |
| `gw1`  | FRR with two VRFs (`vrf-red` originator, `vrf-blue` N6)    |

`vrf-red` advertises its ISD on the session, but gobgpd has no
other peer to forward to, so the ISD never bounces back over BGP.
This isolates the test from any inter-node receive path — every
BGP-MUP RIB transition is either local origination (vrf-red's ISD)
or a directly received T1ST (from the gobgpd injector).

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
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_self_origin_resolve_gobgp/frr_mup_self_origin_resolve_gobgp.sh" \
  /tmp/run.log
grep -E '===VERDICT|FRR-MUP-SELF-ORIGIN-RESOLVE' /tmp/run.log
```

## Pass criteria

`FRR-MUP-SELF-ORIGIN-RESOLVE: PASS` is printed iff:

1. Global MUP RIB carries vrf-red's locally-originated ISD AND the
   gobgpd-injected T1ST (BGP session functioning).
2. vrf-red's ISD installs the `End.M.GTP4.E` SID into the default-vrf
   IPv6 FIB (`oif vrf-red`).
3. vrf-blue (table 200) IPv4 FIB carries `192.168.10.5/32` with an
   SRv6 H.Encaps nexthop pointing at the synthesized End.M.GTP4.E
   SID under gw1's locator (`2001:db8:f::/48`).  vrf-red itself
   does not import `10:10`, so the T1ST does not install in vrf-red.

## See also

- `tests/scenarios/frr_mup_e2e_gobgp_scapy/` — single PE-GW pair
  end-to-end with scapy-driven data plane.
- `tests/scenarios/frr_mup_multi_vrf_gobgp_scapy/` — inter-node
  multi-VRF RT-split companion (separate VRFs differentiate via
  separate RTs, originator and receiver on different speakers).
