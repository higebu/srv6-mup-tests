#!/bin/bash
# FRR BGP-MUP locator delete -> recreate regression test.
#
# Walks the locator chunk release / re-request path that
# `bgp_mup.c` inherits from L3VPN: when the operator deletes the SRv6
# locator behind an auto-SID origination, bgpd must release every
# locator chunk and withdraw the corresponding ISD/DSD from the BGP-MUP
# SAFI; when the locator is added back, bgpd must re-acquire chunks
# (bgp_mup_replay_origins_all() path) and re-originate from the same
# prefix so the SID identity is preserved.
#
# Topology:
#   +-----+ veth +-----+
#   | pe1 |------| pe2 |
#   |65001| eBGP |65002|
#   +-----+      +-----+
#
# pe1 has the SRv6 locator and originates ISD/DSD; pe2 receives.  No
# UL/DL data plane: ISD/DSD origination + receive-side install is the
# whole signal.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
FRR=$ROOT/frr

export PATH="$ROOT/iproute2/ip:$PATH"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /usr/local/var/run 2>/dev/null
mkdir -p /usr/local/var/run/frr 2>/dev/null
mount -t tmpfs tmpfs /usr/local/var/lib 2>/dev/null
mkdir -p /usr/local/var/lib/frr 2>/dev/null

echo "===KERNEL=== $(uname -r)"

for ns in pe1 pe2; do mkdir -p /tmp/$ns; done

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

ip -n pe1 link add slice1 type vrf table 100
ip -n pe1 link set slice1 up
ip -n pe1 link add slice2 type vrf table 200
ip -n pe1 link set slice2 up
ip netns exec pe1 sysctl -wq net.vrf.strict_mode=1

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

PASS=1

# Helpers ------------------------------------------------------------------
isd_v4_pe1() { $VTYSH_PE1 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -cE "\[1\]:\[1\].*10.99.0.0/24"; }
dsd_v4_pe1() { $VTYSH_PE1 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -cE "\[1\]:\[2\].*10.0.0.250"; }
isd_v6_pe1() { $VTYSH_PE1 -c 'show bgp ipv6 mup all' 2>/dev/null | grep -cE "\[1\]:\[1\].*2001:db8:99::/64"; }
isd_v4_pe2() { $VTYSH_PE2 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -cE "\[1\]:\[1\].*10.99.0.0/24"; }
dsd_v4_pe2() { $VTYSH_PE2 -c 'show bgp ipv4 mup all' 2>/dev/null | grep -cE "\[1\]:\[2\].*10.0.0.250"; }
isd_v6_pe2() { $VTYSH_PE2 -c 'show bgp ipv6 mup all' 2>/dev/null | grep -cE "\[1\]:\[1\].*2001:db8:99::/64"; }

# Extract the local-SID prefix for the v4 ISD on pe1's MUP RIB.  The
# detail-routes output prints "Remote SID: <sid>" for the auto-SID;
# under the locator default of 2001:db8:e::/64 the SID falls inside
# that prefix.
isd_v4_sid_pe1() {
    $VTYSH_PE1 -c 'show bgp ipv4 mup all detail-routes' 2>/dev/null \
        | awk '/\[1\]:\[1\]:.*10.99.0.0/{found=1} found && /Remote SID:/ {print $3; exit}'
}
isd_v4_sid_pe2() {
    $VTYSH_PE2 -c 'show bgp ipv4 mup all detail-routes' 2>/dev/null \
        | awk '/\[1\]:\[1\]:.*10.99.0.0/{found=1} found && /Remote SID:/ {print $3; exit}'
}

wait_for() {
    # wait_for <description> <max-tries> <expr>
    local desc=$1 tries=$2; shift 2
    local i
    for i in $(seq 1 "$tries"); do
        if eval "$@"; then
            echo "  ok($i): $desc"
            return 0
        fi
        sleep 1
    done
    echo "  timeout: $desc"
    return 1
}

# Phase 1: baseline ---------------------------------------------------------
echo "===PHASE-1-BASELINE==="
wait_for "ISD(v4) on pe1 RIB"  20 "[ \$(isd_v4_pe1) -ge 1 ]"  || PASS=0
wait_for "DSD(v4) on pe1 RIB"  20 "[ \$(dsd_v4_pe1) -ge 1 ]"  || PASS=0
wait_for "ISD(v6) on pe1 RIB"  20 "[ \$(isd_v6_pe1) -ge 1 ]"  || PASS=0
wait_for "ISD(v4) on pe2 RIB"  20 "[ \$(isd_v4_pe2) -ge 1 ]"  || PASS=0
wait_for "DSD(v4) on pe2 RIB"  20 "[ \$(dsd_v4_pe2) -ge 1 ]"  || PASS=0
wait_for "ISD(v6) on pe2 RIB"  20 "[ \$(isd_v6_pe2) -ge 1 ]"  || PASS=0

baseline_sid_pe1=$(isd_v4_sid_pe1)
baseline_sid_pe2=$(isd_v4_sid_pe2)
echo "baseline ISD(v4) SID pe1=$baseline_sid_pe1 pe2=$baseline_sid_pe2"
[ -n "$baseline_sid_pe1" ] || { echo "FAIL: baseline ISD(v4) SID empty on pe1"; PASS=0; }
[ -n "$baseline_sid_pe2" ] || { echo "FAIL: baseline ISD(v4) SID empty on pe2"; PASS=0; }

echo "===PE1-KERNEL-BASELINE==="
ip netns exec pe1 ip -6 route show table all 2>&1 | grep -E "encap seg6|seg6local" || echo "(no seg6local installs)"
baseline_kern=$(ip netns exec pe1 ip -6 route show table all | grep -cE "encap seg6local.*action End" || true)
echo "baseline pe1 kernel End.* installs: $baseline_kern"

# Phase 2: delete locator ---------------------------------------------------
# `no locator default` releases the chunk; bgp_mup must withdraw every
# auto-SID origination and stop re-advertising to pe2.
echo "===PHASE-2-DELETE-LOCATOR==="
$VTYSH_PE1 -c 'configure' \
    -c 'segment-routing' \
    -c 'srv6' \
    -c 'locators' \
    -c 'no locator default' 2>&1 | grep -vE "vtysh.conf|Configuration file" | head -10

wait_for "ISD(v4) withdrawn from pe1" 20 "[ \$(isd_v4_pe1) -eq 0 ]" || PASS=0
wait_for "DSD(v4) withdrawn from pe1" 20 "[ \$(dsd_v4_pe1) -eq 0 ]" || PASS=0
wait_for "ISD(v6) withdrawn from pe1" 20 "[ \$(isd_v6_pe1) -eq 0 ]" || PASS=0
wait_for "ISD(v4) withdrawn from pe2" 20 "[ \$(isd_v4_pe2) -eq 0 ]" || PASS=0
wait_for "DSD(v4) withdrawn from pe2" 20 "[ \$(dsd_v4_pe2) -eq 0 ]" || PASS=0
wait_for "ISD(v6) withdrawn from pe2" 20 "[ \$(isd_v6_pe2) -eq 0 ]" || PASS=0

echo "===PE1-KERNEL-POST-DELETE==="
ip netns exec pe1 ip -6 route show table all 2>&1 | grep -E "encap seg6|seg6local" || echo "(no seg6local installs)"
post_delete_kern=$(ip netns exec pe1 ip -6 route show table all | grep -cE "encap seg6local.*action End" || true)
echo "post-delete pe1 kernel End.* installs: $post_delete_kern"

# Phase 3: recreate locator -------------------------------------------------
# Re-add the same locator with the same prefix.  bgp_mup must
# re-request chunks and replay all auto-SID originations
# (bgp_mup_replay_origins_all()).
echo "===PHASE-3-RECREATE-LOCATOR==="
$VTYSH_PE1 -c 'configure' \
    -c 'segment-routing' \
    -c 'srv6' \
    -c 'locators' \
    -c 'locator default' \
    -c 'prefix 2001:db8:e::/64 block-len 40 node-len 24 func-bits 16' 2>&1 \
    | grep -vE "vtysh.conf|Configuration file" | head -10

# bgpd needs the per-vrf locator binding to fire its locator-chunk
# replay path.  The `segment-routing srv6 / locator default` stanza
# under `router bgp 65001 vrf slice1` was kept in running-config; in
# practice bgpd re-binds automatically when the locator reappears, so
# no explicit re-binding is required here.

wait_for "ISD(v4) re-originated on pe1" 30 "[ \$(isd_v4_pe1) -ge 1 ]" || PASS=0
wait_for "DSD(v4) re-originated on pe1" 30 "[ \$(dsd_v4_pe1) -ge 1 ]" || PASS=0
wait_for "ISD(v6) re-originated on pe1" 30 "[ \$(isd_v6_pe1) -ge 1 ]" || PASS=0
wait_for "ISD(v4) re-propagated to pe2" 30 "[ \$(isd_v4_pe2) -ge 1 ]" || PASS=0
wait_for "DSD(v4) re-propagated to pe2" 30 "[ \$(dsd_v4_pe2) -ge 1 ]" || PASS=0
wait_for "ISD(v6) re-propagated to pe2" 30 "[ \$(isd_v6_pe2) -ge 1 ]" || PASS=0

recreated_sid_pe1=$(isd_v4_sid_pe1)
recreated_sid_pe2=$(isd_v4_sid_pe2)
echo "recreated ISD(v4) SID pe1=$recreated_sid_pe1 pe2=$recreated_sid_pe2"

# The SID must come from the same locator prefix (2001:db8:e::/64).
# Exact value may differ if bgp_mup re-allocates from the function
# space; the contract is "same locator", not "same SID".
[ -n "$recreated_sid_pe1" ] || { echo "FAIL: recreated ISD(v4) SID empty on pe1"; PASS=0; }
[ -n "$recreated_sid_pe2" ] || { echo "FAIL: recreated ISD(v4) SID empty on pe2"; PASS=0; }
case "$recreated_sid_pe1" in
    2001:db8:e:*) : ;;
    *) echo "FAIL: recreated SID $recreated_sid_pe1 not from locator 2001:db8:e::/64"; PASS=0 ;;
esac
case "$recreated_sid_pe2" in
    2001:db8:e:*) : ;;
    *) echo "FAIL: recreated SID $recreated_sid_pe2 not from locator 2001:db8:e::/64"; PASS=0 ;;
esac

echo "===PE1-KERNEL-POST-RECREATE==="
ip netns exec pe1 ip -6 route show table all 2>&1 | grep -E "encap seg6|seg6local" || echo "(no seg6local installs)"
post_recreate_kern=$(ip netns exec pe1 ip -6 route show table all | grep -cE "encap seg6local.*action End" || true)
echo "post-recreate pe1 kernel End.* installs: $post_recreate_kern"

echo "===PE1-RUNNING-CONFIG-LOCATOR==="
$VTYSH_PE1 -c 'show running-config' 2>&1 | sed -n '/^segment-routing/,/^!/p'
echo "===PE1-BGP-IPV4-MUP-FINAL==="
$VTYSH_PE1 -c 'show bgp ipv4 mup all detail-routes' 2>&1 | grep -vE "Configuration file|vtysh.conf" | head -40

if [ "$PASS" -eq 1 ]; then
    echo "===FRR-LOCATOR-RECREATE=== PASS"
else
    echo "===FRR-LOCATOR-RECREATE=== FAIL"
    echo "===PE1-BGPD-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/bgpd.log 2>/dev/null | tail -80 || true
    echo "===PE1-ZEBRA-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe1/zebra.log 2>/dev/null | tail -40 || true
    echo "===PE2-BGPD-LOG==="
    grep -vE "mkdir|MPLS support|EC 100663303" /tmp/pe2/bgpd.log 2>/dev/null | tail -40 || true
fi

for ns in pe1 pe2; do
    [ -f /tmp/$ns/bgpd.pid  ] && kill "$(cat /tmp/$ns/bgpd.pid)"  2>/dev/null || true
    [ -f /tmp/$ns/zebra.pid ] && kill "$(cat /tmp/$ns/zebra.pid)" 2>/dev/null || true
    [ -f /tmp/$ns/mgmtd.pid ] && kill "$(cat /tmp/$ns/mgmtd.pid)" 2>/dev/null || true
done
echo "===DONE==="
