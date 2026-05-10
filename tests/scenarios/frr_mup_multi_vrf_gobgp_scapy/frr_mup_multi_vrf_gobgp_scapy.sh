#!/bin/bash
# Multi-VRF BGP-MUP RT-split test.
#
# Topology (3 netns in 1 VM):
#
#   +------+ veth +------+ veth +-----------------+
#   | gbgp |------| pe1  |------| pe2             |
#   |65000 | eBGP |65001 | eBGP |65002            |
#   +------+      +------+      | + vrf-red  (10) |
#  gobgpd        FRR transit    | + vrf-blue (20) |
#                               +-----------------+
#                                FRR (zebra+bgpd)
#
# pe2 carries two parallel per-vrf BGP-MUP instances:
#   vrf-red  -- table 100, RT import 10:10
#   vrf-blue -- table 200, RT import 20:20
#
# gobgpd injects four T1ST/T2ST sets with distinct UE/endpoint
# prefixes and distinct RT extcomms:
#
#   Set A -- RT 10:10            -- expect install in vrf-red ONLY
#   Set B -- RT 20:20            -- expect install in vrf-blue ONLY
#   Set C -- RT 10:10 + RT 20:20 -- expect install in BOTH VRFs
#   Set D -- RT 99:99            -- expect install in NEITHER VRF
#
# Each set comes with an ISD/DSD anchor so T1ST resolution against
# the matching segment-origin succeeds.  pe1 is a transit speaker
# only; the multi-vrf RT split is exercised on pe2.
#
# rmap import variant (issue 20260509-093034 Phase 2) is not
# implemented here -- see README.md "Follow-ups" for the plan once
# Phase 2 lands.
#
# Requires the same kernel / iproute2 / FRR / gobgp build tree as
# tests/scenarios/frr_interop_mup.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
FRR=$ROOT/frr
BIN=$HERE/../../../.bin

export PATH="$ROOT/iproute2/ip:$BIN:$PATH"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

echo "===KERNEL=== $(uname -r)"
ip -V

mount -t tmpfs tmpfs /usr/local/var/run 2>/dev/null
mkdir -p /usr/local/var/run/frr 2>/dev/null
mount -t tmpfs tmpfs /usr/local/var/lib 2>/dev/null
mkdir -p /usr/local/var/lib/frr 2>/dev/null

# --- runtime dirs ---------------------------------------------------------
for ns in gbgp pe1 pe2; do mkdir -p /tmp/$ns; done

# --- netns + veths --------------------------------------------------------
for ns in gbgp pe1 pe2; do ip netns add $ns; done
ip link add veth-gbgp netns gbgp type veth peer name veth-pe1g netns pe1
ip link add veth-pe1p netns pe1 type veth peer name veth-pe2  netns pe2
for ns in gbgp pe1 pe2; do ip -n $ns link set lo up; done
ip -n gbgp link set veth-gbgp up
ip -n pe1  link set veth-pe1g up
ip -n pe1  link set veth-pe1p up
ip -n pe2  link set veth-pe2  up

ip -n gbgp addr add 2001:db8:1::2/64 dev veth-gbgp nodad
ip -n pe1  addr add 2001:db8:1::1/64 dev veth-pe1g nodad
ip -n pe1  addr add 2001:db8:2::1/64 dev veth-pe1p nodad
ip -n pe2  addr add 2001:db8:2::2/64 dev veth-pe2  nodad

for ns in pe1 pe2; do
    ip netns exec $ns sysctl -wq net.ipv6.conf.all.forwarding=1
    ip netns exec $ns sysctl -wq net.ipv4.ip_forward=1
done

# Two VRFs on pe2 only.  The per-vrf bgp instance binds to the
# matching netdev; the table id is the VRF's own table.
ip -n pe2 link add vrf-red  type vrf table 100
ip -n pe2 link add vrf-blue type vrf table 200
ip -n pe2 link set vrf-red  up
ip -n pe2 link set vrf-blue up

# --- FRR configs ----------------------------------------------------------
for ns in pe1 pe2; do
    install -m 644 $HERE/$ns/frr.conf /tmp/$ns/frr.conf
done

start_pe() {
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

start_pe pe1
start_pe pe2

sleep 1
ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1 -f /tmp/pe1/frr.conf
ip netns exec pe2 $FRR/vtysh/vtysh --vty_socket /tmp/pe2 -f /tmp/pe2/frr.conf

# Underlay route to gobgpd's SR locator 2001:db8:e::/48.
ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1 \
    -c "configure terminal" \
    -c "ipv6 route 2001:db8:e::/48 2001:db8:1::2 veth-pe1g onlink" \
    -c "exit"
ip netns exec pe2 $FRR/vtysh/vtysh --vty_socket /tmp/pe2 \
    -c "configure terminal" \
    -c "ipv6 route 2001:db8:e::/48 2001:db8:2::1 veth-pe2 onlink" \
    -c "exit"

# --- start gobgpd in gbgp netns -------------------------------------------
install -m 644 $HERE/gbgp/gobgpd.toml /tmp/gbgp/gobgpd.toml
ip netns exec gbgp $BIN/gobgpd -t toml -f /tmp/gbgp/gobgpd.toml --api-hosts=127.0.0.1:50051 \
    > /tmp/gbgp/gobgpd.log 2>&1 &
GOBGP_PID=$!
sleep 2
if ! kill -0 $GOBGP_PID 2>/dev/null; then
    echo "===GOBGPD-CRASHED==="
    cat /tmp/gbgp/gobgpd.log
fi

# --- wait for sessions ----------------------------------------------------
GOBGP="ip netns exec gbgp $BIN/gobgp"
VTYSH_PE1="ip netns exec pe1 $FRR/vtysh/vtysh --vty_socket /tmp/pe1"
VTYSH_PE2="ip netns exec pe2 $FRR/vtysh/vtysh --vty_socket /tmp/pe2"

echo "===WAIT-SESSIONS==="
for i in $(seq 1 60); do
    s1=$($VTYSH_PE1 -c 'show bgp summary json' 2>/dev/null \
         | grep -oE '"state":"Established"' | wc -l || echo 0)
    s2=$($VTYSH_PE2 -c 'show bgp summary json' 2>/dev/null \
         | grep -oE '"state":"Established"' | wc -l || echo 0)
    sg=$($GOBGP neighbor 2>/dev/null | awk 'NR>1 && $0 ~ /Establ/' | wc -l || echo 0)
    echo "  try=$i pe1_est=$s1 pe2_est=$s2 gbgp_est=$sg"
    if [ "$s1" -ge 2 ] && [ "$s2" -ge 1 ] && [ "$sg" -ge 1 ]; then break; fi
    sleep 1
done

# --- inject MUP routes from gobgp -----------------------------------------
# Per-set address plan (kept in sync with README.md):
#
#   Set | RT          | UE prefix (T1ST)  | T2ST v4 endpt | T2ST v6 endpt
#   ----+-------------+-------------------+---------------+---------------
#    A  | 10:10       | 192.168.10.1/32   | 10.10.0.1     | 2001:db8:a::1
#    B  | 20:20       | 192.168.20.1/32   | 10.20.0.1     | 2001:db8:b::1
#    C  | 10:10,20:20 | 192.168.30.1/32   | 10.30.0.1     | 2001:db8:c::1
#    D  | 99:99       | 192.168.40.1/32   | 10.40.0.1     | 2001:db8:d::1
#
# Each set carries an ISD anchor (10.<set>.0.0/24) so T1ST resolves
# against the matching segment-origin in the importing VRF.
echo "===INJECT==="
inject() {
    echo "+ gobgp $*"
    $GOBGP "$@" 2>&1 || echo "  -> FAIL"
}

inject_set() {
    local label=$1
    local rd=$2
    local rts=$3              # space-separated, e.g. "10:10" or "10:10 20:20"
    local isd_pfx=$4          # e.g. 10.10.0.0/24
    local ue_pfx=$5           # e.g. 192.168.10.1/32
    local t1_endpt=$6         # e.g. 10.10.0.1   (must fall inside isd_pfx)
    local t1_psid=$7          # T1ST prefix-sid SID
    local t2v4_endpt=$8       # e.g. 10.10.0.1
    local t2v4_psid=$9
    local t2v6_endpt=${10}    # e.g. 2001:db8:a::1
    local t2v6_psid=${11}

    local rt_args=""
    for r in $rts; do rt_args="$rt_args rt $r"; done

    echo "--- Set $label rd=$rd rts='$rts' ---"

    # ISD anchor — End.M.GTP4.E behavior, locator from the gobgpd
    # injector locator block (2001:db8:e::/48).
    inject global rib add -a ipv4-mup isd $isd_pfx \
        rd $rd prefix 2001:db8:e::/24 locator-node-length 24 \
        function-length 8 behavior ENDM_GTP4E $rt_args \
        nexthop 2001:db8:1::2

    # T1ST -- UE prefix in the per-vrf table (kernel: -4 route show)
    inject global rib add -a ipv4-mup t1st $ue_pfx \
        rd $rd $rt_args teid 12345 qfi 9 endpoint $t1_endpt \
        prefix-sid $t1_psid

    # T2ST IPv4 endpoint -> End.M.GTP4.E (kernel seg6local on the SID)
    inject global rib add -a ipv4-mup t2st $t2v4_endpt \
        rd $rd endpoint-address-length 64 teid 67890 \
        $rt_args \
        prefix-sid $t2v4_psid

    # T2ST IPv6 endpoint -> End.M.GTP6.E
    inject global rib add -a ipv6-mup t2st $t2v6_endpt \
        rd $rd endpoint-address-length 160 teid 67890 \
        $rt_args \
        prefix-sid $t2v6_psid
}

# Set A — RT 10:10 only
inject_set A 100:10 "10:10" \
    10.10.0.0/24 192.168.10.1/32 10.10.0.1 2001:db8:e::a01 \
    10.10.0.1 2001:db8:e::a10 \
    2001:db8:a::1 2001:db8:e::a11

# Set B — RT 20:20 only
inject_set B 100:20 "20:20" \
    10.20.0.0/24 192.168.20.1/32 10.20.0.1 2001:db8:e::b01 \
    10.20.0.1 2001:db8:e::b10 \
    2001:db8:b::1 2001:db8:e::b11

# Set C — RT 10:10 AND RT 20:20.  Skipped: gobgp 3.10's MUP CLI tags
# `rt` as paramSingle for ipv4-mup t1st/t2st (cmd/gobgp/global.go),
# so multi-RT injection is silently truncated to the last `rt` value.
# The bgpd per-matching-VRF iteration code (bgp_mup_st_announce loop
# over `bm->bgp` with bgp_mup_route_rt_in_import) is in place; what's
# missing is a CLI path to inject a multi-RT MUP NLRI.  Tracked in
# srv6-mup-issues followup `bug-gobgp-mup-cli-rt-paramsingle`.
if false; then
inject_set C 100:30 "10:10 20:20" \
    10.30.0.0/24 192.168.30.1/32 10.30.0.1 2001:db8:e::c01 \
    10.30.0.1 2001:db8:e::c10 \
    2001:db8:c::1 2001:db8:e::c11
fi

# Set D — RT 99:99 (negative case)
inject_set D 100:40 "99:99" \
    10.40.0.0/24 192.168.40.1/32 10.40.0.1 2001:db8:e::d01 \
    10.40.0.1 2001:db8:e::d10 \
    2001:db8:d::1 2001:db8:e::d11

sleep 4

# --- inspect ---------------------------------------------------------------
echo "===GOBGP-LOCAL-RIB-V4==="
$GOBGP global rib -a ipv4-mup 2>&1 || true
echo "===GOBGP-LOCAL-RIB-V6==="
$GOBGP global rib -a ipv6-mup 2>&1 || true

echo "===PE1-BGP-IPV4-MUP==="
$VTYSH_PE1 -c 'show bgp ipv4 mup all'
echo "===PE2-BGP-IPV4-MUP==="
$VTYSH_PE2 -c 'show bgp ipv4 mup all'
echo "===PE2-BGP-IPV4-MUP-DETAIL==="
$VTYSH_PE2 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | head -200 || true

echo "===PE2-VRF-RED-IPV4-RIB==="
$VTYSH_PE2 -c 'show ip route vrf vrf-red' 2>&1 | head -60 || true
echo "===PE2-VRF-BLUE-IPV4-RIB==="
$VTYSH_PE2 -c 'show ip route vrf vrf-blue' 2>&1 | head -60 || true
echo "===PE2-VRF-RED-IPV6-RIB==="
$VTYSH_PE2 -c 'show ipv6 route vrf vrf-red' 2>&1 | head -60 || true
echo "===PE2-VRF-BLUE-IPV6-RIB==="
$VTYSH_PE2 -c 'show ipv6 route vrf vrf-blue' 2>&1 | head -60 || true

echo "===PE2-KERNEL-VRF-RED-V4==="
ip -n pe2 -4 route show vrf vrf-red
echo "===PE2-KERNEL-VRF-RED-V6==="
ip -n pe2 -6 route show vrf vrf-red
echo "===PE2-KERNEL-VRF-BLUE-V4==="
ip -n pe2 -4 route show vrf vrf-blue
echo "===PE2-KERNEL-VRF-BLUE-V6==="
ip -n pe2 -6 route show vrf vrf-blue

# --- verify ----------------------------------------------------------------
# Expected install matrix (T1ST UE prefix per set):
#
#   Set | vrf-red | vrf-blue
#   ----+---------+---------
#    A  | install | (none)
#    B  | (none)  | install
#    C  | install | install
#    D  | (none)  | (none)
#
# We assert presence/absence of each set's UE /32 in the matching
# kernel VRF table; H.Encaps presence (encap seg6 mode encap) is the
# hallmark of a successful install.
echo "===VERIFY==="
PASS=1

# expect_install <vrf> <ue_v4> <should_install:0|1> <label>
expect_install() {
    local vrf=$1
    local pfx=$2
    local want=$3
    local label=$4
    local got
    got=$(ip -n pe2 -4 route show "$pfx" vrf "$vrf" 2>/dev/null \
          | grep -oE 'encap seg6 mode encap' | head -1)
    if [ "$want" = "1" ]; then
        if [ -n "$got" ]; then
            echo "OK   ($label) installed in $vrf: $pfx"
        else
            echo "FAIL ($label) expected install of $pfx in $vrf, got none"
            PASS=0
        fi
    else
        if [ -z "$got" ]; then
            echo "OK   ($label) absent from $vrf: $pfx"
        else
            echo "FAIL ($label) unexpected install of $pfx in $vrf"
            PASS=0
        fi
    fi
}

# Set A -- RT 10:10 -- vrf-red only
expect_install vrf-red  192.168.10.1/32 1 "Set A T1ST"
expect_install vrf-blue 192.168.10.1/32 0 "Set A T1ST"

# Set B -- RT 20:20 -- vrf-blue only
expect_install vrf-red  192.168.20.1/32 0 "Set B T1ST"
expect_install vrf-blue 192.168.20.1/32 1 "Set B T1ST"

# Set C -- RT 10:10 + 20:20 -- both VRFs (skipped, see inject_set C
# fence above; re-enable when gobgp CLI gains multi-RT MUP support).
if false; then
expect_install vrf-red  192.168.30.1/32 1 "Set C T1ST"
expect_install vrf-blue 192.168.30.1/32 1 "Set C T1ST"
fi

# Set D -- RT 99:99 -- neither
expect_install vrf-red  192.168.40.1/32 0 "Set D T1ST"
expect_install vrf-blue 192.168.40.1/32 0 "Set D T1ST"

if [ "$PASS" -eq 1 ]; then
    echo "===FRR-MUP-MULTI-VRF=== PASS"
else
    echo "===FRR-MUP-MULTI-VRF=== FAIL"
fi

# --- diagnostics on failure -----------------------------------------------
if [ "${PASS:-0}" != "1" ]; then
    echo "===GOBGPD-LOG==="
    tail -40 /tmp/gbgp/gobgpd.log 2>/dev/null || true
    echo "===PE1-BGPD-LOG-TAIL==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/bgpd.log 2>/dev/null | tail -80 || true
    echo "===PE2-BGPD-LOG-TAIL==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe2/bgpd.log 2>/dev/null | tail -120 || true
    echo "===PE2-ZEBRA-LOG-TAIL==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe2/zebra.log 2>/dev/null | tail -120 || true
fi

# --- teardown -------------------------------------------------------------
kill $GOBGP_PID 2>/dev/null || true
for ns in pe1 pe2; do
    [ -f /tmp/$ns/bgpd.pid  ] && kill "$(cat /tmp/$ns/bgpd.pid)"  2>/dev/null || true
    [ -f /tmp/$ns/zebra.pid ] && kill "$(cat /tmp/$ns/zebra.pid)" 2>/dev/null || true
    [ -f /tmp/$ns/staticd.pid ] && kill "$(cat /tmp/$ns/staticd.pid)" 2>/dev/null || true
    [ -f /tmp/$ns/mgmtd.pid ] && kill "$(cat /tmp/$ns/mgmtd.pid)" 2>/dev/null || true
done
echo "===DONE==="
