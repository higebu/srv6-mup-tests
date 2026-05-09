"""
Property-based tests for FRR's BGP-MUP vtysh surface.

For each in-DEFPY guard or shape constraint in `bgpd/bgp_mup.c`,
declare an invariant and let `hypothesis` search the input space for a
counter-example.

The MUP CLI surface is reachable only under
`address-family ipv[46] mup` of a non-default-vrf bgp instance; the
default-vrf MUP AF exists too but every policy DEFPY there is rejected
by `bgp_mup_export_check_ctx`.  The fixture conf opens both kinds of
context so context-guard properties hit the guard and don't die at the
lexer.

Invariants under exercise:

1. Round-trip + idempotence.
   Commands that store the operator's literal input (`rd`,
   `segment direct address`, DSD `segment-id`) round-trip
   byte-identical through `show running-config`.  The canonicalising
   form `sid explicit X:X::X:X` round-trips after IPv6
   canonicalisation.

2. `no` clears state.
   Any valid set followed by the corresponding `no` removes the line.

3. Default-vrf context guard.
   Every MUP-AF DEFPY issued under the default-vrf bgp instance reaches
   `bgp_mup_export_check_ctx` and returns
   `% MUP policy must be configured under a non-default vrf bgp instance`.

4. Malformed input never round-trips.
   Inputs that don't match the lexer / in-DEFPY parser produce a
   `% Unknown command` / `% Malformed ...` reply AND the line is
   absent from running-config.

5. `route-map` direction is restricted to <import|export>.
   The DEFPY accepts neither `both` nor any other word.

Each example resets the non-default-vrf bgp instances explicitly via
`_baseline_mup_clean` (see conftest.py) so hypothesis examples do not
share state.
"""

import ipaddress
import os
import re

import pytest
from hypothesis import HealthCheck, given, settings, strategies as st

from _helpers import (
    DEFAULT_AF_V4_CONTEXT,
    VRF_AF_CONTEXT_V4,
    VRF_AF_DSD_ENTER_V4,
    VRF_AF_DSD_EXIT,
    VRF_AF_EXIT,
    _baseline_mup_clean,
    _running_config,
    _vtysh,
)


# vtysh roundtrips inside a hypothesis example are slow (~80-150 ms).
# 25 examples per property is the default — fast enough for CI / pre-push
# (~30 s for the full suite).  Override with HYPOTHESIS_MAX_EXAMPLES for
# longer fuzzing sessions:
#   - 200  (~4-5 min)  — daily bug hunt
#   - 500  (~10 min)   — post-refactor regression
#   - 1000 (~25 min)   — overnight fuzz
# Disable the deadline because vtysh roundtrip variance is real, and
# silence the function-scoped-fixture warning — the FRR session is
# session-scoped and we reset state explicitly per example.
settings.register_profile(
    "cli-props",
    max_examples=int(os.environ.get("HYPOTHESIS_MAX_EXAMPLES", "25")),
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
settings.load_profile("cli-props")


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

# RFC 4364 RD shapes.  str2prefix_rd in lib/prefix.c accepts:
#   - <ASN16>:<NN32>     (Type 0)
#   - <IPv4>:<NN16>      (Type 1)
#   - <ASN32>:<NN16>     (Type 2)
asn16 = st.integers(min_value=0, max_value=0xFFFF)
asn32 = st.integers(min_value=0, max_value=0xFFFFFFFF)
nn16 = st.integers(min_value=0, max_value=0xFFFF)
nn32 = st.integers(min_value=0, max_value=0xFFFFFFFF)

ipv4_str = st.ip_addresses(v=4).map(str)
ipv6_str = st.ip_addresses(v=6).map(str)

rd_valid = st.one_of(
    st.tuples(asn16, nn32).map(lambda t: f"{t[0]}:{t[1]}"),
    st.tuples(ipv4_str, nn16).map(lambda t: f"{t[0]}:{t[1]}"),
    st.tuples(asn32, nn16).map(lambda t: f"{t[0]}:{t[1]}"),
)

# RT carries the same lexical shape as RD.
rt_valid = rd_valid

# DSD MUP segment-id: bgp_mup_parse_seg_id_str accepts strict ASN:NN
# with ASN <= UINT16_MAX, NN <= UINT32_MAX (bgpd/bgp_mup.c).
seg_id_valid = st.tuples(asn16, nn32).map(lambda t: f"{t[0]}:{t[1]}")

# Malformed: garbage strings that won't accidentally match the lexer
# token shape.  Restrict to lower-case letters so we don't trip on
# unrelated tokens by chance.
garbage = st.text(
    alphabet=st.characters(whitelist_categories=("Ll",)),
    min_size=2,
    max_size=8,
)
malformed_idpair = st.tuples(garbage, garbage).map(lambda t: f"{t[0]}:{t[1]}")

# Direction tokens for `route-map <import|export> RMAP` — anything
# *other than* the two accepted keywords must be rejected.  The DEFPY
# is intentionally narrower than `rt`'s `<import|export|both>`; mirror
# of L3VPN's `route-map vpn import|export` shape.
bad_direction = (
    st.text(
        alphabet=st.characters(whitelist_categories=("Ll", "Lu")),
        min_size=1,
        max_size=10,
    )
    .filter(lambda s: s not in ("import", "export"))
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _stdout(cp):
    """vtysh's per-command replies live on stdout; stderr only carries
    the unrelated 'Can't open vtysh.conf' startup warning."""
    return cp.stdout or ""


def _try(ctx, cmd):
    return _vtysh(*ctx, cmd, *VRF_AF_EXIT)


def _try_dsd(*cmds):
    """Enter `segment direct` sub-node, run @cmds, leave."""
    return _vtysh(*VRF_AF_DSD_ENTER_V4, *cmds, *VRF_AF_DSD_EXIT)


def _reset():
    """Wipe per-vrf MUP policy state.  Called at the start of every
    hypothesis example to keep examples independent."""
    _baseline_mup_clean()


# ---------------------------------------------------------------------------
# Property 1 — round-trip + idempotence
# ---------------------------------------------------------------------------


@given(rd=rd_valid)
def test_prop_rd_round_trip(rd):
    _reset()
    cp = _try(VRF_AF_CONTEXT_V4, f"rd {rd}")
    assert "% " not in _stdout(cp), _stdout(cp)
    assert f"rd {rd}" in _running_config()
    cp2 = _try(VRF_AF_CONTEXT_V4, f"rd {rd}")
    assert "% " not in _stdout(cp2), _stdout(cp2)
    rc = _running_config()
    assert rc.count(f"rd {rd}") == 1


@given(seg_id=seg_id_valid)
def test_prop_segment_id_round_trip(seg_id):
    _reset()
    cp = _try_dsd(f"segment-id {seg_id}")
    assert "% " not in _stdout(cp), _stdout(cp)
    assert f"segment-id {seg_id}" in _running_config()


@given(addr=ipv4_str)
def test_prop_segment_direct_address_round_trip(addr):
    _reset()
    cp = _try_dsd(f"address {addr}")
    assert "% " not in _stdout(cp), _stdout(cp)
    assert f"address {addr}" in _running_config()


@given(addr=ipv6_str)
def test_prop_sid_explicit_round_trip(addr):
    """`sid explicit X:X::X:X` round-trips after IPv6 canonicalisation
    (FRR re-prints with %pI6, which uses the compressed form)."""
    _reset()
    cp = _try(VRF_AF_CONTEXT_V4, f"sid explicit {addr}")
    assert "% " not in _stdout(cp), _stdout(cp)
    rc = _running_config()
    m = re.search(r"sid explicit (\S+)", rc)
    assert m, f"no sid line in:\n{rc}"
    assert ipaddress.IPv6Address(m.group(1)) == ipaddress.IPv6Address(addr)


# ---------------------------------------------------------------------------
# Property 2 — `no` clears state
# ---------------------------------------------------------------------------


@given(rd=rd_valid)
def test_prop_rd_no_clears(rd):
    """`no rd <rd>` removes the line.

    Note: the value-less alias `no rd` historically tripped
    `Internal CLI error [rd_str]` from the clippy-generated DEFPY
    wrapper because the ALIAS shape strips the `ASN:NN$rd_str`
    token while the DEFPY signature still declared it.  This
    property test uses the value-bearing form, which is the form
    `bgp_mup_config_write_af` round-trips into running-config so it
    always matches.
    """
    _reset()
    _try(VRF_AF_CONTEXT_V4, f"rd {rd}")
    cp = _try(VRF_AF_CONTEXT_V4, f"no rd {rd}")
    assert "% " not in _stdout(cp), _stdout(cp)
    rc = _running_config()
    assert not re.search(r"^\s+rd ", rc, re.MULTILINE), rc


@given(seg_id=seg_id_valid)
def test_prop_segment_id_no_clears(seg_id):
    _reset()
    _try_dsd(f"segment-id {seg_id}")
    cp = _try_dsd(f"no segment-id {seg_id}")
    assert "% " not in _stdout(cp), _stdout(cp)
    rc = _running_config()
    assert "segment-id" not in rc, rc


# ---------------------------------------------------------------------------
# Property 3 — default-vrf context guard always fires
# ---------------------------------------------------------------------------


_CTX_GUARD = "must be configured under a non-default vrf"


@given(rd=rd_valid)
def test_prop_rd_default_vrf_always_rejected(rd):
    _reset()
    cp = _vtysh(
        *DEFAULT_AF_V4_CONTEXT,
        f"rd {rd}",
        *VRF_AF_EXIT,
    )
    assert _CTX_GUARD in _stdout(cp), _stdout(cp)


@given(rt=rt_valid, direction=st.sampled_from(["import", "export", "both"]))
def test_prop_rt_default_vrf_always_rejected(rt, direction):
    _reset()
    cp = _vtysh(
        *DEFAULT_AF_V4_CONTEXT,
        f"rt {direction} {rt}",
        *VRF_AF_EXIT,
    )
    assert _CTX_GUARD in _stdout(cp), _stdout(cp)


@given(addr=ipv6_str)
def test_prop_sid_explicit_default_vrf_always_rejected(addr):
    _reset()
    cp = _vtysh(
        *DEFAULT_AF_V4_CONTEXT,
        f"sid explicit {addr}",
        *VRF_AF_EXIT,
    )
    assert _CTX_GUARD in _stdout(cp), _stdout(cp)


# ---------------------------------------------------------------------------
# Property 4 — malformed input never round-trips
# ---------------------------------------------------------------------------


@given(bad=st.one_of(garbage, malformed_idpair))
def test_prop_rd_malformed_never_roundtrips(bad):
    # Skip strings that happen to match a valid RD.  Hypothesis's
    # `garbage` alphabet is letters only, so `bad:bad` with both halves
    # alphabetic never parses as a valid RD.  No assume() needed.
    _reset()
    cp = _try(VRF_AF_CONTEXT_V4, f"rd {bad}")
    out = _stdout(cp)
    rejected = "% " in out or "Unknown command" in out
    assert rejected, f"expected vtysh rejection for {bad!r}, got {out!r}"
    assert f"rd {bad}" not in _running_config()


@given(bad=st.one_of(garbage, malformed_idpair))
def test_prop_segment_id_malformed_never_roundtrips(bad):
    _reset()
    cp = _try_dsd(f"segment-id {bad}")
    out = _stdout(cp)
    rejected = "% " in out or "Unknown command" in out
    assert rejected, f"expected vtysh rejection for {bad!r}, got {out!r}"
    assert f"segment-id {bad}" not in _running_config()


# ---------------------------------------------------------------------------
# Property 5 — `route-map` direction restricted to <import|export>
# ---------------------------------------------------------------------------


@given(direction=bad_direction)
def test_prop_route_map_only_import_export(direction):
    """`route-map <direction> RMAP` accepts only import|export.
    Any other direction word must be rejected at the lexer."""
    _reset()
    cp = _try(VRF_AF_CONTEXT_V4, f"route-map {direction} RMAP-X")
    out = _stdout(cp)
    rejected = (
        "Unknown command" in out
        or "Ambiguous command" in out
        or "% " in out
    )
    assert rejected, f"expected vtysh rejection for direction {direction!r}, got {out!r}"
    assert f"route-map {direction} RMAP-X" not in _running_config()
