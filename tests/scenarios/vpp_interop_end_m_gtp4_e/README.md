# vpp_interop_end_m_gtp4_e

Linux **End.M.GTP4.E** (RFC 9433 §6.6, SRv6 → GTP-U) interop with VPP
`sr policy + plain encap` (IPv4 → SRv6).  DL (4G) direction: gnb sends
IPv4 GTP-U; VPP wraps it in SRv6 (drop-in workaround for the VPP
`t.m.gtp4.d` plugin glitch); Linux srgw consumes the SRv6 with End.M.GTP4.E
and emits IPv4 GTP-U toward dn.

## Topology

Linux egress / VPP ingress (gnb → VPP → srgw → dn):

```
[gnb netns]                        <-- plays MUP-PE upstream peer (DL source)
   |  veth-g-gnb <-> veth-g
[root ns / VPP]                    <-- VPP sr policy + plain encap (IPv4 → SRv6)
   |  veth-e-vpp <-> veth-e
[srgw netns]                       <-- Linux End.M.GTP4.E (SRv6 → GTP-U)
   |  veth-x <-> veth-x-dn
[dn netns]                         <-- plays gNB-side DL receiver
```

| netns | Role                                                          |
|-------|---------------------------------------------------------------|
| `gnb` | DL source; scapy emits one IPv4/UDP/GTP-U(TEID 0x123, QFI 5)  |
| root  | VPP `sr policy add bsid 2001:db8:: next 2001:db8:dead::1 encap` + `t.m.gtp4.d` BSID; steers `10.99.0.0/24` traffic |
| `srgw`| Linux `seg6local action End.M.GTP4.E`; chained End at `2001:db8:dead::1/128` to drop SL to 0 |
| `dn`  | gNB-side DL receiver; tcpdump + scapy assertion               |

## Address plan

| Element                              | Value                                    |
|--------------------------------------|------------------------------------------|
| gnb ↔ VPP IPv4                       | `10.0.0.0/24` (gnb=.2, VPP=.1)           |
| VPP ↔ srgw IPv6 (SR-domain)          | `2001:db8:2::e/64` ↔ `::1/64`            |
| srgw ↔ dn IPv4                       | `10.0.1.0/24` (srgw=.1, dn=.2)           |
| End.M.GTP4.E SID locator             | `2001:db8::/32` (Source UPF Prefix /64)  |
| VPP `t.m.gtp4.d` outer BSID          | `2001:db8:5::1/128`                      |
| VPP "real-segment" SR transit        | `2001:db8:dead::1/128` (caught by srgw plain `End`) |
| Far-side IPv4 (egress GTP-U DA)      | `10.99.0.0/24`                           |

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- env PCAP_OUT=$PCAP_DIR \
     $ROOT/srv6-mup-tests/tests/scenarios/vpp_interop_end_m_gtp4_e/vpp_interop_end_m_gtp4_e.sh" \
  /tmp/run-vpp-end_m_gtp4_e.log
grep -E 'VPP-INTEROP-END_M_GTP4_E' /tmp/run-vpp-end_m_gtp4_e.log
```

## Pass criteria

`===VPP-INTEROP-END_M_GTP4_E=== PASS` is printed iff dn's pcap
contains an IPv4 GTP-U packet with TEID `0x123` (matches the inner
GTP-U the gnb-side scapy emitted; the SR transit + End.M.GTP4.E pair
preserves the outer TEID).

## Notes

- For DL (E-family) scenarios where VPP is the encap side, the
  SR-domain wire is captured on the **srgw-side** veth peer
  (`veth-e` inside `srgw` netns), not on `veth-e-vpp` — VPP's
  af_packet TX is invisible to tcpdump on the same iface.
- The `sr policy + plain encap` workaround exists because VPP 25.10's
  `t.m.gtp4.d` plugin returns "T.M.GTP4.D bad packets" without
  emitting an SRv6 packet when activated via
  `sr policy add ... behavior t.m.gtp4.d ...`.  The workaround wraps
  the entire incoming IPv4/UDP/GTP-U datagram inside SRv6, which is
  why the egress pcap shows a doubled GTP-U header.

## See also

- `docs/vpp-interop.md` — common topology background and shared notes.
- Sibling scenarios under `tests/scenarios/vpp_interop_*/`.
