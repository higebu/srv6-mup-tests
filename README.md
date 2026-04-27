# srv6-mup-tests

Test harness for the Linux SRv6 Mobile User Plane (RFC 9433) implementation:

- Linux kernel patch series: <https://github.com/higebu/linux/tree/srv6-mup>
- iproute2 patch series:     <https://github.com/higebu/iproute2/tree/srv6-mup>

This repo holds:

1. Pointers and instructions for running the in-tree kernel selftests
   (`tools/testing/selftests/net/srv6_*_test.sh`) under
   [virtme-ng](https://github.com/arighi/virtme-ng).
2. Five VPP 25.10 interop scenarios (one per Linux MUP behavior under
   test), with merged pcaps captured at three points along the path
   (`gNB ingress`, `SR-domain wire`, `egress`).

## Layout

```
srv6-mup-tests/
├── README.md                  -- this file
├── docs/
│   ├── selftests.md           -- how to run the kernel selftests under vng
│   ├── vpp-interop.md         -- how to run the 5 VPP interop scenarios
│   ├── topology.md            -- per-scenario netns + veth topology
│   └── build-tarball.md       -- how to rebuild the CML2-distribution tarball
├── scripts/                   -- VPP interop scripts, named after the
│   │                              Linux behavior under test (1:1 with
│   │                              the in-tree kernel selftests)
│   ├── vpp_interop_h_m_gtp4_d.sh        -- Linux H.M.GTP4.D    ↔ VPP end.m.gtp4.e
│   ├── vpp_interop_end_m_gtp4_e.sh      -- Linux End.M.GTP4.E  ↔ VPP sr policy + plain encap
│   ├── vpp_interop_end_m_gtp6_d.sh      -- Linux End.M.GTP6.D  ↔ VPP end.m.gtp6.e
│   ├── vpp_interop_end_m_gtp6_e.sh      -- Linux End.M.GTP6.E  ↔ VPP end.m.gtp6.d (drop-in)
│   └── vpp_interop_end_m_gtp6_d_di.sh   -- Linux End.M.GTP6.D.Di ↔ VPP End (RFC 8986)
├── pcaps/                     -- merged pcaps from a recent run
│                                 (input + SR-domain wire + egress)
└── logs/                      -- runtime logs (.gitignore'd)
```

## Quick start

### Prerequisites

1. The `srv6-mup` Linux kernel built at `~/ghq/github.com/higebu/linux`
   (`make -j$(nproc) bzImage` succeeded; kernel.release starts with
   `7.0.0-srv6-mup-...`).
2. The `srv6-mup` iproute2 built at `~/ghq/github.com/higebu/iproute2`
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
script -q -c "vng -m 4G --run /home/yuya/ghq/github.com/higebu/linux --user root \
  -- bash -c 'mount -t tmpfs tmpfs /tmp; \
              export PATH=/home/yuya/ghq/github.com/higebu/iproute2/ip:\$PATH; \
              cd /home/yuya/ghq/github.com/higebu/linux/tools/testing/selftests/net && \
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
PCAP_DIR=/home/yuya/ghq/github.com/higebu/srv6-mup-tests/pcaps
rm -f $PCAP_DIR/*.pcap

for s in vpp_interop_h_m_gtp4_d.sh \
         vpp_interop_end_m_gtp4_e.sh \
         vpp_interop_end_m_gtp6_d.sh \
         vpp_interop_end_m_gtp6_e.sh \
         vpp_interop_end_m_gtp6_d_di.sh; do
  script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
    --run /home/yuya/ghq/github.com/higebu/linux --user root \
    -- env PCAP_OUT=$PCAP_DIR \
    /home/yuya/ghq/github.com/higebu/srv6-mup-tests/scripts/$s" \
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

| Script | Linux side | VPP side |
|---|---|---|
| `vpp_interop_h_m_gtp4_d.sh` | H.M.GTP4.D (encap, §6.7) | end.m.gtp4.e (decap, §6.6) |
| `vpp_interop_end_m_gtp4_e.sh` | End.M.GTP4.E (decap, §6.6) | sr policy + plain encap |
| `vpp_interop_end_m_gtp6_d.sh` | End.M.GTP6.D (encap, §6.3 + §6.5 Note) | end.m.gtp6.e (decap, §6.5) |
| `vpp_interop_end_m_gtp6_e.sh` | End.M.GTP6.E (decap, §6.5) | end.m.gtp6.d drop-in (encap, §6.3) |
| `vpp_interop_end_m_gtp6_d_di.sh` | End.M.GTP6.D.Di (encap, §6.4) | End (RFC 8986) |

End.MAP (§6.2) and End.Limit (§6.8) cannot be exercised against VPP
because the VPP `srv6-mobile` plugin (Arrcus contribution) does not
implement either; they are covered by the kernel selftests only.

## References

- RFC 9433 — <https://www.rfc-editor.org/rfc/rfc9433>
- VPP `srv6-mobile` plugin — `~/vpp/src/plugins/srv6-mobile/`
- CML2 distribution tarball (kernel + iproute2 .deb's + selftests) —
  `~/srv6-mup-cml2.tar.gz` (rebuild with
  [`scripts/build_cml2_tarball.sh`](scripts/build_cml2_tarball.sh);
  see [`docs/build-tarball.md`](docs/build-tarball.md) for the full
  procedure)
