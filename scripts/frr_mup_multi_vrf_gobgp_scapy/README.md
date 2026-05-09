# frr_mup_multi_vrf_gobgp_scapy

End-to-end harness for the multi-VRF BGP-MUP RT-split scenario.  A
single PE (pe2) hosts two parallel per-vrf bgpd instances —
`vrf-red` (RT 10:10) and `vrf-blue` (RT 20:20) — and four
T1ST/T2ST sets (A/B/C/D) injected by gobgpd through the transit
speaker pe1.  Each set carries a different RT extcomm
combination, and the harness asserts that each set installs into
exactly the VRF(s) its RT(s) match.  Companion to
`scripts/frr_interop_mup` (single-VRF baseline) and
`scripts/frr_mup_e2e_gobgp_scapy` (data-plane scapy harness).

## Topology

```
+------+ veth +------+ veth +-----------------+
| gbgp |------| pe1  |------| pe2             |
|65000 | eBGP |65001 | eBGP |65002            |
+------+      +------+      | + vrf-red  (10) |
 gobgpd        FRR transit  | + vrf-blue (20) |
                            +-----------------+
                             FRR (zebra+bgpd)
```

`pe1` is a transit BGP-MUP speaker only — no per-vrf instance.
`pe2` carries two per-vrf bgpd instances, one per RT.  All four
sets reach pe2 via the eBGP-MUP session pe1 -> pe2; whether they
install into a given VRF's table is decided locally on pe2 by the
RT-import filter.

## Address plan

| Element                                | Value                          |
|----------------------------------------|--------------------------------|
| gbgp <-> pe1 (BGP-MUP session)         | `2001:db8:1::2 / ::1`          |
| pe1  <-> pe2 (BGP-MUP session)         | `2001:db8:2::1 / ::2`          |
| gobgpd injector SR locator             | `2001:db8:e::/48`              |
| pe1 SRv6 locator                       | `2001:db8:1c::/48`             |
| pe2 SRv6 locator                       | `2001:db8:2c::/48`             |
| pe2 vrf-red                            | netdev `vrf-red`,  table 100   |
| pe2 vrf-blue                           | netdev `vrf-blue`, table 200   |
| pe2 vrf-red  v4 marker network         | `198.51.100.0/24`              |
| pe2 vrf-blue v4 marker network         | `198.51.100.128/25`            |
| pe2 vrf-red  v6 marker network         | `2001:db8:beef:10::/64`        |
| pe2 vrf-blue v6 marker network         | `2001:db8:beef:20::/64`        |

## RT/RD plan per set

| Set | Source RD  | RT extcomm   | T1ST UE prefix    | T2ST v4 endpt | T2ST v6 endpt    |
|-----|-----------|--------------|-------------------|---------------|------------------|
|  A  | `100:10`  | `10:10`      | `192.168.10.1/32` | `10.10.0.1`   | `2001:db8:a::1`  |
|  B  | `100:20`  | `20:20`      | `192.168.20.1/32` | `10.20.0.1`   | `2001:db8:b::1`  |
|  C  | `100:30`  | `10:10` + `20:20` | `192.168.30.1/32` | `10.30.0.1`   | `2001:db8:c::1`  |
|  D  | `100:40`  | `99:99`      | `192.168.40.1/32` | `10.40.0.1`   | `2001:db8:d::1`  |

Each set also injects an ISD anchor at `10.<set-decade>.0.0/24`
(e.g. Set A -> `10.10.0.0/24`) so the T1ST endpoint resolves
against the matching segment-origin in the importing VRF.

pe2's per-vrf instances export their own RDs (`65002:10/11` for
vrf-red, `65002:20/21` for vrf-blue) and announce marker prefixes
that are deliberately disjoint from the gobgpd-side ISD ranges to
avoid tripping the `bgp_mup_isd_is_self` loop guard (same pattern
as `scripts/frr_interop_mup`).

## How to run

The script uses the same vng-driven loop as the other frr_*
harnesses.  From the parent directory:

```
ROOT=$(cd "$(dirname "$0")/.." && pwd)  # adjust to your tree
script -q -c "vng -m 4G --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/scripts/frr_mup_multi_vrf_gobgp_scapy/frr_mup_multi_vrf_gobgp_scapy.sh" \
  /tmp/run-frr-mup-multi-vrf.log
grep -E '===FRR-MUP-MULTI-VRF===' /tmp/run-frr-mup-multi-vrf.log
```

The script expects the same prerequisites as `frr_interop_mup`
(kernel from `../linux`, iproute2 from `../iproute2`, FRR from
`../frr`, gobgp/gobgpd in `../srv6-mup-tests/.bin/`).

## Pass criteria

The harness checks the kernel install of each set's T1ST UE /32
in the matching VRF table on pe2:

| Set | vrf-red (table 100) | vrf-blue (table 200) |
|-----|---------------------|----------------------|
|  A  | install (H.Encaps)  | absent               |
|  B  | absent              | install (H.Encaps)   |
|  C  | install (H.Encaps)  | install (H.Encaps)   |
|  D  | absent              | absent               |

Final line on success: `===FRR-MUP-MULTI-VRF=== PASS`.

The corresponding T2ST seg6local installs (End.M.GTP4.E /
End.M.GTP6.E on the locator SID) land in the SR-underlay (default)
IPv6 table on pe2; they are visible in the `===PE2-KERNEL-VRF-*`
debug dumps but the pass criterion is keyed off the per-vrf T1ST
UE /32 because that is the unambiguous "this VRF imported this
set" signal.

## Follow-ups

- **rmap import variant (Phase 2 of issue
  `20260509-093034-feature-route-map-mup-import-apply.md`)** is
  intentionally NOT exercised here.  The intent is: with vrf-red's
  inbound `route-map mup import RX-FILTER` denying Set C, vrf-red
  loses Set C while vrf-blue keeps it.  The CLI keyword is not
  available until Phase 2 lands; once it does, add a sibling
  script (or a `RMAP=1` mode) and flip the Set C row of the
  expected install matrix for vrf-red from "install" to "absent".
- **v6 multi-VRF (End.M.GTP6.* family).**  Out of scope per the
  source issue; covered by a future issue.
- **ECMP / fan-out across multiple originating PEs.**  Tracked
  separately under `feature-frr-mup-pe-failover-ecmp`.
