# frr_mup_e2e_gtp6_gobgp_scapy

IPv6 (GTP-U over IPv6) variant of `frr_mup_e2e_gobgp_scapy`.  Exercises
RFC 9433 Section 6.3 / Section 6.5 Mobile User Plane behaviors
(End.M.GTP6.D / End.M.GTP6.E) and End.DT6 (RFC 8986 Section 4.8)
end-to-end across the BGP-MUP origination -> receive -> install path,
with **real GTP-U(v6)** transiting the SR-domain.  The
`vpp_interop_end_m_gtp6_*` scripts only validate the kernel-level
wire-format compatibility via manually-installed
`ip route add ... seg6local action End.M.GTP6.*`; this scenario
exercises FRR's `address-family ipv6 unicast` plus
`behavior mup export dt6` / `segment mup export interwork`.

## Topology

Same 5-netns layout as the IPv4 baseline.

```
+-----+ gtpu  +-----+ srv6  +-----+ ipv6  +-----+
| gnb |-------| gw1 |-------| pe1 |-------| dn  |
+-----+ veth  +-----+ veth  +-----+ veth  +-----+
scapy         MUP-GW        MUP-PE
              ISD origin    DSD origin
              (End.M.GTP6.E)   (End.DT6)
                ^                 ^
                |                 |
                +-- gobgpd (MUP-C) --+
                    via separate veth into pe1
                    (ipv6-mup AF)
```

| netns  | Role (Mobile User Plane terminology)             | Key install                                  |
|--------|--------------------------------------------------|----------------------------------------------|
| `gnb`  | gNB (UL ingress / DL egress, scapy send/sniff)   | -                                            |
| `gw1`  | MUP-GW (ISD originator)                          | seg6local `End.M.GTP6.E` at gw1's locator    |
| `pe1`  | MUP-PE (DSD originator)                          | seg6local `End.DT6` at pe1's locator         |
| `dn`   | DN-side host (UE-traffic destination)            | -                                            |
| `gbgp` | MUP-Controller (gobgpd injects T1ST/T2ST)        | -                                            |

## Address plan

`gnb` / `dn` / `ue` are not valid hex digits, so single hex stand-ins
are used (`a` = access network, `b` = backbone, `c` = client).  Same
naming style as the existing single-hex /64 slots in the VPP interop
topology (`e`/`f`/`6`/`9` etc.).

| Element                                  | Prefix                   | Notes                                                |
|------------------------------------------|--------------------------|------------------------------------------------------|
| gNB-side IPv6 link                       | `2001:db8:a::/64`        | gw1=::1, gnb=::5                                     |
| GTP-U(v6) service IP (T2ST endpoint)     | `2001:db8:a::100/128`    | on gw1, inside ISD `2001:db8:a::/64`                 |
| UE prefix (T1ST)                         | `2001:db8:c::5/128`      | single UE                                            |
| DN-side IPv6 link                        | `2001:db8:b::/64`        | pe1=::1, dn=::5                                      |
| SR-domain IPv6 link                      | `2001:db8:1::/64`        | gw1=::1, pe1=::2                                     |
| MUP-C control bus                        | `2001:db8:0::/64`        | pe1=::1, gbgp=::2                                    |
| pe1 SR locator                           | `2001:db8:e::/48`        | block 24 / node 24 / func 8 (loc_func = 56 bits)     |
| gw1 SR locator                           | `2001:db8:f::/48`        | block 24 / node 24 / func 8                          |
| DSD address                              | `10.0.0.250` (IPv4)      | DSD's Address AFI is IPv4-only in current FRR        |
| TEID / QFI                               | 12345 / 9                | UL/DL                                                |
| MUP-EC seg-id                            | `10:10`                  | matches T2ST and DSD                                 |

## How to run

Run as root inside `vng` (virtme-ng).  Like the other scenarios, use
`--rwdir=$PCAP_DIR` to surface pcaps outside the VM.

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_e2e_gtp6_gobgp_scapy/frr_mup_e2e_gtp6_gobgp_scapy.sh" \
  /tmp/run.log
```

Troubleshooting flags:

- `DEBUG=1` — bring up `nlmon0` (RTM_NEWROUTE observation) and
  `tcpdump -i any` on pe1 / gw1.

## Pass criteria

The script ends with `===VERDICT=== FRR-MUP-E2E-GTP6-GOBGP-SCAPY: PASS`.
PASS conditions, in order:

1. `pe1` installs `2001:db8:c::5/128` into vrf-red (table 100) with
   `encap seg6 mode encap` (= H.Encaps).
2. `gw1` installs `2001:db8:a::100/128` into vrf-red with
   `encap seg6local` (action follows the current FRR implementation).
3. `pe1` has an `End.DT6` seg6local install hanging off the DSD SID
   locator.
4. `gw1` has an `End.M.GTP6.E` seg6local install hanging off the ISD
   SID locator.
5. The synthesized SID for `pe1`'s T1ST install carries
   `Args.Mob.Session = (QFI<<2) || TEID` (40 bits, MSB-aligned) at
   bits 88..127.
6. **DL probe**: `dn` sends an ICMPv6 echo-request to the UE prefix and
   `gnb` observes a GTP-U(v6, TEID=12345) packet within 5s.
7. **UL probe**: an ICMPv6 echo-request crafted by `gnb` inside
   GTP-U(v6) reaches DN, and the echo-reply returns inside GTP-U(v6).

## Known gaps

- Current FRR (`bgpd/bgp_mup.c:bgp_mup_build_t2st_route` line 1731)
  picks `ZEBRA_SEG6_LOCAL_ACTION_H_M_GTP4_D` for T2ST install
  regardless of endpoint AFI.  An AFI_IP6 T2ST install therefore
  cannot accept v6 GTP-U ingress, so this scenario's UL leg fails.
  This is a known design bug, tracked separately (see
  `srv6-mup-issues/20260509-150607-bug-t2st-v6-endpoint-installs-h-m-gtp4-d.md`).
  Skipping UL is intentionally not offered — until the fix lands, UL
  fails and is useful for regression detection.
- Per draft-ietf-bess-mup-safi Section 3.3.4, DSD's Address AFI is
  independent of the inner-PDU AFI, but current FRR's
  `segment mup export direct address X` accepts only `A.B.C.D` (IPv4).
  This script uses `address 10.0.0.250` and assumes that an IPv4
  router-id-style DSD address is acceptable on AFI_IP6 BGP-MUP.

## References

- RFC 9433 Section 6.3 (End.M.GTP6.D), Section 6.5 (End.M.GTP6.E),
  RFC 8986 Section 4.8 (End.DT6) <https://www.rfc-editor.org/rfc/rfc9433.txt>
- IPv4 baseline: `tests/scenarios/frr_mup_e2e_gobgp_scapy/`
- v6 wire-format kernel-only compatibility:
  `tests/scenarios/vpp_interop_end_m_gtp6_d/`,
  `tests/scenarios/vpp_interop_end_m_gtp6_d_di/`,
  `tests/scenarios/vpp_interop_end_m_gtp6_e/`
- `bgpd/bgp_mup.c` (`behavior mup export dt6` /
  `bgp_mup_build_t2st_route`)
