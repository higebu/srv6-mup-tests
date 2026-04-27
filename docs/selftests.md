# Running the kernel selftests

`tools/testing/selftests/net/srv6_*_test.sh` covers all six RFC 9433
behaviors (§6.2–§6.7) implemented in the `srv6-mup` kernel branch. Each
selftest is **self-contained** (`ip netns` + veth + scapy + tcpdump);
no VPP is required.

## Prerequisites

- Linux source: `~/ghq/github.com/higebu/linux` built (`make -j$(nproc) bzImage`).
- iproute2 source: `~/ghq/github.com/higebu/iproute2` built (`make -j$(nproc)`).
- On the host: `vng` (virtme-ng), `python3-scapy`, `tcpdump`.

## Run all six in one VM session

```bash
script -q -c "vng -m 4G --run /home/yuya/ghq/github.com/higebu/linux --user root -- bash -c '
  mount -t tmpfs tmpfs /tmp
  export PATH=/home/yuya/ghq/github.com/higebu/iproute2/ip:\$PATH
  cd /home/yuya/ghq/github.com/higebu/linux/tools/testing/selftests/net
  for t in srv6_end_m_gtp4_e_test.sh \
           srv6_end_m_gtp6_d_test.sh \
           srv6_end_m_gtp6_d_di_test.sh \
           srv6_end_m_gtp6_e_test.sh \
           srv6_end_map_test.sh \
           srv6_h_m_gtp4_d_test.sh; do
    echo \"== \$t ==\"
    bash \$t
  done'" /tmp/selftests.log
grep -E '^==|TEST:' /tmp/selftests.log
```

## Why each option is needed

- **`script -q -c "..."`** — `vng --run` puts the inner command's
  stdout/stderr on the VM console, which is not visible from the host
  by default. `script(1)` captures the full console stream into a log
  file.
- **`vng -m 4G`** — kselftest defaults work in 1 GB, but we share this
  invocation with the VPP interop tests (which need ~3 GB), so 4 GB is
  used everywhere for consistency.
- **`vng --run /home/yuya/ghq/github.com/higebu/linux`** — pass the
  freshly-built `bzImage` (and the matching `mods/`) of the `srv6-mup`
  branch instead of the host's installed kernel.
- **`--user root`** — selftests use `setup_ns`, which needs
  `CAP_NET_ADMIN`.
- **`mount -t tmpfs tmpfs /tmp`** — vng's `/tmp` is read-only unless
  passed via `--overlay-rwdir`. Selftests `mktemp` pcap/scratch files
  there, so we lay a tmpfs over it.
- **`export PATH=.../iproute2/ip:$PATH`** — use the patched iproute2.
  Stock Debian/Ubuntu iproute2 does not know the MUP keywords and fails
  the `ip route ... encap seg6local action End.M.GTP6.D ...` setup line
  with `Error: argument "End.M.GTP6.D" is wrong: "action" value is invalid`.
- **`cd .../tools/testing/selftests/net`** — every selftest does
  `source lib.sh` at the top, which is path-relative. Running from
  another directory makes the source fail and the rest of the script
  emits cascade errors (`cleanup_all_ns: command not found`,
  `exit: : numeric argument required`).

## Expected output

```
== srv6_end_m_gtp4_e_test.sh ==
TEST: End.M.GTP4.E [PASS]
== srv6_end_m_gtp6_d_test.sh ==
TEST: End.M.GTP6.D [PASS]
== srv6_end_m_gtp6_d_di_test.sh ==
TEST: End.M.GTP6.D.Di [PASS]
== srv6_end_m_gtp6_e_test.sh ==
TEST: End.M.GTP6.E [PASS]
== srv6_end_map_test.sh ==
TEST: End.MAP [PASS]
== srv6_h_m_gtp4_d_test.sh ==
TEST: H.M.GTP4.D [PASS]
```

## Running a single selftest with a shell trace

```bash
script -q -c "vng -m 4G --run /home/yuya/ghq/github.com/higebu/linux --user root -- bash -c '
  mount -t tmpfs tmpfs /tmp
  export PATH=/home/yuya/ghq/github.com/higebu/iproute2/ip:\$PATH
  cd /home/yuya/ghq/github.com/higebu/linux/tools/testing/selftests/net
  bash -x srv6_end_m_gtp6_d_test.sh'" /tmp/sft-debug.log
less /tmp/sft-debug.log
```

## What each selftest verifies

| Selftest | What it asserts |
|---|---|
| `srv6_end_map_test.sh` | The configured `nh6` SID overwrites the outer DA; the SRH is left untouched. |
| `srv6_end_m_gtp6_d_test.sh` | IPv6/UDP/GTP-U → SRv6. Wire SRH is `[D, E2E SID + Args.Mob.Session]`, i.e. the End.M.GTP6.E SID lives at the **penultimate** position (RFC 9433 §6.5 Note). |
| `srv6_end_m_gtp6_d_di_test.sh` | IPv6/UDP/GTP-U → SRv6. The original outer DA is preserved as the last segment in transit (= wire `SRH[0]`); the GTP-U TEID is intentionally dropped (drop-in semantics). |
| `srv6_end_m_gtp6_e_test.sh` | SRv6 → IPv6/UDP/GTP-U. `Args.Mob.Session` is extracted from the active SID (the outer DA at SL=1); the new GTP-U outer DA is `SRH[0]`. |
| `srv6_end_m_gtp4_e_test.sh` | SRv6 → IPv4/UDP/GTP-U. The IPv4 DA is recovered from the `v4mask`-aligned slice of the SID, and the IPv4 SA from the same slice of the IPv6 SA. |
| `srv6_h_m_gtp4_d_test.sh` | IPv4/UDP/GTP-U → SRv6 (headend). The constructed SID is `locator | IPv4 DA | Args.Mob.Session`. |

## Troubleshooting

- **`grep -B 2 -A 10 'FAIL' /tmp/selftests.log`** to pinpoint the failing
  step.
- Re-run the failing selftest with `bash -x` (see "Running a single
  selftest with a shell trace") to see which assertion blew up.
- For scapy verification failures, dump the captured pcap as a sanity
  check:
  ```python
  from scapy.all import rdpcap, hexdump
  for p in rdpcap('/tmp/some.pcap'):
      hexdump(p)
      print()
  ```
- If iproute2 says `Error: argument "End.M.GTP6.D" is wrong: "action"
  value is invalid`, the host's stock iproute2 is being picked up
  instead of the patched build at `~/ghq/github.com/higebu/iproute2/ip`.
  Check `which ip` inside the vng VM and adjust `PATH` accordingly.
