# vpp_interop_end_m_gtp6_e

Linux **End.M.GTP6.E** (RFC 9433 §6.5, SRv6 → GTP-U) interop with VPP
**end.m.gtp6.d** drop-in (RFC 9433 §6.3, GTP-U → SRv6).  DL (5G)
direction: gnb sends IPv6 GTP-U; VPP `end.m.gtp6.d` (drop-in mode)
encaps it into SRv6 with `SRH = [orig_dst, sid]`; Linux srgw consumes
the SRv6 with End.M.GTP6.E and emits IPv6 GTP-U toward dn.

## Topology

Linux egress / VPP ingress (gnb → VPP → srgw → dn):

```
[gnb netns]                        <-- plays MUP-PE upstream peer (DL source)
   |  veth-g-gnb <-> veth-g
[root ns / VPP]                    <-- VPP end.m.gtp6.d drop-in (GTP-U → SRv6)
   |  veth-e-vpp <-> veth-e
[srgw netns]                       <-- Linux End.M.GTP6.E (SRv6 → GTP-U)
   |  veth-x <-> veth-x-dn
[dn netns]                         <-- plays gNB-side DL receiver
```

| netns | Role                                                          |
|-------|---------------------------------------------------------------|
| `gnb` | DL source; scapy emits IPv6/UDP/GTP-U(TEID 0x123, QFI 5) to `2001:db8:6::1` |
| root  | VPP `sr localsid prefix 2001:db8:6::/64 behavior end.m.gtp6.d 2001:db8:f::/64 nh-type ipv6 fib-table 0 drop-in` |
| `srgw`| Linux `seg6local action End.M.GTP6.E src 2001:db8:2::1`       |
| `dn`  | gNB-side DL receiver; tcpdump asserts IPv6 GTP-U with TEID 0x123 |

The `drop-in` flag on VPP's `end.m.gtp6.d` is required: by default
the plugin would strip GTP-U and forward the inner T-PDU instead of
emitting SRv6 (its non-drop-in path only encaps when the inner
destination is link-local / multicast or the GTP-U message type is
not G-PDU).

## Address plan

| Element                                 | Value                                |
|-----------------------------------------|--------------------------------------|
| gnb ↔ VPP IPv6                          | `2001:db8:1::/64` (gnb=::2, VPP=::1) |
| VPP ↔ srgw IPv6 (SR-domain)             | `2001:db8:2::/64` (VPP=::e, srgw=::1) |
| srgw ↔ dn IPv6                          | `2001:db8:3::/64` (srgw=::1, dn=::2) |
| End.M.GTP6.E SID locator                | `2001:db8:f::/64`                    |
| VPP `end.m.gtp6.d` localsid prefix      | `2001:db8:6::/64`                    |
| Egress GTP-U dst (post-decap)           | `2001:db8:6::1`                      |

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- env PCAP_OUT=$PCAP_DIR \
     $ROOT/srv6-mup-tests/tests/scenarios/vpp_interop_end_m_gtp6_e/vpp_interop_end_m_gtp6_e.sh" \
  /tmp/run-vpp-end_m_gtp6_e.log
grep -E 'VPP-INTEROP-END_M_GTP6_E' /tmp/run-vpp-end_m_gtp6_e.log
```

## Pass criteria

`===VPP-INTEROP-END_M_GTP6_E=== PASS` is printed iff dn observes an
IPv6 GTP-U packet with TEID `0x123` (= the TEID encoded into VPP's
SRv6 SID by the drop-in encap, then re-emitted by Linux End.M.GTP6.E).

## Notes

- For DL (E-family) scenarios the SR-domain wire is captured on the
  **srgw-side** veth peer (`veth-e` inside `srgw` netns), not on
  `veth-e-vpp` — VPP's af_packet TX is invisible to tcpdump on the
  same iface.

## See also

- `docs/vpp-interop.md` — common topology background and shared notes.
