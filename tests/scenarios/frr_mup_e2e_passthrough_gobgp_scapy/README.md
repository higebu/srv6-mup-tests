# frr_mup_e2e_passthrough_gobgp_scapy

Verifies coexistence of `address-family ipv4 unicast` and
`address-family ipv4 mup` under the same per-vrf BGP instance, and
that FRR's BGP-MUP does not break the kernel-level non-T-PDU
GTP-U passthrough contract.

T-PDU GTP-U is consumed by the seg6local action (H.M.GTP4.D /
End.M.GTP4.E / ...), but non-T-PDU GTP-U (Echo Request, Echo Response,
Error Indication, ...) bypasses the seg6local action by design — the
kernel selftests assert that contract (see
`tools/testing/selftests/net/srv6_h_m_gtp4_d_test.sh`,
`TEST: H.M.GTP4.D (non-T-PDU passthrough)`).  For passthrough to
actually reach somewhere, vrf-red must hold normal IPv4 unicast routes
alongside the BGP-MUP install.

## Topology

```
+-----+ gtpu  +-----+ srv6  +-----+ ipv4  +-----+
| gnb |-------| gw1 |-------| pe1 |-------| dn  |
+-----+ veth  +-----+ veth  +-----+ veth  +-----+
                 |
                 +-- veth-gw-lupf (master vrf-red)
                 |
               +------+
               | lupf |  10.20.0.5 — non-T-PDU receiver
               +------+
```

The lupf leg is a directly-attached non-SRv6 IPv4 peer reachable from
`gw1`'s `vrf-red`.  This mirrors the lupf leg in
`tools/testing/selftests/net/srv6_h_m_gtp4_d_test.sh`, which is the
destination for non-T-PDU GTP-U passthrough.

## Address plan

Diff vs. `frr_mup_e2e_gobgp_scapy`:

| Element                  | Value                                |
|--------------------------|--------------------------------------|
| lupf leg                 | `10.20.0.0/24` (gw1=.1, lupf=.5)     |

Everything else (UE prefix, gNB/SR-domain/DN-side links, locators,
TEID, RT) is identical to the baseline scenario.

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
script -q -c "vng -m 4G --rwdir=/tmp \
  --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_e2e_passthrough_gobgp_scapy/frr_mup_e2e_passthrough_gobgp_scapy.sh" \
  /tmp/run.log
grep -E '===VERDICT|FRR-MUP-PASSTHROUGH' /tmp/run.log
```

## Pass criteria

`FRR-MUP-PASSTHROUGH-GOBGP-SCAPY: PASS` is printed iff:

1. `gw1` `vrf-red` has the T2ST install with action `H.M.GTP4.D`
   (regression check: adding the unicast AF must not break MUP).
2. `gw1` `vrf-red` BGP RIB carries `10.20.0.0/24` in `ipv4 unicast`,
   and the kernel `vrf-red` FIB has a connected route for it
   (`redistribute connected` works while the MUP AF is also active).
3. `gnb` -> `lupf` plain ICMP succeeds (vrf-red IPv4 unicast
   forwarding is functional).
4. A GTP-U Echo Request from `gnb` to `lupf` reaches `lupf`
   unaltered — the seg6local non-T-PDU passthrough path is not
   suppressed by FRR's BGP-MUP installs.
5. The original T-PDU end-to-end GTP-U probe still completes (the MUP
   transformations are not regressed by adding the unicast AF).

## See also

- Baseline data-plane test: `tests/scenarios/frr_mup_e2e_gobgp_scapy/`
- Kernel selftest: `tools/testing/selftests/net/srv6_h_m_gtp4_d_test.sh`
  (the wire bytes for the GTP-U Echo Request match this script exactly).
