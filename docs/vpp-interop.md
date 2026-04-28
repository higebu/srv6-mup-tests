# Running the VPP interop tests

`scripts/vpp_interop_*.sh` (5 scripts) bring up VPP and the Linux kernel
inside the same vng VM and connect the SR-domain via veth pairs. Each
script exercises one Linux MUP behavior end-to-end against the FD.io VPP
25.10 `srv6-mobile` plugin (Arrcus contribution).

## Prerequisites

On the host:

- VPP 25.10 from the FDio packagecloud repo:
  ```
  curl -sL https://packagecloud.io/fdio/2510/gpgkey | \
      sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/fdio-2510.gpg
  echo "deb https://packagecloud.io/fdio/2510/debian bookworm main" | \
      sudo tee /etc/apt/sources.list.d/fdio-2510.list
  sudo apt-get update
  sudo apt-get install -y vpp vpp-plugin-core
  ```
  (the `bookworm` suite tag is for Debian 12 hosts; Ubuntu 24.04 LTS
  hosts should use `noble` instead)
- `pip install --user virtme-ng` or `apt install virtme-ng`
- `apt install python3-scapy tcpdump wireshark-common`
  (mergecap / tshark)

Source trees:

- `~/ghq/github.com/higebu/linux` — built (`make -j$(nproc) bzImage`).
- `~/ghq/github.com/higebu/iproute2` — built (`make -j$(nproc)`).

## Run all five scenarios

```bash
PCAP_DIR=/home/yuya/ghq/github.com/higebu/srv6-mup-tests/pcaps
rm -f $PCAP_DIR/*.pcap

for s in vpp_interop_h_m_gtp4_d.sh \
         vpp_interop_end_m_gtp4_e.sh \
         vpp_interop_end_m_gtp6_d.sh \
         vpp_interop_end_m_gtp6_e.sh \
         vpp_interop_end_m_gtp6_d_di.sh; do
  for try in 1 2; do
    script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
      --run /home/yuya/ghq/github.com/higebu/linux --user root \
      -- env PCAP_OUT=$PCAP_DIR \
         /home/yuya/ghq/github.com/higebu/srv6-mup-tests/scripts/$s" \
      /tmp/run-$s.log >/dev/null 2>&1
    if grep -q 'VPP-INTEROP' /tmp/run-$s.log; then break; fi
  done
  echo "== $s =="
  grep -E 'VPP-INTEROP' /tmp/run-$s.log | tail -1
done

ls -la $PCAP_DIR/
```

The `for try in 1 2` retry guards against the (rare) `vng` exit-255
startup glitch when several VMs are spawned back-to-back.

## Expected output

```
== vpp_interop_h_m_gtp4_d.sh ==
===VPP-INTEROP-H_M_GTP4_D=== PASS
== vpp_interop_end_m_gtp4_e.sh ==
===VPP-INTEROP-END_M_GTP4_E=== PASS
== vpp_interop_end_m_gtp6_d.sh ==
===VPP-INTEROP-END_M_GTP6_D=== PASS
== vpp_interop_end_m_gtp6_e.sh ==
===VPP-INTEROP-END_M_GTP6_E=== PASS
== vpp_interop_end_m_gtp6_d_di.sh ==
===VPP-INTEROP-END_M_GTP6_D_DI=== PASS
```

On success, each scenario writes a single merged pcap into `$PCAP_DIR`
that contains the three capture points (test ingress, SR-domain wire,
test egress) in time order — `mergecap`-joined inside the script.
The 3GPP role each end plays (gNB / MUP-PE upstream peer) depends on
the scenario direction; see [`topology.md`](topology.md).

## Run a single scenario with full output

```bash
PCAP_DIR=/home/yuya/ghq/github.com/higebu/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run /home/yuya/ghq/github.com/higebu/linux --user root \
  -- env PCAP_OUT=$PCAP_DIR \
     /home/yuya/ghq/github.com/higebu/srv6-mup-tests/scripts/vpp_interop_end_m_gtp6_d.sh" \
  /tmp/single.log
less /tmp/single.log                         # VPP trace / errors / verify
tshark -V -r $PCAP_DIR/end_m_gtp6_d.pcap     # full packet dissection
```

## Why each option is needed

- **`--rwdir=$PCAP_DIR`** — vng exposes the host filesystem read-only;
  `--rwdir` makes the given path writable in the guest. The script
  copies `/tmp/merged.pcap` to `$PCAP_OUT` (= the rwdir path) so the
  pcap survives after the VM exits.
- **`-m 4G`** — VPP's default config reserves ~1 GB for its main heap;
  with less than ~3 GB of guest RAM you hit
  `Main heap allocation failure!` at start-up.
- **`set -e`** at the top of every script — fail fast on any unexpected
  command exit.
- **`mount -t tmpfs tmpfs /tmp`** — VPP wants to write
  `/tmp/vpp/startup.conf`, `/run/vpp/cli.sock`, etc.; the guest `/tmp`
  is read-only otherwise.
- **`export PATH=.../iproute2/ip:$PATH`** — pick up the patched iproute2
  with MUP keywords.

## Per-script topology

See [`topology.md`](topology.md) for ASCII diagrams. Summary:

### Linux ingress (Linux side encap)

`vpp_interop_h_m_gtp4_d.sh`, `vpp_interop_end_m_gtp6_d.sh`,
`vpp_interop_end_m_gtp6_d_di.sh`:

```
[gnb netns]
   |  veth-g  (in gnb) <-> veth-g-srgw (in srgw)
[srgw netns]   <-- Linux SRv6 MUP encap behavior
   |  veth-e  (in srgw) <-> veth-e-vpp (in root)
[root ns / VPP] <-- VPP decap behavior
   |  veth-f-dn (in dn) <-> veth-f (in root)
[dn netns]
```

### Linux egress (Linux side decap)

`vpp_interop_end_m_gtp4_e.sh`, `vpp_interop_end_m_gtp6_e.sh`:

```
[gnb netns]
   |  veth-g-gnb <-> veth-g
[root ns / VPP]   <-- VPP encap behavior
   |  veth-e-vpp <-> veth-e
[srgw netns]      <-- Linux SRv6 MUP decap behavior
   |  veth-x <-> veth-x-dn
[dn netns]
```

## VPP commands used by each script

| Script | VPP configuration |
|---|---|
| `vpp_interop_h_m_gtp4_d.sh` | `sr localsid prefix 2001:db8:f::/56 behavior end.m.gtp4.e v4src_position 96 fib-table 0` |
| `vpp_interop_end_m_gtp4_e.sh` | `sr policy add bsid 2001:db8:5::1 next 2001:db8:f::a:6300:214:0:123 encap` + `sr steer l3 10.99.0.0/24 via bsid 2001:db8:5::1` |
| `vpp_interop_end_m_gtp6_d.sh` | `sr localsid prefix 2001:db8:e::/88 behavior end.m.gtp6.e fib-table 0` |
| `vpp_interop_end_m_gtp6_e.sh` | `sr localsid prefix 2001:db8:6::/64 behavior end.m.gtp6.d 2001:db8:f::/88 nh-type ipv6 fib-table 0 drop-in` |
| `vpp_interop_end_m_gtp6_d_di.sh` | `sr localsid address 2001:db8:e::1 behavior end` (RFC 8986 plain End) |

## Troubleshooting

### VPP fails to start

- Inspect `/tmp/vpp/stdout.log` inside the VM. `Main heap allocation
  failure!` means `-m` is too small; bump it to `-m 4G` or higher.
- `srv6mobile_plugin.so not found` — install `vpp-plugin-core` on the
  host.

### `Invalid behavior` from `vppctl`

VPP's per-plugin behavior `unformat()` callbacks consume input until
EOF or an unknown token. If `encap` follows `behavior <name> ...` on the
same CLI line, the plugin's parser sees `encap` as an unknown token and
returns 0; the outer parser then prints `sr policy: Invalid behavior`.
Put `encap` *before* `behavior` so the outer parser eats it first.

### Manual neighbor entries

veth pairs do not auto-resolve ARP/ND across the host/netns boundary
reliably enough for these tests. All scripts install static
`ip neigh`/`vppctl set ip neighbor` entries before traffic. When VPP is
on one end, take the MAC from `vppctl show hardware-interfaces ...`
(VPP's af-packet MAC may differ from the kernel veth MAC).

### `Length: 40 (Malformed)` warnings on the gnb-side capture

This was the symptom of a hard-coded, off-by-four GTP-U `Length` field
in the scapy crafting code; fixed and squashed into the patches that
introduce each affected selftest. If you craft your own GTP-U packets,
remember `Length = 4 (long-opts) + 4 (PSC) + len(inner T-PDU)`.

## Known limitations

- **VPP `t.m.gtp4.d`** (the VPP-side equivalent of RFC §6.7 H.M.GTP4.D)
  does not chain through to the SRv6 encap node when activated via
  `sr policy add ... behavior t.m.gtp4.d ...` on VPP 25.10 / FDio
  master (2026-04-20); it returns "T.M.GTP4.D bad packets" without
  emitting an SRv6 packet. The `vpp_interop_end_m_gtp4_e.sh` scenario
  works around this by using a plain `sr policy ... next ... encap`,
  which simply wraps the entire incoming IPv4/UDP/GTP-U datagram inside
  SRv6. As a side-effect the egress pcap shows a doubled GTP-U header
  (Linux End.M.GTP4.E re-encapsulates the inner — which is itself a
  GTP-U from the gNB — into a fresh GTP-U whose TEID/QFI come from the
  SID's `Args.Mob.Session`). The verification checks only the outer
  TEID, which is sufficient to prove that Linux End.M.GTP4.E is
  decoding the SID correctly.

- **End.MAP (§6.2)** and **End.Limit (§6.8)** are not implemented in the
  VPP `srv6-mobile` plugin, so they are exercised by the kernel
  selftests only.
