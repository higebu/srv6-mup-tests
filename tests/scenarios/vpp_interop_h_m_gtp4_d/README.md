# vpp_interop_h_m_gtp4_d

Linux **H.M.GTP4.D** (RFC 9433 §6.7, GTP-U → SRv6) interop with VPP
**end.m.gtp4.e** (RFC 9433 §6.6, SRv6 → GTP-U).  UL (4G) direction:
gnb sends IPv4 GTP-U; Linux srgw consumes it and emits SRv6; VPP
consumes the SRv6 and emits IPv4 GTP-U toward dn.

## Topology

Linux ingress / VPP egress (gnb → srgw → VPP → dn):

```
[gnb netns]                        <-- plays gNB (UL GTP-U source)
   |  veth-g <-> veth-g-srgw
[srgw netns]                       <-- Linux H.M.GTP4.D (GTP-U → SRv6)
   |  veth-e <-> veth-e-vpp
[root ns / VPP]                    <-- VPP end.m.gtp4.e (SRv6 → GTP-U)
   |  veth-f <-> veth-f-dn
[dn netns]                         <-- plays far-side GTP peer
```

| netns | Role                                                          |
|-------|---------------------------------------------------------------|
| `gnb` | Plays gNB; scapy emits one IPv4/UDP/GTP-U(TEID 0x123, QFI 5)  |
| `srgw`| Linux SR Gateway; `ip route ... encap seg6local action H.M.GTP4.D` |
| root  | VPP `sr localsid prefix 2001:db8::/32 behavior end.m.gtp4.e`  |
| `dn`  | Far-side GTP receiver; tcpdump + scapy assertion              |

## Address plan

| Element                         | Value                                  |
|---------------------------------|----------------------------------------|
| gnb ↔ srgw IPv4                 | `10.0.0.0/24` (gnb=.2, srgw=.1)        |
| srgw ↔ VPP IPv6 (SR-domain)     | `2001:db8:2::1/64` ↔ `::e/64`          |
| VPP ↔ dn IPv4                   | `10.0.1.0/24` (VPP=.1, dn=.2)          |
| End.M.GTP4.E SID locator        | `2001:db8::/32` (`v4_mask_len 32`, `sr_prefix_len 32`) |
| Far-side IPv4 (encoded in SID)  | `10.99.0.0/24`                         |

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- env PCAP_OUT=$PCAP_DIR \
     $ROOT/srv6-mup-tests/tests/scenarios/vpp_interop_h_m_gtp4_d/vpp_interop_h_m_gtp4_d.sh" \
  /tmp/run-vpp-h_m_gtp4_d.log
grep -E 'VPP-INTEROP-H_M_GTP4_D' /tmp/run-vpp-h_m_gtp4_d.log
```

## Pass criteria

`===VPP-INTEROP-H_M_GTP4_D=== PASS` is printed iff dn's pcap contains
an IPv4 GTP-U packet with TEID `0x123` (= the TEID the gnb-side scapy
encoded into the original GTP-U).

## Captures

Three tcpdumps run during the test (gnb veth, root-side VPP veth,
dn veth), then `mergecap` joins them in time order.  When `PCAP_OUT`
is set, the merged pcap is copied to `$PCAP_OUT/h_m_gtp4_d.pcap`.

## See also

- `docs/vpp-interop.md` — common topology background, address plan,
  and the "why static ND / promiscuous mode" notes shared with the
  other VPP interop scenarios.
- Sibling scenarios:
  `tests/scenarios/vpp_interop_end_m_gtp4_e/`,
  `tests/scenarios/vpp_interop_end_m_gtp6_d/`,
  `tests/scenarios/vpp_interop_end_m_gtp6_e/`,
  `tests/scenarios/vpp_interop_end_m_gtp6_d_di/`.
