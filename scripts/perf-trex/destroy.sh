#!/bin/bash
# Tear down the testbed provisioned by provision.sh:
#   * Detach VPC 2.0 from both bare-metals (best-effort)
#   * Delete both bare-metals
#   * Delete the VPC 2.0
#   * Remove the state file
#
# Asks for explicit confirmation before issuing any delete -- destroying
# a Vultr bare-metal is irreversible and stops further billing.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
require_vultr_cli
state_load

echo "About to delete:"
echo "  tester: id=$TESTER_ID  ip=$TESTER_IP"
echo "  sut:    id=$SUT_ID     ip=$SUT_IP"
echo "  vpc2:   id=$VPC_ID"
echo
read -r -p "type DESTROY to confirm: " ans
[ "$ans" = "DESTROY" ] || { echo "aborted"; exit 1; }

# Detaching VPC before deleting is best-effort -- if the bare-metal is
# already gone the detach errors but the deletion still proceeds.
vultr bare-metal vpc2 detach "$TESTER_ID" --vpc-id="$VPC_ID" 2>&1 | tail -1 || true
vultr bare-metal vpc2 detach "$SUT_ID"    --vpc-id="$VPC_ID" 2>&1 | tail -1 || true

vultr bare-metal delete "$TESTER_ID" 2>&1 | tail -1
vultr bare-metal delete "$SUT_ID"    2>&1 | tail -1

# Wait for both BMs to actually disappear from the inventory so the VPC
# delete is not blocked by lingering attachments.
gone() { ! vultr bare-metal list 2>/dev/null | grep -qE "^$1 "; }
log "waiting for bare-metals to disappear from inventory ..."
wait_until 300 15 gone "$TESTER_ID" || log "warn: tester still listed"
wait_until 300 15 gone "$SUT_ID"    || log "warn: sut still listed"

vultr vpc2 delete "$VPC_ID" 2>&1 | tail -1 || true

rm -f "$STATE"
log "destroyed."
