#!/bin/bash
# Linux End.M.GTP4.E (decap) ↔ VPP sr policy + plain encap (ingress)
#   gnb --(IPv4 GTP-U)--> VPP --(SRv6)--> srgw (End.M.GTP4.E) --(IPv4 GTP-U)--> dn
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
# gnb <- veth-g -> VPP <- veth-e-vpp -> srgw <- veth-x -> dn
ip link add veth-g type veth peer name veth-g-gnb netns gnb
ip link add veth-e-vpp type veth peer name veth-e netns srgw
ip link add veth-x netns srgw type veth peer name veth-x-dn netns dn

for ns in gnb srgw dn; do ip -n $ns link set lo up; done
ip link set veth-g up; ip link set veth-e-vpp up
ip -n gnb  link set veth-g-gnb up
ip -n srgw link set veth-e up
ip -n srgw link set veth-x up
ip -n dn  link set veth-x-dn up

ip -n gnb  addr add 10.0.0.2/24 dev veth-g-gnb
ip -n srgw addr add 2001:db8:2::1/64 dev veth-e nodad
ip -n srgw addr add 10.0.1.1/24 dev veth-x
ip -n dn  addr add 10.0.1.2/24 dev veth-x-dn

ip netns exec srgw sysctl -wq net.ipv4.ip_forward=1
ip netns exec srgw sysctl -wq net.ipv6.conf.all.forwarding=1

# Linux End.M.GTP4.E: prefix 2001:db8::/32, v4_mask_len 32 — final SID
# of the SR path; fires when SL=0.  Linux fixes the Source UPF Prefix
# at /64 (RFC 9433 §6.6 Figure 10 with P=64): IPv4 SA at bytes 8..11
# of the IPv6 SA, bytes 12..15 are ignored padding.  This matches VPP's
# "v6src_prefix .../64" below.
ip -n srgw -6 route add 2001:db8::/32 \
    encap seg6local action End.M.GTP4.E \
        src 2001:db8:1::2 v4_mask_len 32 \
    dev veth-e

# Generic RFC 8986 End at the "実体側" placeholder SID (= the segment
# VPP's t.m.gtp4.d uses as the policy's transit hop with the dynamic
# End.M.GTP4.E SID stacked behind it).  This advances SL/DA so the
# packet then re-routes via /32 and fires End.M.GTP4.E with SL=0.
# More-specific /128 must precede the /32 above for longest-prefix
# match to pick End first.
ip -n srgw -6 route add 2001:db8:dead::1/128 \
    encap seg6local action End \
    dev veth-e

# Reach back: srgw needs to know the egress IPv4 destination (10.99.0.0/24)
# is forwarded out veth-x via dn.  The decap inserts the IPv4 DA from the
# SID (10.99.0.2 in our test).
ip -n srgw -4 route add 10.99.0.0/24 via 10.0.1.2 dev veth-x

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
$VPPCTL set int ip address host-veth-g 10.0.0.1/24
$VPPCTL set int ip address host-veth-e-vpp 2001:db8:2::e/64

# VPP T.M.GTP4.D — the RFC 9433 §6.7 H.M.GTP4.D equivalent.  Three pieces
# must be in place for the plugin (src/plugins/srv6-mobile/) to actually
# strip the inbound IPv4/UDP/GTP-U and emit an SRv6 packet:
#
#   1. drop-in flag on the t.m.gtp4.d policy.  Without it node.c:1212
#      forwards the inner G_PDU to ip4-lookup instead of chaining into
#      the SRv6 encap node (RFC non-compliant).
#   2. A second "real" SR policy whose BSID matches the t.m.gtp4.d
#      sr_prefix exactly (16-byte mhash key).  Its SID list is what the
#      plugin uses to build the SRH on top of the dynamically derived
#      End.M.GTP4.E SID; without it sl=NULL and you get an SRH-less v6
#      encap.
#   3. sr steer to push the IPv4 ingress flow into the t.m.gtp4.d BSID
#      (the t.m.gtp4.d node only takes IPv4-typed packets).
#
# Sources: VPP 25.10 / master (HEAD ca681ca, 2026-04-20)
# src/plugins/srv6-mobile/{node.c:917,1212; gtp4_d.c:51-64,148}, and the
# upstream test test/test_srv6_mobile.py:189 (drop_in=1).
# "実体側" SR policy: VPP's t.m.gtp4.d emits SRH = [dynamic_SID,
# this_segment] with outer DA = this_segment.  Pointing it at
# 2001:db8:dead::1 (caught by srgw's End route below) gives a clean
# one-transit-hop SR path that drops to the End.M.GTP4.E SID with SL=0
# at Linux.
$VPPCTL sr policy add bsid 2001:db8:: next 2001:db8:dead::1 encap

# t.m.gtp4.d behavior — strips inbound IPv4/UDP/GTP-U, computes
# dynamic SID = locator(/32) | IPv4 DA(32) | Args.Mob.Session(40),
# stacks it onto the policy above.  v6src_prefix /64 places the gNB
# IPv4 SA at bytes 8..11 of the SRv6 outer SA (RFC 9433 §6.6 Figure 10
# canonical layout, P=64), which is the layout Linux End.M.GTP4.E
# expects (Linux fixes the Source UPF Prefix at /64).
$VPPCTL sr policy add bsid 2001:db8:5::1 \
    behavior t.m.gtp4.d 2001:db8::/32 \
    v6src_prefix 2001:db8:1::/64 \
    nhtype ipv4 fib-table 0 drop-in

# Steer IPv4 GTP-U bound for 10.99.0.0/24 into the t.m.gtp4.d BSID.
$VPPCTL sr steer l3 10.99.0.0/24 via bsid 2001:db8:5::1

# Route the SRv6 packet emitted by VPP back to srgw (Linux End.M.GTP4.E).
$VPPCTL ip route add 2001:db8::/32 via 2001:db8:2::1 host-veth-e-vpp

# Static neighbor toward srgw veth-e (use srgw's MAC).
SRGW_E_MAC=$(ip -n srgw link show veth-e | awk '/ether/ {print $2}')
$VPPCTL set ip neighbor host-veth-e-vpp 2001:db8:2::1 $SRGW_E_MAC

# Static neighbor toward gnb (use gnb's MAC).
GNB_MAC=$(ip -n gnb link show veth-g-gnb | awk '/ether/ {print $2}')
$VPPCTL set ip neighbor host-veth-g 10.0.0.2 $GNB_MAC

# Use VPP's actual veth MAC for kernel-side static neigh (gnb-side).
VPP_G_MAC=$($VPPCTL show hardware-interfaces host-veth-g | awk '/Ethernet address/ {print $3}')
ip -n gnb neigh replace 10.0.0.1 dev veth-g-gnb lladdr "$VPP_G_MAC" nud permanent

# srgw needs to know how to reach VPP's veth-e-vpp link-layer.
VPP_E_MAC=$($VPPCTL show hardware-interfaces host-veth-e-vpp | awk '/Ethernet address/ {print $3}')
ip -n srgw -6 neigh replace 2001:db8:2::e dev veth-e lladdr "$VPP_E_MAC" nud permanent

# dn needs ARP toward srgw too (for return GTP-U from srgw via veth-x).
SRGW_X_MAC=$(ip -n srgw link show veth-x | awk '/ether/ {print $2}')
ip -n dn neigh replace 10.0.1.1 dev veth-x-dn lladdr "$SRGW_X_MAC" nud permanent

$VPPCTL trace add af-packet-input 20

ip netns exec gnb tcpdump -U -nni veth-g-gnb -w /tmp/input.pcap 2>/dev/null &
P_IN=$!
# Capture wire on srgw-side veth peer: VPP's af_packet TX on host-veth-e-vpp
# is invisible to tcpdump on the same iface, so capture on the kernel-side
# veth where the SRv6 packet arrives as RX from the veth pair.
ip netns exec srgw tcpdump -U -nni veth-e -w /tmp/srv6.pcap 'ip6' 2>/dev/null &
P_SRV6=$!
ip netns exec dn  tcpdump -U -nni veth-x-dn -w /tmp/dn.pcap 'udp port 2152' 2>/dev/null &
P_DN=$!
sleep 1

# gnb sends IPv4 GTP-U toward 10.99.0.2 (which the VPP steers via t.m.gtp4.d).
ip netns exec gnb python3 - <<'PY'
import os
from scapy.all import IP, UDP, ICMP, sendp, Ether
mac = os.popen("ip -n gnb link show veth-g-gnb | awk '/ether/ {print $2}'").read().strip()
gtpu = bytes.fromhex("34 ff 00 24 00 00 01 23 00 00 00 85"
                     "01 00 05 00")
inner = bytes(IP(src='10.0.0.2', dst='10.99.0.2') / ICMP())
pkt = (Ether() /
       IP(src='10.0.0.2', dst='10.99.0.2') /
       UDP(sport=2152, dport=2152) /
       (gtpu + inner))
sendp(pkt, iface='veth-g-gnb', verbose=False)
PY

sleep 2
kill -INT $P_IN $P_SRV6 $P_DN 2>/dev/null
wait $P_IN $P_SRV6 $P_DN 2>/dev/null
mergecap -w /tmp/merged.pcap /tmp/input.pcap /tmp/srv6.pcap /tmp/dn.pcap 2>/dev/null || true

echo "===VPP-LOCALSID===";  $VPPCTL show sr localsid
echo "===VPP-POLICIES===";  $VPPCTL show sr policies
echo "===VPP-STEER===";     $VPPCTL show sr steering-policies
echo "===VPP-TRACE===";     $VPPCTL show trace
echo "===VPP-ERRORS===";    $VPPCTL show errors
echo "===DN-PCAP==="; tcpdump -nn -r /tmp/dn.pcap 2>/dev/null
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
    print(f"Linux egress: src={p[IP].src} dst={p[IP].dst} TEID=0x{teid:08x}")
    if teid == 0x123: ok = True
print("===VPP-INTEROP-END_M_GTP4_E===" + (" PASS" if ok else " FAIL"))
PY
kill $VPP_PID 2>/dev/null
# Copy the captured pcaps out of the vng VM (set PCAP_OUT externally to /pcap).
if [ -n "${PCAP_OUT:-}" ] && [ -d "$PCAP_OUT" ]; then
    [ -f /tmp/merged.pcap ] && cp /tmp/merged.pcap "$PCAP_OUT/end_m_gtp4_e.pcap"
    echo "===PCAPS-SAVED=== $(ls "$PCAP_OUT" | tr '"'"'\n'"'"' '"'"' '"'"')"
fi
echo "===DONE==="
