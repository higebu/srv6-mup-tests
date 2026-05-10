#!/bin/bash
# Run the BGP-MUP CLI property tests INSIDE vng so the patched
# higebu/linux:seg6-mobile kernel is in scope.  Tier 2 properties
# (`test_bgp_mup_cli_props_tier2.py`) require the SRv6 MUP `seg6_local`
# actions (End.M.GTP4.E / End.M.GTP6.E / H.M.GTP4.D / End.DT4 / End.DT6
# / End.DT46) — none of which exist on the host kernel.
#
# Tier 1 (`test_bgp_mup_cli_props.py`) runs cleanly under either
# `run_cli_props.sh` (host) or this script (vng); kept the host
# runner because vng startup is ~5 s and Tier 1 doesn't need it.
#
# Layout assumption (same sibling tree as the rest of the suite):
#   <parent>/{frr, linux, iproute2, srv6-mup-tests*}
#
# Usage:
#   scripts/run_cli_props_vng.sh                   # both modules
#   scripts/run_cli_props_vng.sh -k tier2          # only Tier 2
#   scripts/run_cli_props_vng.sh -x -vv            # extra args -> pytest
#   HYPOTHESIS_MAX_EXAMPLES=200 scripts/run_cli_props_vng.sh
#
# Env-var overrides:
#   LINUX_PATH         path to a built kernel tree   (default: ../linux)
#   FRR_PATH           path to a built FRR tree      (default: ../frr)
#   IPROUTE2_PATH      path to a built iproute2 tree (default: ../iproute2)
#   HYPOTHESIS_MAX_EXAMPLES  forwarded to the test session
#   VNG_LOG            log file inside /tmp          (default: /tmp/run-cli-props.log)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PARENT=$(cd "$ROOT/.." && pwd)
LINUX_PATH=${LINUX_PATH:-$PARENT/linux}
FRR_PATH=${FRR_PATH:-$PARENT/frr}
IPROUTE2_PATH=${IPROUTE2_PATH:-$PARENT/iproute2}
VNG_LOG=${VNG_LOG:-/tmp/run-cli-props.log}

# aqua-managed uv resolves via a wrapper that re-exec's `aqua exec`;
# fall through to plain `which uv` otherwise.
if command -v aqua >/dev/null 2>&1 && aqua which uv >/dev/null 2>&1; then
    UV=${UV:-$(aqua which uv)}
else
    UV=${UV:-$(command -v uv || true)}
fi

if [ ! -x "$FRR_PATH/bgpd/bgpd" ]; then
    echo "ERROR: $FRR_PATH/bgpd/bgpd is missing.  Build FRR first." >&2
    exit 2
fi
if [ ! -d "$LINUX_PATH" ] || [ ! -e "$LINUX_PATH/vmlinux" ]; then
    echo "ERROR: $LINUX_PATH does not look like a built kernel tree" >&2
    echo "       (expected $LINUX_PATH/vmlinux to exist)" >&2
    exit 2
fi
if [ -z "$UV" ] || [ ! -x "$UV" ]; then
    echo "ERROR: 'uv' not found on PATH; install from https://docs.astral.sh/uv/" >&2
    exit 2
fi

PYTEST_ARGS="$*"
[ -z "$PYTEST_ARGS" ] && PYTEST_ARGS="-v"

# Sync the .venv on the host (vng shares the host fs read/write via
# 9p, so the same .venv resolves inside the VM — but uv-side cache
# writes are cleaner outside the VM).
echo "==> uv sync (prepare .venv at tests/cli/.venv)" >&2
( cd "$ROOT/tests/cli" && "$UV" sync ) || {
    echo "ERROR: uv sync failed; cannot prepare the test venv" >&2
    exit 2
}

# FRR's compile-time runtime dirs need to exist; create them on the
# host so the same path is visible inside vng (the rwdir mount means
# /tmp inside vng is also host-visible).
sudo mkdir -p /usr/local/var/run/frr /usr/local/var/lib/frr || true

# vng glue:
#   --rwdir mounts $ROOT/tests/cli read-write so the .venv, the
#     hypothesis example DB (.hypothesis/examples/), and the pytest
#     cache survive across runs.  bgpd / zebra / mgmtd write logs to
#     /tmp/pe1/, which is also rw inside the VM.
#   --user root: the conftest creates a netns, vrf netdevs, and dummy
#     interfaces — all NET_ADMIN.
#
# `script -q -c` wrapper preserves vng's terminal handling and gives
# us a transcript at $VNG_LOG.
exec script -q -c "vng -m 4G \
  --rwdir=$ROOT/tests/cli \
  --run $LINUX_PATH --user root \
  -- env \
    FRR_PATH=$FRR_PATH \
    IPROUTE2_PATH=$IPROUTE2_PATH \
    HYPOTHESIS_MAX_EXAMPLES=${HYPOTHESIS_MAX_EXAMPLES:-} \
    CLI_PROPS_TIER2=${CLI_PROPS_TIER2:-} \
    PATH=$IPROUTE2_PATH/ip:/usr/local/bin:/usr/bin:/bin \
    bash -c 'mount -t tmpfs tmpfs /tmp 2>/dev/null; \
             mkdir -p /usr/local/var/run /usr/local/var/lib; \
             mount -t tmpfs tmpfs /usr/local/var/run 2>/dev/null; \
             mount -t tmpfs tmpfs /usr/local/var/lib 2>/dev/null; \
             mkdir -p /usr/local/var/run/frr /usr/local/var/lib/frr; \
             cd $ROOT/tests/cli && \
             .venv/bin/pytest $PYTEST_ARGS'" \
  "$VNG_LOG"
