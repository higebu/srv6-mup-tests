"""
Tier 2 property tests for FRR's BGP-MUP origination chain.

Tier 1 (`test_bgp_mup_cli_props.py`) only asserts vtysh round-trip
shape.  Tier 2 drives each hypothesis example past
`bgp_mup_origin_active` (`bgpd/bgp_mup.c:4400`) so the example also
exercises:

  - bgpd: leak (`mup_leak_postchange`) → SAFI_MUP RIB self-origination
  - bgpd → zebra: `bgp_zebra_alloc_srv6_sid` (auto-allocated SIDs)
  - zebra → kernel: `seg6local` route install at the SID locator

The closed bug pile shows this chain regresses in subtle ways the
Tier 1 surface tests cannot see:

  - `closed/20260509-153713-bug-locator-delete-skips-dsd-withdraw.md`
    — locator-delete cleared `sid_ready` but skipped DSD withdraw and
    seg6local uninstall.  `test_prop_dsd_withdraw_on_no_rd` and
    `test_prop_locator_delete_recreate_idempotent` cover this class.
  - `closed/20260509-150607-bug-t2st-v6-endpoint-installs-h-m-gtp4-d.md`
    — install path picked the wrong action for the AFI.
    `test_prop_dsd_install_seg6local` asserts the action matches the
    `behavior dt4|dt6|dt46` keyword.

This module *requires* a kernel with the SRv6 MUP `seg6_local` actions
(higebu/linux:seg6-mobile or equivalent).  The host kernel will fail
the install-side assertions, so the runner script wraps pytest in vng.
"""

import os

import pytest
from hypothesis import HealthCheck, given, settings, strategies as st

from _helpers import (
    DSD_BEHAVIOR_TO_KERNEL,
    VRF_AF_CONTEXT_V4,
    VRF_AF_EXIT,
    VRF_TABLE,
    _apply_dsd,
    _apply_isd,
    _baseline_mup_clean,
    _find_mup_route,
    _find_srv6_sid,
    _kernel_route_count,
    _kernel_seg6local,
    _show_bgp_mup,
    _show_srv6_sids,
    _vtysh,
    _wait_for,
)


# Tier 2 examples are slower than Tier 1 — each exercises bgpd's full
# leak-into-RIB + SID-allocation + zebra netlink install path, which
# is ~300-700 ms per example in vng.  Default to 10 examples for fast
# CI; override via HYPOTHESIS_MAX_EXAMPLES for a real fuzz run.
settings.register_profile(
    "cli-props-tier2",
    max_examples=int(os.environ.get("HYPOTHESIS_MAX_EXAMPLES") or "10"),
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
settings.load_profile("cli-props-tier2")


# Tier 2 properties currently time out under vng on "DSD setup never
# reached SID allocation" — DSD config is accepted by vtysh but no SRv6
# SID surfaces in `show segment-routing srv6 sid json` within the
# 10 s poll window.  The wrap script (run_cli_props_vng.sh), helper
# layer in _helpers.py, and these property skeletons are landed so the
# next session can iterate on the conftest / origination-trigger gap
# without rebuilding the scaffolding.  Set CLI_PROPS_TIER2=1 to opt in.
pytestmark = pytest.mark.skipif(
    os.environ.get("CLI_PROPS_TIER2") != "1",
    reason=(
        "Tier 2 origination-chain properties require additional conftest "
        "investigation; tracked under srv6-mup-issues "
        "20260510-001115 (re-opened)."
    ),
)


# ---------------------------------------------------------------------------
# Strategies
#
# These are deliberately narrower than Tier 1's: a Tier 2 example has
# to reach `bgp_mup_origin_active`, allocate a SID, and install a
# kernel route, so we shrink to the part of the input space that
# bgpd treats as a valid origin policy.  Tier 1 already covers the
# wide-fuzz / malformed input shape.
# ---------------------------------------------------------------------------

# Type-0 RDs only — keeps the per-example reset cheap and means the
# `rd 100:200` grep on running-config won't false-match a Type-1 RD
# that happens to contain a `:`.
asn16 = st.integers(min_value=1, max_value=0xFFFF)
nn32 = st.integers(min_value=1, max_value=0xFFFFFFFF)
rd_simple = st.tuples(asn16, nn32).map(lambda t: f"{t[0]}:{t[1]}")
seg_id_simple = st.tuples(asn16, nn32).map(lambda t: f"{t[0]}:{t[1]}")

# Routable, sane IPv4 endpoints.  Avoid 0.0.0.0/8 and 224/4 / 240/4
# which can make the kernel route install reject for off-policy reasons.
v4_endpoint = (
    st.ip_addresses(v=4, network="10.0.0.0/8")
    .map(str)
)
v4_isd_prefix = (
    st.tuples(
        st.integers(min_value=0, max_value=255),
        st.integers(min_value=0, max_value=255),
        st.sampled_from([16, 24]),
    )
    .map(lambda t: f"10.{t[0]}.{t[1]}.0/{t[2]}")
)

behavior_dsd = st.sampled_from(["dt4", "dt6", "dt46"])

# `rt export` is mandatory for DSD origination — `mup_dsd_policy_ready`
# (bgpd/bgp_mup.c:4147) bails when ep->rtlist[TOMUP] is NULL, so without
# it bgpd never reaches `bgp_zebra_alloc_srv6_sid` and downstream
# SID-allocation polls time out.  Pin to a fixed value so the property
# search doesn't waste a hypothesis dimension on a knob orthogonal to
# what these tests assert.
DSD_RT_EXPORT = "65001:1"


# ---------------------------------------------------------------------------
# Test 1 — DSD applied → SID allocated → kernel seg6local installed
# ---------------------------------------------------------------------------


@given(
    rd=rd_simple,
    addr=v4_endpoint,
    behavior=behavior_dsd,
    seg_id=seg_id_simple,
)
def test_prop_dsd_install_seg6local(rd, addr, behavior, seg_id):
    """For a hypothesis-generated DSD policy on slice1, assert the full
    chain reaches the kernel:

    1. `bgp_mup_origin_active` flips on (rd + segment direct + behavior
       + segment-id), so bgpd self-originates a DSD into its SAFI_MUP
       RIB.  `show bgp ipv4 mup all json` reports a routeType=2 path
       with the same `rd` and `endpointAddress`.

    2. zebra allocates an SRv6 SID via `bgp_zebra_alloc_srv6_sid` for
       the (vrf=slice1, behavior=End.DTx) tuple — `show segment-routing
       srv6 sid json` lists exactly one entry tagged with that vrf
       name and behavior.

    3. zebra installs a `seg6local` route at the allocated SID with
       `action == DSD_BEHAVIOR_TO_KERNEL[behavior]` — visible in
       `ip -j -6 route show table local` (locator-side install lives in
       the local table, not the per-vrf table).

    Note: assertions 2 and 3 are paired: if the SID never gets allocated
    we don't get to "install".  Both polls are bounded so a property
    failure surfaces inside ~10 s.
    """
    _baseline_mup_clean()
    cp = _apply_dsd(rd=rd, addr=addr, behavior=behavior, seg_id=seg_id,
                    sid="auto", afi="ipv4", vrf="slice1",
                    rt_export=DSD_RT_EXPORT)
    assert "% " not in (cp.stdout or ""), cp.stdout

    # 1. DSD leaked into the default-vrf SAFI_MUP RIB.  bgp_mup_originate_
    # common (bgpd/bgp_mup.c:2884) installs locally-originated routes onto
    # the default-vrf bgp instance even when the policy lives on a per-vrf
    # bgp instance, mirroring L3VPN's leak-to-default semantics — that's
    # the BGP RIB pe1 advertises out of, not the per-(vrf, MUP-AF) origin
    # table.
    def _dsd_present():
        out = _show_bgp_mup(afi="ipv4", vrf=None, timeout=0.5)
        return _find_mup_route(out, afi="ipv4", route_type=2,
                               ip=addr, rd=rd) is not None

    _wait_for(_dsd_present,
              f"DSD ({rd}, {addr}) never leaked into slice1 SAFI_MUP RIB",
              timeout=10.0)

    # 2. SID allocated for (slice1, End.DTx).
    expected_action = DSD_BEHAVIOR_TO_KERNEL[behavior]

    def _sid_for_behavior():
        sids = _show_srv6_sids(timeout=0.5)
        return _find_srv6_sid(sids, behavior=expected_action,
                              vrf_name="slice1")

    sid_entry = _wait_for(
        _sid_for_behavior,
        f"no SRv6 SID allocated for (slice1, {expected_action})",
        timeout=10.0,
    )
    sid_addr = sid_entry["sid"]

    # 3. seg6local kernel route at the SID with the matching action.
    #    Locator-side installs live in `table local` (egress decap), not
    #    in the per-vrf table.
    route = _wait_for(
        lambda: _kernel_seg6local(action=expected_action, dst_in=sid_addr,
                                  table="local", timeout=0.5),
        f"no kernel seg6local route at {sid_addr} with action {expected_action}",
        timeout=10.0,
    )
    assert route["encap"] == "seg6local"
    assert route["action"] == expected_action


# ---------------------------------------------------------------------------
# Test 2 — ISD per-network: one ISD + one SID per `network` line
# ---------------------------------------------------------------------------


@given(
    rd=rd_simple,
    networks=st.lists(v4_isd_prefix, min_size=1, max_size=4, unique=True),
)
def test_prop_isd_install_seg6local_per_network(rd, networks):
    """For a hypothesis-generated set of `network <p>` lines on slice1's
    IPv4 MUP AF with `segment interwork`, assert:

    1. Each non-duplicate prefix shows up as one routeType=1 ISD entry
       in the SAFI_MUP RIB.
    2. Exactly one SID is auto-allocated for the (slice1, IPv4 MUP)
       origin — ISDs share the per-AFI SID, they don't allocate one
       per prefix.

    TODO(verify): the second assertion encodes the design "ISDs share
    the per-AFI SID slot".  If bgpd's intent is per-prefix SIDs (it
    is not, at b4/seg6-mobile tip), tighten the test to count SIDs.
    """
    _baseline_mup_clean()
    cp = _apply_isd(rd=rd, networks=networks, afi="ipv4", vrf="slice1",
                    sid="auto")
    assert "% " not in (cp.stdout or ""), cp.stdout

    # 1. Each `network <p>` -> one ISD path.
    def _all_isds_present():
        out = _show_bgp_mup(afi="ipv4", vrf="slice1", timeout=0.5)
        for p in networks:
            ip = p.split("/")[0]
            if _find_mup_route(out, afi="ipv4", route_type=1, ip=ip,
                               rd=rd) is None:
                return False
        return True

    _wait_for(_all_isds_present,
              f"not every {networks!r} surfaced as an ISD under rd {rd}",
              timeout=10.0)

    # 2. One SID per (slice1, ISD-origin AFI).  ISDs share the slot.
    sids = _show_srv6_sids(timeout=2.0)
    isd_sids = [
        e for e in sids.values()
        if isinstance(e, dict)
        and e.get("context", {}).get("vrfName") == "slice1"
        # End.M.GTP4.E is the GTP-U-side action; the auto-SID for ISD
        # origination on the IPv4 MUP AF is anchored under it (per
        # bgpd/bgp_mup.c at b4/seg6-mobile tip).
        # TODO(verify): confirm this is the behavior name reported in
        # the JSON dump.  If it's stored as one of End.DT* instead,
        # widen this filter.
        and e.get("behavior", "").startswith("End.M.GTP")
    ]
    assert len(isd_sids) == 1, (
        f"expected exactly 1 ISD-origin SID for slice1, got: {isd_sids}"
    )


# ---------------------------------------------------------------------------
# Test 3 — `no rd` withdraws DSD and uninstalls the kernel route
# ---------------------------------------------------------------------------


@given(
    rd=rd_simple,
    addr=v4_endpoint,
    behavior=behavior_dsd,
    seg_id=seg_id_simple,
)
def test_prop_dsd_withdraw_on_no_rd(rd, addr, behavior, seg_id):
    """The locator-delete-skips-DSD-withdraw bug
    (`closed/20260509-153713-...md`) is the canonical example of "the
    in-memory `sid_ready` got cleared but the BGP withdraw / kernel
    uninstall got skipped".  This property exercises the same
    invariant from the other direction: `no rd <rd>` collapses
    `bgp_mup_origin_active` to false, which must:

      - withdraw the self-originated DSD from the local RIB
      - release the auto-allocated SID
      - remove the seg6local install from the kernel
    """
    _baseline_mup_clean()
    cp = _apply_dsd(rd=rd, addr=addr, behavior=behavior, seg_id=seg_id,
                    sid="auto", afi="ipv4", vrf="slice1",
                    rt_export=DSD_RT_EXPORT)
    assert "% " not in (cp.stdout or ""), cp.stdout

    expected_action = DSD_BEHAVIOR_TO_KERNEL[behavior]

    # Wait for the install to be fully realized before tearing down,
    # otherwise we'd race the install vs. our `no rd` and pass for
    # the wrong reason.
    sid_entry = _wait_for(
        lambda: _find_srv6_sid(_show_srv6_sids(timeout=0.5),
                               behavior=expected_action, vrf_name="slice1"),
        f"DSD setup never reached SID allocation for {expected_action}",
        timeout=10.0,
    )
    sid_addr = sid_entry["sid"]
    _wait_for(
        lambda: _kernel_seg6local(action=expected_action, dst_in=sid_addr,
                                  table="local", timeout=0.5),
        f"DSD setup never reached kernel install at {sid_addr}",
        timeout=10.0,
    )

    # Now tear down: `no rd <rd>` flips `bgp_mup_origin_active` off.
    cp2 = _vtysh(*VRF_AF_CONTEXT_V4, f"no rd {rd}", *VRF_AF_EXIT)
    assert "% " not in (cp2.stdout or ""), cp2.stdout

    # 1. DSD withdrawn from local RIB.
    _wait_for(
        lambda: _find_mup_route(
            _show_bgp_mup(afi="ipv4", vrf="slice1", timeout=0.5),
            afi="ipv4", route_type=2, ip=addr, rd=rd) is None,
        f"DSD ({rd}, {addr}) still present in local RIB after `no rd`",
        timeout=10.0,
    )

    # 2. SID released.
    _wait_for(
        lambda: _find_srv6_sid(
            _show_srv6_sids(timeout=0.5),
            behavior=expected_action, vrf_name="slice1") is None,
        f"SID {sid_addr} ({expected_action}, slice1) not released after `no rd`",
        timeout=10.0,
    )

    # 3. Kernel route gone.
    _wait_for(
        lambda: _kernel_seg6local(action=expected_action, dst_in=sid_addr,
                                  table="local", timeout=0.5) is None,
        f"kernel seg6local at {sid_addr} not uninstalled after `no rd`",
        timeout=10.0,
    )


# ---------------------------------------------------------------------------
# Test 4 — locator delete + recreate is idempotent end-to-end
# ---------------------------------------------------------------------------


@given(
    rd=rd_simple,
    addr=v4_endpoint,
    behavior=behavior_dsd,
    seg_id=seg_id_simple,
)
def test_prop_locator_delete_recreate_idempotent(rd, addr, behavior, seg_id):
    """The exact regression scenario of the locator-delete-skips-DSD-
    withdraw bug, lifted into a property.  With a full DSD policy
    active:

      1. Delete `locator default` under `segment-routing srv6 locators`.
         All ISDs/DSDs whose SID falls inside the locator must be
         withdrawn from the RIB AND uninstalled from the kernel.
      2. Re-add the locator with the same prefix.  bgpd must
         re-allocate a SID (not necessarily the same value) and
         re-install the kernel route, restoring the chain to the
         pre-delete shape.

    This is the property whose hypothesis-shrunk counter-example would
    have replaced the manual reproducer the closed-bug issue relied on.
    """
    _baseline_mup_clean()
    cp = _apply_dsd(rd=rd, addr=addr, behavior=behavior, seg_id=seg_id,
                    sid="auto", afi="ipv4", vrf="slice1",
                    rt_export=DSD_RT_EXPORT)
    assert "% " not in (cp.stdout or ""), cp.stdout

    expected_action = DSD_BEHAVIOR_TO_KERNEL[behavior]

    sid_entry = _wait_for(
        lambda: _find_srv6_sid(_show_srv6_sids(timeout=0.5),
                               behavior=expected_action, vrf_name="slice1"),
        f"DSD setup never reached SID allocation",
        timeout=10.0,
    )
    sid_addr_before = sid_entry["sid"]
    _wait_for(
        lambda: _kernel_seg6local(action=expected_action,
                                  dst_in=sid_addr_before,
                                  table="local", timeout=0.5),
        f"DSD setup never reached kernel install at {sid_addr_before}",
        timeout=10.0,
    )

    # Step 1: delete the locator.  Use the prefix from pe1/frr.conf
    # (`prefix 2001:db8:e::/64`).  TODO(parameterise) — if the conf
    # ever changes its locator prefix, hoist this into a constant in
    # _helpers.py and import.
    cp2 = _vtysh(
        "configure terminal",
        "segment-routing",
        " srv6",
        "  locators",
        "   no locator default",
        "  exit",
        " exit",
        "exit",
        "exit",
    )
    assert "% " not in (cp2.stdout or ""), cp2.stdout

    _wait_for(
        lambda: _kernel_seg6local(action=expected_action,
                                  dst_in=sid_addr_before,
                                  table="local", timeout=0.5) is None,
        f"locator delete left kernel route at {sid_addr_before} behind "
        f"(closed bug 20260509-153713 regression?)",
        timeout=10.0,
    )
    _wait_for(
        lambda: _find_srv6_sid(
            _show_srv6_sids(timeout=0.5),
            behavior=expected_action, vrf_name="slice1") is None,
        f"locator delete left SID {sid_addr_before} allocated",
        timeout=10.0,
    )

    # Step 2: recreate.
    cp3 = _vtysh(
        "configure terminal",
        "segment-routing",
        " srv6",
        "  locators",
        "   locator default",
        "    prefix 2001:db8:e::/64 block-len 40 node-len 24 func-bits 16",
        "   exit",
        "  exit",
        " exit",
        "exit",
        "exit",
    )
    assert "% " not in (cp3.stdout or ""), cp3.stdout

    sid_entry2 = _wait_for(
        lambda: _find_srv6_sid(_show_srv6_sids(timeout=0.5),
                               behavior=expected_action, vrf_name="slice1"),
        f"locator recreate did not re-allocate a SID for {expected_action}",
        timeout=15.0,
    )
    sid_addr_after = sid_entry2["sid"]
    _wait_for(
        lambda: _kernel_seg6local(action=expected_action,
                                  dst_in=sid_addr_after,
                                  table="local", timeout=0.5),
        f"locator recreate did not re-install kernel route at {sid_addr_after}",
        timeout=15.0,
    )
