#!/bin/bash
# uplink (IPv6, drop-in): Linux End.M.GTP6.D.Di → VPP End (RFC 8986)
# Topology:
#   gnb netns -- (IPv6 GTP-U) -- srgw netns (Linux End.M.GTP6.D.Di) --
#     -- veth -- root netns (VPP End at S1) -- veth -- dn netns
#
# RFC 9433 §6.4 では D.Di は元の outer IPv6 DA (D) を SRH[0] に保存する。
# Args.Mob.Session は書かない (TEID は失われる; "drop-in" の本来の用途は
# IPv6 DA の透過保持)。VPP の End (RFC 8986) で SL を decrement させ、
# outer dst を SRH[0] = D に巻き戻して最終ネームスペースに届ける。
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$HERE/../../iproute2/ip:$PATH"
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

ip -n gnb addr add 2001:db8:1::2/64 dev veth-g nodad
ip -n srgw addr add 2001:db8:1::1/64 dev veth-g-srgw nodad
ip -n srgw addr add 2001:db8:2::1/64 dev veth-e nodad
ip -n dn addr add 2001:db8:3::e/64 dev veth-f-dn nodad

ip netns exec srgw sysctl -wq net.ipv6.conf.all.forwarding=1

# Linux End.M.GTP6.D.Di: catch IPv6 GTP-U to 2001:db8:f::/64 and
# transform to SRv6 with a single SR Policy segment 2001:db8:e::1.
# After encap the SRH is [orig_D, 2001:db8:e::1] (SRH[0]=D preserved,
# SRH[1]=S1 is the active segment).
ip -n srgw -6 route add 2001:db8:f::/64 \
    encap seg6local action End.M.GTP6.D.Di \
        srh segs 2001:db8:e::1 \
        src 2001:db8:2::1 \
    dev veth-e

ip -n gnb -6 route add 2001:db8:f::/64 via 2001:db8:1::1
# After D.Di encap, outer dst = 2001:db8:e::1 (S1) where VPP runs End.
ip -n srgw -6 route add 2001:db8:e::1/128 via 2001:db8:2::e dev veth-e

vpp -c /tmp/vpp/startup.conf > /tmp/vpp/stdout.log 2>&1 &
VPP_PID=$!
for i in $(seq 1 20); do [ -S /run/vpp/cli.sock ] && break; sleep 1; done

VPPCTL="vppctl -s /run/vpp/cli.sock"
$VPPCTL show version | head -1

$VPPCTL create host-interface name veth-e-vpp
$VPPCTL create host-interface name veth-f
$VPPCTL set int state host-veth-e-vpp up
$VPPCTL set int state host-veth-f up
$VPPCTL set int promiscuous on host-veth-e-vpp
$VPPCTL set int promiscuous on host-veth-f
$VPPCTL set int ip address host-veth-e-vpp 2001:db8:2::e/64
$VPPCTL set int ip address host-veth-f 2001:db8:3::1/64

# RFC 8986 plain End behavior at S1: decrement SL, set outer dst = SRH[SL].
$VPPCTL sr localsid address 2001:db8:e::1 behavior end

# After End processing, outer dst = SRH[0] = 2001:db8:f::1 -- forward it
# to the dn netns so we can capture and inspect the resulting SRv6
# packet (SL=0, outer dst = preserved orig D).
$VPPCTL ip route add 2001:db8:f::/64 via 2001:db8:3::e host-veth-f

VPP_E_MAC=$($VPPCTL show hardware-interfaces host-veth-e-vpp | awk '/Ethernet address/ {print $3}')
ip -n srgw -6 neigh replace 2001:db8:2::e dev veth-e lladdr "$VPP_E_MAC" nud permanent

DN_MAC=$(ip -n dn link show veth-f-dn | awk '/ether/ {print $2}')
$VPPCTL set ip neighbor host-veth-f 2001:db8:3::e $DN_MAC

$VPPCTL trace add af-packet-input 20

ip netns exec gnb tcpdump -U -nni veth-g -w /tmp/input.pcap 'ip6' 2>/dev/null &
P_IN=$!
tcpdump -U -nni veth-e-vpp -w /tmp/srv6.pcap 'ip6' 2>/dev/null &
P_SRV6=$!
ip netns exec dn tcpdump -U -nni veth-f-dn -w /tmp/dn.pcap 'ip6' 2>/dev/null &
P_DN=$!
sleep 1

# gnb -> srgw: IPv6/UDP/GTP-U with inner ICMPv6 ping toward 2001:db8:9::dead
ip netns exec gnb python3 - <<'PY'
import os
from scapy.all import IPv6, UDP, ICMPv6EchoRequest, sendp, Ether
mac = os.popen("ip -n srgw link show veth-g-srgw | awk '/ether/ {print $2}'").read().strip()
gtpu = bytes.fromhex("34 ff 00 38 00 00 01 23 00 00 00 85"
                     "01 00 05 00")
inner = bytes(IPv6(src='2001:db8:1::2', dst='2001:db8:9::dead') / ICMPv6EchoRequest())
pkt = (Ether(dst=mac) /
       IPv6(src='2001:db8:1::2', dst='2001:db8:f::1') /
       UDP(sport=2152, dport=2152) /
       (gtpu + inner))
sendp(pkt, iface='veth-g', verbose=False)
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
# After Linux D.Di encap and VPP End processing, the SRv6 packet should
# arrive at dn with:
#   - outer dst = 2001:db8:f::1 (= SRH[0] = preserved original outer DA)
#   - SRH[0]    = 2001:db8:f::1
#   - SRH[1]    = 2001:db8:e::1 (consumed)
#   - SL        = 0
#   - inner     = the original ICMPv6 EchoRequest from gnb (NOT GTP-U,
#                 since D.Di stripped the UDP+GTP-U headers)
python3 - <<'PY'
import sys
import ipaddress
from scapy.all import rdpcap, IPv6, IPv6ExtHdrSegmentRouting, ICMPv6EchoRequest, UDP

ok = False
for p in rdpcap('/tmp/dn.pcap'):
    if not (IPv6 in p and IPv6ExtHdrSegmentRouting in p):
        continue
    srh = p[IPv6ExtHdrSegmentRouting]
    if srh.type != 4:
        continue
    if len(srh.addresses) < 2:
        continue
    srh0 = ipaddress.IPv6Address(str(srh.addresses[0])).packed
    if srh0 != ipaddress.IPv6Address('2001:db8:f::1').packed:
        continue
    if UDP in p:                  # inner must NOT still be GTP-U
        continue
    if ICMPv6EchoRequest not in p:
        continue
    print(f"VPP egress: outer dst={p[IPv6].dst} SL={srh.segleft} "
          f"SRH[0]={srh.addresses[0]} SRH[1]={srh.addresses[1]} "
          f"inner=ICMPv6 echo")
    ok = True
    break
print("===VPP-INTEROP-END_M_GTP6_D_DI===" + (" PASS" if ok else " FAIL"))
PY
kill $VPP_PID 2>/dev/null
# Copy the captured pcaps out of the vng VM (set PCAP_OUT externally to /pcap).
if [ -n "${PCAP_OUT:-}" ] && [ -d "$PCAP_OUT" ]; then
    [ -f /tmp/merged.pcap ] && cp /tmp/merged.pcap "$PCAP_OUT/end_m_gtp6_d_di.pcap"
    echo "===PCAPS-SAVED=== $(ls "$PCAP_OUT" | tr '"'"'\n'"'"' '"'"' '"'"')"
fi
echo "===DONE==="
