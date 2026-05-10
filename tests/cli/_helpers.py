"""
Helpers + constants for the BGP-MUP CLI property tests.

Kept in a regular module (not in conftest.py) so test files can import
the symbols directly via `from _helpers import ...`.  pytest's
rootdir-based test collection adds the containing directory to
sys.path when no `__init__.py` is present.

Layout follows the rest of `srv6-mup-tests/scripts/frr_*`: a single
`pe1/frr.conf` source of truth that is `cp`'d into `/tmp/pe1/` and
rendered through `vtysh -f` after the daemons come up — daemons start
without `-f`.
"""

import ipaddress
import json
import os
import shutil
import signal
import subprocess
import time

import pytest


HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
PARENT = os.path.normpath(os.path.join(ROOT, ".."))
FRR = os.environ.get("FRR_PATH", os.path.join(PARENT, "frr"))
IPROUTE2 = os.environ.get("IPROUTE2_PATH", os.path.join(PARENT, "iproute2"))

NS = "pe1"
RUN = f"/tmp/{NS}"
CONF_SRC = os.path.join(HERE, NS, "frr.conf")

# All MUP policy DEFPYs (rd / rt / route-map / sid / nexthop /
# segment) live under `address-family ipv[46] mup` since the FRR
# refactor that moved the surface out of unicast AF.  See
# bgpd/bgp_mup.c:bgp_mup_vty_init.
VRF_AF_CONTEXT_V4 = (
    "configure terminal",
    "router bgp 65001 vrf slice1",
    "address-family ipv4 mup",
)
VRF_AF_CONTEXT_V6 = (
    "configure terminal",
    "router bgp 65001 vrf slice1",
    "address-family ipv6 mup",
)
VRF_AF_EXIT = ("exit-address-family", "exit", "exit")

# `segment direct` opens a sub-node under MUP AF for DSD knobs
# (address / behavior / segment-id).  Tests that exercise the
# sub-node use these to enter and leave it.
VRF_AF_DSD_ENTER_V4 = VRF_AF_CONTEXT_V4 + ("segment direct",)
VRF_AF_DSD_EXIT = ("exit",) + VRF_AF_EXIT

# Default-vrf instance also has `address-family ipv4 mup` activated so
# default-vrf MUP commands reach bgp_mup_export_check_ctx and trip the
# `must be configured under a non-default vrf bgp instance` guard
# instead of dying at the lexer.
DEFAULT_AF_V4_CONTEXT = (
    "configure terminal",
    "router bgp 65001",
    "address-family ipv4 mup",
)


def _sh(cmd, check=True):
    return subprocess.run(
        cmd, shell=True, check=check, capture_output=True, text=True
    )


def _vtysh(*cmds):
    args = [
        "ip", "netns", "exec", NS,
        f"{FRR}/vtysh/vtysh", "--vty_socket", RUN,
    ]
    for c in cmds:
        args += ["-c", c]
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def _running_config():
    return _vtysh("show running-config").stdout


def _extract_mup_af_body(rc, vrf="slice1", afi="ipv4"):
    """Pull the body lines (whitespace-stripped) inside
    `router bgp 65001 vrf {vrf} / address-family {afi} mup`.

    Used by the writeback fixed-point properties: dump running-config,
    extract the MUP AF body, reset, replay the body, dump again, compare.
    A drift between dump-1 and dump-2 means `bgp_mup_config_write_af`
    emitted a line shape the parser doesn't round-trip back to the same
    state.
    """
    router_marker = f"router bgp 65001 vrf {vrf}"
    af_marker = f"address-family {afi} mup"
    in_router = False
    in_af = False
    body = []
    for line in rc.splitlines():
        if not in_router:
            if line.rstrip() == router_marker:
                in_router = True
            continue
        # Bail at the next top-level block (`router ...` or unindented exit).
        if line and not line.startswith(" "):
            break
        stripped = line.strip()
        if not in_af:
            if stripped == af_marker:
                in_af = True
            continue
        if stripped == "exit-address-family":
            break
        body.append(stripped)
    return body


def _wait_until(predicate, msg, timeout=20.0, interval=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError(f"timeout: {msg}")


def _start_daemons():
    # FRR daemons run with -d (daemonize via fork+exec).  The parent
    # exits after fork, but the child inherits stdout/stderr.  When
    # invoked via subprocess.run with capture_output=True, the child
    # keeps the host pipes open and subprocess.run blocks in poll()
    # forever waiting for EOF.  Redirect daemon stdio to /dev/null at
    # the shell level so the inherited fds drop our pipes immediately.
    common = (
        f"-d -u root -g root --vty_socket {RUN} -P 0 "
        f">/dev/null 2>&1 </dev/null"
    )
    _sh(
        f"ip netns exec {NS} {FRR}/mgmtd/mgmtd "
        f"-i {RUN}/mgmtd.pid --log file:{RUN}/mgmtd.log "
        f"{common}"
    )
    _sh(
        f"ip netns exec {NS} {FRR}/zebra/zebra "
        f"-i {RUN}/zebra.pid -z {RUN}/zserv.api "
        f"--log file:{RUN}/zebra.log "
        f"{common}"
    )
    _sh(
        f"ip netns exec {NS} {FRR}/bgpd/bgpd "
        f"-i {RUN}/bgpd.pid -z {RUN}/zserv.api "
        f"--log file:{RUN}/bgpd.log "
        f"{common}"
    )


def _stop_daemons():
    for daemon in ("bgpd", "zebra", "mgmtd"):
        try:
            with open(f"{RUN}/{daemon}.pid") as f:
                pid = int(f.read().strip())
            os.kill(pid, signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass


def _render_conf():
    """Push pe1/frr.conf through vtysh.  Mirrors the daemon-start
    convention used by scripts/frr_interop_mup.sh and the e2e
    scripts: daemons come up empty (no -f), then vtysh -f renders
    the single shared conf."""
    cp = subprocess.run(
        [
            "ip", "netns", "exec", NS,
            f"{FRR}/vtysh/vtysh", "--vty_socket", RUN,
            "-f", f"{RUN}/frr.conf",
        ],
        capture_output=True, text=True, timeout=60,
    )
    if cp.returncode != 0:
        raise RuntimeError(
            f"vtysh -f failed (rc={cp.returncode}):\n"
            f"stdout={cp.stdout}\nstderr={cp.stderr}"
        )


def _baseline_mup_clean():
    """Reset both non-default-vrf bgp instances to a known-empty
    MUP-policy state.  Removing the whole `router bgp 65001 vrf NAME`
    instance and re-creating it from the same skeleton frr.conf
    rendered at session setup is the only reliable way to clear state
    when a test fails mid-config (a partial config can leave
    EXPLICIT-bit latches and `network` lines around that targeted
    `no` lines won't undo)."""
    _vtysh(
        "configure terminal",
        "no router bgp 65001 vrf slice1",
        "no router bgp 65001 vrf slice2",
        "router bgp 65001 vrf slice1",
        "  bgp router-id 1.1.1.1",
        "  no bgp default ipv4-unicast",
        "  no bgp network import-check",
        "  segment-routing srv6",
        "   locator default",
        "  exit",
        "  address-family ipv4 mup",
        "  exit-address-family",
        "  address-family ipv6 mup",
        "  exit-address-family",
        "exit",
        "router bgp 65001 vrf slice2",
        "  bgp router-id 1.1.1.1",
        "  no bgp default ipv4-unicast",
        "  no bgp network import-check",
        "  address-family ipv4 mup",
        "  exit-address-family",
        "  address-family ipv6 mup",
        "  exit-address-family",
        "exit",
        "exit",
    )


def setup_session():
    if not os.path.isfile(f"{FRR}/bgpd/bgpd"):
        pytest.skip(f"bgpd not built at {FRR}/bgpd/bgpd")

    # FRR daemons want /usr/local/var/run/frr and /usr/local/var/lib/frr
    # to exist and be writable.  The runner script ensures this with
    # sudo before invoking pytest; here we only need to confirm.
    _sh("mkdir -p /usr/local/var/run/frr /usr/local/var/lib/frr", check=False)

    _sh(f"ip netns del {NS} || true", check=False)
    if os.path.isdir(RUN):
        shutil.rmtree(RUN, ignore_errors=True)
    os.makedirs(RUN, exist_ok=True)

    _sh(f"ip netns add {NS}")
    _sh(f"ip -n {NS} link set lo up")
    _sh(f"ip netns exec {NS} sysctl -wq net.vrf.strict_mode=1", check=False)
    for slice_name, table in (("slice1", 100), ("slice2", 101)):
        _sh(f"ip -n {NS} link add {slice_name} type vrf table {table}")
        _sh(f"ip -n {NS} link set {slice_name} up")
        _sh(f"ip -n {NS} link add lo-{slice_name} type dummy")
        _sh(f"ip -n {NS} link set lo-{slice_name} master {slice_name}")
        _sh(f"ip -n {NS} link set lo-{slice_name} up")

    shutil.copyfile(CONF_SRC, f"{RUN}/frr.conf")
    _start_daemons()

    deadline = time.time() + 20.0
    while time.time() < deadline:
        cp = _vtysh("show version")
        if cp.returncode == 0 and "FRRouting" in cp.stdout:
            break
        time.sleep(0.5)
    else:
        _stop_daemons()
        raise RuntimeError("vtysh never came up")

    _render_conf()

    _wait_until(
        lambda: "default" in _vtysh(
            "show segment-routing srv6 locator"
        ).stdout,
        "zebra never published the SRv6 locator",
    )


def teardown_session():
    _stop_daemons()
    _sh(f"ip netns del {NS}", check=False)


# ---------------------------------------------------------------------------
# Tier 2 helpers — kernel-side / SID-manager / BGP RIB introspection
#
# Tier 1 properties only assert "vtysh round-trips cleanly".  Tier 2
# properties drive the policy past `bgp_mup_origin_active`
# (bgpd/bgp_mup.c:4400) and assert against the resulting state in:
#
#   - bgpd's local SAFI_MUP RIB         (`show bgp ipv[46] mup all json`)
#   - zebra's SRv6 SID manager          (`show segment-routing srv6 sid json`)
#   - the kernel routing table          (`ip -j -6 route show ...`)
#
# All four return parsed dicts/lists so callers don't substring-match.
# Each helper accepts a `timeout` for the eventual-consistency wait —
# bgpd→zebra→netlink is a ~50-200 ms roundtrip in practice but spikes
# under load, so the helpers poll up to `timeout` seconds rather than
# making the assertion site sleep.
# ---------------------------------------------------------------------------


def _vtysh_json(cmd, timeout=30):
    """Run `cmd` via vtysh inside the pe1 netns and json-decode stdout.

    Returns the parsed object, or None if the output isn't valid JSON
    (e.g. the show command was rejected — caller decides what to do).
    """
    cp = _vtysh(cmd)
    out = cp.stdout or ""
    try:
        return json.loads(out)
    except (json.JSONDecodeError, ValueError):
        return None


def _show_bgp_mup(afi="ipv4", vrf=None, timeout=10.0, interval=0.2):
    """Return the parsed `show bgp [vrf X] <afi> mup all json` output.

    afi: "ipv4" | "ipv6"
    vrf: VRF name to scope the query, or None for the bgp instance
         that's currently in scope of `show bgp` (i.e. default-vrf).
         Pass "slice1" / "slice2" to inspect the per-vrf bgp instance
         where Tier 2 properties land their MUP policy.

    The polling loop is here, not at the call site, because the
    bgpd-side leak from per-vrf SAFI_MUP into the RIB is event-driven
    and races with the vtysh exit returning.

    TODO(verify): The empty-RIB JSON shape may be `{}` or
    `{"ipv4Mup": {}}`.  bgp_mup_route2json adds payload onto a per-NLRI
    dict; the wrapping `ipv4Mup`/`ipv6Mup` key is added unconditionally
    only when at least one route exists.  Treat both as "no routes
    yet" and continue polling.
    """
    if vrf:
        cmd = "show bgp vrf {} {} mup all json".format(vrf, afi)
    else:
        cmd = "show bgp {} mup all json".format(afi)
    key = "ipv4Mup" if afi == "ipv4" else "ipv6Mup"
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        out = _vtysh_json(cmd)
        last = out
        if isinstance(out, dict) and key in out:
            return out
        time.sleep(interval)
    return last if last is not None else {}


def _iter_bgp_mup_routes(show_out, afi="ipv4"):
    """Flatten the `routes` dict of a `_show_bgp_mup` payload into a
    list of per-path dicts.  Each path carries the route2json fields
    (routeType, archType, rd, ip, ipLen, teid, qfi, ...)."""
    key = "ipv4Mup" if afi == "ipv4" else "ipv6Mup"
    routes = (show_out or {}).get(key, {}).get("routes", {})
    flat = []
    for paths in (routes or {}).values():
        if isinstance(paths, list):
            flat.extend(paths)
    return flat


def _find_mup_route(show_out, afi="ipv4", route_type=None, ip=None, rd=None):
    """Mirror of test_bgp_mup.py's `_find_mup_route`: scan the
    flattened paths and return the first match on the given keys.
    `None` means "don't filter on that field"."""
    for path in _iter_bgp_mup_routes(show_out, afi=afi):
        if route_type is not None and path.get("routeType") != route_type:
            continue
        if ip is not None and path.get("ip") != ip and path.get("endpointAddress") != ip:
            continue
        if rd is not None and path.get("rd") != rd:
            continue
        return path
    return None


def _show_srv6_sids(timeout=10.0, interval=0.2):
    """Return `show segment-routing srv6 sid json` parsed.

    The JSON shape (per
    `frr/.claude/worktrees/.../bgp_srv6_sid_explicit/expected_explicit_srv6_sid_allocated.json`)
    keys each entry by SID address:

        { "<sid>": { "sid": "<sid>", "behavior": "End.DT4",
                     "context": {"vrfName": "...", "table": N},
                     "locator": "default", "allocationMode": "auto",
                     "clients": [{"protocol": "bgp", "instance": 0}] },
          ... }

    Empty result is `{}` (no SIDs allocated); the polling loop returns
    whatever was seen last when the timeout expires."""
    deadline = time.time() + timeout
    last = {}
    while time.time() < deadline:
        out = _vtysh_json("show segment-routing srv6 sid json")
        if isinstance(out, dict):
            last = out
            if out:
                return out
        time.sleep(interval)
    return last


def _find_srv6_sid(sids, behavior=None, vrf_name=None, locator=None):
    """Scan a `_show_srv6_sids()` dict for the first entry matching
    the given filters.  Use `behavior in ("End.DT4", "End.DT6", ...)`
    to assert per-action allocation."""
    for entry in (sids or {}).values():
        if not isinstance(entry, dict):
            continue
        if behavior is not None and entry.get("behavior") != behavior:
            continue
        if vrf_name is not None and entry.get("context", {}).get("vrfName") != vrf_name:
            continue
        if locator is not None and entry.get("locator") != locator:
            continue
        return entry
    return None


def _kernel_ip6_routes(table=None, vrf=None, timeout=10.0, interval=0.2):
    """Return `ip -j -6 route show [table N | vrf NAME]` as a list of
    route dicts.  Polls because zebra → netlink install is async.

    iproute2's JSON encoding for seg6local lwtunnels is (see
    iproute2/ip/iproute_lwtunnel.c:520):

        {
          "dst": "2001:db8:e:0:2::/80",
          "encap": "seg6local",
          "action": "End.DT4",
          "table": "100",
          ...
        }
    """
    if vrf:
        cmd = ["ip", "netns", "exec", NS, "ip", "-j", "-6", "route",
               "show", "vrf", vrf]
    elif table:
        cmd = ["ip", "netns", "exec", NS, "ip", "-j", "-6", "route",
               "show", "table", str(table)]
    else:
        cmd = ["ip", "netns", "exec", NS, "ip", "-j", "-6", "route", "show"]
    deadline = time.time() + timeout
    last = []
    while time.time() < deadline:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        try:
            data = json.loads(cp.stdout or "[]")
            if isinstance(data, list):
                last = data
                if data:
                    return data
        except (json.JSONDecodeError, ValueError):
            pass
        time.sleep(interval)
    return last


def _kernel_seg6local(action=None, dst_in=None, vrf=None, table=None,
                     timeout=10.0):
    """Return the first kernel route with `encap == "seg6local"` whose
    `action` matches and whose destination falls inside `dst_in`
    (an IPv6 prefix string, e.g. the locator block).  `None` means
    "don't filter on that field".

    Used by the install-side properties:
        sid = _kernel_seg6local(action="End.DT4", vrf="slice1")
        assert sid is not None, "expected an End.DT4 install"
    """
    routes = _kernel_ip6_routes(table=table, vrf=vrf, timeout=timeout)
    if dst_in is not None:
        net = ipaddress.ip_network(dst_in, strict=False)
    else:
        net = None
    for r in routes:
        if r.get("encap") != "seg6local":
            continue
        if action is not None and r.get("action") != action:
            continue
        if net is not None:
            dst = r.get("dst", "")
            try:
                # `dst` may be `addr` (host) or `prefix/len`.
                addr = ipaddress.ip_network(dst, strict=False).network_address
            except ValueError:
                continue
            if addr not in net:
                continue
        return r
    return None


def _kernel_route_count(vrf=None, table=None, predicate=None, timeout=2.0):
    """Count routes matching `predicate` in the given vrf/table.
    `predicate` is a callable taking one route dict; default counts all.

    Used as a leak invariant: e.g. before/after a property must show
    the same number of `seg6local` routes in `table local`.
    """
    routes = _kernel_ip6_routes(vrf=vrf, table=table, timeout=timeout)
    if predicate is None:
        return len(routes)
    return sum(1 for r in routes if predicate(r))


# Behavior name (per RFC 9433 §6.x and FRR's seg6local kernel install)
# that bgpd asks zebra to install for each DSD `behavior <kw>` keyword:
#
#   `behavior dt4`  -> End.DT4   (IPv4 PE-CE decap into target VRF)
#   `behavior dt6`  -> End.DT6   (IPv6 PE-CE decap into target VRF)
#   `behavior dt46` -> End.DT46  (dual-stack decap into target VRF)
#
# TODO(verify): If bgpd ever installs the GTP-U-side action (End.M.GTP4.E
# / End.M.GTP6.E) for DSD origin, the test predicates need to widen.
# Last-checked: bgpd/bgp_mup.c at b4/seg6-mobile tip — DSD origin
# installs End.DTx only.
DSD_BEHAVIOR_TO_KERNEL = {
    "dt4": "End.DT4",
    "dt6": "End.DT6",
    "dt46": "End.DT46",
}


# ---------------------------------------------------------------------------
# Tier 2 helpers — apply / wait / scrub a full DSD or ISD policy
#
# These are intentionally above the property-test layer: a Tier 2 test
# constructs (rd, addr, behavior, seg_id, sid?) from hypothesis, calls
# `_apply_dsd(...)`, then asserts on `_show_bgp_mup` / `_show_srv6_sids`
# / `_kernel_seg6local`.
#
# The shape mirrors the slice2/IPv4 DSD block in
# `tests/topotests/bgp_mup/r1/frr.conf:102..111`.
# ---------------------------------------------------------------------------


def _apply_dsd(rd, addr, behavior, seg_id, sid=None, afi="ipv4",
               vrf="slice1", rt_export=None):
    """Drive a full DSD policy onto `vrf`/`afi` so
    `bgp_mup_origin_active` returns true.

    `sid` is None | "auto" | ("explicit", "X:X::X:X").

    The function returns the CompletedProcess of the final vtysh batch
    so the caller can assert "% " not in stdout.
    """
    af_ctx = "address-family {} mup".format(afi)
    cmds = [
        "configure terminal",
        "router bgp 65001 vrf {}".format(vrf),
        af_ctx,
        "rd {}".format(rd),
    ]
    if rt_export is not None:
        cmds.append("rt export {}".format(rt_export))
    if sid == "auto":
        cmds.append("sid auto")
    elif isinstance(sid, tuple) and sid[0] == "explicit":
        cmds.append("sid explicit {}".format(sid[1]))
    cmds += [
        "segment direct",
        "address {}".format(addr),
        "behavior {}".format(behavior),
        "segment-id {}".format(seg_id),
        "exit",
        "exit-address-family",
        "exit",
        "exit",
    ]
    return _vtysh(*cmds)


def _apply_isd(rd, networks, afi="ipv4", vrf="slice1", sid=None,
               rt_export=None):
    """Drive a full ISD-origination policy: `rd` + `segment interwork`
    + one `network <p>` per item in `networks`.  Returns the final
    vtysh CompletedProcess.

    Each `network <p>` enters the SAFI_MUP RIB as a locally-originated
    entry; `segment interwork` then emits one ISD per non-default
    prefix (mirrors `redistribute connected` on slice1, but explicit
    `network` lines give the property test deterministic input).

    TODO(verify): the IPv6 mup AF accepts `network <ipv6-prefix>` the
    same way the IPv4 one accepts `network <ipv4-prefix>`.  If
    bgp_mup.c rejects this in IPv6 AF, switch the v6 path to a
    `redistribute connected` against a hypothesis-controlled set of
    addresses on `lo-slice1`.
    """
    af_ctx = "address-family {} mup".format(afi)
    cmds = [
        "configure terminal",
        "router bgp 65001 vrf {}".format(vrf),
        af_ctx,
        "rd {}".format(rd),
        "segment interwork",
    ]
    if sid == "auto":
        cmds.append("sid auto")
    elif isinstance(sid, tuple) and sid[0] == "explicit":
        cmds.append("sid explicit {}".format(sid[1]))
    if rt_export is not None:
        cmds.append("rt export {}".format(rt_export))
    for p in networks:
        cmds.append("network {}".format(p))
    cmds += ["exit-address-family", "exit", "exit"]
    return _vtysh(*cmds)


def _wait_for(predicate, msg, timeout=10.0, interval=0.2):
    """Poll `predicate()` until it returns truthy, raising
    AssertionError(msg) on timeout.  The Tier 2 properties use this to
    bridge from "vtysh exited" to "kernel route appeared"."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = predicate()
        if v:
            return v
        time.sleep(interval)
    raise AssertionError("timeout: " + msg)


# Per-vrf VRF table mapping (matches setup_session() above and
# pe1/frr.conf's `link add slice1 type vrf table 100` /
# `link add slice2 type vrf table 101`).  Tier 2 helpers that have to
# `ip -6 route show table N` need this.
VRF_TABLE = {
    "slice1": 100,
    "slice2": 101,
}
