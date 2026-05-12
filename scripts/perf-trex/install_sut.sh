#!/bin/bash
# Install the seg6 mobile uplane kernel + iproute2 on the SUT bare-metal,
# bring up the VPC 2.0 leg with the static address plan expected by
# SRPerf/sut/linux/forwarding-behaviour.cfg, then reboot.
#
# Prerequisites:
#   * provision.sh ran successfully (state file present)
#   * Locally available rebuilt debs under $DEB_DIR -- ixgbe / VPC NIC
#     must be enabled, so use the deb set we rebuilt on a bare-metal
#     with stock-config-as-base (see docs/perf-trex-vultr.md).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
state_load

DEB_DIR=${DEB_DIR:-$HOME/srv6-mup-rebuilt-debs}
KERNEL_DEB=${KERNEL_DEB:-$(ls "$DEB_DIR"/linux-image-*srv6mup*_amd64.deb 2>/dev/null | head -1)}
HEADERS_DEB=${HEADERS_DEB:-$(ls "$DEB_DIR"/linux-headers-*srv6mup*_amd64.deb 2>/dev/null | head -1)}
LIBC_DEB=${LIBC_DEB:-$(ls "$DEB_DIR"/linux-libc-dev_*srv6mup*_amd64.deb 2>/dev/null | head -1)}
IPROUTE2_DEB=${IPROUTE2_DEB:-$(ls "$HOME"/srv6-mup-bundle/iproute2_*_amd64.deb 2>/dev/null | head -1)}

for f in "$KERNEL_DEB" "$HEADERS_DEB" "$LIBC_DEB" "$IPROUTE2_DEB"; do
	[ -r "$f" ] || die "missing deb: $f"
done
log "shipping debs to sut $SUT_IP:"
log "  $KERNEL_DEB"; log "  $HEADERS_DEB"; log "  $LIBC_DEB"; log "  $IPROUTE2_DEB"

# ----- 1. Push debs -----------------------------------------------------------
ssh_cmd "$SUT_IP" 'mkdir -p /root/srv6-mup-debs'
scp_to "$SUT_IP" "$KERNEL_DEB"   "/root/srv6-mup-debs/"
scp_to "$SUT_IP" "$HEADERS_DEB"  "/root/srv6-mup-debs/"
scp_to "$SUT_IP" "$LIBC_DEB"     "/root/srv6-mup-debs/"
scp_to "$SUT_IP" "$IPROUTE2_DEB" "/root/srv6-mup-debs/"

# ----- 2. Install + grub-default to seg6-mup kernel --------------------------
ssh_cmd "$SUT_IP" '
set -e
DEBIAN_FRONTEND=noninteractive apt-get update -qq
cd /root/srv6-mup-debs
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ./linux-libc-dev_*.deb ./linux-headers-*.deb ./linux-image-*.deb ./iproute2_*.deb
grub-set-default 0
update-grub >/dev/null 2>&1
echo "--- installed image ---"
dpkg -l | grep linux-image | grep srv6 | head
echo "--- ip -V ---"
ip -V
'

# ----- 3. Stage NIC bring-up for after reboot via systemd one-shot -----------
# We do not know the VPC NIC device name until after the attach reboots
# settle, so we ship a tiny script + oneshot unit that runs once at boot
# to assign the static SRPerf address plan to the second NIC.
ssh_cmd "$SUT_IP" "cat > /usr/local/sbin/srv6-mup-vpc-up.sh <<'EOF'
#!/bin/bash
set -e
# Pick the second cabled interface (i.e. not the one carrying the
# default route).  In Vultr bare-metals the public-facing NIC owns the
# default route -- the VPC 2.0 NIC is the other one.
DEFAULT_DEV=\$(ip -j route show default | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"dev\"])')
VPC_DEV=\$(ip -br link | awk '/^en/ && !/lo/ && \$2 != \"DOWN\" {print \$1}' | grep -v \"\$DEFAULT_DEV\" | head -1)
[ -n \"\$VPC_DEV\" ] || { echo \"no VPC NIC found\" >&2; exit 1; }
ip link set \"\$VPC_DEV\" up
# Rename for SRPerf cfg compatibility (cfg expects enp6s0f0 / enp6s0f1).
ip link set \"\$VPC_DEV\" name enp6s0f0
ip addr flush dev enp6s0f0
ip addr add $SUT_RCV_V4/$SUT_RCV_V4_PLEN dev enp6s0f0
ip -6 addr add $SUT_RCV_V6/$SUT_RCV_V6_PLEN dev enp6s0f0 nodad
# The SUT has only one physical VPC NIC -- alias enp6s0f1 onto the same
# device via a dummy + bridge would be overkill for a single-host b2b
# test.  For the unidirectional SRPerf flow we wire SUT_snd to point at
# TG_rcv on the same NIC; the cfg routes via TG_rcv gateway so the FIB
# still emits SUT_snd-tagged frames correctly.
ip link add enp6s0f1 type dummy 2>/dev/null || true
ip link set enp6s0f1 up
ip addr add $SUT_SND_V4/$SUT_SND_V4_PLEN dev enp6s0f1 2>/dev/null || true
ip -6 addr add $SUT_SND_V6/$SUT_SND_V6_PLEN dev enp6s0f1 nodad 2>/dev/null || true
# Disable NIC offloads for stable single-core forwarding numbers.
ethtool -K enp6s0f0 rx off tx off tso off gso off gro off lro off 2>/dev/null || true
sysctl -wq net.ipv4.conf.all.forwarding=1
sysctl -wq net.ipv6.conf.all.forwarding=1
sysctl -wq net.ipv6.conf.enp6s0f0.seg6_enabled=1
echo \"srv6-mup-vpc-up: \$(ip -br addr show enp6s0f0)\"
EOF
chmod +x /usr/local/sbin/srv6-mup-vpc-up.sh
cat > /etc/systemd/system/srv6-mup-vpc-up.service <<'UNIT'
[Unit]
Description=Bring up SRv6 MUP VPC interface (SRPerf cfg layout)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/srv6-mup-vpc-up.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable srv6-mup-vpc-up.service >/dev/null 2>&1
"

# ----- 4. Reboot into new kernel ---------------------------------------------
log "rebooting sut into seg6-mup kernel ..."
ssh_cmd "$SUT_IP" 'nohup reboot >/dev/null 2>&1 &' || true
sleep 30

log "waiting up to 15 min for SSH to come back ..."
back_up() { ssh_cmd "$SUT_IP" 'uname -r' >/dev/null 2>&1; }
wait_until 900 20 back_up || die "sut did not come back from reboot"

ssh_cmd "$SUT_IP" '
echo "--- kernel ---"; uname -r
echo "--- ixgbe loaded? ---"; lsmod | grep -E "ixgbe|ice|i40e" | head
echo "--- enp6s0f0 ---"; ip -br addr show enp6s0f0 2>/dev/null || echo "MISSING -- check srv6-mup-vpc-up.service journal"
echo "--- ip -V ---"; ip -V
'

log "done.  Next: scripts/perf-trex/install_trex.sh"
