# frr_mup_e2e_gobgp_scapy

End-to-end BGP-MUP IPv4 (GTP-U over IPv4) data-plane test inside one
vng VM.  gobgpd plays MUP-Controller and injects T1ST + T2ST; FRR on
gw1 plays MUP-GW (originates ISD); FRR on pe1 plays MUP-PE
(originates DSD); scapy in the gnb netns crafts a GTP-U(ICMP echo)
and verifies a GTP-U(ICMP echo-reply) returns.

## Topology

```
+-----+ gtpu  +-----+ srv6  +-----+ ipv4  +-----+
| gnb |-------| gw1 |-------| pe1 |-------| dn  |
+-----+ veth  +-----+ veth  +-----+ veth  +-----+
scapy         MUP-GW        MUP-PE
              ISD origin    DSD origin
                ^                  ^
                |                  |
                +-- gobgpd (MUP-C) --+
                    via separate veth into pe1
```

| netns  | Role                                                |
|--------|-----------------------------------------------------|
| `gnb`  | gNB (UL GTP-U source / DL GTP-U receiver, scapy)    |
| `gw1`  | MUP-GW: ISD origin, runs `End.M.GTP4.E` install     |
| `pe1`  | MUP-PE: DSD origin, runs `End.DT4` install          |
| `dn`   | DN-side host (UE-traffic destination)               |
| `gbgp` | MUP-Controller (gobgpd, injects T1ST/T2ST)          |

DL flow (`dn` -> UE `192.168.10.5`):
1. `dn` -> `pe1`: plain IPv4
2. `pe1` -> `gw1`: H.Encaps SRv6, `segs = <synth-SID>`
3. `gw1` -> `gnb`: End.M.GTP4.E (consume SID, synthesize GTP-U)

UL flow (`gnb` -> `dn`):
1. `gnb` (scapy) crafts GTP-U(TEID, QFI) inside ICMP echo and sends to gw1
2. `gw1` -> `pe1`: H.M.GTP4.D (consume GTP-U, encaps SRv6 with
   `nh6 = DSD-SID`)
3. `pe1` -> `dn`: End.DT4 (decap SRv6, lookup IPv4 table)

## Address plan

| Element                               | Value                          |
|---------------------------------------|--------------------------------|
| gNB-side IPv4                         | `10.99.0.0/24` (gw1=.1, gnb=.5)|
| GTP-U service IP (T2ST endpoint)      | `10.99.0.100/32` (on gw1)      |
| SR-domain IPv6                        | `2001:db8:1::/64` (gw1=::1, pe1=::2) |
| DN-side IPv4                          | `10.1.0.0/24` (pe1=.1, dn=.5)  |
| MUP-C control bus                     | `2001:db8:0::/64` (pe1=::1, gbgp=::2) |
| pe1 SR locator                        | `2001:db8:e::/48` (block 24/node 16/func 8) |
| gw1 SR locator                        | `2001:db8:f::/48` (block 24/node 16/func 8) |
| UE prefix (T1ST)                      | `192.168.10.5/32`              |
| T1ST endpoint                         | `10.99.0.5` (= gnb, inside ISD)|
| TEID / QFI                            | 12345 / 9                      |
| MUP-EC seg-id                         | `10:10`                        |
| ASNs                                  | gbgp 65000, pe1 65001, gw1 65002 |
| Negative-RT inject set                | UE `192.168.10.99/32`, T1ST endpoint `10.99.0.99`, T2ST endpoint `10.99.0.200`, RT `99:99` |

The negative-RT set must land in the default-vrf BGP-MUP RIB but must
NOT install into vrf-red — the script verifies this RT-import filter
explicitly.

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_e2e_gobgp_scapy/frr_mup_e2e_gobgp_scapy.sh" \
  /tmp/run.log
grep -E '===VERDICT|FRR-MUP-E2E' /tmp/run.log
```

Tunables (env):

- `DEBUG=1` — enable `nlmon0` (RTM_NEWROUTE capture) on pe1/gw1 and
  per-netns `tcpdump -i any` so the seg6local internal flow is
  observable.

## Pass criteria

`FRR-MUP-E2E-GOBGP-SCAPY: PASS` is printed iff every check passes:

1. pe1 installs T1ST UE prefix into vrf-red with `encap seg6 mode encap`
   (and main FIB stays empty for the same prefix — slice isolation).
2. gw1 installs T2ST endpoint into vrf-red with
   `encap seg6local action H.M.GTP4.D nh6 <pe1-DSD-SID>`.
3. The negative-RT (`rt 99:99`) routes are present in the default-vrf
   MUP RIB but absent from vrf-red on both pe1 and gw1.
4. pe1 has an `End.DT4` seg6local install hanging off its DSD SID.
5. gw1 has an `End.M.GTP4.E` seg6local install hanging off its ISD SID.
6. The T1ST synthesized SID at pe1 carries the IPv4 DA (32 bits) and
   `Args.Mob.Session = (QFI<<2) || TEID` (40 bits, MSB-aligned).
7. UL: scapy's GTP-U(ICMP echo) gets a matching GTP-U(ICMP echo-reply)
   on the same TEID within 5s.

## See also

- IPv6 variant: `tests/scenarios/frr_mup_e2e_gtp6_gobgp_scapy/`
- IS-IS underlay variant: `tests/scenarios/frr_mup_e2e_isis_gobgp_scapy/`
- Non-T-PDU passthrough: `tests/scenarios/frr_mup_e2e_passthrough_gobgp_scapy/`
- Graceful Restart / route refresh:
  `tests/scenarios/frr_mup_gr_gobgp_scapy/`
