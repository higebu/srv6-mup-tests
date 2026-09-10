# srv6-mup-tests

Test scripts and documentation for the Linux SRv6 Mobile User Plane (RFC 9433) implementation:

- Linux kernel patch series: <https://github.com/higebu/linux/tree/srv6-mup>
- iproute2 patch series:     <https://github.com/higebu/iproute2/tree/srv6-mup>

This repo holds:

1. Pointers and instructions for running the in-tree kernel selftests
   (`tools/testing/selftests/net/srv6_*_test.sh`) under
   [virtme-ng](https://github.com/arighi/virtme-ng).
2. Five VPP 25.10 interop scenarios (one per Linux MUP behavior under
   test), with merged pcaps captured at three points along the path
   (test ingress, SR-domain wire, test egress).  The role each end
   plays in 3GPP terms (gNB / MUP-PE upstream peer) depends on the
   scenario direction (UL D-family vs. DL E-family); see
   [`docs/vpp-interop.md`](docs/vpp-interop.md) for the per-scenario
   topology and role mapping.
3. Per-test READMEs under each `tests/scenarios/*/` directory (FRR
   control-plane / data-plane tests + VPP interop scenarios) and
   `tests/properties/bgp_mup_cli/` (BGP-MUP CLI property tests).

## Layout

```
srv6-mup-tests/
├── README.md                  -- this file
├── .bin/                      -- gobgp / gobgpd the frr_* scenarios drive
│                                 (not in git; see "gobgp binaries" below)
├── docs/
│   ├── selftests.md           -- how to run the kernel selftests under vng
│   ├── vpp-interop.md         -- how to run the 5 VPP interop scenarios + per-scenario topology
│   ├── cli-props.md           -- BGP-MUP CLI property test catalogue + evidence
│   └── build-tarball.md       -- how to rebuild the SRv6 MUP .deb bundle tarball
├── scripts/                   -- build / release / runner utilities (no tests)
│   ├── build_frr_deb.sh
│   ├── build_tarball.sh
│   ├── pack_release.sh
│   ├── run_cli_props.sh       -- host-side runner for the CLI property tests
│   └── run_cli_props_vng.sh   -- vng-side runner for the same suite
├── tests/
│   ├── properties/
│   │   └── bgp_mup_cli/       -- single-PE pytest+hypothesis property tests
│   │                             for BGP-MUP CLI (see docs/cli-props.md)
│   └── scenarios/             -- one directory per end-to-end scenario;
│                                 RFC 9433 mnemonic — the "D" suffix means
│                                 GTP-U-Decap (= produces SRv6) and the "E"
│                                 suffix means GTP-U-Encap (= produces
│                                 GTP-U from SRv6).
│       ├── frr_*/                          -- FRR-driven scenarios
│       └── vpp_interop_*/                  -- VPP interop scenarios:
│           ├── vpp_interop_h_m_gtp4_d/        -- Linux H.M.GTP4.D    -> VPP end.m.gtp4.e
│           ├── vpp_interop_end_m_gtp4_e/      -- VPP sr policy+encap -> Linux End.M.GTP4.E
│           ├── vpp_interop_end_m_gtp6_d/      -- Linux End.M.GTP6.D  -> VPP End.DT6
│           ├── vpp_interop_end_m_gtp6_e/      -- VPP end.m.gtp6.d (drop-in) -> Linux End.M.GTP6.E
│           └── vpp_interop_end_m_gtp6_d_di/   -- Linux End.M.GTP6.D.Di -> VPP End
├── pcaps/                     -- merged pcaps from a recent run
│                                 (test ingress + SR-domain wire + test egress)
└── logs/                      -- runtime logs (.gitignore'd)
```

### gobgp binaries

`.bin/gobgp{,d}` are not tracked here.  The `frr_*` scenarios need a
gobgp whose T1ST / T2ST route CLI accepts `prefix-sid`, which no
released gobgp has: the parser change lives only as an uncommitted
working-tree diff (+52/-10 in `cmd/gobgp/global.go`) on branch
`srv6-mup-frr-interop` of the `osrg/gobgp` clone (origin =
`higebu/gobgp`), over the GoBGP 4.5.0 tag `5f191066a78e`.  Rebuild with:

```bash
cd <osrg/gobgp clone> && git checkout srv6-mup-frr-interop
go build -o <srv6-mup-tests>/.bin/gobgp  ./cmd/gobgp
go build -o <srv6-mup-tests>/.bin/gobgpd ./cmd/gobgpd
```

That base predates osrg/gobgp#3418, so `rt` is still `paramSingle` and
a scenario passing more than one `rt` will not work.  Getting both the
`prefix-sid` support and `rt: paramList` needs the parser change
committed and rebased onto current upstream — tracked in
`issues/20260530-201922-feature-gobgp-mup-t1st-t2st-prefix-sid-cli.md`.

## BGP-MUP CLI property tests (`tests/properties/bgp_mup_cli/`)

A single-PE pytest + `hypothesis` test suite exercises FRR's BGP-MUP
vtysh surface for round-trip preservation, context guards, and
malformed-input rejection.  Run it with:

```bash
scripts/run_cli_props.sh                 # everything (host + sudo, ~30s)
```

See [`docs/cli-props.md`](docs/cli-props.md) for the property
catalogue, the input strategies, and the validation gate evidence.

## Quick start

### Prerequisites

1. The `srv6-mup` Linux kernel checked out and built at `<parent>/linux`
   (where `<parent>` is the directory holding this repo's checkout;
   `make -j$(nproc) bzImage` succeeded; kernel.release starts with
   `7.0.0-srv6-mup-...`).
2. The `srv6-mup` iproute2 checked out and built at `<parent>/iproute2`
   (`make -j$(nproc)` succeeded; `./ip/ip route help` shows the MUP
   actions).
3. On the host: `vpp` + `vpp-plugin-core` (25.10 from the FDio
   `2510` packagecloud repo), `virtme-ng`,
   `python3-scapy`, `tcpdump`, `wireshark-common` (for `mergecap` and
   `tshark`).

### Run the kernel selftests

See [`docs/selftests.md`](docs/selftests.md) for the full walk-through.
TL;DR:

```bash
# Default layout: linux/, iproute2/, and srv6-mup-tests/ are siblings
# under the same parent.  Adjust ROOT if your layout differs.
ROOT=$(cd "$(dirname "$0")/.." && pwd)   # or just: ROOT=~/ghq/github.com/higebu

script -q -c "vng -m 4G --run $ROOT/linux --user root \
  -- bash -c 'mount -t tmpfs tmpfs /tmp; \
              export PATH=$ROOT/iproute2/ip:\$PATH; \
              cd $ROOT/linux/tools/testing/selftests/net && \
              for t in srv6_end_m_gtp4_e_test.sh srv6_end_m_gtp6_d_test.sh \
                       srv6_end_m_gtp6_d_di_test.sh srv6_end_m_gtp6_e_test.sh \
                       srv6_end_map_test.sh srv6_h_m_gtp4_d_test.sh; do
                echo \"== \$t ==\"; bash \$t
              done'" /tmp/selftests.log
grep -E '^==|TEST:' /tmp/selftests.log
```

Expected:

```
TEST: End.M.GTP4.E   [PASS]
TEST: End.M.GTP6.D   [PASS]
TEST: End.M.GTP6.D.Di [PASS]
TEST: End.M.GTP6.E   [PASS]
TEST: End.MAP        [PASS]
TEST: H.M.GTP4.D     [PASS]
```

### Run the VPP interop tests

See [`docs/vpp-interop.md`](docs/vpp-interop.md) for the full walk-through.
TL;DR:

```bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)   # parent of linux/ iproute2/ srv6-mup-tests/
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
rm -f $PCAP_DIR/*.pcap

for s in vpp_interop_h_m_gtp4_d \
         vpp_interop_end_m_gtp4_e \
         vpp_interop_end_m_gtp6_d \
         vpp_interop_end_m_gtp6_e \
         vpp_interop_end_m_gtp6_d_di; do
  script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
    --run $ROOT/linux --user root \
    -- env PCAP_OUT=$PCAP_DIR \
    $ROOT/srv6-mup-tests/tests/scenarios/$s/$s.sh" \
    /tmp/run-$s.log >/dev/null 2>&1
  grep -E 'VPP-INTEROP' /tmp/run-$s.log | tail -1
done

ls -la $PCAP_DIR/
```

Expected:

```
===VPP-INTEROP-H_M_GTP4_D=== PASS
===VPP-INTEROP-END_M_GTP4_E=== PASS
===VPP-INTEROP-END_M_GTP6_D=== PASS
===VPP-INTEROP-END_M_GTP6_E=== PASS
===VPP-INTEROP-END_M_GTP6_D_DI=== PASS
```

## What each test covers

### Kernel selftests (RFC 9433 §6.2-§6.7, all six behaviors)

| Selftest | RFC | Linux behavior |
|---|---|---|
| `srv6_end_map_test.sh` | §6.2 | End.MAP |
| `srv6_end_m_gtp6_d_test.sh` | §6.3 + §6.5 Note | End.M.GTP6.D |
| `srv6_end_m_gtp6_d_di_test.sh` | §6.4 | End.M.GTP6.D.Di |
| `srv6_end_m_gtp6_e_test.sh` | §6.5 | End.M.GTP6.E |
| `srv6_end_m_gtp4_e_test.sh` | §6.6 | End.M.GTP4.E |
| `srv6_h_m_gtp4_d_test.sh` | §6.7 | H.M.GTP4.D |

### VPP 25.10 interop scenarios

RFC 9433 action-name mnemonic: **D** = GTP-U **D**ecap (output is SRv6), **E** = GTP-U **E**ncap (output is GTP-U).  Below "GTP-U → SRv6" and "SRv6 → GTP-U" describe what each end actually emits.

| Script | Linux side | VPP side |
|---|---|---|
| `tests/scenarios/vpp_interop_h_m_gtp4_d/` | H.M.GTP4.D §6.7 (GTP-U → SRv6) | end.m.gtp4.e §6.6 (SRv6 → GTP-U) |
| `tests/scenarios/vpp_interop_end_m_gtp4_e/` | End.M.GTP4.E §6.6 (SRv6 → GTP-U) | sr policy + plain encap (IPv4 → SRv6) |
| `tests/scenarios/vpp_interop_end_m_gtp6_d/` | End.M.GTP6.D Section 6.3 (GTP-U → SRv6) | End.DT6 RFC 8986 Section 4.8 (SRv6 → IPv6) |
| `tests/scenarios/vpp_interop_end_m_gtp6_e/` | End.M.GTP6.E §6.5 (SRv6 → GTP-U) | end.m.gtp6.d drop-in §6.3 (GTP-U → SRv6 inline) |
| `tests/scenarios/vpp_interop_end_m_gtp6_d_di/` | End.M.GTP6.D.Di §6.4 (GTP-U → SRv6 inline) | End (RFC 8986 transit) |

End.MAP (§6.2) and End.Limit (§6.8) cannot be exercised against VPP
because the VPP `srv6-mobile` plugin (Arrcus contribution) does not
implement either; they are covered by the kernel selftests only.

## References

- RFC 9433 — <https://www.rfc-editor.org/rfc/rfc9433>
- VPP `srv6-mobile` plugin — `~/vpp/src/plugins/srv6-mobile/`
- SRv6 MUP `.deb` bundle tarball (kernel + iproute2 debs + selftests) —
  `~/srv6-mup-bundle.tar.gz`, installable on any Ubuntu 24.04 LTS host
  (rebuild with
  [`scripts/build_tarball.sh`](scripts/build_tarball.sh);
  see [`docs/build-tarball.md`](docs/build-tarball.md) for the full
  procedure)
