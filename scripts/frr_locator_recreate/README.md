# frr_locator_recreate

End-to-end harness that exercises the BGP-MUP locator chunk
delete -> recreate path on FRR (`bgp_mup.c`).  When the operator
removes the SRv6 locator behind an auto-SID origination, bgpd must
release the locator chunk and withdraw every ISD/DSD it had originated
under that locator; when the same locator is added back, bgpd must
re-acquire chunks via `bgp_mup_replay_origins_all()` and re-originate
the ISD/DSD from the same prefix.  The harness asserts both directions
on `vtysh -c 'show bgp ipv[46] mup all'` (origination side) and on the
peer's BGP-MUP RIB (receive side), plus zebra's `seg6local` install on
the originator.  No GTP-U data plane is involved; this is a pure
control-plane regression.

## Topology

```
+-----+ veth-pe1   veth-pe2 +-----+
| pe1 |--- 2001:db8:2::/64 -| pe2 |
| AS  |      eBGP MUP       | AS  |
|65001|                     |65002|
+-----+                     +-----+
   |
   +-- vrf slice1 (table 100)
       originates ISD 10.99.0.0/24, 2001:db8:99::/64
       originates DSD 10.0.0.250
       SRv6 locator default = 2001:db8:e::/64
```

Both PEs run FRR (mgmtd + zebra + bgpd).  pe1 owns the SRv6 locator and
the per-vrf BGP instance that originates ISD/DSD; pe2 only receives.

## Address plan

| Item                    | Value                              |
|-------------------------|------------------------------------|
| Transport link          | `2001:db8:2::/64` (`::1` pe1, `::2` pe2) |
| pe1 vrf                 | `slice1`, table 100                |
| SRv6 locator (pe1)      | `2001:db8:e::/64`, block 40 / node 24 / func 16 |
| ISD prefix v4           | `10.99.0.0/24`                     |
| ISD prefix v6           | `2001:db8:99::/64`                 |
| DSD address v4          | `10.0.0.250`                       |
| RD (v4 / v6)            | `100:100` / `200:200`              |
| RT (v4 / v6)            | `65001:1` / `65001:2`              |
| MUP ext-community (v4)  | `65001:10`                         |
| ASNs                    | pe1 65001, pe2 65002 (eBGP)        |

## Scenario

1. **Phase 1 — baseline.**  Bring up pe1/pe2, wait for both BGP
   sessions (`ipv4 mup`, `ipv6 mup`) to reach Established, and confirm
   pe1 has originated and pe2 has received ISD(v4), ISD(v6), DSD(v4).
   Capture the v4 ISD's auto-SID and verify pe1 has at least one
   `seg6local` `End.D*` install in the local table.
2. **Phase 2 — locator delete.**  On pe1 run

   ```
   configure
    segment-routing
     srv6
      locators
       no locator default
   ```

   then assert: pe1's BGP-MUP RIB has zero ISD/DSD entries, pe2 has
   withdrawn the routes, and pe1's kernel has no `End.D*` `seg6local`
   route under the locator.
3. **Phase 3 — locator recreate.**  Re-add the locator with the same
   prefix and same SID structure:

   ```
   configure
    segment-routing
     srv6
      locators
       locator default
        prefix 2001:db8:e::/64 block-len 40 node-len 24 func-bits 16
   ```

   Assert: ISD(v4), ISD(v6), DSD(v4) reappear on pe1 and propagate to
   pe2, the new auto-SID falls inside `2001:db8:e::/64`, and pe1's
   kernel reinstalls `seg6local`.

The expected wall-clock is well under 30 seconds on a tmpfs `/tmp`.

## How to run

The harness is meant to run inside the project's `vng` rootfs; the FRR
binaries are built in the sibling `frr/` worktree.  From the
`srv6-mup-tests` repo root:

```bash
ROOT=$(pwd)/..
script -q -c "vng -m 4G --rwdir=/tmp \
  --run $ROOT/linux --user root \
  -- env PATH=$ROOT/iproute2/ip:\$PATH \
     bash $ROOT/srv6-mup-tests/scripts/frr_locator_recreate/frr_locator_recreate.sh" \
  /tmp/run-frr_locator_recreate.log
grep -E '^===|FAIL|PASS' /tmp/run-frr_locator_recreate.log
```

The script self-cleans (kills bgpd / zebra / mgmtd by pid file) so it
can be run repeatedly without restarting `vng`.

## Pass criteria

The script prints `===FRR-LOCATOR-RECREATE=== PASS` at the end iff all
of the following hold:

- Phase 1: ISD(v4), ISD(v6), DSD(v4) are present in pe1's and pe2's
  BGP-MUP RIBs and pe1 has at least one `seg6local` `End.D*` install.
- Phase 2: every BGP-MUP entry above is gone from pe1 and pe2 within
  the per-step timeout, and pe1 has zero `seg6local` `End.D*` installs.
- Phase 3: every BGP-MUP entry returns on both sides, the new ISD(v4)
  auto-SID falls within `2001:db8:e::/64`, and pe1 reinstalls
  `seg6local`.

Any failed assertion sets `PASS=0`, dumps pe1/pe2 bgpd + pe1 zebra
logs, and the script exits with `===FRR-LOCATOR-RECREATE=== FAIL`.

## See also

- `scripts/frr_only_segment/` — baseline single-locator harness this
  one was derived from.
- FRR `bgp_mup.c`: locator chunk callbacks and
  `bgp_mup_replay_origins_all()`.
- L3VPN reference behavior: `tests/topotests/bgp_srv6l3vpn_sid/`
  (`test_locator_delete` / `test_locator_recreate`).
