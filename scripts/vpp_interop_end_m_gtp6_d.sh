#!/bin/bash
# Linux End.M.GTP6.D (RFC 9433 Section 6.3) -> VPP End.DT6 (RFC 8986 Section
# 4.8) interop test.  This is the matching pairing for End.M.GTP6.D's
# Section 6.3 semantics: the SR Policy ends at a non-GTP-U decap endpoint,
# so the resulting SRv6 packet (segments_left == 0 for a 1-segment policy
# per Section 6.3) is consumed by an End-DT6-class behavior — End.DT6
# does not require segments_left == 1 (that is End.M.GTP6.E's Section 6.5
# SRH-S02 constraint, which is the End.M.GTP6.D.Di pairing covered by
# vpp_interop_end_m_gtp6_d_di.sh).
#
# Topology:
#   gnb netns -- (IPv6 GTP-U) -- srgw netns (Linux End.M.GTP6.D) --
#     -- veth -- root netns (VPP End.DT6) -- veth -- dn netns
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

# IPv6: gnb 2001:db8:1::2 -- 2001:db8:1::1 srgw -- 2001:db8:2::1/::e veth-e -- 2001:db8:3::e veth-f
ip -n gnb addr add 2001:db8:1::2/64 dev veth-g nodad
ip -n srgw addr add 2001:db8:1::1/64 dev veth-g-srgw nodad
ip -n srgw addr add 2001:db8:2::1/64 dev veth-e nodad
ip -n dn addr add 2001:db8:3::e/64 dev veth-f-dn nodad

ip netns exec srgw sysctl -wq net.ipv6.conf.all.forwarding=1

# Linux End.M.GTP6.D: locator 2001:db8:f::/64 -> SRv6 toward 2001:db8:e::
# (VPP End.DT6 SID).  Per RFC 9433 Section 6.3 the rebuilt SRH carries the
# 1-segment SR Policy verbatim with segments_left == 0 and Args.Mob.Session
# encoded in SRH[0].  End.DT6 is content-agnostic about the Args.Mob bits
# (it just decaps and forwards based on the inner IPv6 DA), so the chain
# terminates cleanly without needing the leading-D slot that End.M.GTP6.D.Di
# (Section 6.4) preserves.
#
# sr_prefix_len 88 places Args.Mob.Session in bits 88..127 of SRH[0]; the
# resulting outer DA is the deterministic /128 SID
# 2001:db8:e:0:0:14:0:123 for TEID=0x123, QFI=5 (Args.Mob layout per RFC
# 9433 Section 6.1: high byte = (QFI<<2) | R<<1 | U, then 32-bit TEID).
# VPP's core SRv6 plugin matches End.DT6 by exact address only — placing
# Args.Mob at /88 keeps the prefix bits 0..87 (= 2001:db8:e::/88) clean
# and lets VPP install a /128 localsid at the full computed SID.
ip -n srgw -6 route add 2001:db8:f::/64 \
    encap seg6local action End.M.GTP6.D \
        srh segs 2001:db8:e:: \
        src 2001:db8:2::1 sr_prefix_len 88 \
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
# VPP End.DT6 (RFC 8986 Section 4.8): exact-address /128 localsid at the
# computed full SID = 2001:db8:e::/88 locator + Args.Mob.Session
# (TEID=0x123, QFI=5) at bits 88..127 = 2001:db8:e:0:0:14:0:123.  VPP's
# core SRv6 plugin matches localsids by exact address; the
# `prefix /N` form is srv6mobile plugin-specific (end.m.gtp6.*).
# fib-table 0 sends the post-decap inner packet through the default v6
# FIB toward dn.
$VPPCTL sr localsid address 2001:db8:e:0:0:14:0:123 behavior end.dt6 0
# Inner IPv6 destination route: gnb encodes the inner with dst within
# 2001:db8:9::/64; route that prefix toward dn so VPP's post-End.DT6 FIB
# lookup forwards out host-veth-f.
$VPPCTL ip route add 2001:db8:9::/64 via 2001:db8:3::e host-veth-f

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

# gnb -> srgw: IPv6/UDP/GTP-U (TEID 0x123, QFI 5) wrapping an inner
# ICMPv6 echo from 2001:db8:1::2 (gnb) to 2001:db8:9::dead (DN-side prefix).
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
# Expect a plain inner ICMPv6 echo at dn (no GTP-U, no SRv6 — End.DT6
# stripped both).  The inner src/dst must match what gnb emitted.
python3 - <<'PY'
from scapy.all import rdpcap, IPv6, UDP, ICMPv6EchoRequest
pkts = rdpcap('/tmp/dn.pcap')
ok = False
for p in pkts:
    if not (IPv6 in p and ICMPv6EchoRequest in p):
        continue
    # Reject any packet that still carries SRv6 or GTP-U:
    if UDP in p and p[UDP].dport == 2152:
        continue
    print(f"dn egress: src={p[IPv6].src} dst={p[IPv6].dst} (inner ICMPv6 echo)")
    if p[IPv6].src == '2001:db8:1::2' and p[IPv6].dst == '2001:db8:9::dead':
        ok = True
print("===VPP-INTEROP-END_M_GTP6_D===" + (" PASS" if ok else " FAIL"))
PY
kill $VPP_PID 2>/dev/null
# Copy the captured pcaps out of the vng VM (set PCAP_OUT externally to /pcap).
if [ -n "${PCAP_OUT:-}" ] && [ -d "$PCAP_OUT" ]; then
    [ -f /tmp/merged.pcap ] && cp /tmp/merged.pcap "$PCAP_OUT/end_m_gtp6_d.pcap"
    echo "===PCAPS-SAVED=== $(ls "$PCAP_OUT" | tr '\n' ' ')"
fi
echo "===DONE==="
