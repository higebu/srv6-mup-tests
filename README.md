# srv6-mup-tests

Test harness for the SRv6 Mobile User Plane (RFC 9433) reference stack.
Three independently versioned components, all built for Ubuntu 24.04 LTS:

- Linux kernel patch series — <https://github.com/higebu/linux/tree/b4/seg6-mobile>
  (RFC 9433 §6.2-§6.7 behaviors: End.MAP, End.M.GTP4.E, End.M.GTP6.D /
  D.Di / E, H.M.GTP4.D)
- iproute2 patch series — <https://github.com/higebu/iproute2/tree/b4/seg6-mobile>
  (`seg6local action End.M.GTP4.E / End.M.GTP6.E / End.M.GTP6.D /
  End.M.GTP6.D.Di / End.MAP / H.M.GTP4.D` keywords)
- FRR series — <https://github.com/higebu/frr/tree/seg6-mobile>
  (BGP-MUP SAFI per draft-ietf-bess-mup-safi: ISD/DSD originate +
  T1ST/T2ST receive-side resolution)

This repo holds:

1. Pointers and instructions for running the in-tree kernel selftests
   (`tools/testing/selftests/net/srv6_*_test.sh`) under
   [virtme-ng](https://github.com/arighi/virtme-ng).
2. Five VPP 25.10 interop scenarios (one per kernel MUP behavior under
   test), with merged pcaps captured at three points along the path
   (test ingress, SR-domain wire, test egress).
3. Three FRR BGP-MUP harnesses: FRR-only `segment` origination, gobgpd
   ↔ FRR ↔ FRR control-plane interop, and a full E2E (gobgpd +
   FRR + scapy) including data-plane forwarding.
4. Reference rtnetlink (nlmon) captures of zebra vs. iproute2 SID
   programming for debugging the netlink attribute layout.

## Layout

```
srv6-mup-tests/
├── README.md                  -- this file
├── docs/
│   ├── selftests.md           -- how to run the kernel selftests under vng
│   ├── vpp-interop.md         -- how to run the 5 VPP interop scenarios
│   ├── topology.md            -- per-scenario netns + veth topology
│   └── build-tarball.md       -- how to rebuild the SRv6 MUP .deb bundle tarball
├── scripts/                   -- harness scripts
│   ├── vpp_interop_h_m_gtp4_d.sh        -- Linux H.M.GTP4.D (GTP-U -> SRv6) -> VPP end.m.gtp4.e (SRv6 -> GTP-U)
│   ├── vpp_interop_end_m_gtp4_e.sh      -- VPP `sr policy + plain encap` (IPv4 -> SRv6) -> Linux End.M.GTP4.E (SRv6 -> GTP-U)
│   ├── vpp_interop_end_m_gtp6_d.sh      -- Linux End.M.GTP6.D (GTP-U -> SRv6) -> VPP end.m.gtp6.e (SRv6 -> GTP-U)
│   ├── vpp_interop_end_m_gtp6_e.sh      -- VPP end.m.gtp6.d drop-in (GTP-U -> SRv6) -> Linux End.M.GTP6.E (SRv6 -> GTP-U)
│   ├── vpp_interop_end_m_gtp6_d_di.sh   -- Linux End.M.GTP6.D.Di (GTP-U -> SRv6 inline) -> VPP End (RFC 8986 transit)
│   ├── frr_only_segment/                -- pe1 (FRR) `segment interwork|direct` -> pe2 (FRR), no external MUP-C
│   │   ├── frr_only_segment.sh
│   │   ├── pe1/{zebra.conf,bgpd.conf}
│   │   └── pe2/{zebra.conf,bgpd.conf}
│   ├── frr_interop_mup/                 -- gobgpd -> pe1 (FRR) -> pe2 (FRR), 3-router BGP-MUP control-plane interop
│   │   ├── frr_interop_mup.sh
│   │   ├── pe1/{zebra.conf,bgpd.conf}
│   │   ├── pe2/{zebra.conf,bgpd.conf}
│   │   └── gbgp/gobgpd.toml
│   ├── frr_mup_e2e_gobgp_scapy/         -- gobgpd (MUP-C) + pe1/gw1 (FRR) + scapy gNB, full E2E (DL + UL)
│   │   ├── frr_mup_e2e_gobgp_scapy.sh
│   │   ├── pe1/{zebra.conf,bgpd.conf}
│   │   ├── gw1/{zebra.conf,bgpd.conf}
│   │   └── gbgp/gobgpd.toml
│   └── build_tarball.sh                 -- rebuild ~/srv6-mup-bundle.tar.gz from sibling linux/ + iproute2/
├── pcaps/                     -- merged pcaps from a recent run
│   │                              (test ingress + SR-domain wire + test egress)
│   └── nlmon/                 -- reference rtnetlink captures of zebra
│                                 vs. iproute2 SID programming
└── logs/                      -- runtime logs (.gitignore'd)
```

The harness assumes a sibling layout — `linux/`, `iproute2/`, `frr/`,
and `srv6-mup-tests/` all under the same parent directory.  Scripts
derive paths from `$0` so any parent location works.

The RFC 9433 action-name mnemonic refers to the **GTP-U** header, not
the SRv6 header: **D** suffix means GTP-U **D**ecap (output is SRv6),
**E** suffix means GTP-U **E**ncap (output is GTP-U from SRv6).  This
is the *opposite* of the SR-domain-side encap/decap reading.

## Quick start

The fastest way to a working test bench is to install the prebuilt
bundle from [Releases](https://github.com/higebu/srv6-mup-tests/releases),
then clone this repo and run the harnesses.  See "Bundle install"
below.

### Prerequisites

For running the harnesses (all paths):

- `virtme-ng` — `pip install --user virtme-ng` or `apt install virtme-ng`
- `python3-scapy`, `tcpdump`, `wireshark-common` (for `mergecap` and
  `tshark`)
- For the VPP interop path: VPP 25.10 + `vpp-plugin-core` from the FDio
  `2510` packagecloud repo (see [`docs/vpp-interop.md`](docs/vpp-interop.md))
- For the FRR harnesses: a built `frr/` sibling, plus the patched
  `gobgp/gobgpd` under `.bin/` for the `frr_interop_mup.sh` and
  `frr_mup_e2e_gobgp_scapy.sh` scenarios

For source-built kernels / iproute2 / FRR, build the three siblings
first:

1. **Linux** at `<parent>/linux` (branch `b4/seg6-mobile`).
   `make -j$(nproc) bzImage` succeeded; `kernel.release` looks like
   `7.1.0-rc1-srv6-mup-...`.
2. **iproute2** at `<parent>/iproute2` (branch `b4/seg6-mobile`).
   `make -j$(nproc)` succeeded; `./ip/ip route help` shows the MUP
   actions.
3. **FRR** at `<parent>/frr` (branch `seg6-mobile`).  Built per the
   FRR developer docs, or installed from the bundle below.

### Bundle install (Ubuntu 24.04 LTS)

Prebuilt `.deb` artifacts are attached to each
[GitHub Release](https://github.com/higebu/srv6-mup-tests/releases)
(kernel + iproute2 + FRR).  See the release notes for the exact
versions and the `libyang2` repo step needed for FRR.  In short:

```bash
mkdir bundle && cd bundle
gh release download bundle-v27 --repo higebu/srv6-mup-tests
# kernel + iproute2
sudo apt-get install -y ./linux-*.deb ./iproute2*.deb
# FRR (after adding the FRR apt repo for libyang2 >= 2.1.128)
sudo apt-get install -y ./frr*.deb
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 7.1.0-rc1-srv6-mup-..."
sudo reboot
```

`scripts/build_tarball.sh` rebuilds `~/srv6-mup-bundle.tar.gz` from
the siblings; see [`docs/build-tarball.md`](docs/build-tarball.md).

### Run the kernel selftests

See [`docs/selftests.md`](docs/selftests.md) for the full walk-through.
TL;DR:

```bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)   # parent of linux/ iproute2/ frr/ srv6-mup-tests/

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
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
rm -f $PCAP_DIR/*.pcap

for s in vpp_interop_h_m_gtp4_d.sh \
         vpp_interop_end_m_gtp4_e.sh \
         vpp_interop_end_m_gtp6_d.sh \
         vpp_interop_end_m_gtp6_e.sh \
         vpp_interop_end_m_gtp6_d_di.sh; do
  script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
    --run $ROOT/linux --user root \
    -- env PCAP_OUT=$PCAP_DIR \
    $ROOT/srv6-mup-tests/scripts/$s" \
    /tmp/run-$s.log >/dev/null 2>&1
  grep -E 'VPP-INTEROP' /tmp/run-$s.log | tail -1
done
```

Expected:

```
===VPP-INTEROP-H_M_GTP4_D=== PASS
===VPP-INTEROP-END_M_GTP4_E=== PASS
===VPP-INTEROP-END_M_GTP6_D=== PASS
===VPP-INTEROP-END_M_GTP6_E=== PASS
===VPP-INTEROP-END_M_GTP6_D_DI=== PASS
```

### Run the FRR BGP-MUP harnesses

Three scenarios, increasing in scope:

```bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 1. FRR-only originate (no external MUP-Controller)
script -q -c "vng -m 4G --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/scripts/frr_only_segment/frr_only_segment.sh" /tmp/frr-only.log
grep -E 'FRR-ONLY-SEGMENT' /tmp/frr-only.log

# 2. gobgpd <-> FRR <-> FRR control-plane interop
script -q -c "vng -m 4G --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/scripts/frr_interop_mup/frr_interop_mup.sh" /tmp/frr-interop.log
grep -E 'FRR-INTEROP' /tmp/frr-interop.log

# 3. Full E2E (gobgpd MUP-C + FRR PE/GW + scapy gNB), DL + UL
script -q -c "vng -m 4G --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/scripts/frr_mup_e2e_gobgp_scapy/frr_mup_e2e_gobgp_scapy.sh" /tmp/frr-e2e.log
grep -E 'E2E' /tmp/frr-e2e.log
```

`frr_interop_mup.sh` and `frr_mup_e2e_gobgp_scapy.sh` need the patched
`gobgp/gobgpd` binaries dropped under `.bin/` (gitignore'd; see the
script preambles for build pointers).

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

| Script | Linux side | VPP side |
|---|---|---|
| `vpp_interop_h_m_gtp4_d.sh` | H.M.GTP4.D §6.7 (GTP-U → SRv6) | end.m.gtp4.e §6.6 (SRv6 → GTP-U) |
| `vpp_interop_end_m_gtp4_e.sh` | End.M.GTP4.E §6.6 (SRv6 → GTP-U) | sr policy + plain encap (IPv4 → SRv6) |
| `vpp_interop_end_m_gtp6_d.sh` | End.M.GTP6.D §6.3 + §6.5 Note (GTP-U → SRv6) | end.m.gtp6.e §6.5 (SRv6 → GTP-U) |
| `vpp_interop_end_m_gtp6_e.sh` | End.M.GTP6.E §6.5 (SRv6 → GTP-U) | end.m.gtp6.d drop-in §6.3 (GTP-U → SRv6) |
| `vpp_interop_end_m_gtp6_d_di.sh` | End.M.GTP6.D.Di §6.4 (GTP-U → SRv6) | End (RFC 8986 transit) |

End.MAP (§6.2) and End.Limit (§6.8) cannot be exercised against VPP
because the VPP `srv6-mobile` plugin (Arrcus contribution) does not
implement either; they are covered by the kernel selftests only.

### FRR BGP-MUP harnesses (draft-ietf-bess-mup-safi)

| Script | Topology | Asserts |
|---|---|---|
| `frr_only_segment.sh` | pe1 (FRR) ↔ pe2 (FRR) | ISD/DSD origination, propagation, Prefix-SID round-trip, `show running-config` re-emit, `no segment` cleanup |
| `frr_interop_mup.sh` | gbgp (gobgpd) → pe1 (FRR) → pe2 (FRR) | All four MUP route types (ISD/DSD/T1ST/T2ST) re-advertised end-to-end; pe2 kernel installs `End.M.GTP4.E` / `End.M.GTP6.E` seg6local routes |
| `frr_mup_e2e_gobgp_scapy.sh` | gnb (scapy) ↔ gw1 (FRR MUP-GW) ↔ pe1 (FRR MUP-PE) ↔ dn, with gobgpd MUP-Controller | DL: dn → pe1 (H.Encaps) → gw1 (End.M.GTP4.E synth) → gnb sees expected GTP-U PDU.  UL: gnb (scapy GTP-U) → gw1 (H.M.GTP4.D synth) → pe1 (End.DT4 decap) → dn |

## References

- RFC 9433 (SRv6 Mobile User Plane) — <https://www.rfc-editor.org/rfc/rfc9433>
- draft-ietf-bess-mup-safi (BGP MUP SAFI) —
  <https://datatracker.ietf.org/doc/draft-ietf-bess-mup-safi/>
- VPP `srv6-mobile` plugin — `~/vpp/src/plugins/srv6-mobile/`
- Prebuilt `.deb` artifacts —
  [GitHub Releases](https://github.com/higebu/srv6-mup-tests/releases)
  (kernel + iproute2 + FRR for Ubuntu 24.04 LTS)
