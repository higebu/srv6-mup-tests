#!/bin/bash
# End-to-end BGP-MUP test inside one vng VM:
#
#   - gobgp        plays MUP-Controller (injects T1ST + T2ST)
#   - pe1 (FRR)    plays MUP-PE         (originates DSD; UE-side termination)
#   - gw1 (FRR)    plays MUP-GW         (originates ISD; gNB-side bridge)
#   - gnb          plays gNB            (scapy GTP-U sender / sniffer)
#   - dn           plays DN host        (carries the UE-reachable network)
#
# Topology (gNB on the left, UE-side network on the right):
#
#   +-----+ gtpu  +-----+ srv6  +-----+ ipv4  +-----+
#   | gnb |-------| gw1 |-------| pe1 |-------| dn  |
#   +-----+ veth  +-----+ veth  +-----+ veth  +-----+
#   scapy         MUP-GW        MUP-PE
#                 ISD origin    DSD origin
#                  ↑                  ↑
#                  |                  |
#                  +-- gobgpd (MUP-C) --+
#                      via separate veth into pe1
#
# DL flow (dn -> UE 192.168.10.5):
#   dn -> pe1                                    plain IPv4
#       --H.Encaps SRv6, segs=<synth-SID>------> gw1
#       --End.M.GTP4.E (consume SID, synth GTP-U)-> gnb
#   gnb (scapy) sniffs incoming GTP-U and decaps
#
# UL flow (gnb -> dn):
#   gnb (scapy crafts GTP-U(TEID,QFI) inside ICMP echo) -> gw1
#       --H.M.GTP4.D (consume GTP-U, encaps SRv6 nh6=DSD-SID)-> pe1
#       --End.DT4 (decap SRv6, lookup IPv4 table)----> dn
#
# Required co-built siblings:
#   ../linux:b4/seg6-mobile (bzImage)
#   ../iproute2:b4/seg6-mobile  (ip)
#   ../frr (this work, master + seg6-mobile commits)
#   ../srv6-mup-tests/.bin/gobgp{,d}
#
# Usage (from outside the VM, host shell):
#   vng -m 4G --rwdir=$ROOT --run ../linux --user root \
#       -- ./scripts/frr_mup_e2e_gobgp_scapy.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
FRR=$ROOT/frr
BIN=$HERE/../../.bin

export PATH="$ROOT/iproute2/ip:$BIN:$PATH"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /usr/local/var/run 2>/dev/null
mkdir -p /usr/local/var/run/frr 2>/dev/null
mount -t tmpfs tmpfs /usr/local/var/lib 2>/dev/null
mkdir -p /usr/local/var/lib/frr 2>/dev/null

echo "===KERNEL=== $(uname -r)"
ip -V

NSES="gnb gw1 pe1 dn gbgp"

# -------------------------------------------------------------------------
# Address plan
# -------------------------------------------------------------------------
# gNB-side IPv4:    10.99.0.0/24    gw1=.1   gnb=.5
#                   10.99.0.100/32  T2ST endpoint (GTP-U service IP on gw1)
# SR-domain IPv6:   2001:db8:1::/64 gw1=::1  pe1=::2
# DN-side IPv4:     10.1.0.0/24     pe1=.1   dn=.5
# MUP-C bus:        2001:db8:0::/64 pe1=::1  gbgp=::2
# pe1 SR locator:   2001:db8:e::/48 block 24 / node 16 / func 8
# gw1 SR locator:   2001:db8:f::/48 block 24 / node 16 / func 8
#                   (loc_func = 48 bits; v4_DA(32)+ArgsMob(40) fits in 128)
#
# UE prefix:        192.168.10.5/32 (single UE)
# T1ST endpoint:    10.99.0.5  (gnb, falls inside gw1's ISD 10.99.0.0/24)
# T2ST endpoint:    10.99.0.100 (gw1's GTP-U service IP)
# TEID:             12345  QFI: 9
# MUP-EC seg-id:    10:10
ASN_PE1=65001
ASN_GW1=65002
ASN_GBGP=65000
TEID=12345
QFI=9
UE_PFX=192.168.10.5
ISD_PFX=10.99.0.0/24
T1ST_EP=10.99.0.5    # = gnb
T2ST_EP=10.99.0.100  # = gw1 GTP-U service
DSD_EP=10.0.0.250
DN_IP=10.1.0.5

# -------------------------------------------------------------------------
# netns + veth wiring (gnb on the left)
# -------------------------------------------------------------------------
for ns in $NSES; do mkdir -p /tmp/$ns; done
for ns in $NSES; do ip netns add $ns; done

# gnb <-> gw1
ip link add veth-gnb netns gnb type veth peer name veth-gw-gnb netns gw1
# gw1 <-> pe1 (SR-domain)
ip link add veth-gw-sr netns gw1 type veth peer name veth-pe-sr netns pe1
# pe1 <-> dn
ip link add veth-pe-dn netns pe1 type veth peer name veth-dn netns dn
# pe1 <-> gbgp (MUP-C control bus)
ip link add veth-pe-gb netns pe1 type veth peer name veth-gb netns gbgp

for ns in $NSES; do ip -n $ns link set lo up; done

# SR locator dummies live on a dedicated interface (kernel rejects
# attaching SIDs to lo).
for ns in pe1 gw1; do
	ip -n $ns link add sr0 type dummy
	ip -n $ns link set sr0 up
done

# Bring interfaces up first so address assignments stick.
ip -n gnb  link set veth-gnb     up
ip -n gw1  link set veth-gw-gnb  up
ip -n gw1  link set veth-gw-sr   up
ip -n pe1  link set veth-pe-sr   up
ip -n pe1  link set veth-pe-dn   up
ip -n pe1  link set veth-pe-gb   up
ip -n dn   link set veth-dn      up
ip -n gbgp link set veth-gb      up

# pe1 hosts the End.DT4 endpoint, which the kernel's seg6_local code
# can only attach to a real VRF device (drivers/net/vrf.c rejects with
# EPERM when strict_mode is off).  Create vrf-red (table 100) and bind
# only the DN-side veth: SRv6 packets arrive in default vrf at sr0,
# the seg6local action decapsulates and forwards the inner IPv4 via
# vrf-red's table to dn.  BGP itself stays in the default vrf because
# `address-family ipv4 mup` is not allowed in non-default instances
# (bgp_vty.c:11679-11685).
ip -n pe1 link add vrf-red type vrf table 100
ip -n pe1 link set vrf-red up
ip netns exec pe1 sysctl -wq net.vrf.strict_mode=1
ip -n pe1 link set veth-pe-dn master vrf-red

# Now assign addresses (after vrf bind so inet6 addrs aren't flushed)
ip -n gnb  addr add 10.99.0.5/24      dev veth-gnb
ip -n gw1  addr add 10.99.0.1/24      dev veth-gw-gnb
ip -n gw1  addr add 2001:db8:1::1/64  dev veth-gw-sr nodad
ip -n pe1  addr add 2001:db8:1::2/64  dev veth-pe-sr nodad
ip -n pe1  addr add 10.1.0.1/24       dev veth-pe-dn
ip -n pe1  addr add 2001:db8:0::1/64  dev veth-pe-gb nodad
ip -n dn   addr add $DN_IP/24         dev veth-dn
ip -n gbgp addr add 2001:db8:0::2/64  dev veth-gb nodad
ip -n pe1  addr add 2001:db8:e::/48   dev sr0 nodad
ip -n gw1  addr add 2001:db8:f::/48   dev sr0 nodad

# Forwarding
for ns in pe1 gw1; do
	ip netns exec $ns sysctl -wq net.ipv6.conf.all.forwarding=1
	ip netns exec $ns sysctl -wq net.ipv4.ip_forward=1
	ip netns exec $ns sysctl -wq net.ipv4.conf.all.rp_filter=0
	ip netns exec $ns sysctl -wq net.ipv4.conf.default.rp_filter=0
done

# Set the SRv6 H.Encaps tunnel source on pe1 so the outer IPv6 SA
# carries the gNB's IPv4 at bytes 8..11 (per RFC 9433 §6.7).  gw1's
# End.M.GTP4.E reads those bits to construct the egress GTP-U IPv4
# source.  Without this the kernel emits GTP-U with src=0.0.0.0.
echo "===PE1-SR-TUNSRC-BEFORE==="
ip netns exec pe1 ip sr tunsrc show 2>&1
ip netns exec pe1 ip sr tunsrc set ::a63:5:0:0
echo "===PE1-SR-TUNSRC-AFTER==="
ip netns exec pe1 ip sr tunsrc show 2>&1

# Prime ND between pe1 and gw1 so zebra's NHT marks the SR-domain
# nexthops ACTIVE before BGP starts injecting routes.
ip netns exec pe1 ping -c 1 -W 1 2001:db8:1::1 >/dev/null 2>&1 || true
ip netns exec gw1 ping -c 1 -W 1 2001:db8:1::2 >/dev/null 2>&1 || true

# Default routes for the leaf hosts so reply packets can return.
ip -n gnb route add default via 10.99.0.1
ip -n dn  route add default via 10.1.0.1
# gnb explicitly knows the GTP-U service IP is reachable via gw1.
ip -n gnb route add $T2ST_EP/32 via 10.99.0.1
# SR locator routes are configured via FRR `ipv6 route` static
# commands inside pe1/gw1 zebra.conf so zebra's NHT subsystem sees
# them.  See write_pe1_conf / write_gw1_conf below.

# -------------------------------------------------------------------------
# FRR configs (daemon configs sit alongside this script in pe1/, gw1/,
# gbgp/; ASN_PE1=$ASN_PE1 / ASN_GW1=$ASN_GW1 / ASN_GBGP=$ASN_GBGP /
# ISD_PFX=$ISD_PFX are baked in there as literals)
# -------------------------------------------------------------------------
for ns in pe1 gw1; do
	install -m 644 $HERE/$ns/zebra.conf /tmp/$ns/zebra.conf
	install -m 644 $HERE/$ns/bgpd.conf  /tmp/$ns/bgpd.conf
done

# -------------------------------------------------------------------------
# Start FRR daemons in pe1 + gw1
# -------------------------------------------------------------------------
start_frr() {
	local ns=$1
	local mopts="-d -u root -g root -i /tmp/$ns/mgmtd.pid --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/mgmtd.log"
	local zopts="-d -u root -g root -f /tmp/$ns/zebra.conf -i /tmp/$ns/zebra.pid -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/zebra.log"
	local sopts="-d -u root -g root -i /tmp/$ns/staticd.pid -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/staticd.log"
	local bopts="-d -u root -g root -f /tmp/$ns/bgpd.conf  -i /tmp/$ns/bgpd.pid  -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/bgpd.log"
	ip netns exec $ns $FRR/mgmtd/mgmtd $mopts
	ip netns exec $ns $FRR/zebra/zebra $zopts
	ip netns exec $ns $FRR/staticd/staticd $sopts
	ip netns exec $ns $FRR/bgpd/bgpd  $bopts
}
start_frr pe1
start_frr gw1

VTYSH_PE1="ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1"
VTYSH_GW1="ip netns exec gw1 $FRR/vtysh/vtysh --vty_socket /tmp/gw1"

# staticd doesn't take a config file; push the static IPv6 routes for
# the SR domain via vtysh after the daemons are up.
sleep 1
$VTYSH_PE1 -c "configure terminal" -c "ipv6 route 2001:db8:f::/48 2001:db8:1::1 veth-pe-sr onlink" -c "exit"
$VTYSH_GW1 -c "configure terminal" -c "ipv6 route 2001:db8:e::/48 2001:db8:1::2 veth-gw-sr onlink" -c "exit"

# Wait for FRR to learn vrf-red, then apply segment direct.  The
# 'vrf vrf-red' option lets End.DT4 install reference vrf-red's
# table 100 (matching net.vrf.strict_mode).
for i in $(seq 1 30); do
	if $VTYSH_PE1 -c 'show vrf' 2>/dev/null | grep -q vrf-red; then break; fi
	sleep 0.5
done
$VTYSH_PE1 <<EOF
configure terminal
router bgp $ASN_PE1
address-family ipv4 mup
segment direct $DSD_EP rd 100:100 rt 10:10 mup 10:10 behavior End_DT4 vrf vrf-red
end
EOF

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
	echo "  try=$i pe1_est=$pe_n gw1_est=$gw_n gbgp_est=$gb_n"
	if [ "$pe_n" -ge 2 ] && [ "$gw_n" -ge 1 ] && [ "$gb_n" -ge 1 ]; then break; fi
	sleep 1
done

# Wait for ISD/DSD origination to complete (zebra SID Manager async).
echo "===WAIT-LOCAL-ORIG==="
for i in $(seq 1 30); do
	pe_dsd=$($VTYSH_PE1 -c "show bgp ipv4 mup all" 2>/dev/null | grep -c "$DSD_EP")
	gw_isd=$($VTYSH_GW1 -c "show bgp ipv4 mup all" 2>/dev/null | grep -c "10.99.0.0/24")
	echo "  try=$i pe_dsd=$pe_dsd gw_isd=$gw_isd"
	if [ "$pe_dsd" -ge 1 ] && [ "$gw_isd" -ge 1 ]; then break; fi
	sleep 1
done

# Capture the auto-allocated SIDs so the synthesized T1ST SID can be
# verified bit-by-bit against the operator-declared (TEID, QFI, EP).
# Parse the per-route detail block.  GW1's ISD (route_type 1) Remote SID
# is gw1's own locator-allocated SID; pe1's DSD (route_type 2) Remote
# SID is pe1's own.  Anchor the awk on the route_type marker so we
# don't confuse the two when both peers re-advertise to each other.
GW_ISD_SID=$($VTYSH_GW1 -c "show bgp ipv4 mup all detail-routes" 2>/dev/null \
	| awk '/^BGP routing table entry for \[1\]:\[1\]:/{f=1; next}
	       /^BGP routing table entry/{f=0}
	       f && /Remote SID:/{print $3; exit}' | tr -d ',')
PE_DSD_SID=$($VTYSH_PE1 -c "show bgp ipv4 mup all detail-routes" 2>/dev/null \
	| awk '/^BGP routing table entry for \[1\]:\[2\]:/{f=1; next}
	       /^BGP routing table entry/{f=0}
	       f && /Remote SID:/{print $3; exit}' | tr -d ',')
echo "===AUTO-SIDS==="
echo "  gw1 ISD SID = ${GW_ISD_SID:-<not-yet-allocated>}"
echo "  pe1 DSD SID = ${PE_DSD_SID:-<not-yet-allocated>}"

# Inject T1ST + T2ST from gobgpd.
echo "===INJECT==="
$GOBGP global rib add -a ipv4-mup t1st $UE_PFX/32 \
	rd 100:100 rt 10:10 teid $TEID qfi $QFI \
	endpoint $T1ST_EP source $T1ST_EP 2>&1 || echo "T1ST inject FAIL"

$GOBGP global rib add -a ipv4-mup t2st $T2ST_EP \
	rd 100:100 endpoint-address-length 32 teid $TEID \
	rt 10:10 mup 10:10 2>&1 || echo "T2ST inject FAIL"

sleep 3

# -------------------------------------------------------------------------
# RIB / FIB inspection
# -------------------------------------------------------------------------
echo "===PE1-BGP-MUP-DETAIL==="
$VTYSH_PE1 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | head -80
echo "===GW1-BGP-MUP-DETAIL==="
$VTYSH_GW1 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | head -80

echo "===PE1-IP-ROUTE==="
ip -n pe1 -d -4 route show $UE_PFX  2>&1
echo "===GW1-IP-ROUTE==="
ip -n gw1 -d -4 route show $T2ST_EP 2>&1
echo "===PE1-VRF-STATE==="
ip -n pe1 -d link show vrf-red 2>&1 | head -3
ip -n pe1 addr show 2>&1 | grep -E '^\d|inet|master' | head -30
ip -n pe1 -6 route show table 100 2>&1 | head -15
# Mirror the T1ST install (auto-installed by FRR in pe1's main table)
# into vrf-red table 100 so the DL reply path (dn -> 192.168.10.5)
# resolves on the vrf-red side after End.DT4 decap.  In production the
# proper mechanism would be a per-VRF BGP instance importing the T1ST
# via RT (L3VPN-style), but our `address-family ipv4 mup` is restricted
# to the default instance (bgp_vty.c:11679-11685).
T1ST_SID=$(ip -n pe1 -d -4 route show $UE_PFX 2>/dev/null \
	| awk '/encap seg6/{for (i=1; i<=NF; i++) if ($i=="segs" && $(i+1)=="1") print $(i+3)}' | head -1)
if [ -n "$T1ST_SID" ]; then
	ip -n pe1 -4 route add table 100 $UE_PFX/32 \
		encap seg6 mode encap segs $T1ST_SID \
		via inet6 2001:db8:1::1 dev veth-pe-sr onlink \
		proto bgp metric 20 2>&1 | sed 's/^/  /'
	echo "===PE1-VRF-RED-T1ST-MIRROR==="
	ip -n pe1 -d -4 route show table 100 $UE_PFX/32 2>&1
fi

echo "===PE1-SEG6LOCAL-DT4==="
ip -n pe1 -d -6 route show 2>&1 | grep -B0 -A0 -E 'End\.DT4|2001:db8:e:100' | head -10
echo "===GW1-SEG6LOCAL-GTP4E==="
ip -n gw1 -d -6 route show 2>&1 | grep -B0 -A0 -E 'End\.M\.GTP4\.E|2001:db8:f:100' | head -10
echo "===PE1-FULL-ROUTES-V4-MAIN==="
ip -n pe1 -d -4 route show table all 2>&1 | head -40
echo "===PE1-FULL-ROUTES-V6-MAIN==="
ip -n pe1 -d -6 route show table all 2>&1 | head -40
echo "===GW1-FULL-ROUTES-V4-MAIN==="
ip -n gw1 -d -4 route show table all 2>&1 | head -40
echo "===GW1-FULL-ROUTES-V6-MAIN==="
ip -n gw1 -d -6 route show table all 2>&1 | head -40
echo "===PE1-VRF-RED-ROUTES==="
ip -n pe1 -d -4 route show table 100 2>&1 | head -20
ip -n pe1 -d -6 route show table 100 2>&1 | head -20

echo "===PE1-V6-ROUTE-TO-GW1-LOC==="
ip -n pe1 -d -6 route show 2001:db8:f::/48 2>&1
$VTYSH_PE1 -c 'show ipv6 route 2001:db8:f::/48' 2>&1 | head -10
echo "===PE1-V6-NHT==="
$VTYSH_PE1 -c 'show ipv6 nht' 2>&1 | head -30
echo "===GW1-V6-ROUTE-TO-PE1-LOC==="
ip -n gw1 -d -6 route show 2001:db8:e::/48 2>&1
$VTYSH_GW1 -c 'show ipv6 route 2001:db8:e::/48' 2>&1 | head -10

# -------------------------------------------------------------------------
# Verifications
# -------------------------------------------------------------------------
PASS=1
FAIL_REASONS=()
fail() { PASS=0; FAIL_REASONS+=("$1"); }

# (1) pe1's UE-prefix install: encap seg6 mode encap (H.Encaps).
PE1_T1ST=$(ip -n pe1 -d -4 route show $UE_PFX 2>&1 | head -1)
case "$PE1_T1ST" in
	*"encap seg6"*"mode encap"*) ;;
	*) fail "pe1: T1ST install missing 'encap seg6 mode encap' (got: $PE1_T1ST)" ;;
esac

# (2) gw1's T2ST install: encap seg6local action H.M.GTP4.D nh6 <pe1-DSD-SID>.
GW1_T2ST=$(ip -n gw1 -d -4 route show $T2ST_EP 2>&1 | head -1)
case "$GW1_T2ST" in
	*"encap seg6local"*"H.M.GTP4.D"*) ;;
	*) fail "gw1: T2ST install missing 'H.M.GTP4.D' action (got: $GW1_T2ST)" ;;
esac
if [ -n "$PE_DSD_SID" ]; then
	if ! echo "$GW1_T2ST" | grep -qF "$PE_DSD_SID"; then
		fail "gw1: T2ST nh6 != pe1's DSD SID $PE_DSD_SID (got: $GW1_T2ST)"
	fi
fi

# (3) pe1's End.DT4 seg6local install at the DSD SID locator (must
# exist for UL terminator).  iproute2 prints encap *first* with `-d`.
PE1_DT4=$(ip -n pe1 -d -6 route show 2>&1 | grep -E 'End\.DT4' | head -1)
[ -n "$PE1_DT4" ] || fail "pe1: End.DT4 seg6local install missing"

# (4) gw1's End.M.GTP4.E seg6local install at the ISD SID locator.
GW1_GTP4E=$(ip -n gw1 -d -6 route show 2>&1 | grep -E 'End\.M\.GTP4\.E' | head -1)
[ -n "$GW1_GTP4E" ] || fail "gw1: End.M.GTP4.E seg6local install missing"

# (5) Args.Mob.Session bits in pe1's synthesized SID.
#
# Layout (RFC 9433 §6.6 + §6.7):
#   bits 0..(loc_func-1)   = ISD's locator+function (40 bits here)
#   bits loc_func..loc_func+31 = T1ST.endpoint v4 DA (32 bits)
#   bits 88..127           = Args.Mob.Session (40 bits, MSB-aligned)
#
# Args.Mob.Session = (TEID << 8) | (QFI & 0x3F) << 2  [40-bit value]
# For TEID=12345 QFI=9: (12345 << 8) | (9 << 2) = 0x3039_24
# Stored MSB-first in the trailing 40 bits -> last 5 bytes of the
# IPv6 SID are 00:00:30:39:24, i.e. the SID ends with "...:0:30:3924".
# -- compute expected suffix in pure shell (avoid python dep)
# Args.Mob.Session per RFC 9433 §6.1 Figure 8 layout (kernel decode):
#   byte 0   = (QFI<<2)  (top 6 bits = QFI, bottom 2 = R/U=0)
#   bytes 1..4 = TEID (network byte order)
ARGS_MOB_HEX=$(printf '%02x%08x' $(( (QFI & 0x3f) << 2 )) $TEID)
LAST5_BYTES="${ARGS_MOB_HEX:0:2}:${ARGS_MOB_HEX:2:4}:${ARGS_MOB_HEX:6:4}"
# Trailing groups -> we expect ":<group11>:<group12>" in IPv6 hex form
PE1_SEGS=$(ip -n pe1 -d -4 route show $UE_PFX 2>&1 | head -1)
echo "===ARGS-MOB-EXPECTED==="
echo "  Args.Mob.Session = 0x$ARGS_MOB_HEX  (TEID=$TEID QFI=$QFI)"
echo "  expected SID trailing-bytes 11..15 = $LAST5_BYTES"
echo "  pe1 install: $PE1_SEGS"

# Extract the segs SID hex from the route output.
SYNTH_SID=$(echo "$PE1_SEGS" | grep -oE 'segs 1 \[ [^ ]+' | awk '{print $4}')
echo "  pe1 synthesized SID = $SYNTH_SID"

# Expand SID to 32 hex chars (no colons) so we can verify last 10 chars.
expand_v6() {
	local v=$1
	python3 -c "import ipaddress; print(ipaddress.IPv6Address('$v').exploded.replace(':',''))" 2>/dev/null
}
# Locator structure for gw1 ISD: block-len 24 + node-len 24 + func-bits 8
# = loc_func 56 bits.  v4_DA starts at bit 56 = hex char offset 14.
LOC_FUNC_BITS=56
V4_DA_OFFSET=$(( LOC_FUNC_BITS / 4 ))
if [ -n "$SYNTH_SID" ]; then
	SID_HEX=$(expand_v6 "$SYNTH_SID")
	if [ -n "$SID_HEX" ]; then
		# Last 10 hex chars = bits 88..127 = Args.Mob.Session
		SID_LAST10=${SID_HEX: -10}
		echo "  pe1 synth Args.Mob bits = 0x$SID_LAST10  (expected 0x$ARGS_MOB_HEX)"
		[ "$SID_LAST10" = "$ARGS_MOB_HEX" ] || fail \
			"pe1: synthesized Args.Mob.Session mismatch (got 0x$SID_LAST10 want 0x$ARGS_MOB_HEX)"
		# v4_DA at bits loc_func..(loc_func+32) → 8 hex chars at offset
		EP_HEX=$(printf '%02x%02x%02x%02x' \
			$(echo $T1ST_EP | tr '.' ' '))
		SID_V4=${SID_HEX:$V4_DA_OFFSET:8}
		echo "  pe1 synth v4 DA bits   = 0x$SID_V4   (expected 0x$EP_HEX)"
		[ "$SID_V4" = "$EP_HEX" ] || fail \
			"pe1: synthesized v4 DA mismatch (got 0x$SID_V4 want 0x$EP_HEX)"
	fi
fi

# -------------------------------------------------------------------------
# scapy GTP-U end-to-end ping (UL: gnb -> dn, DL reply: dn -> gnb)
# -------------------------------------------------------------------------
echo "===PRE-PING-CONNECTIVITY==="
echo "-- pe1 -> gw1 (SR-domain v6):"
ip netns exec pe1 ping -c 1 -W 2 2001:db8:1::1 2>&1 | tail -3
echo "-- gnb -> gw1 (gNB-side v4):"
ip netns exec gnb ping -c 1 -W 2 10.99.0.1 2>&1 | tail -3
echo "-- dn -> pe1 (DN-side v4):"
ip netns exec dn ping -c 1 -W 2 10.1.0.1 2>&1 | tail -3
echo "-- pe1 (vrf-red) -> dn (validates vrf-red table):"
ip netns exec pe1 ip vrf exec vrf-red ping -c 1 -W 2 10.1.0.5 2>&1 | tail -3

echo "===TCPDUMP-START==="
mkdir -p /tmp/pcap
ip netns exec gnb tcpdump -nU -i veth-gnb     -w /tmp/pcap/gnb.pcap 2>/dev/null &
PT_GNB=$!
ip netns exec gw1 tcpdump -nU -i veth-gw-sr   -w /tmp/pcap/gw1-sr.pcap 2>/dev/null &
PT_GW1S=$!
ip netns exec gw1 tcpdump -nU -i veth-gw-gnb  -w /tmp/pcap/gw1-gnb.pcap 2>/dev/null &
PT_GW1G=$!
ip netns exec pe1 tcpdump -nU -i veth-pe-sr   -w /tmp/pcap/pe1-sr.pcap 2>/dev/null &
PT_PE1S=$!
ip netns exec pe1 tcpdump -nU -i veth-pe-dn   -w /tmp/pcap/pe1-dn.pcap 2>/dev/null &
PT_PE1D=$!
ip netns exec dn  tcpdump -nU -i veth-dn      -w /tmp/pcap/dn.pcap 2>/dev/null &
PT_DN=$!
sleep 1

echo "===SCAPY-GTPU-PING==="
cat > /tmp/gnb/gtpu_ping.py <<'PYEOF'
#!/usr/bin/env python3
"""Send one GTP-U(TEID) wrapping ICMP echo from UE -> DN, then sniff
for a GTP-U reply carrying the ICMP echo-reply on the same TEID.
Uses AsyncSniffer so the sniffer is armed BEFORE send -- in-VM netns
loopbacks can deliver the reply faster than the synchronous
send-then-sniff sequence catches."""
import sys, time
from scapy.all import IP, ICMP, UDP, conf, send, AsyncSniffer
from scapy.contrib.gtp import GTP_U_Header

GW       = sys.argv[1]
UE       = sys.argv[2]
DN       = sys.argv[3]
TEID     = int(sys.argv[4])
TIMEOUT  = float(sys.argv[5])

conf.verb = 0

def is_reply(pkt):
    if not pkt.haslayer(GTP_U_Header):
        return False
    teid = pkt[GTP_U_Header].teid
    has_icmp = pkt.haslayer(ICMP)
    icmp_type = int(pkt[ICMP].type) if has_icmp else None
    print("is_reply: teid={}({}) want={} has_icmp={} type={}".format(
        teid, type(teid).__name__, TEID, has_icmp, icmp_type))
    if int(teid) != TEID:
        return False
    if not has_icmp:
        return False
    return icmp_type == 0

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
            print("GTPU-PING-OK teid={} icmp_id={:#x}".format(TEID, pkt[ICMP].id))
            sniffer.stop()
            sys.exit(0)
    time.sleep(0.1)

sniffer.stop()
print("GTPU-PING-FAIL no matching GTP-U(ICMP echo-reply) within {}s".format(TIMEOUT))
print("--- captured ({} pkts) ---".format(len(sniffer.results or [])))
for pkt in (sniffer.results or []):
    print(pkt.summary())
    print("    layers:", [layer.name for layer in pkt.layers()])
sys.exit(1)
PYEOF
chmod +x /tmp/gnb/gtpu_ping.py

ip netns exec gnb python3 /tmp/gnb/gtpu_ping.py \
	$T2ST_EP $UE_PFX $DN_IP $TEID 5 \
	2>&1 | tee /tmp/gnb/gtpu_ping.log

if grep -q "GTPU-PING-OK" /tmp/gnb/gtpu_ping.log; then
	echo "ping: PASS"
else
	fail "scapy GTP-U end-to-end ping did not complete"
fi

# Stop captures and dump per-link summaries.
sleep 1
kill $PT_GNB $PT_GW1S $PT_GW1G $PT_PE1S $PT_PE1D $PT_DN 2>/dev/null
wait $PT_GNB $PT_GW1S $PT_GW1G $PT_PE1S $PT_PE1D $PT_DN 2>/dev/null
for p in gnb gw1-gnb gw1-sr pe1-sr pe1-dn dn; do
	echo "===PCAP-$p==="
	tcpdump -nr /tmp/pcap/$p.pcap 2>/dev/null | head -20
done

# -------------------------------------------------------------------------
# Verdict
# -------------------------------------------------------------------------
echo "===VERDICT==="
if [ "$PASS" = "1" ]; then
	echo "FRR-MUP-E2E-GOBGP-SCAPY: PASS"
else
	echo "FRR-MUP-E2E-GOBGP-SCAPY: FAIL"
	for r in "${FAIL_REASONS[@]}"; do echo "  - $r"; done
fi

# -------------------------------------------------------------------------
# Diagnostics on failure
# -------------------------------------------------------------------------
if [ "$PASS" != "1" ]; then
	echo "===PE1-ZEBRA-LOG-TAIL==="
	tail -120 /tmp/pe1/zebra.log 2>/dev/null
	echo "===GW1-ZEBRA-LOG-TAIL==="
	tail -120 /tmp/gw1/zebra.log 2>/dev/null
	echo "===PE1-BGPD-LOG-TAIL==="
	tail -120 /tmp/pe1/bgpd.log 2>/dev/null
	echo "===GW1-BGPD-LOG-TAIL==="
	tail -120 /tmp/gw1/bgpd.log 2>/dev/null
	echo "===GOBGPD-LOG-TAIL==="
	tail -60 /tmp/gbgp/gobgpd.log 2>/dev/null
fi

# -------------------------------------------------------------------------
# Teardown
# -------------------------------------------------------------------------
kill $GOBGP_PID 2>/dev/null || true
for ns in pe1 gw1; do
	[ -f /tmp/$ns/bgpd.pid    ] && kill $(cat /tmp/$ns/bgpd.pid)    2>/dev/null || true
	[ -f /tmp/$ns/staticd.pid ] && kill $(cat /tmp/$ns/staticd.pid) 2>/dev/null || true
	[ -f /tmp/$ns/zebra.pid   ] && kill $(cat /tmp/$ns/zebra.pid)   2>/dev/null || true
	[ -f /tmp/$ns/mgmtd.pid   ] && kill $(cat /tmp/$ns/mgmtd.pid)   2>/dev/null || true
done
echo "===DONE==="
