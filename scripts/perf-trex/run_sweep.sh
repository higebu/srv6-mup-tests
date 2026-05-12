#!/bin/bash
# Drive an end-to-end SRPerf sweep against the provisioned testbed:
#
#   1. Discover the SUT_rcv NIC MAC and regenerate every pcap with that
#      dst_mac (the build_pcaps.py defaults are placeholders).
#   2. rsync the SRPerf fork to the tester.
#   3. On the tester, generate the orchestrator config + testbed YAMLs
#      and launch orchestrator.py which drives both T-Rex (locally) and
#      forwarding-behaviour.cfg on the SUT (via SSH).
#   4. Pull the resulting Linux.txt CSV/JSON back to local.
#
# Behaviour selection:
#   PROFILE=mup  -> 5 MUP behaviours only          (default)
#   PROFILE=base -> plain v4/v6 + 8 classic SRv6
#   PROFILE=all  -> everything
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
state_load

PROFILE=${PROFILE:-mup}
SIZE=${SIZE:-min}
[ -d "$SRPERF" ] || die "SRPerf repo not found at $SRPERF -- set SRPERF=... or clone alongside this repo"

# ----- 1. Discover SUT_rcv MAC + regen pcaps ---------------------------------
log "discovering SUT_rcv MAC ..."
SUT_RCV_MAC=$(ssh_cmd "$SUT_IP" "ip -j link show enp6s0f0 | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"address\"])'")
[ -n "$SUT_RCV_MAC" ] || die "could not read SUT_rcv MAC"
log "SUT_rcv MAC: $SUT_RCV_MAC -- regenerating pcaps"
( cd "$SRPERF" && python3 pcap/build_pcaps.py --dst-mac "$SUT_RCV_MAC" )

# ----- 2. rsync SRPerf to tester ---------------------------------------------
log "rsyncing SRPerf to tester ..."
rsync -az --delete \
	-e "ssh -i $SSH_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
	--exclude '.git/' --exclude '.venv*/' --exclude '__pycache__/' \
	"$SRPERF"/ "root@$TESTER_IP:/root/SRPerf/"

# ----- 3. Stage testbed.yaml + config.yaml on tester -------------------------
log "staging testbed.yaml + config.yaml on tester ..."
ssh_cmd "$TESTER_IP" "cat > /root/SRPerf/orchestrator/testbed.yaml <<EOF
sut: $SUT_IP
sut_home: /root/SRPerf
sut_user: root
sut_name: sut
fwd: linux
EOF
"
ssh_cmd "$TESTER_IP" "
set -e
pip3 install --quiet --break-system-packages pyyaml paramiko numpy trex-stl-lib 2>/dev/null || true
cd /root/SRPerf/orchestrator
python3 config_generator.py -t $PROFILE -s $SIZE
wc -l config.yaml
"

# ----- 4. Launch T-Rex in stateless mode (background) ------------------------
log "starting T-Rex on tester (stateless, daemon) ..."
ssh_cmd "$TESTER_IP" '
pkill -f t-rex-64 || true
sleep 2
cd /opt/trex/current
nohup ./t-rex-64 -c 4 --stl -i --no-scapy-server > /var/log/trex.log 2>&1 &
'
sleep 20
ssh_cmd "$TESTER_IP" 'pgrep -af t-rex-64 | head -3; ss -ltn | grep -E "4500|4501" || true'

# ----- 5. Run orchestrator (drives T-Rex + SSHes to SUT) ---------------------
log "launching SRPerf orchestrator ..."
ssh_cmd "$TESTER_IP" '
cd /root/SRPerf/orchestrator
# Forward the tester key into the orchestrator so it can SSH to the SUT.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f ~/.ssh/id_rsa ] || cp /root/.ssh/* ~/.ssh/ 2>/dev/null || true
python3 orchestrator.py
'

# ----- 6. Pull results back --------------------------------------------------
mkdir -p "$HOME/srv6-mup-trex-results"
RUN=$(date +%Y%m%d-%H%M%S)
scp_from "$TESTER_IP" "/root/SRPerf/orchestrator/Linux.txt" "$HOME/srv6-mup-trex-results/Linux-$RUN.json"
log "results pulled: ~/srv6-mup-trex-results/Linux-$RUN.json"

# ----- 7. Stop T-Rex ---------------------------------------------------------
ssh_cmd "$TESTER_IP" 'pkill -f t-rex-64 || true'

log "sweep complete.  Next: scripts/perf-trex/destroy.sh when you no longer need the testbed."
