# frr_mup_gr_gobgp_scapy

End-to-end coverage for BGP Graceful Restart (RFC 4724), route refresh
(RFC 2918), and `clear bgp` interruption behavior on the BGP-MUP install
path.  Same 5-netns topology as `frr_mup_e2e_gobgp_scapy`, but the
gw1 to pe1 BGP session has `bgp graceful-restart` enabled at boot and
the harness drives continuous GTP-U(ICMP echo) traffic from gnb while
triggering control-plane events on pe1, counting delivered vs. lost
packets per sub-test.

## Topology

```
+-----+ gtpu  +-----+ srv6  +-----+ ipv4  +-----+
| gnb |-------| gw1 |-------| pe1 |-------| dn  |
+-----+ veth  +-----+ veth  +-----+ veth  +-----+
scapy         MUP-GW        MUP-PE
              ISD origin    DSD origin
              (GR helper)   (GR restarter,
                             trigger origin)
                                 ^
                                 |
                            gobgpd (MUP-Controller)
                            via separate veth into pe1
```

The 3GPP framing matches the upstream `frr_mup_e2e_gobgp_scapy`
harness: there is no UPF; gw1 is the MUP-GW (RFC 9433 Section 6
behaviors), pe1 is the MUP-PE.  See `docs/topology.md` for the
canonical role table.

## Address plan

| Network                | Prefix                | Hosts                                          |
|------------------------|-----------------------|------------------------------------------------|
| gNB-side IPv4          | `10.99.0.0/24`        | gw1 = .1, gnb = .5; T2ST EP = `10.99.0.100`    |
| SR-domain IPv6         | `2001:db8:1::/64`     | gw1 = ::1, pe1 = ::2                           |
| DN-side IPv4           | `10.1.0.0/24`         | pe1 = .1, dn = .5                              |
| MUP-Controller bus     | `2001:db8:0::/64`     | pe1 = ::1, gbgp = ::2                          |
| pe1 SR locator         | `2001:db8:e::/48`     | block 24 / node 24 / func 8                    |
| gw1 SR locator         | `2001:db8:f::/48`     | block 24 / node 24 / func 8                    |
| UE prefix              | `192.168.10.5/32`     | T1ST endpoint                                  |
| TEID / QFI             | 12345 / 9             | MUP-EC seg-id 10:10                            |

## Sub-tests

| Label | Setup                                  | Trigger                          | Expected outcome                                                                 |
|-------|----------------------------------------|----------------------------------|----------------------------------------------------------------------------------|
| A     | GR enabled (boot config)               | `clear bgp *` on pe1             | `lost == 0`. GR / `preserve-fw-state` keeps the kernel seg6local install in place across the session bounce, so GTP-U continues uninterrupted. |
| B     | GR enabled (boot config)               | `clear bgp * soft in` on pe1     | `lost == 0`. Route refresh re-sends MUP NLRI; the install must never bounce (no withdraw / re-add gap). |
| C     | GR disabled at runtime (`no bgp graceful-restart`) | `clear bgp *` on pe1     | Interruption recorded. With GR off, zebra withdraws the install on session-down and re-installs after re-establish. The script reports `lost` and the implied interruption window (`lost / RATE_HZ`); upper bound is configurable via `LOSS_BOUND_C` (default `9999` = record only). |

The traffic generator sends one GTP-U(ICMP echo) every `1/RATE_HZ`
seconds with a unique inner ICMP `seq`, then diffs sent vs. seen seqs
to compute `lost`.  Defaults: `RATE_HZ=50`, `PRE_S=2`, `POST_S=15`.

## How to run

From outside the VM, host shell, with the harness sibling tree in
place (`linux/`, `iproute2/`, `frr/`, `srv6-mup-tests/`):

```sh
ROOT=$(cd path/to/parent && pwd)
script -q -c "vng -m 4G --rwdir=$ROOT --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/scripts/frr_mup_gr_gobgp_scapy/frr_mup_gr_gobgp_scapy.sh" \
  /tmp/run-gr.log
grep -E 'SUBTEST|VERDICT|FRR-MUP-GR' /tmp/run-gr.log
```

Tunables (env):

- `DEBUG=1` — extra diagnostic captures.
- `RATE_HZ` — packets per second per sub-test (default `50`).
- `PRE_S` / `POST_S` — pre-trigger and post-trigger stream window.
- `LOSS_BOUND_C` — sub-test C upper bound; `9999` = record-only.

## Pass criteria

```
FRR-MUP-GR-GOBGP-SCAPY: PASS
```

is printed iff:

- A: `lost == 0`.
- B: `lost == 0`.
- C: `lost <= LOSS_BOUND_C` (default `9999`, so always passes; set to a
  concrete bound once a baseline interruption window is established).

The verdict block also emits the per-sub-test `sent / delivered / lost`
line and the SR-domain pcap (`/tmp/pcap/<label>-gw-sr.pcap`) for
forensic review.

## TODO: rmap-edit-driven refresh

Sub-test B currently exercises only the identity-refresh form
(`clear bgp * soft in` re-sends the same NLRI / attributes).  The
issue body also calls for the rmap-import edit variant: edit a
`route-map MUP_VRF_IMPORT` permit/deny line and re-apply, which drives
the same refresh code path but with an attribute / filter change.

That requires the per-vrf rmap-import work tracked in
`srv6-mup-issues/wip/20260509-093034-...md` (Phase 2), which is not
yet implemented in `higebu/frr:seg6-mobile`.  Once it lands, add a
sub-test B' that toggles a `MUP_VRF_IMPORT` line between
`permit -> deny -> permit` (or flips an extended-community match) and
asserts that the install survives the implied refresh without
bouncing.
