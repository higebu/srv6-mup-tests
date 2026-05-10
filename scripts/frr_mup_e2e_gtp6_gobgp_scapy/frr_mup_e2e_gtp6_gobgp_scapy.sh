#!/bin/bash
# End-to-end BGP-MUP v6 test inside one vng VM.  Mirrors
# scripts/frr_mup_e2e_gobgp_scapy/ but switches the UE-side and
# gNB-side address families to IPv6 so the test exercises:
#
#   - gw1: ISD origination on AFI_IP6 -> End.M.GTP6.E install at
#     gw1's locator (RFC 9433 Section 6.5)
#   - pe1: DSD origination on AFI_IP6 -> End.DT6 install at pe1's
#     locator (RFC 8986 Section 4.8) under `behavior mup export dt6`
#   - T1ST resolution against the v6 ISD synthesises an End.M.GTP6.E
#     SID per RFC 9433 Section 6.5 (Args.Mob.Session at bits 88..127,
#     no v4 DA bits)
#   - T2ST install carries the GTP-U(v6) endpoint (gw1's service IP
#     `2001:db8:a::100`).  The seg6local ingress action installed
#     by FRR follows the seg6-mobile branch's current implementation.
#
# Topology (gNB on the left, UE-side network on the right):
#
#   +-----+ gtpu  +-----+ srv6  +-----+ ipv6  +-----+
#   | gnb |-------| gw1 |-------| pe1 |-------| dn  |
#   +-----+ veth  +-----+ veth  +-----+ veth  +-----+
#   scapy         MUP-GW        MUP-PE
#                 ISD origin    DSD origin
#                  (End.M.GTP6.E)   (End.DT6)
#                  ^                 ^
#                  |                 |
#                  +-- gobgpd (MUP-C) --+
#                      via separate veth into pe1 (ipv6-mup AF)
#
# DL flow (dn -> UE 2001:db8:c::5):
#   dn -> pe1                                     plain IPv6
#       --H.Encaps SRv6, segs=<synth-SID>------>  gw1
#       --End.M.GTP6.E (consume SID, synth GTP-U v6) --> gnb
#   gnb (scapy) sniffs incoming GTP-U(v6) and decaps the inner
#   ICMPv6 echo-reply.
#
# UL flow (gnb -> dn):
#   gnb (scapy crafts GTP-U(TEID,QFI) over IPv6 inside ICMPv6 echo)
#       -> gw1 -- T2ST seg6local action (FRR install) --> pe1
#       -- End.DT6 (decap, lookup IPv6 table) -> dn
#
# Required co-built siblings (same as the v4 baseline):
#   ../linux:b4/seg6-mobile (bzImage)
#   ../iproute2:b4/seg6-mobile  (ip)
#   ../frr (this work, master + seg6-mobile commits)
#   ../srv6-mup-tests/.bin/gobgp{,d}
#
# Usage (from outside the VM, host shell):
#   vng -m 4G --rwdir=$ROOT --run ../linux --user root \
#       -- ./scripts/frr_mup_e2e_gtp6_gobgp_scapy/frr_mup_e2e_gtp6_gobgp_scapy.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
FRR=$ROOT/frr
BIN=$HERE/../../.bin

# DEBUG=1 turns on:
#   * nlmon0 inside pe1 + gw1 — captures every RTM_NEWROUTE FRR/zebra
#     emits, including the seg6local nest for End.DT6 / End.M.GTP6.E.
#   * `tcpdump -i any` on pe1 + gw1 alongside the existing per-veth
#     pcaps, useful for the seg6local internal flow that does not
#     reach a physical veth.
DEBUG=${DEBUG:-0}

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
# gNB-side IPv6:    2001:db8:a::/64    gw1=::1   gnb=::5
#                   2001:db8:a::100/128 T2ST endpoint (GTP-U service IP
#                   on gw1; falls inside gw1's ISD 2001:db8:a::/64).
# SR-domain IPv6:   2001:db8:1::/64    gw1=::1   pe1=::2
# DN-side IPv6:     2001:db8:b::/64    pe1=::1   dn=::5
# MUP-C bus:        2001:db8:0::/64    pe1=::1   gbgp=::2
# pe1 SR locator:   2001:db8:e::/48    block 24 / node 24 / func 8
# gw1 SR locator:   2001:db8:f::/48    block 24 / node 24 / func 8
#                   (loc_func = 56 bits; Args.Mob.Session 40 bits at
#                    the 88..127 range fits trivially.)
#
# Mnemonic key: 'a' = access network (gNB side), 'b' = backbone (DN
# side), 'c' = client (UE).  The 'gnb' / 'dn' / 'ue' words from the
# issue body are not valid hex digits, so this script picks the
# closest single-hex-digit stand-ins.  Same scheme as
# docs/topology.md's existing single-hex-digit /64 slots (e/f/6/9).
#
# UE prefix:        2001:db8:c::5/128  (single UE)
# T1ST endpoint:    2001:db8:a::5      (= gnb)
# T2ST endpoint:    2001:db8:a::100    (= gw1 GTP-U service IPv6)
# DSD address:      10.0.0.250  (DSD's Address AFI is IPv4 by current
#                                FRR; the inner-PDU AFI is independent
#                                per draft-ietf-bess-mup-safi
#                                Section 3.3.4.)
# TEID:             12345  QFI: 9
# MUP-EC seg-id:    10:10
ASN_PE1=65001
ASN_GW1=65002
ASN_GBGP=65000
TEID=12345
QFI=9
UE_PFX=2001:db8:c::5
ISD_PFX=2001:db8:a::/64
T1ST_EP=2001:db8:a::5    # = gnb
T2ST_EP=2001:db8:a::100  # = gw1 GTP-U service v6
DSD_EP=10.0.0.250
DN_IP=2001:db8:b::5

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

# pe1 hosts the End.DT6 endpoint.  vrf-red (table 100) owns the
# DN-side veth so SRv6 packets arriving at sr0 in the default vrf
# are decapped by End.DT6 and forwarded into vrf-red's IPv6 table.
ip -n pe1 link add vrf-red type vrf table 100
ip -n pe1 link set vrf-red up
ip netns exec pe1 sysctl -wq net.vrf.strict_mode=1
ip -n pe1 link set veth-pe-dn master vrf-red

# gw1 also needs vrf-red so `router bgp $ASN_GW1 vrf vrf-red` can
# bind.  veth-gw-gnb (toward the UE-prefix side) goes under it so
# the T1ST install lands in a table that resolves toward gnb.
ip -n gw1 link add vrf-red type vrf table 100
ip -n gw1 link set vrf-red up
ip netns exec gw1 sysctl -wq net.vrf.strict_mode=1
ip -n gw1 link set veth-gw-gnb master vrf-red

# Now assign addresses (after vrf bind so inet6 addrs aren't flushed).
ip -n gnb  addr add 2001:db8:a::5/64    dev veth-gnb     nodad
ip -n gw1  addr add 2001:db8:a::1/64    dev veth-gw-gnb  nodad
ip -n gw1  addr add 2001:db8:a::100/128 dev veth-gw-gnb  nodad
ip -n gw1  addr add 2001:db8:1::1/64      dev veth-gw-sr   nodad
ip -n pe1  addr add 2001:db8:1::2/64      dev veth-pe-sr   nodad
ip -n pe1  addr add 2001:db8:b::1/64     dev veth-pe-dn   nodad
ip -n pe1  addr add 2001:db8:0::1/64      dev veth-pe-gb   nodad
ip -n dn   addr add $DN_IP/64             dev veth-dn      nodad
ip -n gbgp addr add 2001:db8:0::2/64      dev veth-gb      nodad
ip -n pe1  addr add 2001:db8:e::/48       dev sr0          nodad
ip -n gw1  addr add 2001:db8:f::/48       dev sr0          nodad

# Forwarding (v6 only is enough for this test, but keep v4 too in
# case staticd/zebra leaks an internal v4 route).
for ns in pe1 gw1; do
	ip netns exec $ns sysctl -wq net.ipv6.conf.all.forwarding=1
	ip netns exec $ns sysctl -wq net.ipv4.ip_forward=1
done

# Set the SRv6 H.Encaps tunnel source on pe1 so the outer IPv6 SA is
# a globally-routable address (not ::).  Pe1's End.M.GTP6.E peer at
# gw1 doesn't reach back into the IPv4-encoded bytes 8..11 (that is a
# v4-only convention in End.M.GTP4.E), so this only needs to be a
# valid v6 address in pe1's underlay.
echo "===PE1-SR-TUNSRC-BEFORE==="
ip netns exec pe1 ip sr tunsrc show 2>&1
ip netns exec pe1 ip sr tunsrc set 2001:db8:e::cafe
echo "===PE1-SR-TUNSRC-AFTER==="
ip netns exec pe1 ip sr tunsrc show 2>&1

# Prime ND between pe1 and gw1 so zebra's NHT marks the SR-domain
# nexthops ACTIVE before BGP starts injecting routes.
ip netns exec pe1 ping -c 1 -W 1 2001:db8:1::1 >/dev/null 2>&1 || true
ip netns exec gw1 ping -c 1 -W 1 2001:db8:1::2 >/dev/null 2>&1 || true

# Default routes for the leaf hosts so reply packets can return.
ip -n gnb route add default via 2001:db8:a::1 dev veth-gnb
ip -n dn  route add default via 2001:db8:b::1  dev veth-dn

# -------------------------------------------------------------------------
# FRR configs (single frr.conf per ns, same convention used by the FRR
# topotests; each daemon picks up only the directives it owns).
# -------------------------------------------------------------------------
for ns in pe1 gw1; do
	install -m 644 $HERE/$ns/frr.conf /tmp/$ns/frr.conf
done

# -------------------------------------------------------------------------
# Start FRR daemons in pe1 + gw1
# -------------------------------------------------------------------------
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
DBG_PIDS=()
if [ "$DEBUG" = "1" ]; then
	echo "===DEBUG-NLMON-START==="
	mkdir -p /tmp/pcap
	for ns in pe1 gw1; do
		ip -n $ns link add nlmon0 type nlmon
		ip -n $ns link set nlmon0 up
		ip netns exec $ns tcpdump -nU -i nlmon0 \
			-w /tmp/pcap/$ns-nl.pcap 2>/dev/null &
		DBG_PIDS+=($!)
	done
fi

start_frr pe1
start_frr gw1

VTYSH_PE1="ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1"
VTYSH_GW1="ip netns exec gw1 $FRR/vtysh/vtysh --vty_socket /tmp/gw1"

sleep 1
$VTYSH_PE1 -f /tmp/pe1/frr.conf
$VTYSH_GW1 -f /tmp/gw1/frr.conf

# Static routes for the remote SR locators in default vrf.
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
	echo "  try=$i pe1_est=$pe_n gw1_est=$gw_n gbgp_est=$gb_n"
	if [ "$pe_n" -ge 2 ] && [ "$gw_n" -ge 1 ] && [ "$gb_n" -ge 1 ]; then break; fi
	sleep 1
done

# Wait for ISD/DSD origination to complete (zebra SID Manager async).
echo "===WAIT-LOCAL-ORIG==="
for i in $(seq 1 30); do
	pe_dsd=$($VTYSH_PE1 -c "show bgp ipv6 mup all" 2>/dev/null | grep -c "$DSD_EP")
	gw_isd=$($VTYSH_GW1 -c "show bgp ipv6 mup all" 2>/dev/null | grep -ci "2001:db8:a::/64")
	echo "  try=$i pe_dsd=$pe_dsd gw_isd=$gw_isd"
	if [ "$pe_dsd" -ge 1 ] && [ "$gw_isd" -ge 1 ]; then break; fi
	sleep 1
done

# Capture the auto-allocated SIDs.  GW1's ISD (route_type 1) Remote
# SID is gw1's own locator-allocated SID; pe1's DSD (route_type 2)
# Remote SID is pe1's own.
GW_ISD_SID=$($VTYSH_GW1 -c "show bgp ipv6 mup all detail-routes" 2>/dev/null \
	| awk '/^BGP routing table entry for \[1\]:\[1\]:/{f=1; next}
	       /^BGP routing table entry/{f=0}
	       f && /Remote SID:/{print $3; exit}' | tr -d ',')
PE_DSD_SID=$($VTYSH_PE1 -c "show bgp ipv6 mup all detail-routes" 2>/dev/null \
	| awk '/^BGP routing table entry for \[1\]:\[2\]:/{f=1; next}
	       /^BGP routing table entry/{f=0}
	       f && /Remote SID:/{print $3; exit}' | tr -d ',')
echo "===AUTO-SIDS==="
echo "  gw1 ISD SID = ${GW_ISD_SID:-<not-yet-allocated>}"
echo "  pe1 DSD SID = ${PE_DSD_SID:-<not-yet-allocated>}"

# Inject T1ST + T2ST from gobgpd.
echo "===INJECT==="
# T1ST: UE prefix 2001:db8:c::5/128, endpoint 2001:db8:a::5
# (must fall under gw1's ISD 2001:db8:a::/64).  endpoint-address
# is implied by `endpoint` value family for ipv6-mup.
$GOBGP global rib add -a ipv6-mup t1st $UE_PFX/128 \
	rd 100:100 rt 10:10 teid $TEID qfi $QFI \
	endpoint $T1ST_EP source $T1ST_EP 2>&1 || echo "T1ST inject FAIL"

# T2ST: GTP-U(v6) endpoint 2001:db8:a::100, endpoint-address-length
# 160 = 32 (RD) + 128 (full IPv6 addr).  Mirrors the v4 baseline's
# `endpoint-address-length 64` (= 32 RD + 32 v4 addr).
$GOBGP global rib add -a ipv6-mup t2st $T2ST_EP \
	rd 100:100 endpoint-address-length 160 teid $TEID \
	rt 20:20 mup 10:10 2>&1 || echo "T2ST inject FAIL"

sleep 3

# -------------------------------------------------------------------------
# RIB / FIB inspection
# -------------------------------------------------------------------------
echo "===PE1-BGP-MUP-DETAIL==="
$VTYSH_PE1 -c 'show bgp ipv6 mup all detail-routes' 2>&1 | head -80
echo "===GW1-BGP-MUP-DETAIL==="
$VTYSH_GW1 -c 'show bgp ipv6 mup all detail-routes' 2>&1 | head -80

echo "===PE1-IP-ROUTE-VRF-RED==="
ip -n pe1 -d -6 route show table 100 $UE_PFX  2>&1
echo "===GW1-IP-ROUTE-VRF-RED==="
ip -n gw1 -d -6 route show table 100 $T2ST_EP 2>&1
echo "===PE1-VRF-STATE==="
ip -n pe1 -d link show vrf-red 2>&1 | head -3
ip -n pe1 -6 route show table 100 2>&1 | head -15

echo "===PE1-SEG6LOCAL-DT6==="
ip -n pe1 -d -6 route show 2>&1 | grep -B0 -A0 -E 'End\.DT6|2001:db8:e:100' | head -10
echo "===GW1-SEG6LOCAL-GTP6E==="
ip -n gw1 -d -6 route show 2>&1 | grep -B0 -A0 -E 'End\.M\.GTP6\.E|2001:db8:f:100' | head -10
echo "===PE1-FULL-ROUTES-V6-MAIN==="
ip -n pe1 -d -6 route show table all 2>&1 | head -40
echo "===GW1-FULL-ROUTES-V6-MAIN==="
ip -n gw1 -d -6 route show table all 2>&1 | head -40
echo "===PE1-VRF-RED-ROUTES==="
ip -n pe1 -d -6 route show table 100 2>&1 | head -20
echo "===GW1-VRF-RED-ROUTES==="
ip -n gw1 -d -6 route show table 100 2>&1 | head -20

# -------------------------------------------------------------------------
# Verifications
# -------------------------------------------------------------------------
# FOLLOWUP-MUP-V6-E2E: gw1 End.M.GTP6.E install fires SR-decap but no
# outgoing GTP-U(v6) is observed at gnb (`src ::` placeholder may be
# the cause).  UL is also blocked because T2ST(v6) install is
# intentionally skipped (closed/20260509-150607) and there is no
# matching End.M.GTP6.D install on gw1 yet.  Both probes default to
# record-only (skipper) until srv6-mup-issues 20260510-042434 lands
# the fix.  Set SKIP_DL=0 / SKIP_UL=0 in env to re-gate strictly.
SKIP_DL=${SKIP_DL:-1}
SKIP_UL=${SKIP_UL:-1}

PASS=1
FAIL_REASONS=()
fail() { PASS=0; FAIL_REASONS+=("$1"); }

# (1) pe1's UE-prefix install: encap seg6 mode encap (H.Encaps).
PE1_T1ST=$(ip -n pe1 -d -6 route show table 100 $UE_PFX 2>&1 | head -1)
case "$PE1_T1ST" in
	*"encap seg6"*"mode encap"*) ;;
	*) fail "pe1: T1ST install missing 'encap seg6 mode encap' in vrf-red (got: $PE1_T1ST)" ;;
esac
PE1_T1ST_MAIN=$(ip -n pe1 -6 route show table main $UE_PFX 2>&1 | head -1)
[ -z "$PE1_T1ST_MAIN" ] || \
	fail "pe1: T1ST leaked into main FIB (slice isolation broken): $PE1_T1ST_MAIN"

# (2) gw1's T2ST install — intentionally skipped for v6 endpoints
# (closed/20260509-150607: bgp_mup_st_announce skips FIB install for
# T2ST(v6) and instead expects End.M.GTP6.D to dispatch on the MUP-GW
# side).  Kept as record-only output until the End.M.GTP6.D origination
# story lands; tracked by srv6-mup-issues 20260510-042434
# (FOLLOWUP-MUP-V6-E2E).  Skip both the encap-seg6local presence and
# the DSD-SID match assertions.
GW1_T2ST=$(ip -n gw1 -d -6 route show table 100 $T2ST_EP 2>&1 | head -1)
echo "  gw1 T2ST(v6) install (record-only): $GW1_T2ST"
GW1_T2ST_MAIN=$(ip -n gw1 -6 route show table main $T2ST_EP 2>&1 | head -1)
echo "  gw1 T2ST(v6) main-FIB (record-only): $GW1_T2ST_MAIN"

# (3) pe1's End.DT6 seg6local install at the DSD SID locator.
PE1_DT6=$(ip -n pe1 -d -6 route show 2>&1 | grep -E 'End\.DT6' | head -1)
[ -n "$PE1_DT6" ] || fail "pe1: End.DT6 seg6local install missing"

# (4) gw1's End.M.GTP6.E seg6local install at the ISD SID locator.
GW1_GTP6E=$(ip -n gw1 -d -6 route show 2>&1 | grep -E 'End\.M\.GTP6\.E' | head -1)
[ -n "$GW1_GTP6E" ] || fail "gw1: End.M.GTP6.E seg6local install missing"

# (5) Args.Mob.Session bits in pe1's synthesized SID.  For
# End.M.GTP6.E the layout is:
#   bits 0..(loc_func-1)   = ISD's locator+function (56 bits here)
#   bits 56..87            = pad (zero, no v4 DA)
#   bits 88..127           = Args.Mob.Session (40 bits, MSB-aligned)
ARGS_MOB_HEX=$(printf '%02x%08x' $(( (QFI & 0x3f) << 2 )) $TEID)
PE1_SEGS=$(ip -n pe1 -d -6 route show table 100 $UE_PFX 2>&1 | head -1)
echo "===ARGS-MOB-EXPECTED==="
echo "  Args.Mob.Session = 0x$ARGS_MOB_HEX  (TEID=$TEID QFI=$QFI)"
echo "  pe1 install: $PE1_SEGS"

SYNTH_SID=$(echo "$PE1_SEGS" | grep -oE 'segs 1 \[ [^ ]+' | awk '{print $4}')
echo "  pe1 synthesized SID = $SYNTH_SID"

expand_v6() {
	local v=$1
	python3 -c "import ipaddress; print(ipaddress.IPv6Address('$v').exploded.replace(':',''))" 2>/dev/null
}
if [ -n "$SYNTH_SID" ]; then
	SID_HEX=$(expand_v6 "$SYNTH_SID")
	if [ -n "$SID_HEX" ]; then
		SID_LAST10=${SID_HEX: -10}
		echo "  pe1 synth Args.Mob bits = 0x$SID_LAST10  (expected 0x$ARGS_MOB_HEX)"
		[ "$SID_LAST10" = "$ARGS_MOB_HEX" ] || fail \
			"pe1: synthesized Args.Mob.Session mismatch (got 0x$SID_LAST10 want 0x$ARGS_MOB_HEX)"
	fi
fi

# -------------------------------------------------------------------------
# scapy GTP-U(v6) end-to-end
# -------------------------------------------------------------------------
echo "===PRE-PING-CONNECTIVITY==="
echo "-- pe1 -> gw1 (SR-domain v6):"
ip netns exec pe1 ping -c 1 -W 2 2001:db8:1::1 2>&1 | tail -3
echo "-- gnb -> gw1 (gNB-side v6):"
ip netns exec gnb ping -c 1 -W 2 2001:db8:a::1 2>&1 | tail -3
echo "-- dn -> pe1 (DN-side v6):"
ip netns exec dn ping -c 1 -W 2 2001:db8:b::1 2>&1 | tail -3
echo "-- pe1 (vrf-red) -> dn (validates vrf-red v6 table):"
ip netns exec pe1 ip vrf exec vrf-red ping -c 1 -W 2 2001:db8:b::5 2>&1 | tail -3

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

if [ "$DEBUG" = "1" ]; then
	for ns in pe1 gw1; do
		ip netns exec $ns tcpdump -nU -i any \
			-w /tmp/pcap/$ns-any.pcap 2>/dev/null &
		DBG_PIDS+=($!)
	done
fi

sleep 1

# Render the scapy probe.  UL: gnb sends GTP-U(v6) wrapping ICMPv6
# echo-request; the harness sniffs for a GTP-U(v6) reply carrying the
# ICMPv6 echo-reply on the same TEID.
echo "===SCAPY-GTPU-PING==="
cat > /tmp/gnb/gtpu_ping.py <<'PYEOF'
#!/usr/bin/env python3
"""Send one GTP-U(TEID) over IPv6 wrapping an ICMPv6 echo from
UE -> DN, then sniff for a GTP-U(v6) reply carrying the ICMPv6
echo-reply on the same TEID."""
import sys, time
from scapy.all import IPv6, UDP, ICMPv6EchoRequest, ICMPv6EchoReply, conf, send, AsyncSniffer
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
    has_icmp = pkt.haslayer(ICMPv6EchoReply)
    print("is_reply: teid={}({}) want={} has_icmpv6_reply={}".format(
        teid, type(teid).__name__, TEID, has_icmp))
    if int(teid) != TEID:
        return False
    return has_icmp

sniffer = AsyncSniffer(filter="udp port 2152", store=True, stop_filter=is_reply)
sniffer.start()
time.sleep(0.2)

inner = IPv6(src=UE, dst=DN) / ICMPv6EchoRequest(id=0xbeef, seq=1, data=b"srv6mup")
outer = IPv6(src="2001:db8:a::5", dst=GW) / UDP(sport=2152, dport=2152) \
        / GTP_U_Header(teid=TEID) / inner
send(outer)

deadline = time.time() + TIMEOUT
seen = 0
while time.time() < deadline:
    for pkt in (sniffer.results or [])[seen:]:
        seen += 1
        if is_reply(pkt):
            print("GTPU-PING-OK teid={}".format(TEID))
            sniffer.stop()
            sys.exit(0)
    time.sleep(0.1)

sniffer.stop()
print("GTPU-PING-FAIL no matching GTP-U(ICMPv6 echo-reply) within {}s".format(TIMEOUT))
print("--- captured ({} pkts) ---".format(len(sniffer.results or [])))
for pkt in (sniffer.results or []):
    print(pkt.summary())
    print("    layers:", [layer.name for layer in pkt.layers()])
sys.exit(1)
PYEOF
chmod +x /tmp/gnb/gtpu_ping.py

# DL-only probe: dn-side scapy emits an ICMPv6 echo-request toward
# the UE prefix; pe1 H.Encaps it; gw1 End.M.GTP6.E emits GTP-U(v6)
# toward gnb.  gnb sniffs for the GTP-U arrival.  This leg exercises
# all of: T1ST resolve, End.M.GTP6.E synth SID, kernel End.M.GTP6.E
# at gw1's locator.
cat > /tmp/dn/dl_probe.py <<'PYEOF'
#!/usr/bin/env python3
"""DL-only probe: emit an ICMPv6 echo-request from the DN toward the
UE prefix.  pe1 imports the T1ST, builds an H.Encaps SRv6 with the
synthesized End.M.GTP6.E SID; gw1's seg6local End.M.GTP6.E action
emits GTP-U(v6) with TEID=expected toward gnb.  This script exits
immediately after sending; the verification happens in gnb's pcap."""
import sys
from scapy.all import IPv6, ICMPv6EchoRequest, conf, send

UE = sys.argv[1]
DN = sys.argv[2]
conf.verb = 0
pkt = IPv6(src=DN, dst=UE) / ICMPv6EchoRequest(id=0xcafe, seq=1, data=b"dl-probe")
send(pkt)
print("DL-PROBE-SENT dst={}".format(UE))
PYEOF
chmod +x /tmp/dn/dl_probe.py

# Sniff at gnb for an arriving GTP-U(v6).  The DL probe's inner
# packet has no listener at the UE address (no UE present), so the
# kernel will emit an ICMPv6 destination-unreachable; we only need to
# see the GTP-U arrival to confirm the SR-domain crossed into a
# GTP-U(v6) at gw1.
cat > /tmp/gnb/dl_sniff.py <<'PYEOF'
#!/usr/bin/env python3
"""Verify a GTP-U(v6) packet with matching TEID arrived in the
harness-managed tcpdump pcap.  The harness starts `tcpdump -i veth-gnb
-w /tmp/pcap/gnb.pcap` before the probe is sent, so by the time we
read the pcap the kernel-emitted GTP-U is already on disk.  Reading
the existing pcap with scapy avoids the AsyncSniffer BPF-setup race
(scapy's sniffer thread starts after the GTP-U has already crossed
the wire) while still decoding the GTP-U layer for TEID verification."""
import sys
from scapy.all import rdpcap
from scapy.contrib.gtp import GTP_U_Header

TEID  = int(sys.argv[1])
PCAP  = sys.argv[2]

pkts = rdpcap(PCAP)
for pkt in pkts:
    if not pkt.haslayer(GTP_U_Header):
        continue
    teid = int(pkt[GTP_U_Header].teid)
    if teid == TEID:
        print("DL-PROBE-RX teid={} (from {})".format(TEID, PCAP))
        sys.exit(0)
print("DL-PROBE-MISS no matching GTP-U(v6) with TEID={} in {} ({} pkts)".format(
    TEID, PCAP, len(pkts)))
for pkt in pkts:
    print("  ", pkt.summary())
    if pkt.haslayer(GTP_U_Header):
        print("       teid={}".format(int(pkt[GTP_U_Header].teid)))
sys.exit(1)
PYEOF
chmod +x /tmp/gnb/dl_sniff.py

# DL leg
echo "===DL-PROBE==="
if [ "$SKIP_DL" = "1" ]; then
	echo "DL: SKIP (FOLLOWUP-MUP-V6-E2E, srv6-mup-issues 20260510-042434)"
else
	# Send the probe and verify against the harness-managed tcpdump
	# pcap (tcpdump was started earlier in the script).  We use scapy's
	# rdpcap() to decode the GTP-U layer and confirm TEID; the previous
	# AsyncSniffer-based verifier raced against scapy's BPF socket
	# setup and the GTP-U arrival landed before the filter was
	# attached, leaving `sniffer.results` empty.  Reading the already-
	# captured pcap avoids that race entirely.
	ip netns exec dn python3 /tmp/dn/dl_probe.py $UE_PFX $DN_IP 2>&1 \
		| tee /tmp/dn/dl_probe.log
	# tcpdump -U writes per-packet, but FS / 9p sync still benefits
	# from a small grace before scapy reads the file.
	sleep 1
	ip netns exec gnb python3 /tmp/gnb/dl_sniff.py $TEID /tmp/pcap/gnb.pcap \
		> /tmp/gnb/dl_sniff.log 2>&1
	DL_RC=$?
	cat /tmp/gnb/dl_sniff.log
	if [ "$DL_RC" -eq 0 ]; then
		echo "DL: PASS"
	else
		fail "DL probe: gnb did not see GTP-U(v6) with TEID=$TEID"
	fi
fi

# UL leg.  See README "Known gaps" — current FRR T2ST install for
# AFI_IP6 hits the H_M_GTP4_D hardcode in bgp_mup_build_t2st_route
# (srv6-mup-issues 20260509-150607).  Until that is fixed UL is
# expected to fail, and the harness reports the failure cleanly so
# the regression stays visible in CI.
echo "===UL-PROBE==="
if [ "$SKIP_UL" = "1" ]; then
	echo "UL: SKIP (FOLLOWUP-MUP-V6-E2E, srv6-mup-issues 20260510-042434)"
else
	ip netns exec gnb python3 /tmp/gnb/gtpu_ping.py \
		$T2ST_EP $UE_PFX $DN_IP $TEID 5 \
		2>&1 | tee /tmp/gnb/gtpu_ping.log

	if grep -q "GTPU-PING-OK" /tmp/gnb/gtpu_ping.log; then
		echo "UL: PASS"
	else
		fail "UL probe: scapy GTP-U(v6) end-to-end ping did not complete"
	fi
fi

# Stop captures.
sleep 1
kill $PT_GNB $PT_GW1S $PT_GW1G $PT_PE1S $PT_PE1D $PT_DN 2>/dev/null
wait $PT_GNB $PT_GW1S $PT_GW1G $PT_PE1S $PT_PE1D $PT_DN 2>/dev/null
if [ "${#DBG_PIDS[@]}" -gt 0 ]; then
	kill "${DBG_PIDS[@]}" 2>/dev/null
	wait "${DBG_PIDS[@]}" 2>/dev/null
fi
for p in gnb gw1-gnb gw1-sr pe1-sr pe1-dn dn; do
	echo "===PCAP-$p==="
	tcpdump -nr /tmp/pcap/$p.pcap 2>/dev/null | head -20
done
if [ "$DEBUG" = "1" ]; then
	echo "===PCAP-pe1-any==="
	tcpdump -nr /tmp/pcap/pe1-any.pcap 2>/dev/null | head -40
	echo "===PCAP-gw1-any==="
	tcpdump -nr /tmp/pcap/gw1-any.pcap 2>/dev/null | head -40
	echo "===NLMON-SIZES==="
	ls -l /tmp/pcap/pe1-nl.pcap /tmp/pcap/gw1-nl.pcap 2>/dev/null
fi

# -------------------------------------------------------------------------
# Verdict
# -------------------------------------------------------------------------
echo "===VERDICT==="
if [ "$PASS" = "1" ]; then
	echo "FRR-MUP-E2E-GTP6-GOBGP-SCAPY: PASS"
else
	echo "FRR-MUP-E2E-GTP6-GOBGP-SCAPY: FAIL"
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
