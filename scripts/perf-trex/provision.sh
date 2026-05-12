#!/bin/bash
# Provision a 2-node b2b testbed on Vultr for SRPerf:
#
#   * One VPC 2.0 (free L2 network) in $REGION
#   * Two bare-metal instances ($PLAN) labelled tester / sut, with the
#     VPC 2.0 attached as their second NIC.
#
# State is written to $STATE so install_*.sh / run_sweep.sh / destroy.sh
# can pick up the IDs and IPs.  This script is idempotent only insofar
# as a fresh run will re-create everything from scratch -- destroy.sh
# first if you want to start over without paying for a stalled run.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

require_vultr_cli

if [ -r "$STATE" ]; then
	log "WARN: $STATE already exists.  Run destroy.sh first if you want a clean slate."
	log "      Existing state:"
	sed 's/^/         /' "$STATE"
	exit 1
fi

# ----- 1. Create VPC 2.0 ------------------------------------------------------
log "creating VPC 2.0 in region=$REGION (subnet 10.200.0.0/24) ..."
VPC_ID=$(vultr vpc2 create \
		--region="$REGION" \
		--description=srv6-mup-trex \
		--ip-type=v4 --ip-block=10.200.0.0 --prefix-length=24 \
		--output=json 2>/dev/null |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["vpc2"]["id"])')
[ -n "$VPC_ID" ] || die "VPC 2.0 create failed"
log "VPC2 id: $VPC_ID"

# ----- 2. Create both bare-metal instances -----------------------------------
create_bm() {
	local hostname=$1
	vultr bare-metal create \
		--plan "$PLAN" --region "$REGION" --os "$OS_ID" \
		--ssh "$SSH_KEY_ID" \
		--hostname "$hostname" --label "$hostname" \
		--output=json 2>/dev/null |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["bare_metal"]["id"])'
}

log "creating bare-metal tester ($PLAN/$REGION) ..."
TESTER_ID=$(create_bm srv6-mup-tester)
[ -n "$TESTER_ID" ] || die "tester create failed"

log "creating bare-metal sut    ($PLAN/$REGION) ..."
SUT_ID=$(create_bm srv6-mup-sut)
[ -n "$SUT_ID" ] || die "sut create failed"

log "tester id: $TESTER_ID"
log "sut    id: $SUT_ID"

# ----- 3. Wait until both are active ----------------------------------------
get_status() {
	vultr bare-metal get "$1" 2>/dev/null | awk '/^STATUS/{print $2}'
}
get_main_ip() {
	vultr bare-metal get "$1" 2>/dev/null | awk '/^IP[ \t]/{print $2}'
}
is_active() { [ "$(get_status "$1" 2>/dev/null)" = "active" ]; }

log "waiting up to 20 min for both bare-metals to become active ..."
wait_until 1200 30 is_active "$TESTER_ID" || die "tester never became active"
wait_until 1200 30 is_active "$SUT_ID"    || die "sut never became active"

TESTER_IP=$(get_main_ip "$TESTER_ID")
SUT_IP=$(get_main_ip "$SUT_ID")
log "tester ip: $TESTER_IP"
log "sut    ip: $SUT_IP"

# ----- 4. Attach VPC 2.0 to both ---------------------------------------------
attach_vpc() {
	local bm_id=$1 ip_addr=$2
	vultr bare-metal vpc2 attach "$bm_id" \
		--vpc-id="$VPC_ID" --ip-address="$ip_addr" >/dev/null 2>&1
}
log "attaching VPC 2.0 to tester (10.200.0.10) ..."
attach_vpc "$TESTER_ID" "10.200.0.10"
log "attaching VPC 2.0 to sut    (10.200.0.20) ..."
attach_vpc "$SUT_ID"    "10.200.0.20"

# Attaching VPC 2.0 triggers a server-side reconfigure that may briefly
# disrupt SSH on the public NIC.  Give the metal a moment to settle.
log "waiting 60s for VPC2 attach to settle ..."
sleep 60

# ----- 5. Persist state ------------------------------------------------------
cat <<EOF | state_save
# srv6-mup-trex provision state -- sourced by scripts/perf-trex/*.sh
VPC_ID=$VPC_ID
TESTER_ID=$TESTER_ID
TESTER_IP=$TESTER_IP
SUT_ID=$SUT_ID
SUT_IP=$SUT_IP
EOF

log "done.  Next: scripts/perf-trex/install_sut.sh && scripts/perf-trex/install_trex.sh"
