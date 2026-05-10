#!/bin/bash
# Coexistence of address-family ipv4 unicast and address-family ipv4 mup
# in the same per-vrf BGP instance, exercising the kernel-level
# non-T-PDU passthrough contract from the FRR side.
#
# Background (Matsushima feedback, 2026-05):
#
#   The MUP-PE / MUP-GW vrf-red carries N3 traffic.  T-PDU GTP-U is
#   transformed by the seg6local action (H.M.GTP4.D / End.M.GTP4.E /
#   ...).  Non-T-PDU GTP-U (Echo Request, Echo Response, Error
#   Indication, ...) bypasses the seg6local action by design — the
#   kernel selftests assert that contract (see
#   tools/testing/selftests/net/srv6_h_m_gtp4_d_test.sh,
#   "TEST: H.M.GTP4.D (non-T-PDU passthrough)").  For passthrough to
#   actually work, vrf-red must hold normal IPv4 unicast routes
#   alongside the BGP-MUP route installs.  This test asserts that
#   FRR's BGP-MUP implementation does not break that property:
#
#     1. ipv4 unicast and ipv4 mup AFs coexist under
#        `router bgp <asn> vrf vrf-red` on gw1.
#     2. A connected ipv4 unicast route in vrf-red (the "lupf leg")
#        is reachable end-to-end via plain IPv4 forwarding.
#     3. Non-T-PDU GTP-U (Echo Request, msg type 0x01) sent from gnb
#        and addressed to the lupf-leg destination is forwarded
#        unaltered to lupf.  The same byte pattern is what the
#        kernel selftest sends.
#     4. T-PDU GTP-U end-to-end (gnb -> dn, ICMP echo carried in
#        GTP-U) still works — the MUP transformations are not
#        regressed by adding the unicast AF.
#
# Topology:
#
#   +-----+ gtpu  +-----+ srv6  +-----+ ipv4  +-----+
#   | gnb |-------| gw1 |-------| pe1 |-------| dn  |
#   +-----+ veth  +-----+ veth  +-----+ veth  +-----+
#                    |
#                    +-- veth-gw-lupf (master vrf-red)
#                    |
#                  +------+
#                  | lupf |  10.20.0.5 — non-T-PDU receiver
#                  +------+
#
# Address plan diff vs baseline (frr_mup_e2e_gobgp_scapy):
#
#   lupf leg:  10.20.0.0/24   gw1=.1   lupf=.5
#   (everything else is identical to the baseline harness.)
#
# Usage (from outside the VM, host shell):
#   vng -m 4G --rwdir=$ROOT --run ../linux --user root \
#       -- ./scripts/frr_mup_e2e_passthrough_gobgp_scapy/\
#frr_mup_e2e_passthrough_gobgp_scapy.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
FRR=$ROOT/frr
BIN=$HERE/../../.bin

DEBUG=${DEBUG:-0}

export PATH="$ROOT/iproute2/ip:$BIN:$PATH"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /usr/local/var/run 2>/dev/null
mkdir -p /usr/local/var/run/frr 2>/dev/null
mount -t tmpfs tmpfs /usr/local/var/lib 2>/dev/null
mkdir -p /usr/local/var/lib/frr 2>/dev/null

echo "===KERNEL=== $(uname -r)"
ip -V

NSES="gnb gw1 pe1 dn lupf gbgp"

ASN_PE1=65001
ASN_GW1=65002
ASN_GBGP=65000
TEID=12345
QFI=9
UE_PFX=192.168.10.5
T1ST_EP=10.99.0.5
T2ST_EP=10.99.0.100
DSD_EP=10.0.0.250
DN_IP=10.1.0.5
LUPF_IP=10.20.0.5
LUPF_GW=10.20.0.1

# -------------------------------------------------------------------------
# netns + veth wiring
# -------------------------------------------------------------------------
for ns in $NSES; do mkdir -p /tmp/$ns; done
for ns in $NSES; do ip netns add $ns; done

ip link add veth-gnb netns gnb type veth peer name veth-gw-gnb netns gw1
ip link add veth-gw-sr netns gw1 type veth peer name veth-pe-sr netns pe1
ip link add veth-pe-dn netns pe1 type veth peer name veth-dn netns dn
ip link add veth-pe-gb netns pe1 type veth peer name veth-gb netns gbgp
# lupf leg: a directly attached non-SRv6 IPv4 peer reachable from
# gw1's vrf-red.  Mirrors the lupf leg in
# tools/testing/selftests/net/srv6_h_m_gtp4_d_test.sh, where lupf is
# the destination for non-T-PDU GTP-U passthrough.
ip link add veth-gw-lupf netns gw1 type veth peer name veth-lupf netns lupf

for ns in $NSES; do ip -n $ns link set lo up; done

for ns in pe1 gw1; do
	ip -n $ns link add sr0 type dummy
	ip -n $ns link set sr0 up
done

for ns in $NSES; do
	for ifn in $(ip -n $ns -j link | python3 -c 'import sys,json
for l in json.load(sys.stdin):
    n=l["ifname"]
    if n!="lo": print(n)' 2>/dev/null); do
		ip -n $ns link set $ifn up 2>/dev/null || true
	done
done

# vrf-red on pe1 — End.DT4 binds to the DN-side veth.
ip -n pe1 link add vrf-red type vrf table 100
ip -n pe1 link set vrf-red up
ip netns exec pe1 sysctl -wq net.vrf.strict_mode=1
ip -n pe1 link set veth-pe-dn master vrf-red

# vrf-red on gw1 — gNB-side veth AND the lupf leg both live here.
# The lupf leg gives vrf-red an extra ipv4-unicast egress so non-T-PDU
# GTP-U has somewhere to forward to.
ip -n gw1 link add vrf-red type vrf table 100
ip -n gw1 link set vrf-red up
ip netns exec gw1 sysctl -wq net.vrf.strict_mode=1
ip -n gw1 link set veth-gw-gnb  master vrf-red
ip -n gw1 link set veth-gw-lupf master vrf-red

ip -n gnb  addr add 10.99.0.5/24      dev veth-gnb
ip -n gw1  addr add 10.99.0.1/24      dev veth-gw-gnb
ip -n gw1  addr add $LUPF_GW/24       dev veth-gw-lupf
ip -n lupf addr add $LUPF_IP/24       dev veth-lupf
ip -n gw1  addr add 2001:db8:1::1/64  dev veth-gw-sr nodad
ip -n pe1  addr add 2001:db8:1::2/64  dev veth-pe-sr nodad
ip -n pe1  addr add 10.1.0.1/24       dev veth-pe-dn
ip -n pe1  addr add 2001:db8:0::1/64  dev veth-pe-gb nodad
ip -n dn   addr add $DN_IP/24         dev veth-dn
ip -n gbgp addr add 2001:db8:0::2/64  dev veth-gb nodad
ip -n pe1  addr add 2001:db8:e::/48   dev sr0 nodad
ip -n gw1  addr add 2001:db8:f::/48   dev sr0 nodad

for ns in pe1 gw1; do
	ip netns exec $ns sysctl -wq net.ipv6.conf.all.forwarding=1
	ip netns exec $ns sysctl -wq net.ipv4.ip_forward=1
	ip netns exec $ns sysctl -wq net.ipv4.conf.all.rp_filter=0
	ip netns exec $ns sysctl -wq net.ipv4.conf.default.rp_filter=0
done

ip netns exec pe1 ip sr tunsrc set ::a63:5:0:0

ip netns exec pe1 ping -c 1 -W 1 2001:db8:1::1 >/dev/null 2>&1 || true
ip netns exec gw1 ping -c 1 -W 1 2001:db8:1::2 >/dev/null 2>&1 || true

ip -n gnb route add default via 10.99.0.1
ip -n dn  route add default via 10.1.0.1
ip -n gnb route add $T2ST_EP/32 via 10.99.0.1
# gnb needs to know how to reach the lupf leg via gw1.  Without this,
# Echo Request packets sent to LUPF_IP would be dropped at gnb.
ip -n gnb  route add 10.20.0.0/24 via 10.99.0.1
ip -n lupf route add default via $LUPF_GW

# -------------------------------------------------------------------------
# FRR configs
# -------------------------------------------------------------------------
for ns in pe1 gw1; do
	install -m 644 $HERE/$ns/frr.conf /tmp/$ns/frr.conf
done

start_frr() {
	local ns=$1
	local mopts="-d -u root -g root -i /tmp/$ns/mgmtd.pid --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/mgmtd.log"
	local zopts="-d -u root -g root -i /tmp/$ns/zebra.pid -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/zebra.log"
	local sopts="-d -u root -g root -i /tmp/$ns/staticd.pid -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/staticd.log"
	local bopts="-d -u root -g root -i /tmp/$ns/bgpd.pid  -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/bgpd.log"
	ip netns exec $ns $FRR/mgmtd/mgmtd $mopts
	ip netns exec $ns $FRR/zebra/zebra $zopts
	ip netns exec $ns $FRR/staticd/staticd $sopts
	ip netns exec $ns $FRR/bgpd/bgpd  $bopts
}

start_frr pe1
start_frr gw1

VTYSH_PE1="ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1"
VTYSH_GW1="ip netns exec gw1 $FRR/vtysh/vtysh --vty_socket /tmp/gw1"

sleep 1
$VTYSH_PE1 -f /tmp/pe1/frr.conf
$VTYSH_GW1 -f /tmp/gw1/frr.conf

sleep 1
$VTYSH_PE1 -c "configure terminal" -c "ipv6 route 2001:db8:f::/48 2001:db8:1::1 veth-pe-sr onlink" -c "exit"
$VTYSH_GW1 -c "configure terminal" -c "ipv6 route 2001:db8:e::/48 2001:db8:1::2 veth-gw-sr onlink" -c "exit"

# -------------------------------------------------------------------------
# Start gobgpd in gbgp + inject T1ST + T2ST as MUP-Controller
# -------------------------------------------------------------------------
install -m 644 $HERE/gbgp/gobgpd.toml /tmp/gbgp/gobgpd.toml
ip netns exec gbgp $BIN/gobgpd -t toml -f /tmp/gbgp/gobgpd.toml \
	--api-hosts=127.0.0.1:50051 \
	> /tmp/gbgp/gobgpd.log 2>&1 &
GOBGP_PID=$!
sleep 2
GOBGP="ip netns exec gbgp $BIN/gobgp"

echo "===WAIT-SESSIONS==="
for i in $(seq 1 60); do
	pe_n=$($VTYSH_PE1 -c 'show bgp summary json' 2>/dev/null \
		| grep -oE '"state":"Established"' | wc -l || echo 0)
	gw_n=$($VTYSH_GW1 -c 'show bgp summary json' 2>/dev/null \
		| grep -oE '"state":"Established"' | wc -l || echo 0)
	gb_n=$($GOBGP neighbor 2>/dev/null | awk 'NR>1 && $0 ~ /Establ/' | wc -l || echo 0)
	if [ "$pe_n" -ge 2 ] && [ "$gw_n" -ge 1 ] && [ "$gb_n" -ge 1 ]; then break; fi
	sleep 1
done

echo "===WAIT-LOCAL-ORIG==="
for i in $(seq 1 30); do
	pe_dsd=$($VTYSH_PE1 -c "show bgp ipv4 mup all" 2>/dev/null | grep -c "$DSD_EP")
	gw_isd=$($VTYSH_GW1 -c "show bgp ipv4 mup all" 2>/dev/null | grep -c "10.99.0.0/24")
	if [ "$pe_dsd" -ge 1 ] && [ "$gw_isd" -ge 1 ]; then break; fi
	sleep 1
done

echo "===INJECT==="
$GOBGP global rib add -a ipv4-mup t1st $UE_PFX/32 \
	rd 100:100 rt 10:10 teid $TEID qfi $QFI \
	endpoint $T1ST_EP source $T1ST_EP 2>&1 || echo "T1ST inject FAIL"
$GOBGP global rib add -a ipv4-mup t2st $T2ST_EP \
	rd 100:100 endpoint-address-length 64 teid $TEID \
	rt 20:20 mup 10:10 2>&1 || echo "T2ST inject FAIL"

sleep 3

# -------------------------------------------------------------------------
# Verifications — coexistence of ipv4 unicast and ipv4 mup AFs
# -------------------------------------------------------------------------
PASS=1
FAIL_REASONS=()
fail() { PASS=0; FAIL_REASONS+=("$1"); }

echo "===GW1-VRF-RED-IPV4-UNICAST==="
$VTYSH_GW1 -c 'show bgp vrf vrf-red ipv4 unicast' 2>&1 | head -20

echo "===GW1-VRF-RED-IPV4-MUP==="
$VTYSH_GW1 -c 'show bgp vrf vrf-red ipv4 mup' 2>&1 | head -20

echo "===GW1-IP-ROUTE-VRF-RED==="
ip -n gw1 -d -4 route show table 100 2>&1

# (1) gw1 vrf-red MUP install: T2ST H.M.GTP4.D action present (regression).
GW1_T2ST=$(ip -n gw1 -d -4 route show table 100 $T2ST_EP 2>&1 | head -1)
case "$GW1_T2ST" in
	*"encap seg6local"*"H.M.GTP4.D"*) ;;
	*) fail "gw1: T2ST install missing 'H.M.GTP4.D' action in vrf-red (got: $GW1_T2ST)" ;;
esac

# (2) gw1 vrf-red ipv4 unicast install: lupf-leg connected route
# present in BGP unicast RIB AND in the kernel vrf-red FIB.  This
# proves the two AFs hold the same vrf without the unicast side being
# silently swallowed by MUP processing.
GW1_LUPF_BGP=$($VTYSH_GW1 -c 'show bgp vrf vrf-red ipv4 unicast 10.20.0.0/24' 2>&1 | head -20)
echo "$GW1_LUPF_BGP" | grep -qE '10\.20\.0\.0/24|Network not in table' \
	|| fail "gw1: vrf-red ipv4 unicast RIB has no 10.20.0.0/24 entry"
echo "$GW1_LUPF_BGP" | grep -qE 'Network not in table' \
	&& fail "gw1: vrf-red ipv4 unicast 10.20.0.0/24 NOT installed in BGP RIB (redistribute connected ineffective)"

GW1_LUPF_FIB=$(ip -n gw1 -4 route show table 100 10.20.0.0/24 2>&1 | head -1)
[ -n "$GW1_LUPF_FIB" ] || fail "gw1: vrf-red FIB missing 10.20.0.0/24 connected route"

# (3) Sanity: vrf-red kernel forwarding works for plain IPv4.
echo "===SANITY-PING-LUPF==="
if ip netns exec gnb ping -c 1 -W 2 $LUPF_IP >/dev/null 2>&1; then
	echo "  gnb -> lupf plain ICMP: OK"
else
	fail "gnb -> lupf plain ICMP failed (vrf-red ipv4 unicast forwarding broken)"
fi

# -------------------------------------------------------------------------
# Non-T-PDU passthrough — Echo Request unaltered at lupf
# -------------------------------------------------------------------------
mkdir -p /tmp/pcap
ip netns exec lupf tcpdump -nU -i veth-lupf -w /tmp/pcap/lupf.pcap \
	'udp port 2152' 2>/dev/null &
PT_LUPF=$!
sleep 1

# Same wire bytes as the kernel selftest's gtpu_echo:
# msg type 0x01 (Echo Request), len 4, TEID 0, seq 0x4242, recovery TLV.
echo "===ECHO-REQUEST-SEND==="
ip netns exec gnb python3 - "$LUPF_IP" <<'PY'
import sys
from scapy.all import IP, UDP, send, conf
conf.verb = 0
v4_dst = sys.argv[1]
gtpu_echo = bytes.fromhex("32 01 00 04 00 00 00 00 42 42 00 00")
pkt = IP(src='10.99.0.5', dst=v4_dst) / UDP(sport=2152, dport=2152) / gtpu_echo
send(pkt)
PY

sleep 1
kill -INT $PT_LUPF 2>/dev/null
wait $PT_LUPF 2>/dev/null

echo "===PCAP-LUPF==="
tcpdump -nr /tmp/pcap/lupf.pcap 2>/dev/null | head -20

# Decode the pcap and check for an unaltered GTP-U Echo Request.
ECHO_OK=$(LUPF_IP=$LUPF_IP python3 - /tmp/pcap/lupf.pcap <<'PY'
import os, sys
from scapy.all import rdpcap, IP, UDP
want = os.environ['LUPF_IP']
for p in rdpcap(sys.argv[1]):
    if IP not in p or UDP not in p:
        continue
    if p[UDP].sport != 2152 or p[UDP].dport != 2152:
        continue
    if p[IP].dst != want:
        continue
    payload = bytes(p[UDP].payload)
    if len(payload) >= 2 and payload[1] == 0x01:
        print("ECHO-OK")
        sys.exit(0)
print("ECHO-MISSING")
sys.exit(1)
PY
) || true
echo "  passthrough verdict: $ECHO_OK"
case "$ECHO_OK" in
	*ECHO-OK*) ;;
	*) fail "non-T-PDU GTP-U Echo Request did NOT reach lupf — passthrough broken" ;;
esac

# -------------------------------------------------------------------------
# T-PDU end-to-end (regression — same scapy ping as the baseline test)
# -------------------------------------------------------------------------
echo "===TCPDUMP-START-TPDU==="
ip netns exec gnb tcpdump -nU -i veth-gnb     -w /tmp/pcap/gnb.pcap 2>/dev/null &
PT_GNB=$!
ip netns exec dn  tcpdump -nU -i veth-dn      -w /tmp/pcap/dn.pcap  2>/dev/null &
PT_DN=$!
sleep 1

cat > /tmp/gnb/gtpu_ping.py <<'PYEOF'
import sys, time
from scapy.all import IP, ICMP, UDP, conf, send, AsyncSniffer
from scapy.contrib.gtp import GTP_U_Header

GW, UE, DN, TEID, TIMEOUT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
conf.verb = 0

def is_reply(pkt):
    if not pkt.haslayer(GTP_U_Header):
        return False
    if int(pkt[GTP_U_Header].teid) != TEID:
        return False
    if not pkt.haslayer(ICMP):
        return False
    return int(pkt[ICMP].type) == 0

sniffer = AsyncSniffer(filter="udp port 2152", store=True, stop_filter=is_reply)
sniffer.start()
time.sleep(0.2)
inner = IP(src=UE, dst=DN) / ICMP(type=8, id=0xbeef, seq=1) / b'srv6mup'
outer = IP(src="10.99.0.5", dst=GW) / UDP(sport=2152, dport=2152) \
        / GTP_U_Header(teid=TEID) / inner
send(outer)
deadline = time.time() + TIMEOUT
seen = 0
while time.time() < deadline:
    for pkt in (sniffer.results or [])[seen:]:
        seen += 1
        if is_reply(pkt):
            print("GTPU-PING-OK teid={}".format(TEID))
            sniffer.stop(); sys.exit(0)
    time.sleep(0.1)
sniffer.stop()
print("GTPU-PING-FAIL")
sys.exit(1)
PYEOF

ip netns exec gnb python3 /tmp/gnb/gtpu_ping.py \
	$T2ST_EP $UE_PFX $DN_IP $TEID 5 2>&1 | tee /tmp/gnb/gtpu_ping.log

if grep -q "GTPU-PING-OK" /tmp/gnb/gtpu_ping.log; then
	echo "  T-PDU regression: OK"
else
	fail "T-PDU GTP-U end-to-end regression — adding ipv4 unicast AF broke MUP"
fi

sleep 1
kill $PT_GNB $PT_DN 2>/dev/null
wait $PT_GNB $PT_DN 2>/dev/null

# -------------------------------------------------------------------------
# Verdict
# -------------------------------------------------------------------------
echo "===VERDICT==="
if [ "$PASS" = "1" ]; then
	echo "FRR-MUP-PASSTHROUGH-GOBGP-SCAPY: PASS"
else
	echo "FRR-MUP-PASSTHROUGH-GOBGP-SCAPY: FAIL"
	for r in "${FAIL_REASONS[@]}"; do echo "  - $r"; done
fi

if [ "$PASS" != "1" ]; then
	echo "===GW1-ZEBRA-LOG-TAIL==="; tail -120 /tmp/gw1/zebra.log 2>/dev/null
	echo "===GW1-BGPD-LOG-TAIL==="; tail -120 /tmp/gw1/bgpd.log 2>/dev/null
	echo "===PE1-BGPD-LOG-TAIL==="; tail -60 /tmp/pe1/bgpd.log 2>/dev/null
	echo "===GOBGPD-LOG-TAIL==="; tail -60 /tmp/gbgp/gobgpd.log 2>/dev/null
fi

kill $GOBGP_PID 2>/dev/null || true
for ns in pe1 gw1; do
	[ -f /tmp/$ns/bgpd.pid    ] && kill $(cat /tmp/$ns/bgpd.pid)    2>/dev/null || true
	[ -f /tmp/$ns/staticd.pid ] && kill $(cat /tmp/$ns/staticd.pid) 2>/dev/null || true
	[ -f /tmp/$ns/zebra.pid   ] && kill $(cat /tmp/$ns/zebra.pid)   2>/dev/null || true
	[ -f /tmp/$ns/mgmtd.pid   ] && kill $(cat /tmp/$ns/mgmtd.pid)   2>/dev/null || true
done
echo "===DONE==="
