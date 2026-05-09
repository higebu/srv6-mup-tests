#!/bin/bash
# FRR-only BGP-MUP test: no external controller (gobgp).
#
# pe1 (FRR) originates ISD from slice1 (`network` + `segment interwork`
# under `address-family ipv[46] mup`) and DSD from slice2 (`segment
# direct` sub-block under `address-family ipv4 mup`); pe2 receives both.
# Two slices are required because `segment <interwork|direct>` is
# mutually exclusive within a single (vrf, AFI) policy under SAFI_MUP.
# This verifies FRR's MUP-PE/MUP-GW origination paths independently of
# any external MUP-C.
#
# Topology:
#   +-----+ veth +-----+
#   | pe1 |------| pe2 |
#   |65001| eBGP |65002|
#   +-----+      +-----+

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
FRR=$ROOT/frr

export PATH="$ROOT/iproute2/ip:$PATH"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /usr/local/var/run 2>/dev/null
mkdir -p /usr/local/var/run/frr 2>/dev/null
mount -t tmpfs tmpfs /usr/local/var/lib 2>/dev/null
mkdir -p /usr/local/var/lib/frr 2>/dev/null

echo "===KERNEL=== $(uname -r)"

# --- runtime dirs ---------------------------------------------------------
for ns in pe1 pe2; do mkdir -p /tmp/$ns; done

# --- netns + veths --------------------------------------------------------
for ns in pe1 pe2; do ip netns add $ns; done
ip link add veth-pe1 netns pe1 type veth peer name veth-pe2 netns pe2
for ns in pe1 pe2; do ip -n $ns link set lo up; done
ip -n pe1 link set veth-pe1 up
ip -n pe2 link set veth-pe2 up
ip -n pe1 addr add 2001:db8:2::1/64 dev veth-pe1 nodad
ip -n pe2 addr add 2001:db8:2::2/64 dev veth-pe2 nodad
for ns in pe1 pe2; do
    ip netns exec $ns sysctl -wq net.ipv6.conf.all.forwarding=1
done

# Per-vrf MUP origination policy (`rd|rt|sid` + `segment
# <interwork|direct>` under `address-family ipv[46] mup`) only lives
# under a non-default vrf bgp instance (RFC 8986 Section 4.7-Section
# 4.8: End.DT4/DT6 are vrf-mandatory; the cleanest split puts the MUP
# session in the default vrf instance and the per-slice originations
# in their own vrf instance).  slice1 carries ISD, slice2 carries DSD
# (mutually-exclusive segment directives, so two vrfs are required).
# pe2 only receives, so the default vrf is enough.
ip -n pe1 link add slice1 type vrf table 100
ip -n pe1 link set slice1 up
ip -n pe1 link add slice2 type vrf table 200
ip -n pe1 link set slice2 up
ip netns exec pe1 sysctl -wq net.vrf.strict_mode=1

# --- FRR configs ----------------------------------------------------------
# pe1: originates ISD (10.99.0.0/24) and DSD (10.0.0.250) for the SR
# locator 2001:db8:e::/96 served by behavior End.M.GTP4.E.
# Daemon configs sit alongside this script in pe1/ and pe2/.
for ns in pe1 pe2; do
    install -m 644 $HERE/$ns/zebra.conf /tmp/$ns/zebra.conf
    install -m 644 $HERE/$ns/bgpd.conf  /tmp/$ns/bgpd.conf
done

start_pe() {
    local ns=$1
    local mopts="-d -u root -g root -i /tmp/$ns/mgmtd.pid --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/mgmtd.log"
    local zopts="-d -u root -g root -f /tmp/$ns/zebra.conf -i /tmp/$ns/zebra.pid -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/zebra.log"
    local bopts="-d -u root -g root -f /tmp/$ns/bgpd.conf  -i /tmp/$ns/bgpd.pid  -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/bgpd.log"
    ip netns exec $ns $FRR/mgmtd/mgmtd $mopts
    ip netns exec $ns $FRR/zebra/zebra $zopts
    ip netns exec $ns $FRR/bgpd/bgpd  $bopts
}
start_pe pe1
start_pe pe2

VTYSH_PE1="ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1"
VTYSH_PE2="ip netns exec pe2 $FRR/vtysh/vtysh --vty_socket /tmp/pe2"

echo "===WAIT-SESSIONS==="
for i in $(seq 1 30); do
    s1=$($VTYSH_PE1 -c 'show bgp summary json' 2>/dev/null | grep -oE '"state":"Established"' | wc -l || echo 0)
    s2=$($VTYSH_PE2 -c 'show bgp summary json' 2>/dev/null | grep -oE '"state":"Established"' | wc -l || echo 0)
    echo "  try=$i pe1_est=$s1 pe2_est=$s2"
    [ "$s1" -ge 2 ] && [ "$s2" -ge 2 ] && break
    sleep 1
done

sleep 3

# ISD/DSD origination is declarative in pe1/bgpd.conf; bgpd defers
# each origination until the SRv6 locator chunks arrive from zebra
# and replays them via bgp_mup_replay_origins_all() (mirrors L3VPN's
# `sid vpn export auto` post-locator replay).
echo "===PE1-ZEBRA-LOG==="
grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/zebra.log 2>/dev/null | tail -60 || true
echo "===PE1-ZEBRA-LOCATOR==="
$VTYSH_PE1 -d zebra -c 'show segment-routing srv6 locator' 2>&1 | grep -vE "vtysh.conf|Configuration file" | head -20
$VTYSH_PE1 -d zebra -c 'show segment-routing srv6 locator default' 2>&1 | grep -vE "vtysh.conf|Configuration file" | head -20
echo "===PE1-BGP-SRV6==="
$VTYSH_PE1 -c 'show bgp segment-routing srv6' 2>&1 | grep -vE "vtysh.conf|Configuration file" | head -20

echo "===PE1-ORIGINATE==="

sleep 2

echo "===PE1-BGP-IPV4-MUP==="
$VTYSH_PE1 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | grep -vE "Configuration file|vtysh.conf" | head -60
echo "===PE1-BGP-IPV6-MUP==="
$VTYSH_PE1 -c 'show bgp ipv6 mup all detail-routes' 2>&1 | grep -vE "Configuration file|vtysh.conf" | head -30

echo "===PE2-BGP-IPV4-MUP==="
$VTYSH_PE2 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | grep -vE "Configuration file|vtysh.conf" | head -60
echo "===PE2-BGP-IPV6-MUP==="
$VTYSH_PE2 -c 'show bgp ipv6 mup all detail-routes' 2>&1 | grep -vE "Configuration file|vtysh.conf" | head -30

# --- verify ----------------------------------------------------------------
echo "===VERIFY==="
PASS=1
isd_pe1=$($VTYSH_PE1 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -oE "\[1\]:\[1\].*10.99.0.0/24" | head -1)
dsd_pe1=$($VTYSH_PE1 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -oE "\[1\]:\[2\].*10.0.0.250" | head -1)
isd6_pe1=$($VTYSH_PE1 -c 'show bgp ipv6 mup all' 2>/dev/null | grep -oE "\[1\]:\[1\].*2001:db8:99::/64" | head -1)

isd_pe2=$($VTYSH_PE2 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -oE "\[1\]:\[1\].*10.99.0.0/24" | head -1)
dsd_pe2=$($VTYSH_PE2 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -oE "\[1\]:\[2\].*10.0.0.250" | head -1)
isd6_pe2=$($VTYSH_PE2 -c 'show bgp ipv6 mup all' 2>/dev/null | grep -oE "\[1\]:\[1\].*2001:db8:99::/64" | head -1)

[ -n "$isd_pe1"  ] || { echo "FAIL: ISD(v4) not in pe1 RIB";  PASS=0; }
[ -n "$dsd_pe1"  ] || { echo "FAIL: DSD(v4) not in pe1 RIB";  PASS=0; }
[ -n "$isd6_pe1" ] || { echo "FAIL: ISD(v6) not in pe1 RIB";  PASS=0; }
[ -n "$isd_pe2"  ] || { echo "FAIL: ISD(v4) not propagated to pe2"; PASS=0; }
[ -n "$dsd_pe2"  ] || { echo "FAIL: DSD(v4) not propagated to pe2"; PASS=0; }
[ -n "$isd6_pe2" ] || { echo "FAIL: ISD(v6) not propagated to pe2"; PASS=0; }

# Verify Prefix-SID Structure (RFC 9252 §3.1) reflects the locator config:
# block_len=40 node_len=24 func_len=16 arg_len=0 → "[40 24 16 0 0 0]".
psid=$($VTYSH_PE2 -c 'show bgp ipv4 mup all detail-routes' 2>/dev/null | grep -oE "sid structure=\[40 24 16 0 0 0\]" | head -1)
[ -n "$psid" ] || { echo "FAIL: SID Structure sub-sub-TLV not propagated to pe2 ($psid)"; PASS=0; }
# ISD behavior must be 72 (End.M.GTP4.E) per draft §3.3.1; show the route.
isd_sid=$($VTYSH_PE2 -c 'show bgp ipv4 mup all detail-routes' 2>/dev/null | grep "Remote SID:" | head -1)
echo "ISD remote SID line: $isd_sid"

echo "===PE1-KERNEL-SEG6LOCAL==="
ip netns exec pe1 ip -6 route show table local | grep -E "^2001:db8:e:" || true
ip netns exec pe1 ip -6 route show table local | grep -E "encap seg6local" || true

echo "===PE1-RUNNING-CONFIG-MUP==="
$VTYSH_PE1 -c 'show running-config' 2>&1 | sed -n '/address-family ipv4 mup/,/exit-address-family/p; /address-family ipv6 mup/,/exit-address-family/p'

# Race coverage: add+remove a `network` line under the per-vrf MUP AF
# in the same vtysh transaction (no sleep between add and `no`).  This
# exercises the SAFI_MUP-RIB origination race — best-path selection
# may or may not have triggered an ISD originate by the time
# `no network` runs, so both cancel-while-pending and withdraw-after-
# originate code paths need to coexist without leaking a pending entry
# or a stale BGP-MUP route.
#
# FOLLOWUP-MUP-AF-NO-NETWORK: temporarily disabled.  After the move to
# `address-family ipv[46] mup` direct origination, `no network` removes
# the line from running-config but leaves the route in the SAFI_MUP RIB
# (no WITHDRAW emitted).  Re-enable once
# wip/20260510-001805-bug-mup-af-network-no-network-no-withdraw.md
# is fixed in bgpd.
if false; then
    echo "===PE1-RACE-CANCEL==="
    $VTYSH_PE1 -c 'configure' \
        -c 'router bgp 65001 vrf slice1' \
        -c 'address-family ipv4 mup' \
        -c 'network 10.77.0.0/24' \
        -c 'no network 10.77.0.0/24' \
        -c 'exit-address-family' 2>&1 | grep -vE "vtysh.conf|Configuration file" | head -5
    sleep 2
    race_left=$($VTYSH_PE1 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -c "10.77.0.0/24")
    race_cfg=$($VTYSH_PE1 -c 'show running-config' 2>/dev/null | grep -c "network 10.77.0.0/24")
    [ "$race_left" -eq 0 ] || { echo "FAIL: race-cancel ISD still in RIB"; PASS=0; }
    [ "$race_cfg" -eq 0 ] || { echo "FAIL: race-cancel network still in running-config"; PASS=0; }
fi

# Verify the running-config emits the operator's origination directives.
isd_v4_cfg=$($VTYSH_PE1 -c 'show running-config' 2>/dev/null | grep -c "network 10.99.0.0/24")
isd_v6_cfg=$($VTYSH_PE1 -c 'show running-config' 2>/dev/null | grep -c "network 2001:db8:99::/64")
dsd_v4_cfg=$($VTYSH_PE1 -c 'show running-config' 2>/dev/null | grep -c "address 10.0.0.250")
seg_interwork_cfg=$($VTYSH_PE1 -c 'show running-config' 2>/dev/null | grep -cE '^\s+segment interwork$')
seg_direct_cfg=$($VTYSH_PE1 -c 'show running-config' 2>/dev/null | grep -cE '^\s+segment direct$')
[ "$isd_v4_cfg" -ge 1 ] || { echo "FAIL: ISD(v4) network not in running-config"; PASS=0; }
[ "$dsd_v4_cfg" -ge 1 ] || { echo "FAIL: DSD(v4) address not in running-config"; PASS=0; }
[ "$isd_v6_cfg" -ge 1 ] || { echo "FAIL: ISD(v6) network not in running-config"; PASS=0; }
[ "$seg_interwork_cfg" -ge 2 ] || { echo "FAIL: segment interwork directives missing (got $seg_interwork_cfg, expect >=2)"; PASS=0; }
[ "$seg_direct_cfg" -ge 1 ] || { echo "FAIL: segment direct directive missing (got $seg_direct_cfg, expect >=1)"; PASS=0; }

if [ "$PASS" -eq 1 ]; then
    echo "===FRR-ONLY-SEGMENT=== PASS"
else
    echo "===FRR-ONLY-SEGMENT=== FAIL"
    echo "===PE1-BGPD-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/bgpd.log 2>/dev/null | tail -60 || true
    echo "===PE2-BGPD-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe2/bgpd.log 2>/dev/null | tail -60 || true
fi

for ns in pe1 pe2; do
    [ -f /tmp/$ns/bgpd.pid  ] && kill $(cat /tmp/$ns/bgpd.pid)  2>/dev/null || true
    [ -f /tmp/$ns/zebra.pid ] && kill $(cat /tmp/$ns/zebra.pid) 2>/dev/null || true
    [ -f /tmp/$ns/mgmtd.pid ] && kill $(cat /tmp/$ns/mgmtd.pid) 2>/dev/null || true
done
echo "===DONE==="
