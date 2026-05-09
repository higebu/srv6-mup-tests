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
