#!/bin/bash
# Run the BGP-MUP CLI property test modules.  Uses uv to manage the
# Python environment (pytest is fetched on demand).
#
# The suite only needs `ip netns`, `ip link add type vrf|dummy`, and
# the locally-built FRR daemons — none of which require the
# kernel-side SRv6 MUP behaviors.  The fastest, most observable place
# to run it is therefore the host with sudo, not vng.  vng is reserved
# for tests that exercise those behaviors (the VPP interop scripts and
# the kernel selftests, both of which use `script -q -c "vng ..."`).
#
# Layout assumption (same as the rest of the test suite):
#   <parent>/{frr, linux, iproute2, srv6-mup-tests*}
# where srv6-mup-tests* is either srv6-mup-tests/ (mainline) or an
# active worktree.
#
# Usage:
#   scripts/run_cli_props.sh                # both modules
#   scripts/run_cli_props.sh -k props       # only the property tests
#   scripts/run_cli_props.sh -k dynamic     # only the dynamic module
#   scripts/run_cli_props.sh -x -vv         # extra args forwarded to pytest
#
# All args are forwarded to `pytest` verbatim.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PARENT=$(cd "$ROOT/.." && pwd)
IPROUTE2=${IPROUTE2:-$PARENT/iproute2}
FRR=${FRR:-$PARENT/frr}

# aqua-managed uv resolves via a wrapper that re-exec's `aqua exec`.
# Plain `which uv` falls through for non-aqua installs.
if command -v aqua >/dev/null 2>&1 && aqua which uv >/dev/null 2>&1; then
    UV=${UV:-$(aqua which uv)}
else
    UV=${UV:-$(command -v uv || true)}
fi

if [ ! -x "$FRR/bgpd/bgpd" ]; then
    echo "ERROR: $FRR/bgpd/bgpd is missing.  Build FRR first." >&2
    exit 2
fi
if [ -z "$UV" ] || [ ! -x "$UV" ]; then
    echo "ERROR: 'uv' not found on PATH; install from https://docs.astral.sh/uv/" >&2
    exit 2
fi

PYTEST_ARGS="$*"
[ -z "$PYTEST_ARGS" ] && PYTEST_ARGS="-v"

echo "==> uv sync (prepare .venv at tests/properties/bgp_mup_cli/.venv)" >&2
( cd "$ROOT/tests/properties/bgp_mup_cli" && "$UV" sync ) || {
    echo "ERROR: uv sync failed; cannot prepare the test venv" >&2
    exit 2
}

# Make sure FRR's compile-time runtime dirs exist; the daemons will
# write to /usr/local/var/run/frr and /usr/local/var/lib/frr.
sudo mkdir -p /usr/local/var/run/frr /usr/local/var/lib/frr || true

cd "$ROOT/tests/properties/bgp_mup_cli"

# Run pytest as root: the conftest creates a netns, vrf netdevs, and
# dummy interfaces, all of which need NET_ADMIN.  Forward the same env
# vars the conftest expects.  HYPOTHESIS_MAX_EXAMPLES is forwarded so
# the caller can dial up shrinking / fuzzing depth without editing the
# test source.
exec sudo -E env FRR_PATH="$FRR" IPROUTE2_PATH="$IPROUTE2" \
    HYPOTHESIS_MAX_EXAMPLES="${HYPOTHESIS_MAX_EXAMPLES:-}" \
    PATH="$IPROUTE2/ip:/usr/local/bin:/usr/bin:/bin" \
    .venv/bin/pytest $PYTEST_ARGS
