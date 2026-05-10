#!/bin/bash
# Intra-node N3+N6 co-location — verifies FRR's BGP-MUP loop guard
# correctly suppresses T1ST install when the endpoint is covered by a
# self-originated ISD on a sibling VRF.
#
# Background (Matsushima feedback, 2026-05, concern #2):
#
#   "gw1 自体も、N6 VRF に T1ST route を import することがあるので、
#    vrf-red が export する ISD route で T1ST route を resolve できるか"
#
# Translated to wire-level semantics: if a single FRR node hosts both
# the N3 VRF (vrf-red, originating the ISD) and the N6 VRF (vrf-blue,
# importing T1ST whose endpoint falls inside the local ISD), what
# does FRR's BGP-MUP do?
#
# Answer (this test asserts): FRR's loop guard
# `bgp_mup_isd_is_self` correctly recognizes the situation and
# skips the T1ST install in any local per-vrf table.  H.Encaps'ing
# at vrf-blue toward the local ISD's SID would land on vrf-red's
# own End.M.GTP4.E SID install (same node), which is a physical
# encap-then-immediate-decap self-loop.  The data plane still works
# because vrf-red's seg6local action is installed in the default-vrf
# IPv6 FIB and any locally-emitted SRv6 packet whose outer dst hits
# the locator gets transformed there; the install in vrf-blue is
# unnecessary and would loop, so it is correctly omitted.
#
# Inter-node cross-VRF resolve (gw1 originates ISD, a different PE
# imports T1ST and resolves against the received ISD) is a separate
# scenario and is covered by:
#   - scripts/frr_mup_e2e_gobgp_scapy           (single PE-GW pair)
#   - scripts/frr_mup_multi_vrf_gobgp_scapy     (RT-split per-vrf import)
#
# Topology:
#
#   +-------+ 2001:db8:1::/64 +-----------------+
#   | gbgp  |-----------------|       gw1       |
#   | 65000 | BGP-MUP eBGP    | 65001           |
#   +-------+                 |  + vrf-red  100 |  ISD origin (rt 10:10)
#   gobgpd                    |  + vrf-blue 200 |  rt import 10:10
#                             +-----------------+
#
# gobgpd is the only BGP peer.  vrf-red advertises its ISD on the
# session, but gobgpd has no other peer to forward to, so the ISD
# never bounces back over BGP.  This isolates the test from any
# inter-node receive path — every BGP-MUP RIB transition we see is
# either local origination (vrf-red's ISD) or a directly received
# T1ST (from gobgpd injector).
#
# Address plan:
#   gbgp <-> gw1 BGP-MUP session   2001:db8:1::2 / ::1
#   gw1 SRv6 locator               2001:db8:f::/48 (24/24/8)
#   vrf-red ISD prefix             10.99.0.0/24    (T1ST endpoint inside)
#   T1ST UE prefix                 192.168.10.5/32
#   T1ST endpoint                  10.99.0.5
#   T1ST RT extcomm                10:10 (matches vrf-red export, vrf-blue import)
#   T1ST RD                        100:100
#
# Pass criteria:
#   1. Global MUP RIB carries the locally-originated ISD AND the
#      received T1ST (BGP session functioning).
#   2. vrf-red's ISD installs the End.M.GTP4.E SID into the default-vrf
#      IPv6 FIB (locator 2001:db8:f:100::/56 with `oif vrf-red`).
#   3. bgpd log records the loop guard firing for the T1ST:
#      "BGP-MUP: T1ST endpoint matches self-originated ISD".
#   4. No T1ST install lands in either vrf-red (table 100) or
#      vrf-blue (table 200) IPv4 FIB — the loop guard prevented it.

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

# -------------------------------------------------------------------------
# netns + veth wiring
# -------------------------------------------------------------------------
NSES="gbgp gw1"
for ns in $NSES; do mkdir -p /tmp/$ns; done
for ns in $NSES; do ip netns add $ns; done

ip link add veth-gb netns gbgp type veth peer name veth-gw netns gw1
for ns in $NSES; do ip -n $ns link set lo up; done
ip -n gbgp link set veth-gb up
ip -n gw1  link set veth-gw up

ip -n gbgp addr add 2001:db8:1::2/64 dev veth-gb nodad
ip -n gw1  addr add 2001:db8:1::1/64 dev veth-gw nodad

ip -n gw1 link add sr0 type dummy
ip -n gw1 link set sr0 up
ip -n gw1 addr add 2001:db8:f::/48 dev sr0 nodad

ip netns exec gw1 sysctl -wq net.ipv6.conf.all.forwarding=1
ip netns exec gw1 sysctl -wq net.ipv4.ip_forward=1

# Two VRFs on gw1 — vrf-red is the N3-side, vrf-blue is the N6-side.
ip -n gw1 link add vrf-red  type vrf table 100
ip -n gw1 link add vrf-blue type vrf table 200
ip -n gw1 link set vrf-red  up
ip -n gw1 link set vrf-blue up

# Prime ND so BGP can come up promptly.
ip netns exec gw1 ping -c 1 -W 1 2001:db8:1::2 >/dev/null 2>&1 || true

# -------------------------------------------------------------------------
# FRR + gobgpd
# -------------------------------------------------------------------------
install -m 644 $HERE/gw1/frr.conf /tmp/gw1/frr.conf

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

start_frr gw1

VTYSH="ip netns exec gw1 $FRR/vtysh/vtysh --vty_socket /tmp/gw1"
sleep 1
$VTYSH -f /tmp/gw1/frr.conf

install -m 644 $HERE/gbgp/gobgpd.toml /tmp/gbgp/gobgpd.toml
ip netns exec gbgp $BIN/gobgpd -t toml -f /tmp/gbgp/gobgpd.toml \
	--api-hosts=127.0.0.1:50051 \
	> /tmp/gbgp/gobgpd.log 2>&1 &
GOBGP_PID=$!
sleep 2
GOBGP="ip netns exec gbgp $BIN/gobgp"

echo "===WAIT-SESSIONS==="
for i in $(seq 1 60); do
	gw_n=$($VTYSH -c 'show bgp summary json' 2>/dev/null \
		| grep -oE '"state":"Established"' | wc -l || echo 0)
	gb_n=$($GOBGP neighbor 2>/dev/null | awk 'NR>1 && $0 ~ /Establ/' | wc -l || echo 0)
	if [ "$gw_n" -ge 1 ] && [ "$gb_n" -ge 1 ]; then break; fi
	sleep 1
done

echo "===WAIT-ISD-ORIG==="
for i in $(seq 1 30); do
	gw_isd=$($VTYSH -c "show bgp ipv4 mup all" 2>/dev/null \
		| grep -c "10.99.0.0/24")
	if [ "$gw_isd" -ge 1 ]; then break; fi
	sleep 1
done

echo "===INJECT==="
$GOBGP global rib add -a ipv4-mup t1st 192.168.10.5/32 \
	rd 100:100 rt 10:10 teid 12345 qfi 9 \
	endpoint 10.99.0.5 source 10.99.0.5 2>&1 || echo "T1ST inject FAIL"

sleep 3

# -------------------------------------------------------------------------
# Diagnostic dumps
# -------------------------------------------------------------------------
echo "===VRF-RED-MUP-RIB==="
$VTYSH -c 'show bgp vrf vrf-red ipv4 mup' 2>&1 | tail -25
echo "===VRF-RED-MUP-DETAIL==="
$VTYSH -c 'show bgp vrf vrf-red ipv4 mup all detail-routes' 2>&1 | head -60
echo "===VRF-BLUE-MUP-RIB==="
$VTYSH -c 'show bgp vrf vrf-blue ipv4 mup' 2>&1 | tail -25
echo "===VRF-BLUE-MUP-DETAIL==="
$VTYSH -c 'show bgp vrf vrf-blue ipv4 mup all detail-routes' 2>&1 | head -60
echo "===GLOBAL-MUP-RIB==="
$VTYSH -c 'show bgp ipv4 mup all' 2>&1 | tail -25
echo "===VRF-BLUE-FIB==="
ip -n gw1 -d -4 route show table 200 2>&1
echo "===VRF-RED-FIB==="
ip -n gw1 -d -4 route show table 100 2>&1
echo "===GW1-V6-MAIN==="
ip -n gw1 -d -6 route show 2>&1 | head -20

# -------------------------------------------------------------------------
# Verifications
# -------------------------------------------------------------------------
PASS=1
FAIL_REASONS=()
fail() { PASS=0; FAIL_REASONS+=("$1"); }

# (1) Global MUP RIB carries vrf-red's locally-originated ISD and
# gobgpd-injected T1ST.
GLOBAL_RIB=$($VTYSH -c 'show bgp ipv4 mup all' 2>&1)
echo "$GLOBAL_RIB" | grep -qE '\[1\]:.*10\.99\.0\.0/24' \
	|| fail "global MUP RIB lacks vrf-red ISD 10.99.0.0/24 (origination broken)"
echo "$GLOBAL_RIB" | grep -qE '\[3\]:.*192\.168\.10\.5' \
	|| fail "global MUP RIB lacks T1ST 192.168.10.5 (BGP session not delivering the inject)"

# (2) vrf-red's ISD has installed its End.M.GTP4.E SID into the
# default-vrf IPv6 FIB.  This is the install that data-plane traffic
# actually relies on, regardless of whether the T1ST install in
# vrf-blue/vrf-red ever lands.
ISD_INSTALL=$(ip -n gw1 -d -6 route show 2>&1 | grep -E 'End\.M\.GTP4\.E.*oif vrf-red' | head -1)
[ -n "$ISD_INSTALL" ] \
	|| fail "default-vrf IPv6 FIB missing End.M.GTP4.E install for vrf-red's ISD"

# (3) Loop guard fired in bgpd log.
LOOP_GUARD=$(grep -E "T1ST endpoint matches self-originated ISD" /tmp/gw1/bgpd.log 2>/dev/null | tail -1)
[ -n "$LOOP_GUARD" ] \
	|| fail "bgpd loop guard did NOT fire for T1ST 192.168.10.5 / ISD 10.99.0.0/24 (regression in bgp_mup_isd_is_self)"
echo "===LOOP-GUARD==="
echo "  ${LOOP_GUARD:-<no log line found>}"

# (4) No T1ST install in either vrf-red or vrf-blue IPv4 FIB.
VR_T1ST_FIB=$(ip -n gw1 -4 route show table 100 192.168.10.5 2>&1 | head -1)
VB_T1ST_FIB=$(ip -n gw1 -4 route show table 200 192.168.10.5 2>&1 | head -1)
[ -z "$VR_T1ST_FIB" ] \
	|| fail "vrf-red FIB has T1ST install (loop guard failed to suppress it): $VR_T1ST_FIB"
[ -z "$VB_T1ST_FIB" ] \
	|| fail "vrf-blue FIB has T1ST install (loop guard failed to suppress it): $VB_T1ST_FIB"

# -------------------------------------------------------------------------
# Verdict
# -------------------------------------------------------------------------
echo "===VERDICT==="
if [ "$PASS" = "1" ]; then
	echo "FRR-MUP-INTRA-NODE-XVRF: PASS"
else
	echo "FRR-MUP-INTRA-NODE-XVRF: FAIL"
	for r in "${FAIL_REASONS[@]}"; do echo "  - $r"; done
fi

if [ "$PASS" != "1" ]; then
	echo "===GW1-ZEBRA-LOG-TAIL==="; tail -120 /tmp/gw1/zebra.log 2>/dev/null
	echo "===GW1-BGPD-LOG-TAIL==="; tail -200 /tmp/gw1/bgpd.log 2>/dev/null
	echo "===GOBGPD-LOG-TAIL==="; tail -60 /tmp/gbgp/gobgpd.log 2>/dev/null
fi

kill $GOBGP_PID 2>/dev/null || true
[ -f /tmp/gw1/bgpd.pid    ] && kill $(cat /tmp/gw1/bgpd.pid)    2>/dev/null || true
[ -f /tmp/gw1/staticd.pid ] && kill $(cat /tmp/gw1/staticd.pid) 2>/dev/null || true
[ -f /tmp/gw1/zebra.pid   ] && kill $(cat /tmp/gw1/zebra.pid)   2>/dev/null || true
[ -f /tmp/gw1/mgmtd.pid   ] && kill $(cat /tmp/gw1/mgmtd.pid)   2>/dev/null || true
echo "===DONE==="
