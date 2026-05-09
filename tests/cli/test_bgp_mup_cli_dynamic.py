"""
Dynamic CLI operations.

The dynamic cases — `clear bgp <peer>` reannounce, T1ST/T2ST re-install
after toggle / link-down, FIB withdraw on link-down — are most
meaningful with a peer in the loop, which the single-PE fixture in
this directory can't provide.

Stand-alone single-PE variants (e.g. local-RIB-only `network` +
`segment interwork` to check origination through the
mup_leak_postchange path) regress in fragile ways: with no peer or
interface address, BGP's unicast bestpath does not always select the
static `network` and the ISD does not appear locally — those failures
aren't bugs in the CLI under test, they're test-fixture limitations.

This module is therefore intentionally empty.  The dynamic surface is
exercised by the multi-PE test scripts under `scripts/frr_*` instead.
"""

import pytest


@pytest.mark.skip(reason="dynamic ops covered by scripts/frr_*; see module docstring")
def test_dynamic_placeholder():
    pass
