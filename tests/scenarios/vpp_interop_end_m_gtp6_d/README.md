# vpp_interop_end_m_gtp6_d

Linux **End.M.GTP6.D** (RFC 9433 §6.3, GTP-U → SRv6) interop with VPP
**End.DT6** (RFC 8986 §4.8, SRv6 → IPv6).  UL (5G) direction: gnb sends
IPv6 GTP-U; Linux srgw consumes it and emits a 1-segment SRv6 packet
with `Args.Mob.Session` encoded in `SRH[0]`; VPP's `End.DT6` strips
both the SRv6 and the inner IPv6 header is forwarded toward dn.

End.DT6 is content-agnostic about the `Args.Mob` bits — that is why
it is the matching pairing for End.M.GTP6.D's §6.3 semantics.  The
SRH-S02 constraint (`segments_left == 1`) of End.M.GTP6.E §6.5 lives
in the End.M.GTP6.D.Di pairing covered by
`tests/scenarios/vpp_interop_end_m_gtp6_d_di/`.

## Topology

Linux ingress / VPP egress (gnb → srgw → VPP → dn):

```
[gnb netns]                        <-- plays gNB (UL GTP-U source)
   |  veth-g <-> veth-g-srgw
[srgw netns]                       <-- Linux End.M.GTP6.D (GTP-U → SRv6)
   |  veth-e <-> veth-e-vpp
[root ns / VPP]                    <-- VPP End.DT6 (SRv6 → IPv6)
   |  veth-f <-> veth-f-dn
[dn netns]                         <-- plays far-side IPv6 peer
```

| netns | Role                                                          |
|-------|---------------------------------------------------------------|
| `gnb` | Plays gNB; scapy emits IPv6/UDP/GTP-U(TEID 0x123, QFI 5) wrapping inner ICMPv6 to `2001:db8:9::dead` |
| `srgw`| Linux `seg6local action End.M.GTP6.D srh segs 2001:db8:e:: src ... sr_prefix_len 88` |
| root  | VPP `sr localsid address 2001:db8:e:0:0:14:0:123 behavior end.dt6 0` (full SID = locator/88 + Args.Mob) |
| `dn`  | Far-side IPv6 receiver; tcpdump asserts plain inner ICMPv6 echo arrived (no GTP-U, no SRv6) |

## Address plan

| Element                                 | Value                              |
|-----------------------------------------|------------------------------------|
| gnb ↔ srgw IPv6                         | `2001:db8:1::/64` (gnb=::2, srgw=::1) |
| srgw ↔ VPP IPv6 (SR-domain)             | `2001:db8:2::/64` (srgw=::1, VPP=::e) |
| VPP ↔ dn IPv6                           | `2001:db8:3::/64` (VPP=::1, dn=::e) |
| End.M.GTP6.D routing prefix             | `2001:db8:f::/64`                  |
| VPP End.DT6 localsid (full /128 SID)    | `2001:db8:e:0:0:14:0:123/128`      |
| Inner IPv6 destination (UE side)        | `2001:db8:9::dead` (under `2001:db8:9::/64`) |

The `2001:db8:e:0:0:14:0:123` SID = locator+function `2001:db8:e::/88`
plus `Args.Mob.Session` for `(QFI=5, TEID=0x123)` at bits 88..127.
VPP's core SRv6 plugin matches localsids by exact address; the
`prefix /N` form is `srv6mobile`-plugin-specific.

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- env PCAP_OUT=$PCAP_DIR \
     $ROOT/srv6-mup-tests/tests/scenarios/vpp_interop_end_m_gtp6_d/vpp_interop_end_m_gtp6_d.sh" \
  /tmp/run-vpp-end_m_gtp6_d.log
grep -E 'VPP-INTEROP-END_M_GTP6_D' /tmp/run-vpp-end_m_gtp6_d.log
```

## Pass criteria

`===VPP-INTEROP-END_M_GTP6_D=== PASS` is printed iff dn observes a
plain inner ICMPv6 echo with `src=2001:db8:1::2` and
`dst=2001:db8:9::dead` — i.e. End.DT6 stripped both the SRv6 and the
GTP-U headers and forwarded the inner T-PDU.

## See also

- `docs/vpp-interop.md` — common topology background and shared notes.
- D.Di companion: `tests/scenarios/vpp_interop_end_m_gtp6_d_di/`.
