# BGP-MUP CLI property tests

Single-PE pytest suite driving FRR's BGP-MUP vtysh surface with
`hypothesis`-generated input.  Lives in `tests/cli/`.

The MUP CLI surface is reachable only under
`address-family ipv[46] mup` of a non-default-vrf bgp instance, since
all MUP-policy DEFPYs are consolidated there
(`bgpd/bgp_mup.c:bgp_mup_vty_init`).  The fixture `pe1/frr.conf`
activates the MUP AF in both default and non-default-vrf instances so
the context-guard property hits `bgp_mup_export_check_ctx` rather than
dying at the lexer.

## Invariants under exercise

For each in-DEFPY guard or shape constraint in `bgpd/bgp_mup.c` the
suite declares a property and lets `hypothesis` shrink-search the
input space.

1. **Round-trip + idempotence.**  For commands that store the
   operator's literal input (`rd`, `segment direct address`, DSD
   `segment-id`), the line emitted by `show running-config` is
   byte-identical to what the operator typed.  Re-running the same
   command leaves the config unchanged.  For canonicalising commands
   (`sid explicit X:X::X:X`), the round-tripped IPv6 address parses
   back to the same value as the input.

2. **`no` clears state.**  Any valid set followed by the
   value-bearing `no <command> <value>` removes the line from
   running-config.

3. **Default-vrf context guard.**  Every MUP-AF DEFPY issued under the
   default-vrf bgp instance returns
   `% MUP policy must be configured under a non-default vrf bgp instance`.
   Strategy ranges over the full valid input space for each command,
   so an accidentally weakened guard surfaces as a failing example
   from any value.

4. **Malformed input never round-trips.**  Inputs that don't match
   the lexer / in-DEFPY parser produce a `% Unknown command` /
   `% Malformed ...` reply AND the line is absent from
   running-config.  Strategy spans random alphabetic strings and
   `garbage:garbage` shapes that match the token form but not the
   numeric content.

5. **`route-map` direction restricted to <import|export>.**  The
   DEFPY for `route-map` accepts only those two keywords (no `both`,
   mirror of L3VPN's `route-map vpn import|export`).

## Strategies

| Token | Strategy |
|---|---|
| RD `ASN:NN_OR_IP-ADDRESS:NN` | `<ASN16>:<NN32>` ∪ `<IPv4>:<NN16>` ∪ `<ASN32>:<NN16>` |
| RT `RTLIST` | same lexical shape as RD |
| DSD `segment-id ASN:NN` | `<ASN16>:<NN32>` (per `bgp_mup_parse_seg_id_str`) |
| `address A.B.C.D` | `hypothesis.strategies.ip_addresses(v=4)` |
| `sid explicit X:X::X:X` | `hypothesis.strategies.ip_addresses(v=6)` |
| Malformed | random lower-case strings, or `garbage:garbage` pairs |

## How to run

The runner uses `uv` to manage the Python venv (which includes
`hypothesis`) and `sudo` to run pytest as root (netns + vrf + dummy
interface creation needs `NET_ADMIN`):

```bash
scripts/run_cli_props.sh                 # everything (~30 s)
scripts/run_cli_props.sh -k round_trip   # only round-trip props
scripts/run_cli_props.sh -k always_rejected
                                         # only the always-rejection props
scripts/run_cli_props.sh --hypothesis-show-statistics
                                         # show example counts / shrinking
scripts/run_cli_props.sh -x -vv          # extra args forwarded to pytest
```

Default profile: `max_examples=25`, no deadline.  Bump example count
for deeper fuzzing via the `HYPOTHESIS_MAX_EXAMPLES` env var:

```bash
HYPOTHESIS_MAX_EXAMPLES=200  scripts/run_cli_props.sh   # ~4-5 min
HYPOTHESIS_MAX_EXAMPLES=500  scripts/run_cli_props.sh   # ~10 min
HYPOTHESIS_MAX_EXAMPLES=1000 scripts/run_cli_props.sh   # ~25 min
```

The suite runs on the host — not under `vng`.  The CLI commands
under test exercise BGP-MUP code paths that don't depend on the
kernel-side SRv6 MUP behaviors, so the kernel selftests' / VPP
interop scenarios' `vng` boot would only add latency without gaining
coverage.

The fixture expects the standard sibling layout:

```
<parent>/
├── frr/                            (the FRR build with bgp_mup.c)
├── iproute2/                       (newer iproute2; PATH-prepended for ip)
└── srv6-mup-tests/                 (this repo; worktrees are equivalent)
```

## Conf layout

`tests/cli/pe1/frr.conf` is a single-file config in the same shape
the rest of `scripts/frr_*` uses: daemons (mgmtd / zebra / bgpd) come
up empty, and the conf is rendered via `vtysh -f /tmp/pe1/frr.conf`
once the vty socket is ready.  The conf opens the MUP AF in three
bgp instances (default, slice1, slice2) so the property suite has
both contexts on hand without needing per-test conf reloads.

## What categories of bugs the suite catches

1. **Round-trip drift** — if the writeback path drops, normalises, or
   reformats a line, the round-trip property fails on a shrunken
   minimal example.
2. **Context guard regressions** — if the default-vrf rejection in
   `bgp_mup_export_check_ctx` is silently weakened, the
   always-rejected property fails on a wide range of valid values.
3. **Lexer / DEFPY token-shape regressions** — if the DEFPY token for
   `rd` is widened to accept arbitrary strings, the malformed
   property fails with an alphabetic-only example.
4. **EXPLICIT-bit / writeback round-trip regressions** — covered by
   the round-trip property which exercises the writeback path on
   every shrunk example.

## Validation gate

To confirm a property actually exercises the guard it claims to,
deliberately weaken the guard, rebuild bgpd, and run the suite —
hypothesis should converge on a minimal counter-example within a
few seconds of shrinking.  Restore the guard before committing.
