# frr_only_segment

FRR-only BGP-MUP origination test: no external MUP-Controller
(gobgp).  pe1 originates ISD from `slice1`
(`network` + `segment interwork` under `address-family ipv[46] mup`)
and DSD from `slice2`
(`segment direct` sub-block under `address-family ipv4 mup`); pe2
receives both.  Two slices are required because
`segment <interwork|direct>` is mutually exclusive within a single
(vrf, AFI) policy under SAFI_MUP.  This verifies FRR's MUP-PE / MUP-GW
origination paths independently of any external MUP-C, plus the
add-then-remove race on the `network` directive within a single
vtysh transaction.

## Topology

```
+-----+ veth +-----+
| pe1 |------| pe2 |
|65001| eBGP |65002|
+-----+      +-----+
```

| netns | Role                                                   |
|-------|--------------------------------------------------------|
| `pe1` | Originator (slice1 ISD + slice2 DSD)                   |
| `pe2` | Receive-side install / propagation verifier            |

## Address plan

| Element                              | Value                                       |
|--------------------------------------|---------------------------------------------|
| pe1 <-> pe2 BGP session              | `2001:db8:2::1 / ::2`                       |
| pe1 SR locator (default)             | `2001:db8:e::/96` (block 40/node 24/func 16/arg 0) |
| pe1 slice1                           | vrf, table 100 (ISD origin)                 |
| pe1 slice2                           | vrf, table 200 (DSD origin)                 |
| ISD prefix v4                        | `10.99.0.0/24` (`segment interwork`)        |
| ISD prefix v6                        | `2001:db8:99::/64` (`segment interwork`)    |
| DSD address v4                       | `10.0.0.250` (`segment direct`)             |
| ASNs                                 | pe1 65001, pe2 65002 (eBGP)                 |

## How to run

```bash
ROOT=$(cd .. && pwd)  # parent of srv6-mup-tests/ (run from the repo root)
script -q -c "vng -m 4G --rwdir=/tmp \
  --run $ROOT/linux --user root \
  -- env PATH=$ROOT/iproute2/ip:\$PATH \
     bash $ROOT/srv6-mup-tests/tests/scenarios/frr_only_segment/frr_only_segment.sh" \
  /tmp/run-frr-only-segment.log
grep -E '===FRR-ONLY-SEGMENT===' /tmp/run-frr-only-segment.log
```

## Pass criteria

`===FRR-ONLY-SEGMENT=== PASS` is printed iff:

1. pe1's MUP RIB carries the locally-originated ISD(v4), DSD(v4), and
   ISD(v6) entries.
2. pe2's MUP RIB receives all three from pe1.
3. The Prefix-SID Structure sub-sub-TLV (RFC 9252 Section 3.1)
   propagates with `[40 24 16 0 0 0]` (matches the locator config).
4. The race-cancel transaction (`network ... ; no network ...` in a
   single vtysh batch) leaves neither a stale BGP-MUP RIB entry nor a
   leaked running-config line.
5. Running-config emits the operator's origination directives
   (`network`, `address`, `segment interwork`, `segment direct`).

## See also

- `tests/scenarios/frr_locator_recreate/` — locator delete / recreate
  regression that builds on this baseline.
- `tests/scenarios/frr_interop_mup/` — origination via an external
  gobgp MUP-Controller.
