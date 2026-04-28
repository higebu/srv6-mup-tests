#!/bin/bash
# Linux End.M.GTP6.E (decap) ↔ VPP end.m.gtp6.d drop-in (ingress)
#   gnb --(IPv6 GTP-U)--> VPP (end.m.gtp6.d) --(SRv6)--> srgw (End.M.GTP6.E) --(IPv6 GTP-U)--> dn
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
ip link add veth-g type veth peer name veth-g-gnb netns gnb
ip link add veth-e-vpp type veth peer name veth-e netns srgw
ip link add veth-x netns srgw type veth peer name veth-x-dn netns dn

for ns in gnb srgw dn; do ip -n $ns link set lo up; done
ip link set veth-g up; ip link set veth-e-vpp up
ip -n gnb  link set veth-g-gnb up
ip -n srgw link set veth-e up
ip -n srgw link set veth-x up
ip -n dn  link set veth-x-dn up

# IPv6 addressing
ip -n gnb  addr add 2001:db8:1::2/64 dev veth-g-gnb nodad
ip -n srgw addr add 2001:db8:2::1/64 dev veth-e nodad
ip -n srgw addr add 2001:db8:3::1/64 dev veth-x nodad
ip -n dn  addr add 2001:db8:3::2/64 dev veth-x-dn nodad

ip netns exec srgw sysctl -wq net.ipv6.conf.all.forwarding=1

# Linux End.M.GTP6.E at locator 2001:db8:f::/64
ip -n srgw -6 route add 2001:db8:f::/64 \
    encap seg6local action End.M.GTP6.E \
        src 2001:db8:2::1 \
    dev veth-e

# After Linux End.M.GTP6.E decap, the new GTP-U dst = SRH segments[0]
# (= original GTP-peer address 2001:db8:6::1 that VPP encoded as the
# tunnel target).  Route that toward dn to observe.
ip -n srgw -6 route add 2001:db8:6::/64 via 2001:db8:3::2 dev veth-x

vpp -c /tmp/vpp/startup.conf > /tmp/vpp/stdout.log 2>&1 &
VPP_PID=$!
for i in $(seq 1 20); do [ -S /run/vpp/cli.sock ] && break; sleep 1; done

VPPCTL="vppctl -s /run/vpp/cli.sock"
$VPPCTL show version | head -1

$VPPCTL create host-interface name veth-g
$VPPCTL create host-interface name veth-e-vpp
$VPPCTL set int state host-veth-g up
$VPPCTL set int state host-veth-e-vpp up
$VPPCTL set int promiscuous on host-veth-g
$VPPCTL set int promiscuous on host-veth-e-vpp
$VPPCTL set int ip address host-veth-g 2001:db8:1::1/64
$VPPCTL set int ip address host-veth-e-vpp 2001:db8:2::e/64

# VPP End.M.GTP6.D: localsid prefix 2001:db8:6::/64, sr_prefix 2001:db8:f::/64
# When gnb sends IPv6/UDP/GTP-U to 2001:db8:6::1, VPP encaps in SRv6 with
#   segments[1] = 2001:db8:f::Args.Mob.Session  (active SID, outer dst)
#   segments[0] = 2001:db8:6::1                 (preserved orig dst -> new GTP-U dst)
# VPP's end.m.gtp6.d only performs SRv6 encap when:
#   - drop-in flag is set, OR
#   - the inner T-PDU destination is link-local / multicast, OR
#   - GTP-U type != G-PDU (echo/error etc.).
# For an ordinary global-unicast inner, default behaviour is to strip the
# outer GTP-U and forward the inner raw, which is NOT what we want.
# Use drop-in to force SRv6 encapsulation per RFC 9433 §6.3 semantics.
$VPPCTL sr localsid prefix 2001:db8:6::/64 behavior end.m.gtp6.d 2001:db8:f::/64 nh-type ipv6 fib-table 0 drop-in

# Route SRv6 packet toward srgw (Linux End.M.GTP6.E).  The /48 must cover
# 2001:db8:f::/64.
$VPPCTL ip route add 2001:db8:f::/64 via 2001:db8:2::1 host-veth-e-vpp

# Static neighbors.
SRGW_E_MAC=$(ip -n srgw link show veth-e | awk '/ether/ {print $2}')
$VPPCTL set ip neighbor host-veth-e-vpp 2001:db8:2::1 $SRGW_E_MAC

GNB_MAC=$(ip -n gnb link show veth-g-gnb | awk '/ether/ {print $2}')
$VPPCTL set ip neighbor host-veth-g 2001:db8:1::2 $GNB_MAC

VPP_G_MAC=$($VPPCTL show hardware-interfaces host-veth-g | awk '/Ethernet address/ {print $3}')
ip -n gnb -6 neigh replace 2001:db8:1::1 dev veth-g-gnb lladdr "$VPP_G_MAC" nud permanent

VPP_E_MAC=$($VPPCTL show hardware-interfaces host-veth-e-vpp | awk '/Ethernet address/ {print $3}')
ip -n srgw -6 neigh replace 2001:db8:2::e dev veth-e lladdr "$VPP_E_MAC" nud permanent

DN_MAC=$(ip -n dn link show veth-x-dn | awk '/ether/ {print $2}')
ip -n srgw -6 neigh replace 2001:db8:3::2 dev veth-x lladdr "$DN_MAC" nud permanent

$VPPCTL trace add af-packet-input 20

ip netns exec gnb tcpdump -U -nni veth-g-gnb -w /tmp/input.pcap 'ip6' 2>/dev/null &
P_IN=$!
# Capture wire on srgw-side veth peer: VPP's af_packet TX on host-veth-e-vpp
# is invisible to tcpdump on the same iface, so capture on the kernel-side
# veth where the SRv6 packet arrives as RX from the veth pair.
ip netns exec srgw tcpdump -U -nni veth-e -w /tmp/srv6.pcap 'ip6' 2>/dev/null &
P_SRV6=$!
ip netns exec dn  tcpdump -U -nni veth-x-dn -w /tmp/dn.pcap 'ip6 and udp port 2152' 2>/dev/null &
P_DN=$!
sleep 1

# gnb sends IPv6/UDP/GTP-U to 2001:db8:6::1 (VPP localsid)
VPP_G_MAC_FOR_PKT="$VPP_G_MAC" ip netns exec gnb python3 - <<'PY'
import os
from scapy.all import IPv6, UDP, ICMPv6EchoRequest, sendp, Ether
dmac = os.environ['VPP_G_MAC_FOR_PKT']
gtpu = bytes.fromhex("34 ff 00 38 00 00 01 23 00 00 00 85"
                     "01 00 05 00")
inner = bytes(IPv6(src='2001:db8:1::2', dst='2001:db8:9::dead') / ICMPv6EchoRequest())
pkt = (Ether(dst=dmac) /
       IPv6(src='2001:db8:1::2', dst='2001:db8:6::1') /
       UDP(sport=2152, dport=2152) /
       (gtpu + inner))
sendp(pkt, iface='veth-g-gnb', verbose=False)
PY

sleep 2
kill -INT $P_IN $P_SRV6 $P_DN 2>/dev/null
wait $P_IN $P_SRV6 $P_DN 2>/dev/null
mergecap -w /tmp/merged.pcap /tmp/input.pcap /tmp/srv6.pcap /tmp/dn.pcap 2>/dev/null || true

echo "===VPP-LOCALSID==="; $VPPCTL show sr localsid
echo "===VPP-TRACE===";   $VPPCTL show trace
echo "===VPP-ERRORS===";  $VPPCTL show errors
echo "===DN-PCAP==="; tcpdump -nn -r /tmp/dn.pcap 2>/dev/null
echo "===VERIFY==="
python3 - <<'PY'
from scapy.all import rdpcap, IPv6, UDP
pkts = rdpcap('/tmp/dn.pcap')
ok = False
for p in pkts:
    if not (IPv6 in p and UDP in p): continue
    if p[UDP].dport != 2152: continue
    payload = bytes(p[UDP].payload)
    if len(payload) < 12: continue
    teid = int.from_bytes(payload[4:8], 'big')
    print(f"Linux egress: src={p[IPv6].src} dst={p[IPv6].dst} TEID=0x{teid:08x}")
    if teid == 0x123: ok = True
print("===VPP-INTEROP-END_M_GTP6_E===" + (" PASS" if ok else " FAIL"))
PY
kill $VPP_PID 2>/dev/null
# Copy the captured pcaps out of the vng VM (set PCAP_OUT externally to /pcap).
if [ -n "${PCAP_OUT:-}" ] && [ -d "$PCAP_OUT" ]; then
    [ -f /tmp/merged.pcap ] && cp /tmp/merged.pcap "$PCAP_OUT/end_m_gtp6_e.pcap"
    echo "===PCAPS-SAVED=== $(ls "$PCAP_OUT" | tr '"'"'\n'"'"' '"'"' '"'"')"
fi
echo "===DONE==="
