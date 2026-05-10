# frr_interop_mup

FRR-to-FRR BGP-MUP interop, end-to-end inside one vng VM.  gobgpd
injects ISD/DSD/T1ST/T2ST into pe1 over BGP-MUP; pe1 re-advertises
to pe2; pe2 must end up with `seg6local` routes for the T2ST endpoint
SIDs (`End.M.GTP4.E` / `End.M.GTP6.E`) and the `seg6` H.Encaps install
for the T1ST UE prefix.  Pure control-plane test — no GTP-U data path.

## Topology

```
+------+ veth +------+ veth +------+
| gbgp |------| pe1  |------| pe2  |
|65000 | eBGP |65001 | eBGP |65002 |
+------+      +------+      +------+
 gobgpd        FRR           FRR
              (zebra+bgpd)   (zebra+bgpd)
```

All three nodes are netns inside a single vng VM.

| netns  | Role                                        |
|--------|---------------------------------------------|
| `gbgp` | gobgpd MUP-Controller (originates MUP NLRI) |
| `pe1`  | FRR transit / re-advertiser                 |
| `pe2`  | FRR receive-side install verification node  |

## Address plan

| Element                              | Value                                |
|--------------------------------------|--------------------------------------|
| `gbgp` <-> `pe1` BGP session         | `2001:db8:1::2 / ::1`                |
| `pe1`  <-> `pe2` BGP session         | `2001:db8:2::1 / ::2`                |
| Local SR locator on pe1/pe2          | `2001:db8:e::/48` (block 24/node 24/func 8) |
| pe1/pe2 vrf                          | `slice1`, table 100                  |
| ISD prefix v4                        | `10.99.0.0/24`                       |
| DSD address                          | `10.0.0.250`                         |
| T1ST UE prefix                       | `192.168.1.1/32`                     |
| T1ST endpoint                        | `10.99.0.1` (inside ISD)             |
| T2ST IPv4 endpoint / SID             | `10.0.0.1` / `2001:db8:e::100`       |
| T2ST IPv6 endpoint / SID             | `2001:db8:99::1` / `2001:db8:e::200` |
| RT (v4 / v6)                         | `10:10` / `20:20`                    |
| ASNs                                 | gbgp 65000, pe1 65001, pe2 65002     |

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
script -q -c "vng -m 4G --rwdir=/tmp \
  --run $ROOT/linux --user root \
  -- env PATH=$ROOT/iproute2/ip:\$PATH \
     bash $ROOT/srv6-mup-tests/tests/scenarios/frr_interop_mup/frr_interop_mup.sh" \
  /tmp/run-frr-interop-mup.log
grep -E '===FRR-INTEROP-MUP===' /tmp/run-frr-interop-mup.log
```

Requires the same prerequisites as the other FRR tests: kernel from
`../linux`, iproute2 from `../iproute2`, FRR from `../frr`,
`gobgp`/`gobgpd` in `../srv6-mup-tests/.bin/`.

## Pass criteria

`===FRR-INTEROP-MUP=== PASS` is printed iff both pe1 and pe2 have all
three of these installs:

- `seg6local action End.M.GTP4.E` for the T2ST IPv4 endpoint SID, in
  the SR-underlay (default) IPv6 table.
- `seg6local action End.M.GTP6.E` for the T2ST IPv6 endpoint SID, in
  the SR-underlay (default) IPv6 table.
- `encap seg6 mode encap` route for the T1ST UE prefix
  `192.168.1.1/32`, inside `slice1` (table 100).

## See also

- `tests/scenarios/frr_only_segment/` — FRR-only origination baseline (no
  external MUP-Controller).
- `tests/scenarios/frr_mup_multi_vrf_gobgp_scapy/` — RT-split per-vrf import
  variant.
- `tests/scenarios/frr_mup_e2e_gobgp_scapy/` — same control plane but with
  the GTP-U data path exercised.
