#!/bin/bash
# Shared helpers for the scripts/perf-trex/ family.
# Sourced by every script under scripts/perf-trex/.

set -u

PERF_TREX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$PERF_TREX_DIR/../.." && pwd)
SRPERF=${SRPERF:-$ROOT/../SRPerf}

# Vultr CLI path.  Default matches `go install github.com/vultr/vultr-cli`.
VULTR_CLI=${VULTR_CLI:-$HOME/go/bin/vultr-cli}

# State file used to thread bare-metal IDs / VPC IDs / IPs across
# provision / install / run / destroy steps.  Plain shell-sourceable.
STATE=${STATE:-$HOME/.cache/srv6-mup-trex-state.env}

# Default Vultr provisioning knobs.
REGION=${REGION:-nrt}
PLAN=${PLAN:-vbm-6c-32gb}
OS_ID=${OS_ID:-2284}            # Ubuntu 24.04 LTS x64
SSH_KEY_ID=${SSH_KEY_ID:-d514dabb-0671-4795-abf5-dd97719811e2}
SSH_KEY_FILE=${SSH_KEY_FILE:-$HOME/.ssh/id_rsa4096}

# Address plan -- must match SRPerf/sut/linux/forwarding-behaviour.cfg.
SUT_RCV_V4=${SUT_RCV_V4:-10.10.1.2}
SUT_RCV_V4_PLEN=${SUT_RCV_V4_PLEN:-24}
SUT_RCV_V6=${SUT_RCV_V6:-12:1::2}
SUT_RCV_V6_PLEN=${SUT_RCV_V6_PLEN:-64}
SUT_SND_V4=${SUT_SND_V4:-10.10.2.2}
SUT_SND_V4_PLEN=${SUT_SND_V4_PLEN:-24}
SUT_SND_V6=${SUT_SND_V6:-12:2::2}
SUT_SND_V6_PLEN=${SUT_SND_V6_PLEN:-64}
TG_TX_V4=${TG_TX_V4:-10.10.1.1}
TG_RCV_V4=${TG_RCV_V4:-10.10.2.1}
TG_TX_V6=${TG_TX_V6:-12:1::1}
TG_RCV_V6=${TG_RCV_V6:-12:2::1}

# T-Rex release tarball -- pinned for reproducibility.  Override via
# TREX_TARBALL=https://... if a newer release is desired.
TREX_TARBALL=${TREX_TARBALL:-https://trex-tgn.cisco.com/trex/release/v3.06.tar.gz}
TREX_VERSION=${TREX_VERSION:-v3.06}

die() { echo "perf-trex: error: $*" >&2; exit 1; }
log() { echo "perf-trex: $*"; }

require_cmd() {
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
	done
}

require_vultr_cli() {
	[ -x "$VULTR_CLI" ] || die "vultr-cli not found: $VULTR_CLI"
	if [ -n "${VULTR_API_KEY:-}" ]; then return 0; fi
	# Allow sourcing from ~/.profile (where the user keeps the key).
	[ -r "$HOME/.profile" ] && { set +u; . "$HOME/.profile"; set -u; }
	[ -n "${VULTR_API_KEY:-}" ] || die "VULTR_API_KEY not set (expected in ~/.profile)"
}

state_save() {
	mkdir -p "$(dirname "$STATE")"
	cat > "$STATE"
	log "state saved: $STATE"
}

state_load() {
	[ -r "$STATE" ] || die "state file missing: $STATE (run provision.sh first)"
	# shellcheck source=/dev/null
	. "$STATE"
}

ssh_cmd() {
	local host=$1; shift
	ssh -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes \
	    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
	    "root@$host" "$@"
}

scp_to() {
	local host=$1 src=$2 dst=$3
	scp -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes \
	    -o StrictHostKeyChecking=accept-new "$src" "root@$host:$dst"
}

scp_from() {
	local host=$1 src=$2 dst=$3
	scp -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes \
	    -o StrictHostKeyChecking=accept-new "root@$host:$src" "$dst"
}

# Strip the noisy "Error reading in config file" header vultr-cli prints
# when ~/.vultr-cli.yaml does not exist (it is harmless -- the API key
# is read from the env).
vultr() {
	"$VULTR_CLI" "$@" 2> >(grep -v 'Error reading in config file' >&2)
}

wait_until() {
	# wait_until <max_seconds> <step_seconds> <command...>
	# Re-runs the command (returning non-zero -> "not yet") until it
	# returns 0, or the budget is exhausted.
	local budget=$1 step=$2; shift 2
	local elapsed=0
	until "$@"; do
		[ $elapsed -ge $budget ] && return 1
		sleep "$step"
		elapsed=$((elapsed + step))
	done
}
