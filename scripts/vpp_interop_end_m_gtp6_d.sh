#!/bin/bash
# Linux End.M.GTP6.D → VPP end.m.gtp6.e interop test
# Topology:
#   gnb netns -- (IPv6 GTP-U) -- srgw netns (Linux End.M.GTP6.D) --
#     -- veth -- root netns (VPP end.m.gtp6.e) -- veth -- dn netns
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

# IPv6: gnb 2001:db8:1::2 -- 2001:db8:1::1 srgw -- 2001:db8:2::1/::e veth-e -- 2001:db8:3::e veth-f
ip -n gnb addr add 2001:db8:1::2/64 dev veth-g nodad
ip -n srgw addr add 2001:db8:1::1/64 dev veth-g-srgw nodad
ip -n srgw addr add 2001:db8:2::1/64 dev veth-e nodad
ip -n dn addr add 2001:db8:3::e/64 dev veth-f-dn nodad

ip netns exec srgw sysctl -wq net.ipv6.conf.all.forwarding=1

# Linux End.M.GTP6.D: locator 2001:db8:f::/64 → SRv6 toward 2001:db8:e::/64 (VPP egress)
ip -n srgw -6 route add 2001:db8:f::/64 \
    encap seg6local action End.M.GTP6.D \
        srh segs 2001:db8:e:: \
        src 2001:db8:2::1 sr_prefix_len 64 \
    dev veth-e

ip -n gnb -6 route add 2001:db8:f::/64 via 2001:db8:1::1
# srgw needs a route toward the egress SID (2001:db8:e::/64) so the SRv6
# packet emitted by End.M.GTP6.D actually reaches VPP.
ip -n srgw -6 route add 2001:db8:e::/64 via 2001:db8:2::e dev veth-e

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
# end.m.gtp6.e on /88: locator 88 + Args.Mob.Session 40 = 128
$VPPCTL sr localsid prefix 2001:db8:e::/64 behavior end.m.gtp6.e fib-table 0
$VPPCTL ip route add 2001:db8:9::/64 via 2001:db8:3::e host-veth-f
# After end.m.gtp6.e decap, the new GTP-U outer dst = SRH[0] which is
# the original GTP-U dst (= 2001:db8:f::1, preserved by Linux's
# End.M.GTP6.D per RFC 9433 §6.5).  Route that toward the dn ns.
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

# gnb -> srgw: IPv6/UDP/GTP-U (TEID 0x123, QFI 5)
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

echo "===VPP-FIB==="; $VPPCTL show ip6 fib | head -60
echo "===VPP-LOCALSID==="; $VPPCTL show sr localsid
echo "===VPP-TRACE==="; $VPPCTL show trace
echo "===VPP-ERRORS==="; $VPPCTL show errors
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
    print(f"VPP egress: src={p[IPv6].src} dst={p[IPv6].dst} TEID=0x{teid:08x}")
    if teid == 0x123: ok = True
print("===VPP-INTEROP-END_M_GTP6_D===" + (" PASS" if ok else " FAIL"))
PY
kill $VPP_PID 2>/dev/null
# Copy the captured pcaps out of the vng VM (set PCAP_OUT externally to /pcap).
if [ -n "${PCAP_OUT:-}" ] && [ -d "$PCAP_OUT" ]; then
    [ -f /tmp/merged.pcap ] && cp /tmp/merged.pcap "$PCAP_OUT/end_m_gtp6_d.pcap"
    echo "===PCAPS-SAVED=== $(ls "$PCAP_OUT" | tr '"'"'\n'"'"' '"'"' '"'"')"
fi
echo "===DONE==="
