# vpp_interop_end_m_gtp6_d_di

Linux **End.M.GTP6.D.Di** (RFC 9433 §6.4, GTP-U → SRv6 inline /
drop-in) interop with VPP plain **End** (RFC 8986 transit).  UL
direction with original outer IPv6 destination preserved in `SRH[0]`:
gnb sends IPv6 GTP-U; Linux srgw rewrites it into SRv6 with
`SRH = [orig_D, S1]` (no Args.Mob.Session — TEID is intentionally
discarded; D.Di's purpose is transparent IPv6 DA preservation); VPP's
plain `End` decrements SL and rewinds outer dst to `SRH[0]`; the
final SRv6 packet (SL=0, outer dst = preserved D) reaches dn.

## Topology

Linux ingress / VPP egress (gnb → srgw → VPP → dn):

```
[gnb netns]                        <-- plays gNB (UL GTP-U source)
   |  veth-g <-> veth-g-srgw
[srgw netns]                       <-- Linux End.M.GTP6.D.Di (GTP-U → SRv6 inline)
   |  veth-e <-> veth-e-vpp
[root ns / VPP]                    <-- VPP End (RFC 8986 transit)
   |  veth-f <-> veth-f-dn
[dn netns]                         <-- plays next-hop SR endpoint
```

| netns | Role                                                          |
|-------|---------------------------------------------------------------|
| `gnb` | Plays gNB; scapy emits IPv6/UDP/GTP-U(TEID 0x123, QFI 5) wrapping inner ICMPv6 |
| `srgw`| Linux `seg6local action End.M.GTP6.D.Di srh segs 2001:db8:e::1` |
| root  | VPP `sr localsid address 2001:db8:e::1 behavior end`           |
| `dn`  | Next-hop SR endpoint; scapy asserts `SRH[0] == orig_D` and inner is plain ICMPv6 (NOT GTP-U) |

## Address plan

| Element                                  | Value                              |
|------------------------------------------|------------------------------------|
| gnb ↔ srgw IPv6                          | `2001:db8:1::/64` (gnb=::2, srgw=::1) |
| srgw ↔ VPP IPv6 (SR-domain)              | `2001:db8:2::/64` (srgw=::1, VPP=::e) |
| VPP ↔ dn IPv6                            | `2001:db8:3::/64` (VPP=::1, dn=::e) |
| End.M.GTP6.D.Di routing prefix           | `2001:db8:f::/64`                  |
| VPP plain End localsid                   | `2001:db8:e::1/128`                |
| Original outer GTP-U dst (preserved)     | `2001:db8:f::1`                    |

After D.Di encap, the SRH is `[2001:db8:f::1, 2001:db8:e::1]` with the
active segment at `SRH[1]` (= S1 = VPP's End).  After VPP's End fires,
outer dst is rewound to `SRH[0] = 2001:db8:f::1` and SL=0.

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- env PCAP_OUT=$PCAP_DIR \
     $ROOT/srv6-mup-tests/tests/scenarios/vpp_interop_end_m_gtp6_d_di/vpp_interop_end_m_gtp6_d_di.sh" \
  /tmp/run-vpp-end_m_gtp6_d_di.log
grep -E 'VPP-INTEROP-END_M_GTP6_D_DI' /tmp/run-vpp-end_m_gtp6_d_di.log
```

## Pass criteria

`===VPP-INTEROP-END_M_GTP6_D_DI=== PASS` is printed iff dn observes
an SRv6 packet with:

- outer dst = `2001:db8:f::1` (= `SRH[0]` = preserved original outer DA)
- `SRH[0]` = `2001:db8:f::1`, `SRH[1]` = `2001:db8:e::1` (consumed)
- SL = 0
- inner = the original ICMPv6 EchoRequest (not GTP-U; D.Di stripped
  the UDP+GTP-U headers per §6.4)

## See also

- `docs/vpp-interop.md` — common topology background and shared notes.
- D companion (without inline `Args.Mob` discard):
  `tests/scenarios/vpp_interop_end_m_gtp6_d/`.
