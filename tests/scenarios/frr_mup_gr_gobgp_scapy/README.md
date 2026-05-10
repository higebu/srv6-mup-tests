# frr_mup_gr_gobgp_scapy

End-to-end coverage for BGP Graceful Restart (RFC 4724), route refresh
(RFC 2918), and `clear bgp` interruption behavior on the BGP-MUP install
path.  Same 5-netns topology as `frr_mup_e2e_gobgp_scapy`, but the
gw1 to pe1 BGP session has `bgp graceful-restart` enabled at boot and
the script drives continuous GTP-U(ICMP echo) traffic from gnb while
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

| netns  | Role                                                |
|--------|-----------------------------------------------------|
| `gnb`  | Continuous GTP-U(ICMP echo) traffic generator       |
| `gw1`  | MUP-GW: ISD originator, GR helper                   |
| `pe1`  | MUP-PE: DSD originator, GR restarter, trigger target|
| `dn`   | DN-side host (UE-traffic destination)               |
| `gbgp` | MUP-Controller (gobgpd, T1ST/T2ST source)           |

3GPP framing matches the baseline `frr_mup_e2e_gobgp_scapy` scenario:
no UPF in the data path; gw1 is the MUP-GW (RFC 9433 Section 6
behaviors), pe1 is the MUP-PE.

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
| A     | GR enabled (boot config)               | `clear bgp 2001:db8:1::1` on pe1 (single peer) | `lost == 0`. GR / `preserve-fw-state` keeps gw1's kernel seg6local install in place across the bounce of the pe1 -> gw1 session. pe1 still holds the gobgp-sourced T1ST/T2ST in its RIB (that session was not bounced), so it re-advertises the full MUP RIB on the new session and gw1's post-EOR cleanup leaves the install untouched. |
| B     | GR enabled (boot config)               | `clear bgp * soft in` on pe1     | `lost == 0`. Route refresh re-sends MUP NLRI; the install must never bounce (no withdraw / re-add gap). |
| C     | GR disabled at runtime (`no bgp graceful-restart`) | `clear bgp *` on pe1     | Interruption recorded. With GR off, zebra withdraws the install on session-down and re-installs after re-establish. The script reports `lost` and the implied interruption window (`lost / RATE_HZ`); upper bound is configurable via `LOSS_BOUND_C` (default `9999` = record only). |
| D     | GR re-enabled after C                  | `clear bgp *` on pe1 (all peers) | Interruption recorded. `clear bgp *` also resets the pe1 -> gobgp session that supplies T1ST/T2ST to pe1; pe1 re-establishes with gw1 first and sends EOR before gobgp re-converges, so gw1's helper correctly prunes the un-refreshed stale T2ST per RFC 4724 and the install drops for the gobgp re-converge window. This is a multi-session ordering pitfall, not an FRR bug; recorded but not gated. |

The traffic generator sends one GTP-U(ICMP echo) every `1/RATE_HZ`
seconds with a unique inner ICMP `seq`, then diffs sent vs. seen seqs
to compute `lost`.  Defaults: `RATE_HZ=50`, `PRE_S=2`, `POST_S=15`.

## How to run

From outside the VM, host shell, with the sibling tree in place
(`linux/`, `iproute2/`, `frr/`, `srv6-mup-tests/`):

```sh
ROOT=$(cd path/to/parent && pwd)
script -q -c "vng -m 4G --rwdir=$ROOT --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/tests/scenarios/frr_mup_gr_gobgp_scapy/frr_mup_gr_gobgp_scapy.sh" \
  /tmp/run-gr.log
grep -E 'SUBTEST|VERDICT|FRR-MUP-GR' /tmp/run-gr.log
```

Tunables (env):

- `DEBUG=1` — extra diagnostic captures.
- `RATE_HZ` — packets per second per sub-test (default `50`).
- `PRE_S` / `POST_S` — pre-trigger and post-trigger stream window.
- `LOSS_BOUND_A` — sub-test A upper bound; default `0` (gate strict).
- `LOSS_BOUND_C` — sub-test C upper bound; `9999` = record-only.

## Pass criteria

```
FRR-MUP-GR-GOBGP-SCAPY: PASS
```

is printed iff:

- A: `lost <= LOSS_BOUND_A` (default `0`).
- B: `lost == 0`.
- C: `lost <= LOSS_BOUND_C` (default `9999`, so always passes; set to a
  concrete bound once a baseline interruption window is established).
- D: `lost <= 9999` (always passes; multi-session ordering case, recorded
  for forensic comparison with C).

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
