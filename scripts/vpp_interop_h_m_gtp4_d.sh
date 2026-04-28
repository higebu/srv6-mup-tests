#!/bin/bash
set -e
export PATH=/home/yuya/ghq/github.com/higebu/iproute2/ip:$PATH
mount -t tmpfs tmpfs /tmp 2>/dev/null
mkdir -p /run/vpp /tmp/vpp

cat > /tmp/vpp/startup.conf <<'VPPCONF'
unix {
  nodaemon
  log /tmp/vpp/vpp.log
  cli-listen /run/vpp/cli.sock
  cli-no-banner
  cli-no-pager
}
api-segment { gid root prefix vpptest }
plugins {
  plugin default { disable }
  plugin srv6mobile_plugin.so { enable }
  plugin af_packet_plugin.so { enable }
}
buffers { buffers-per-numa 4096 default data-size 2048 }
cpu { main-core 0 }
VPPCONF

echo "===KERNEL===" $(uname -r)

ip netns add gnb; ip netns add srgw; ip netns add dn
ip link add veth-g netns gnb type veth peer name veth-g-srgw netns srgw
ip link add veth-e netns srgw type veth peer name veth-e-vpp
ip link add veth-f type veth peer name veth-f-dn netns dn

for ns in gnb srgw dn; do ip -n $ns link set lo up; done
ip -n gnb link set veth-g up
ip -n srgw link set veth-g-srgw up; ip -n srgw link set veth-e up
ip link set veth-e-vpp up; ip link set veth-f up
ip -n dn link set veth-f-dn up

ip -n gnb addr add 10.0.0.2/24 dev veth-g
ip -n srgw addr add 10.0.0.1/24 dev veth-g-srgw
ip -n srgw addr add 2001:db8:2::1/64 dev veth-e nodad
ip -n dn addr add 10.0.1.2/24 dev veth-f-dn

ip netns exec srgw sysctl -wq net.ipv4.ip_forward=1
ip netns exec srgw sysctl -wq net.ipv6.conf.all.forwarding=1

ip -n srgw -4 route add 10.99.0.0/24 \
    encap seg6local action H.M.GTP4.D \
        nh6 2001:db8:: src 2001:db8:2::1 v4_mask_len 32 sr_prefix_len 32 \
    dev veth-e
ip -n srgw -6 route add 2001:db8::/32 via 2001:db8:2::e dev veth-e

vpp -c /tmp/vpp/startup.conf > /tmp/vpp/stdout.log 2>&1 &
VPP_PID=$!
for i in $(seq 1 20); do [ -S /run/vpp/cli.sock ] && break; sleep 1; done

VPPCTL="vppctl -s /run/vpp/cli.sock"
$VPPCTL show version | head -1

$VPPCTL create host-interface name veth-e-vpp
$VPPCTL create host-interface name veth-f
$VPPCTL set int state host-veth-e-vpp up
$VPPCTL set int state host-veth-f up
# Promiscuous so VPP accepts traffic dst-MAC'd to the kernel veth MAC
$VPPCTL set int promiscuous on host-veth-e-vpp
$VPPCTL set int promiscuous on host-veth-f
$VPPCTL set int ip address host-veth-e-vpp 2001:db8:2::e/64
$VPPCTL set int ip address host-veth-f 10.0.1.1/24
$VPPCTL sr localsid prefix 2001:db8::/32 behavior end.m.gtp4.e v4src_position 32 fib-table 0
$VPPCTL ip route add 10.0.1.0/24 via 10.0.1.2 host-veth-f
$VPPCTL ip route add 10.99.0.0/24 via 10.0.1.2 host-veth-f

# Use VPP's actual host-interface MAC (it may auto-assign different from kernel veth)
VPP_E_MAC=$($VPPCTL show hardware-interfaces host-veth-e-vpp | awk '/Ethernet address/ {print $3}')
VPP_F_MAC=$($VPPCTL show hardware-interfaces host-veth-f      | awk '/Ethernet address/ {print $3}')
echo "VPP veth-e-vpp MAC: $VPP_E_MAC"
echo "VPP veth-f      MAC: $VPP_F_MAC"
ip -n srgw -6 neigh replace 2001:db8:2::e dev veth-e lladdr "$VPP_E_MAC" nud permanent

DN_MAC=$(ip -n dn link show veth-f-dn | awk '/ether/ {print $2}')
$VPPCTL set ip neighbor host-veth-f 10.0.1.2 $DN_MAC

$VPPCTL trace add af-packet-input 20

# Triple capture so we can mergecap the full path (pre-encap GTP-U on
# gnb-side, SRv6 wire on the SR-GW->VPP veth, post-decap GTP-U on the
# dn-side).  No single link sees all three stages.
ip netns exec gnb tcpdump -U -nni veth-g -w /tmp/input.pcap 2>/dev/null &
P_IN=$!
tcpdump -U -nni veth-e-vpp -w /tmp/srv6.pcap 'ip6' 2>/dev/null &
P_SRV6=$!
ip netns exec dn tcpdump -U -nni veth-f-dn -w /tmp/dn.pcap 2>/dev/null &
P_DN=$!
sleep 1

ip netns exec gnb python3 - <<'PY'
import os
from scapy.all import IP, UDP, ICMP, sendp, Ether
mac = os.popen("ip -n srgw link show veth-g-srgw | awk '/ether/ {print $2}'").read().strip()
gtpu = bytes.fromhex("34 ff 00 24 00 00 01 23 00 00 00 85"
                     "01 00 05 00")
inner = bytes(IP(src='10.0.0.2', dst='10.0.1.2') / ICMP())
pkt = (Ether(dst=mac) /
       IP(src='10.0.0.2', dst='10.99.0.2') /
       UDP(sport=2152, dport=2152) /
       (gtpu + inner))
sendp(pkt, iface='veth-g', verbose=False)
PY

sleep 2
kill -INT $P_IN $P_SRV6 $P_DN 2>/dev/null
wait $P_IN $P_SRV6 $P_DN 2>/dev/null
mergecap -w /tmp/merged.pcap /tmp/input.pcap /tmp/srv6.pcap /tmp/dn.pcap 2>/dev/null || true

echo "===VPP-LOCALSID==="
$VPPCTL show sr localsid
echo "===VPP-TRACE==="
$VPPCTL show trace
echo "===VPP-ERRORS==="
$VPPCTL show errors
echo "===DN-PCAP==="
tcpdump -nn -r /tmp/dn.pcap 2>/dev/null
echo "===VERIFY==="
python3 - <<'PY'
from scapy.all import rdpcap, IP, UDP
pkts = rdpcap('/tmp/dn.pcap')
ok = False
for p in pkts:
    if not (IP in p and UDP in p): continue
    if p[UDP].dport != 2152: continue
    payload = bytes(p[UDP].payload)
    if len(payload) < 12: continue
    teid = int.from_bytes(payload[4:8], 'big')
    print(f"VPP egress: src={p[IP].src} dst={p[IP].dst} TEID=0x{teid:08x}")
    if teid == 0x123: ok = True
print("===VPP-INTEROP-H_M_GTP4_D===" + (" PASS" if ok else " FAIL"))
PY
kill $VPP_PID 2>/dev/null
# Copy the captured pcaps out of the vng VM (set PCAP_OUT externally to /pcap).
if [ -n "${PCAP_OUT:-}" ] && [ -d "$PCAP_OUT" ]; then
    [ -f /tmp/merged.pcap ] && cp /tmp/merged.pcap "$PCAP_OUT/h_m_gtp4_d.pcap"
    echo "===PCAPS-SAVED=== $(ls "$PCAP_OUT" | tr '"'"'\n'"'"' '"'"' '"'"')"
fi
echo "===DONE==="
