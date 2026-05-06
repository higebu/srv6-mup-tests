#!/bin/bash
# FRR <-> FRR BGP-MUP interop, end-to-end inside a single vng VM.
#
# Topology (3 netns in 1 VM):
#
#   +------+ veth +------+ veth +------+
#   | gbgp |------| pe1  |------| pe2  |
#   |65000 | eBGP |65001 | eBGP |65002 |
#   +------+      +------+      +------+
#  gobgpd        FRR(zebra+bgpd) FRR(zebra+bgpd)
#
# gbgp injects ISD/DSD/T1ST/T2ST into pe1 over BGP-MUP.  pe1
# re-advertises to pe2.  pe2's kernel must end up with seg6local
# routes for T2ST endpoint SIDs (action End.M.GTP4.E / End.M.GTP6.E).
#
# Requires:
#   - kernel from ../linux  (b4/seg6-mobile)
#   - iproute2 from ../iproute2 (b4/seg6-mobile)
#   - FRR built in ../frr (master + seg6-mobile commits)
#   - gobgp/gobgpd built into srv6-mup-tests/.bin/ (patched to attach
#     a Prefix-SID for T1ST/T2ST when prefix-sid is given)

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
FRR=$ROOT/frr
BIN=$HERE/../../.bin

export PATH="$ROOT/iproute2/ip:$BIN:$PATH"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

echo "===KERNEL=== $(uname -r)"
ip -V

# FRR's mgmtd hardcodes its socket path under /usr/local/var/run/frr
# (FRR_RUNSTATE_PATH from autoconf).  vng's 9p root is read-only so we
# tmpfs-overmount that directory; otherwise mgmtd can't bind, zebra's
# Backend client can't connect, and zebra floods the log with
# "NB_OP_CHANGE: oper_walk_done: ERROR" for every interface event.
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

# --- FRR configs ----------------------------------------------------------
# Daemon configs sit alongside this script in pe1/, pe2/, gbgp/.
install -m 644 $HERE/pe1/zebra.conf /tmp/pe1/zebra.conf
install -m 644 $HERE/pe1/bgpd.conf  /tmp/pe1/bgpd.conf
install -m 644 $HERE/pe2/zebra.conf /tmp/pe2/zebra.conf
# Sanity: can the kernel itself accept the seg6local route we want zebra
# to install?  If this fails, zebra has no chance.  Mirror zebra's exact
# proto/metric/type so any divergence becomes visible here.
echo "===KERNEL-DIRECT-INSTALL-TRY==="
ip -n pe1 -6 route add 2001:db8:e::/56 encap seg6local action End.M.GTP4.E \
    src 2001:db8:e::100 v4_mask_len 32 dev lo proto bgp metric 20 2>&1 || true
ip -n pe1 -d -6 route show 2001:db8:e::/56 2>&1 || true
ip -n pe1 -6 route del  2001:db8:e::/56 2>/dev/null || true
echo "===NLMON-IPROUTE2-CAPTURE==="
ip -n pe1 link add nlmon0 type nlmon 2>&1
ip -n pe1 link set nlmon0 up 2>&1
ip netns exec pe1 tcpdump -nXX -i nlmon0 -w /tmp/pe1/iproute2.nlmon 2>/dev/null &
T_IP=$!
sleep 0.5
ip -n pe1 -6 route add 2001:db8:e::/56 encap seg6local action End.M.GTP4.E \
    src 2001:db8:e::100 v4_mask_len 32 dev lo proto bgp metric 20 2>&1
sleep 0.5
ip -n pe1 -6 route del  2001:db8:e::/56 2>/dev/null
kill $T_IP 2>/dev/null; wait $T_IP 2>/dev/null
# Leave nlmon0 up; we'll re-arm capture for the zebra path further down.
echo "===NLMON-IPROUTE2-DUMP==="
ip netns exec pe1 tcpdump -nXr /tmp/pe1/iproute2.nlmon 2>&1 | head -60 || true
install -m 644 $HERE/pe2/bgpd.conf /tmp/pe2/bgpd.conf

# --- start zebra + bgpd in each PE namespace ------------------------------
start_pe() {
    local ns=$1
    local mopts="-d -u root -g root -i /tmp/$ns/mgmtd.pid --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/mgmtd.log"
    local zopts="-d -u root -g root -f /tmp/$ns/zebra.conf -i /tmp/$ns/zebra.pid -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/zebra.log"
    local bopts="-d -u root -g root -f /tmp/$ns/bgpd.conf  -i /tmp/$ns/bgpd.pid  -z /tmp/$ns/zserv.api --vty_socket /tmp/$ns -P 0 --log file:/tmp/$ns/bgpd.log"
    ip netns exec $ns $FRR/mgmtd/mgmtd $mopts
    ip netns exec $ns $FRR/zebra/zebra $zopts
    ip netns exec $ns $FRR/bgpd/bgpd  $bopts
}
# Re-arm nlmon capture to record zebra's RTM_NEWROUTE attempts.
ip netns exec pe1 tcpdump -nXX -i nlmon0 -w /tmp/pe1/zebra.nlmon 2>/dev/null &
T_ZB=$!

start_pe pe1
start_pe pe2

# Resolve BGP-MUP nexthop (the SR locator 2001:db8:e::/96).  Use a
# dummy interface rather than lo: putting the locator on lo makes the
# kernel reject zebra's seg6local install ("Egress device can not be
# loopback device" / EINVAL on RTM_NEWROUTE) because the route prefix
# overlaps an existing local route on the loopback.  A dummy device
# sidesteps that check while still resolving the BGP /128 SID nexthop.
for ns in pe1 pe2; do
    ip -n $ns link add srv6loc type dummy
    ip -n $ns link set srv6loc up
    ip -n $ns addr add 2001:db8:e::/96 dev srv6loc nodad
done

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
    if [ "$s1" -ge 4 ] && [ "$s2" -ge 2 ] && [ "$sg" -ge 1 ]; then break; fi
    sleep 1
done

echo "===GOBGP-NEIGHBOR==="
$GOBGP neighbor 2>&1 | head -20 || true
echo "===GOBGP-NEIGHBOR-DETAIL==="
$GOBGP neighbor 2001:db8:1::1 2>&1 | head -40 || true

# --- inject MUP routes from gobgp -----------------------------------------
echo "===INJECT==="
inject() {
    echo "+ gobgp $*"
    $GOBGP "$@" 2>&1 || echo "  -> FAIL"
}
# IPv4-MUP nexthop must be IPv6 (BGP-MUP carries v4 NLRI with v6 NH)
inject global rib add -a ipv4-mup isd 10.99.0.0/24 \
    rd 100:100 prefix 2001:db8:e::/96 locator-node-length 24 \
    function-length 16 behavior ENDM_GTP4E rt 10:10 \
    nexthop 2001:db8:1::2

inject global rib add -a ipv4-mup dsd 10.0.0.250 \
    rd 100:100 prefix 2001:db8:e::abcd/128 locator-node-length 24 \
    function-length 16 behavior ENDM_GTP4E rt 10:10 mup 10:10 \
    nexthop 2001:db8:1::2

# T1ST: UE prefix 192.168.1.1/32, prefix-SID 2001:db8:e::1
inject global rib add -a ipv4-mup t1st 192.168.1.1/32 \
    rd 100:100 rt 10:10 teid 12345 qfi 9 endpoint 10.0.0.1 \
    prefix-sid 2001:db8:e::1

# T2ST IPv4 endpoint with prefix-SID 2001:db8:e::100 -> End.M.GTP4.E
inject global rib add -a ipv4-mup t2st 10.0.0.1 \
    rd 100:100 endpoint-address-length 64 teid 67890 \
    rt 10:10 mup 10:10 \
    prefix-sid 2001:db8:e::100

# T2ST IPv6 endpoint with prefix-SID 2001:db8:e::200 -> End.M.GTP6.E
inject global rib add -a ipv6-mup t2st 2001:db8:99::1 \
    rd 200:200 endpoint-address-length 160 teid 67890 \
    rt 20:20 mup 20:20 \
    prefix-sid 2001:db8:e::200

sleep 3
echo "===GOBGP-LOCAL-RIB-V4==="
$GOBGP global rib -a ipv4-mup 2>&1 || true
echo "===GOBGP-LOCAL-RIB-V6==="
$GOBGP global rib -a ipv6-mup 2>&1 || true
echo "===GOBGP-NEIGHBOR-AFTER-INJECT==="
$GOBGP neighbor 2>&1 || true

# --- inspect ---------------------------------------------------------------
echo "===PE1-BGP-IPV4-MUP==="
$VTYSH_PE1 -c 'show bgp ipv4 mup all'
echo "===PE1-BGP-IPV6-MUP==="
$VTYSH_PE1 -c 'show bgp ipv6 mup all'

echo "===PE2-BGP-IPV4-MUP==="
$VTYSH_PE2 -c 'show bgp ipv4 mup all'
echo "===PE2-BGP-IPV6-MUP==="
$VTYSH_PE2 -c 'show bgp ipv6 mup all'

echo "===PE1-DIRECT-ROUTE-ADD-AFTER-ZEBRA==="
# zebra failed to install — try the same install ourselves with the EXACT
# attributes zebra sent (dev srv6loc proto bgp metric 20).  If the kernel
# still rejects, the bug is in the netlink message; if it accepts, zebra
# is doing something extra (different socket, NLM_F flags, etc).
ip -n pe1 -6 route add 2001:db8:e::/56 encap seg6local action End.M.GTP4.E \
    src 2001:db8:e::100 v4_mask_len 32 dev srv6loc proto bgp metric 20 2>&1 || true
ip -n pe1 -d -6 route show 2001:db8:e::/56 2>&1 | head -5 || true
ip -n pe1 -6 route del 2001:db8:e::/56 2>/dev/null || true
echo "===PE1-DIRECT-ROUTE-ADD-AFTER-ZEBRA-LO==="
# Same install but on dev lo — sanity check.
ip -n pe1 -6 route add 2001:db8:e::/56 encap seg6local action End.M.GTP4.E \
    src 2001:db8:e::100 v4_mask_len 32 dev lo proto bgp metric 20 2>&1 || true
ip -n pe1 -d -6 route show 2001:db8:e::/56 2>&1 | head -5 || true
ip -n pe1 -6 route del 2001:db8:e::/56 2>/dev/null || true

echo "===PE1-DIRECT-T1ST-MIRROR-ZEBRA==="
# Mirror exactly what zebra sends for T1ST: v4 dst, IPv6 nexthop (RTA_VIA),
# seg6 encap, OIF=srv6loc dummy, ONLINK.  This is what zebra's RTM_NEWROUTE
# for 192.168.1.1/32 contains.
ip -n pe1 -4 route add 192.168.1.1/32 \
    encap seg6 mode encap segs 2001:db8:e::1 \
    via inet6 2001:db8:e::1 dev srv6loc onlink proto bgp metric 20 2>&1
ip -n pe1 -d -4 route show 192.168.1.1/32 2>&1 | head -5
ip -n pe1 -4 route del 192.168.1.1/32 2>/dev/null

echo "===PE1-DIRECT-T1ST-INLINE==="
# Try seg6 mode inline (H.Insert) instead of encap.  zebra's encoder
# defaults to ZEBRA_SRV6_HEADEND_BEHAVIOR_H_INSERT, which corresponds to
# 'mode inline' in iproute2 — but inline only works on IPv6 destinations
# in the kernel.  For a v4 dst this should fail too, mirroring zebra.
ip -n pe1 -4 route add 192.168.1.1/32 \
    encap seg6 mode inline segs 2001:db8:e::1 \
    via inet6 2001:db8:e::1 dev srv6loc onlink proto bgp metric 20 2>&1
ip -n pe1 -d -4 route show 192.168.1.1/32 2>&1 | head -5
ip -n pe1 -4 route del 192.168.1.1/32 2>/dev/null

echo "===PE1-DIRECT-T1ST-ENCAP-LO==="
ip -n pe1 -4 route add 192.168.1.1/32 \
    encap seg6 mode encap segs 2001:db8:e::1 \
    via inet6 2001:db8:e::1 dev lo onlink proto bgp metric 20 2>&1
ip -n pe1 -d -4 route show 192.168.1.1/32 2>&1 | head -5
ip -n pe1 -4 route del 192.168.1.1/32 2>/dev/null

echo "===PE1-ZEBRA-IPV6-NHT==="
$VTYSH_PE1 -c 'show ipv6 nht' 2>&1 | head -30 || true
echo "===PE1-BGP-IPV6-NHT==="
$VTYSH_PE1 -c 'show bgp ipv6 nexthop' 2>&1 | head -30 || true
echo "===PE1-ZEBRA-IPV6-RIB==="
$VTYSH_PE1 -d zebra -c 'show ipv6 route' 2>&1 | head -40 || true
echo "===PE1-ZEBRA-IPV4-RIB==="
$VTYSH_PE1 -d zebra -c 'show ip route' 2>&1 | head -40 || true
echo "===PE2-ZEBRA-IPV6-RIB==="
$VTYSH_PE2 -d zebra -c 'show ipv6 route' 2>&1 | head -40 || true
echo "===PE2-ZEBRA-IPV4-RIB==="
$VTYSH_PE2 -d zebra -c 'show ip route' 2>&1 | head -40 || true

echo "===PE1-KERNEL-V6-ROUTES==="
ip -n pe1 -6 route show
echo "===PE1-KERNEL-V6-ROUTES-DETAIL==="
ip -n pe1 -d -6 route show 2001:db8:e::100/128 || true
ip -n pe1 -d -6 route show 2001:db8:e::200/128 || true
echo "===PE1-KERNEL-V4-ROUTES==="
ip -n pe1 -4 route show
echo "===PE1-KERNEL-V4-ROUTES-DETAIL==="
ip -n pe1 -d -4 route show 192.168.1.1 || true

echo "===PE1-BGP-IPV4-MUP-DETAIL==="
$VTYSH_PE1 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | head -80 || true
echo "===PE2-BGP-IPV4-MUP-DETAIL==="
$VTYSH_PE2 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | head -80 || true

echo "===PE2-KERNEL-V6-ROUTES==="
ip -n pe2 -6 route show
echo "===PE2-KERNEL-V6-ROUTES-DETAIL==="
ip -n pe2 -d -6 route show 2001:db8:e::100/128 || true
ip -n pe2 -d -6 route show 2001:db8:e::200/128 || true
echo "===PE2-KERNEL-V4-ROUTES==="
ip -n pe2 -4 route show
echo "===PE2-KERNEL-V4-ROUTES-DETAIL==="
ip -n pe2 -d -4 route show 192.168.1.1 || true

# --- verify ----------------------------------------------------------------
# Both pe1 (received from gobgp) and pe2 (re-advertised via pe1) must
# end up with End.M.GTP4.E + End.M.GTP6.E seg6local routes (T2ST) and
# the seg6 H.Encaps route for the T1ST UE prefix on their kernels.
echo "===VERIFY==="
PASS=1
check_pe() {
    local ns=$1
    local v4=$(ip -n "$ns" -6 route show 2>/dev/null | grep -oE 'End\.M\.GTP4\.E' | head -1)
    local v6=$(ip -n "$ns" -6 route show 2>/dev/null | grep -oE 'End\.M\.GTP6\.E' | head -1)
    local t1=$(ip -n "$ns" -4 route show 192.168.1.1 2>/dev/null | grep -oE 'encap seg6 mode encap')
    [ "$v4" = "End.M.GTP4.E" ] || { echo "FAIL: T2ST(v4) End.M.GTP4.E missing on $ns"; PASS=0; }
    [ "$v6" = "End.M.GTP6.E" ] || { echo "FAIL: T2ST(v6) End.M.GTP6.E missing on $ns"; PASS=0; }
    [ -n "$t1" ]               || { echo "FAIL: T1ST seg6 H.Encaps missing for 192.168.1.1 on $ns"; PASS=0; }
}
check_pe pe1
check_pe pe2

if [ "$PASS" -eq 1 ]; then
    echo "===FRR-INTEROP-MUP=== PASS"
else
    echo "===FRR-INTEROP-MUP=== FAIL"
fi

kill $T_ZB 2>/dev/null; wait $T_ZB 2>/dev/null
# Persist the captures out of vng for offline diff (set NLMON_OUT externally).
# /tmp is overmounted with tmpfs at the top of the script, so callers must
# pass a path that lives outside /tmp (typically the harness repo).
if [ -n "${NLMON_OUT:-}" ]; then
    mkdir -p "$NLMON_OUT" 2>/dev/null
    cp /tmp/pe1/iproute2.nlmon "$NLMON_OUT/" 2>&1
    cp /tmp/pe1/zebra.nlmon    "$NLMON_OUT/" 2>&1
fi
echo "===NLMON-ZEBRA-DUMP-FILTERED==="
# Only show packets whose first nlmsg is RTM_NEWROUTE (type=0x18) targeting our /56 SID locator.
ip netns exec pe1 tcpdump -nXr /tmp/pe1/zebra.nlmon 2>/dev/null | head -200 || true

# --- diagnostics on failure -----------------------------------------------
if [ "${PASS:-0}" != "1" ]; then
    echo "===GOBGPD-LOG==="
    tail -40 /tmp/gbgp/gobgpd.log 2>/dev/null || true
    echo "===PE1-ZEBRA-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/zebra.log 2>/dev/null | tail -200 || true
    echo "===PE1-BGPD-LOG-TAIL==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/bgpd.log 2>/dev/null | tail -60 || true
    echo "===PE2-ZEBRA-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe2/zebra.log 2>/dev/null | tail -120 || true
    echo "===PE2-BGPD-LOG-TAIL==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe2/bgpd.log 2>/dev/null | tail -60 || true
fi

# --- teardown -------------------------------------------------------------
kill $GOBGP_PID 2>/dev/null || true
for ns in pe1 pe2; do
    [ -f /tmp/$ns/bgpd.pid  ] && kill $(cat /tmp/$ns/bgpd.pid)  2>/dev/null || true
    [ -f /tmp/$ns/zebra.pid ] && kill $(cat /tmp/$ns/zebra.pid) 2>/dev/null || true
done
echo "===DONE==="
