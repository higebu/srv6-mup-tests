# frr_mup_e2e_isis_gobgp_scapy

Same end-to-end BGP-MUP IPv4 data-plane scenario as
`frr_mup_e2e_gobgp_scapy`, but with the SR-domain underlay routes
exchanged via IS-IS L2 reachability TLVs instead of static routes.
Each side advertises its SRv6 locator via `router isis 1`; BGP-MUP's
T1ST/T2ST nexthops resolve against the IS-IS-learned routes to the
remote locator.

## Topology

```
+-----+ gtpu  +-----+ srv6  +-----+ ipv4  +-----+
| gnb |-------| gw1 |-------| pe1 |-------| dn  |
+-----+ veth  +-----+ veth  +-----+ veth  +-----+
scapy         MUP-GW        MUP-PE
              ISD origin    DSD origin
              + IS-IS L2    + IS-IS L2
                ^                  ^
                |                  |
                +-- gobgpd (MUP-C) --+
                    via separate veth into pe1
```

Roles per netns are identical to the static-underlay baseline; see
`tests/scenarios/frr_mup_e2e_gobgp_scapy/README.md` for the table.

## Address plan

Identical to `frr_mup_e2e_gobgp_scapy`:

| Element                          | Value                          |
|----------------------------------|--------------------------------|
| gNB-side IPv4                    | `10.99.0.0/24`                 |
| GTP-U service IP (T2ST endpoint) | `10.99.0.100/32`               |
| SR-domain IPv6                   | `2001:db8:1::/64`              |
| DN-side IPv4                     | `10.1.0.0/24`                  |
| MUP-C control bus                | `2001:db8:0::/64`              |
| pe1 SR locator                   | `2001:db8:e::/48`              |
| gw1 SR locator                   | `2001:db8:f::/48`              |
| UE prefix                        | `192.168.10.5/32`              |
| TEID / QFI                       | 12345 / 9                      |
| MUP-EC seg-id                    | `10:10`                        |

The locator prefixes are advertised between gw1 and pe1 over IS-IS
L2; the script waits for the IS-IS adjacency to come up
(`show isis neighbor json` -> `state Up`) and for the kernel routes
tagged `proto isis` to land before injecting MUP routes.

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_e2e_isis_gobgp_scapy/frr_mup_e2e_isis_gobgp_scapy.sh" \
  /tmp/run.log
grep -E '===VERDICT|FRR-MUP-E2E-ISIS' /tmp/run.log
```

## Pass criteria

Same as the static-underlay baseline; final line is
`FRR-MUP-E2E-ISIS-GOBGP-SCAPY: PASS`.  See
`tests/scenarios/frr_mup_e2e_gobgp_scapy/README.md` for the per-check
description.

## See also

- Static-underlay baseline: `tests/scenarios/frr_mup_e2e_gobgp_scapy/`
- IPv6 variant: `tests/scenarios/frr_mup_e2e_gtp6_gobgp_scapy/`
