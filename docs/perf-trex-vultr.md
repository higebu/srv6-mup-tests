# SRv6 (incl. RFC 9433 MUP) performance benchmarking on Vultr

End-to-end runbook for driving an [SRPerf](https://github.com/higebu/SRPerf)
based PDR@0.5% / MRR sweep against the seg6 mobile uplane datapath, on
a 2-node Vultr bare-metal testbed connected by a free VPC 2.0 L2
network.

## Topology

```
   +------------------+               +------------------+
   |  Vultr Bare      |  VPC 2.0      |  Vultr Bare      |
   |  Metal (tester)  |  (free L2)    |  Metal (SUT)     |
   |                  |   tx port     |                  |
   |  T-Rex stateless |==============>| enp6s0f0 (rcv)   |
   |  PDR/MRR client  |   rx port     |                  |
   |  + SRPerf orch   |<==============| enp6s0f0 (snd)*  |
   +--------+---------+               +--------+---------+
            |  public NIC (mgmt + SSH from local)  |
            v                                       v
        Internet                               Internet
```

`*` -- This deployment runs the SUT's RX and TX sides through a single
physical VPC NIC.  The SRPerf "two-NIC b2b" pattern is preserved
logically by configuring an additional `enp6s0f1` dummy interface
inside the SUT OS so `forwarding-behaviour.cfg`'s 2-NIC variable layout
holds.  For absolute-Mpps-per-direction studies, attach a second
distinct VPC 2.0 NIC and skip the dummy.

## Required local artefacts

| Artefact | Path | How to get it |
|---|---|---|
| Vultr API key | `VULTR_API_KEY` env (e.g. in `~/.profile`) | <https://my.vultr.com/settings/#settingsapi> — allowlist your IP |
| `vultr-cli` | `~/go/bin/vultr-cli` | `go install github.com/vultr/vultr-cli/v3@latest` |
| SSH key registered with Vultr | `~/.ssh/id_rsa4096*` | Add public key under <https://my.vultr.com/settings/#settingsssh> |
| Rebuilt kernel/iproute2 debs | `~/srv6-mup-rebuilt-debs/` | Build once on a bare-metal using stock `/boot/config-6.8.0-...` as base (see [§ Rebuilding the deb bundle](#rebuilding-the-deb-bundle)) |
| SRPerf fork | `../SRPerf` (sibling of this repo, branch `srv6-mup-port`) | `git clone https://github.com/higebu/SRPerf.git` |

## End-to-end flow

```bash
# 1. Spin up testbed (~5-10 min)
scripts/perf-trex/provision.sh

# 2. Install the seg6-mup kernel + iproute2 on SUT, reboot, bring up VPC NIC
scripts/perf-trex/install_sut.sh

# 3. Install T-Rex + DPDK on the tester, bind VPC NIC to vfio-pci
scripts/perf-trex/install_trex.sh

# 4. Run a sweep (default: 5 MUP behaviours at min frame size)
PROFILE=mup SIZE=min scripts/perf-trex/run_sweep.sh
# or for the full picture:
PROFILE=all SIZE=all scripts/perf-trex/run_sweep.sh

# 5. Destroy when finished (asks for "DESTROY" confirmation)
scripts/perf-trex/destroy.sh
```

Results land under `~/srv6-mup-trex-results/Linux-<timestamp>.json`
with one entry per `<behaviour>-<rate>` pair.

## Cost

Default plan `vbm-6c-32gb` (Intel Xeon E-2286G, 6c12t @ 4.0 GHz) is
**$0.275/hr** per box in NRT.  A typical session is:

| Phase | Duration | Cost |
|---|---|---|
| Provision + install SUT | 30-45 min | $0.30 |
| Install T-Rex + bind NIC | 10-15 min | $0.13 |
| Run sweep (mup, min)    |  5-10 min | $0.07 |
| Run sweep (all, all)    | 20-30 min | $0.27 |
| **Total** (typical) | **1-2 h** | **$0.55-1.10** |

VPC 2.0 itself is free
(<https://docs.vultr.com/how-to-create-a-vultr-virtual-private-cloud-2-0>:
*"Vultr does not bill for VPC 2.0 bandwidth"*).

## Address plan

Static, mirroring `SRPerf/sut/linux/forwarding-behaviour.cfg`.  These
values can be overridden via the env knobs in
`scripts/perf-trex/lib.sh`.

| Role | IPv4 | IPv6 |
|---|---|---|
| Tester tx side (`TG_TX_*`)              | `10.10.1.1`  | `12:1::1` |
| SUT receive (`SUT_RCV_*`)               | `10.10.1.2/24` | `12:1::2/64` |
| SUT send    (`SUT_SND_*`)               | `10.10.2.2/24` | `12:2::2/64` |
| Tester rx side (`TG_RCV_*`)             | `10.10.2.1`  | `12:2::1` |
| Plain v4/v6 traffic dst                  | `48.0.0.2`   | `b::2`    |
| Classic SRv6 SIDs                        | -            | `f1::`, `f2::` |
| MUP IPv4 locator                         | -            | `2001:db8::/32` |
| MUP IPv6 locator                         | -            | `2001:db8:f::/64` |
| H.M.GTP4.D outer match                   | `10.99.0.0/24` | -       |

## Rebuilding the deb bundle

The `~/srv6-mup-bundle.tar.gz` shipped from the
[srv6-mup-tests](https://github.com/higebu/srv6-mup-tests) builds
work-loop debs against a *minimal* kernel `.config` -- great for vng,
but it does not include the `ixgbe` / `i40e` / `ice` NIC drivers Vultr
bare-metal needs to come back online after reboot.

Rebuild once against the Ubuntu stock config as base:

```bash
# On a freshly-provisioned bare-metal (e.g. the test session itself):
sudo apt-get install -y build-essential bc bison flex libelf-dev \
    libssl-dev libncurses-dev rsync kmod fakeroot dwarves cpio git \
    debhelper devscripts pkg-config libdw-dev
git clone --depth 1 --branch b4/seg6-mobile https://github.com/higebu/linux.git
cd linux
cp /boot/config-$(uname -r) .config
scripts/config --disable CONFIG_MODULE_SIG_ALL \
               --set-str CONFIG_SYSTEM_TRUSTED_KEYS    "" \
               --set-str CONFIG_SYSTEM_REVOCATION_KEYS "" \
               --disable DEBUG_INFO_BTF
yes "" | make olddefconfig
make -j$(nproc) bindeb-pkg KDEB_PKGVERSION=7.0.0-srv6mup-NN
scp ../linux-image-*srv6mup-NN_amd64.deb \
    ../linux-headers-*srv6mup-NN_amd64.deb \
    ../linux-libc-dev_*srv6mup-NN_amd64.deb  \
    yuya@<local>:~/srv6-mup-rebuilt-debs/
```

This takes ~30 min on the `vbm-6c-32gb` plan.  Once you have the
rebuilt debs locally, `install_sut.sh` re-uses them for every
subsequent session in ~3 min.

## Troubleshooting

### SUT does not come back from reboot

The default seg6-mup kernel config (when built from a minimal
`.config`) lacks Vultr's NIC drivers.  Symptom: SUPERMICRO POST logo,
no SSH after 5+ minutes.  Fix: use the **rebuilt** debs from
`~/srv6-mup-rebuilt-debs/` (see above).  If you already triggered this
state, [Vultr Web Console] -> bare-metal -> View Console gives serial /
KVM access; pick the stock 6.8.0 kernel from GRUB advanced options.

### `tcpreplay`-style 138 kpps ceiling under veth

If you skip T-Rex and try to drive the SUT from a userspace `sendto`
loop on the same box, the per-packet syscall cost caps you well below
the kernel forwarding ceiling.  Use T-Rex on the dedicated tester
bare-metal -- it bypasses the syscall path entirely.

### `End.DT4` returns DR ≈ 0 with `vrf-dt4 RX` non-zero

Known issue, see `srv6-mup-tests` [issue/task #20](../../scripts/perf/README.md).
On bare-metal the inner IPv4 packet after decap is not delivered to
the IPv4 stack (`Ip InReceives = 0`).  Workaround: skip `end_dt4`; the
End.DT6 v6 counterpart works correctly.

## See also

- [SRPerf upstream](https://github.com/SRouting/SRPerf) — parent project
- [SRPerf fork](https://github.com/higebu/SRPerf) (branch `srv6-mup-port`) — Python 3 / RFC 9433 additions used here
- [SRPerf paper](https://arxiv.org/pdf/2001.06182) — methodology
- [RFC 9433](https://www.rfc-editor.org/rfc/rfc9433.txt) — SRv6 Mobile User Plane
- [Vultr VPC 2.0 docs](https://docs.vultr.com/how-to-create-a-vultr-virtual-private-cloud-2-0)
