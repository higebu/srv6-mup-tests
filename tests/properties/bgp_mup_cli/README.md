# tests/properties/bgp_mup_cli — BGP-MUP CLI property tests

Single-PE pytest + `hypothesis` test suite for FRR's BGP-MUP `vtysh`
surface.  Two tiers:

- **Tier 1** (`test_bgp_mup_cli_props.py`) — round-trip preservation,
  context guards, and malformed-input rejection at the parser level.
- **Tier 2** (`test_bgp_mup_cli_props_tier2.py`) — drives the policy
  past `bgp_mup_origin_active` and asserts state in bgpd's local
  SAFI_MUP RIB, zebra's SID manager, and the kernel route table.

The catalogue, input strategies, and validation gate are documented
in [`docs/cli-props.md`](../../docs/cli-props.md).

## Topology

A single FRR node, no peers.  All test traffic is `vtysh -c '...'`
into a daemon set running inside the `pe1` netns.

```
+-------------+
|  pe1 netns  |
| FRR (mgmtd, |
|  zebra,     |
|  staticd,   |
|  bgpd)      |
|             |
|  + slice1   |  vrf, table 100  (per-vrf MUP policy under test)
|  + slice2   |  vrf, table 101  (sibling vrf for cross-vrf checks)
+-------------+
```

| netns | Role                                                          |
|-------|---------------------------------------------------------------|
| `pe1` | Single-node origination + RIB + SID manager surface           |

`slice1` carries the per-vrf MUP policy under test (RD/RT, segment
interwork/direct, sid/nexthop directives).  `slice2` exists so
cross-vrf rejection tests (`segment direct address ... vrf slice2`,
etc.) have a real sibling to refer to.  No external BGP session is
established — Tier 2 tests inject MUP NLRI by issuing `network` /
`segment` directives locally and watching the local-origin path.

The session fixture in `conftest.py` builds the netns and starts FRR;
each test runs `_baseline_mup_clean()` afterward to restore the
per-vrf MUP policy to a known-empty state.

## Address plan

The CLI surface tests don't drive any wire traffic, so the address
plan is minimal:

| Element                          | Value                             |
|----------------------------------|-----------------------------------|
| `pe1` AS / router-id             | 65001 / declared in `pe1/frr.conf`|
| SR locator                       | declared in `pe1/frr.conf`        |
| `slice1` table                   | 100                               |
| `slice2` table                   | 101                               |

Anything else (T1ST UE prefixes, T2ST endpoints, RD/RT values) comes
from the per-test hypothesis strategies.

## How to run

From the repo root, on the host with sudo:

```bash
scripts/run_cli_props.sh                 # Tier 1 + Tier 2, ~30s
```

`run_cli_props.sh` provisions
`/usr/local/var/{run,lib}/frr`, then invokes
`pytest -q tests/properties/bgp_mup_cli/` under sudo so the netns +
daemon spawn succeeds.  Use
`scripts/run_cli_props_vng.sh` to run the same suite inside a vng VM
(useful when your host doesn't satisfy the FRR daemon's requirements
or when you want to pin the exact kernel under test).

## Pass criteria

`pytest` exits 0 (all property tests passed).  Hypothesis prints any
shrunk counter-example on failure; `--hypothesis-show-statistics`
adds per-test draw counts.

## See also

- `docs/cli-props.md` — property catalogue, input strategies, and
  validation evidence.
- `bgpd/bgp_mup.c:bgp_mup_vty_init` — the DEFPYs the tests exercise.
