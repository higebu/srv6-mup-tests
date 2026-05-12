#!/bin/bash
# Install Cisco T-Rex + DPDK runtime prerequisites on the tester
# bare-metal, bind the VPC 2.0 NIC to vfio-pci, and stage a stateless
# t-rex_cfg.yaml that points T-Rex at that NIC.  The MGMT NIC (the
# public-facing one carrying SSH and the default route) is left
# untouched.
#
# Prerequisites:
#   * provision.sh ran successfully
#   * install_sut.sh has finished (so the VPC 2.0 leg is up on the SUT
#     and routing is known to work end-to-end).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
state_load

require_cmd ssh scp

# ----- 1. apt deps + HugePages -----------------------------------------------
log "installing runtime deps on tester $TESTER_IP ..."
ssh_cmd "$TESTER_IP" '
set -e
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	python3 python3-pip python3-yaml python3-scapy python3-numpy \
	pciutils kmod ethtool curl tar wget \
	build-essential libpcap-dev dpdk-kmods-dkms dkms linux-headers-$(uname -r)
# 4 x 1G HugePages.
echo 4 > /proc/sys/vm/nr_hugepages_per_node 2>/dev/null || \
	echo 4 > /sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages
mkdir -p /mnt/huge
mountpoint -q /mnt/huge || mount -t hugetlbfs -o pagesize=1G nodev /mnt/huge
grep -q hugetlbfs /etc/fstab || echo "nodev /mnt/huge hugetlbfs pagesize=1G 0 0" >> /etc/fstab
# vfio + iommu modules.
modprobe vfio || true
modprobe vfio-pci || true
modprobe vfio_iommu_type1 allow_unsafe_interrupts=1 || true
echo "options vfio_iommu_type1 allow_unsafe_interrupts=1" > /etc/modprobe.d/vfio-srv6mup.conf
'

# ----- 2. Download + install T-Rex --------------------------------------------
log "installing T-Rex $TREX_VERSION on tester ..."
ssh_cmd "$TESTER_IP" "
set -e
mkdir -p /opt/trex
if [ ! -d /opt/trex/$TREX_VERSION ]; then
	cd /opt/trex
	curl -sL --fail '$TREX_TARBALL' -o '$TREX_VERSION.tar.gz' ||
		wget -q '$TREX_TARBALL' -O '$TREX_VERSION.tar.gz'
	tar xzf '$TREX_VERSION.tar.gz'
	rm '$TREX_VERSION.tar.gz'
fi
ls /opt/trex/$TREX_VERSION/ | head
ln -sfn /opt/trex/$TREX_VERSION /opt/trex/current
"

# ----- 3. Identify VPC NIC + bind to vfio-pci --------------------------------
log "identifying VPC NIC on tester ..."
VPC_PCI=$(ssh_cmd "$TESTER_IP" '
DEFAULT_DEV=$(ip -j route show default | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"dev\"])")
VPC_DEV=$(ip -br link | awk "/^en/ && !/lo/ {print \$1}" | grep -v "^$DEFAULT_DEV$" | head -1)
echo -n "$VPC_DEV "
ls -l /sys/class/net/$VPC_DEV/device 2>/dev/null | awk -F/ "{print \$NF}"
' | tail -1)
VPC_DEV=$(echo "$VPC_PCI" | awk '{print $1}')
PCI_ID=$(echo "$VPC_PCI"  | awk '{print $2}')
[ -n "$VPC_DEV" ] && [ -n "$PCI_ID" ] || die "could not identify VPC NIC on tester (got dev='$VPC_DEV' pci='$PCI_ID')"
log "tester VPC NIC: dev=$VPC_DEV  pci=$PCI_ID"

# ----- 4. Generate /etc/trex_cfg.yaml ----------------------------------------
ssh_cmd "$TESTER_IP" "cat > /etc/trex_cfg.yaml <<EOF
- port_limit      : 2
  version         : 2
  interfaces      : [\"$PCI_ID\", \"dummy\"]
  c               : 4
  port_info       :
      - dest_mac        :  aa:bb:cc:00:00:02     # SUT_rcv NIC -- overridden at run_sweep.sh
        src_mac         :  aa:bb:cc:00:00:01
      - dest_mac        :  aa:bb:cc:00:00:01
        src_mac         :  aa:bb:cc:00:00:02
  platform :
      master_thread_id  : 0
      latency_thread_id : 5
      dual_if   :
          - socket   : 0
            threads  : [1, 2, 3, 4]
EOF
"

# ----- 5. Bind NIC to vfio-pci -----------------------------------------------
ssh_cmd "$TESTER_IP" "
set -e
/opt/trex/current/dpdk_setup_ports.py -s 2>&1 | head -20 || true
/opt/trex/current/dpdk_setup_ports.py -L 2>&1 | head -20 || true
# Bind: detach from kernel ixgbe and attach to vfio-pci.
/opt/trex/current/dpdk_setup_ports.py -i 2>&1 | tail -20 || true
"

# ----- 6. State update -------------------------------------------------------
{
	cat "$STATE"
	echo "TESTER_VPC_PCI=$PCI_ID"
	echo "TESTER_VPC_DEV=$VPC_DEV"
} | state_save

log "done.  Tester T-Rex install complete.  Next: scripts/perf-trex/run_sweep.sh"
