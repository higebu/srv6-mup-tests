# Cutting an `srv6-mup-tests` bundle release

A "bundle release" on
[higebu/srv6-mup-tests](https://github.com/higebu/srv6-mup-tests/releases)
ships three independently-versioned components built for Ubuntu 26.04 LTS
(resolute) as the seg6-mobile reference stack:

| Component | Source branch | Build version |
|-----------|---------------|---------------|
| Linux kernel | [`higebu/linux seg6-mobile`](https://github.com/higebu/linux/tree/seg6-mobile)       | `7.1.0-srv6mup-NN` |
| iproute2     | [`higebu/iproute2 seg6-mobile`](https://github.com/higebu/iproute2/tree/seg6-mobile) | `7.0.0-srv6mupMM`  |
| FRR          | [`higebu/frr bgp-mup-safi-originate`](https://github.com/higebu/frr/tree/bgp-mup-safi-originate) | `10.8.0~dev+srv6mupP-0ubuntu1~resolute1` |

Ubuntu 24.04 cannot use these: 26.04 dropped `libyang2` and the FRR debs
link against `libyang3`.  v41 is the last 24.04 bundle.

`NN`, `MM`, `P` increment **independently** — bumping one does not
require rebuilding the others.  The release tag is the bundle number
itself: `vNN` (the kernel tag).

## Staging directory

All artifacts land in `/tmp/srv6-mup-release/` before being uploaded.
Reusing the directory across rebuilds lets you bump just the changed
component(s); the previous bundle's untouched debs remain available for
the next release.

```
/tmp/srv6-mup-release/
├── bzImage-7.1.0-rc1-srv6-mup-...                           # kernel
├── linux-image-...-srv6mup-NN_amd64.deb                     # kernel
├── linux-headers-...-srv6mup-NN_amd64.deb                   # kernel
├── linux-libc-dev_...-srv6mup-NN_amd64.deb                  # kernel
├── iproute2_7.0.0-srv6mupMM_amd64.deb                       # iproute2
├── frr_10.8.0~dev+srv6mupP-0ubuntu1~resolute1_amd64.deb     # FRR
├── frr-doc_..._all.deb                                      # FRR
├── frr-pythontools_..._all.deb                              # FRR
├── frr-rpki-rtrlib_..._amd64.deb                            # FRR
├── frr-snmp_..._amd64.deb                                   # FRR
└── frr-test-tools_..._amd64.deb                             # FRR
```

## Step 1 — rebuild the changed component(s)

### Kernel + iproute2 (`scripts/build_tarball.sh`)

See [`build-tarball.md`](build-tarball.md).  The script writes
`~/srv6-mup-bundle.tar.gz`; expand it into `/tmp/srv6-mup-release/`:

**Build the kernel from the Ubuntu-config tree, not the default
sibling `linux/`.**  The development tree's `.config` is the minimal
vng one; a deb built from it (~16 MB linux-image) will not boot a
stock Ubuntu system.  Check out the release SHA in the
`linux-ubuntu2604` tree (Ubuntu 26.04 config, linux-image ~117 MB)
and point `LINUX` at it — this bit v45, whose kernel assets had to
be re-uploaded:

```bash
git -C ../linux-ubuntu2604 fetch ../linux seg6-mobile
git -C ../linux-ubuntu2604 checkout <release SHA>
LINUX=$PWD/../linux-ubuntu2604 \
KERNEL_PKG_VER=7.1.0-srv6mup-NN IPROUTE2_PKG_TAG=srv6mupMM \
    scripts/build_tarball.sh
mkdir -p /tmp/srv6-mup-release
tar xzf ~/srv6-mup-bundle.tar.gz -C /tmp/srv6-mup-release \
    --strip-components=1 \
    srv6-mup-bundle/linux-image-*.deb \
    srv6-mup-bundle/linux-headers-*.deb \
    srv6-mup-bundle/linux-libc-dev_*.deb \
    srv6-mup-bundle/iproute2_*.deb
```

To extract the standalone bzImage from the kernel deb:

```bash
( cd /tmp/srv6-mup-release && \
  KREL=$(ls linux-image-*.deb | sed 's/^linux-image-//; s/_.*//') && \
  dpkg-deb --fsys-tarfile linux-image-${KREL}_*.deb \
      | tar -xO ./boot/vmlinuz-${KREL} > bzImage-${KREL} )
```

### FRR (`scripts/build_frr_deb.sh`)

```bash
FRR_BRANCH=bgp-mup-safi-originate FRR_PKG_TAG=srv6mupP \
    scripts/build_frr_deb.sh
```

The script:

1. `git worktree add --detach /tmp/frr-deb-build $FRR_BRANCH` against the
   sibling `../frr` tree.
2. `dch --newversion <configure.ac version>+srv6mupP-0ubuntu1~resolute1`.
3. Inside `srv6mup-build:$UBUNTU_SUITE`, enables `deb.frrouting.org`,
   installs FRR build deps (`libyang-dev`), runs
   `dpkg-buildpackage -b -us -uc`.
4. Copies the six resulting `frr*.deb` into `/tmp/srv6-mup-release/`,
   replacing any prior `frrXsrv6mup*` debs.
5. Removes the worktree.

`FRR_PKG_TAG` must monotonically increase — `dch` refuses to add a
duplicate entry for an existing version.

## Step 2 — write release notes

Keep the notes deliberately short — anything that does not change
between releases (RFC scope, asset descriptions, generic install steps,
vng usage) lives in the README, not in every release body.  The
template is:

```markdown
SRv6 Mobile User Plane (RFC 9433) Ubuntu 26.04 LTS deb bundle.

| Component    | Branch | Commit | Build version |
|--------------|--------|--------|---------------|
| Linux kernel | [`seg6-mobile`](https://github.com/higebu/linux/tree/seg6-mobile)       | <SHA> | `7.1.0-srv6mup-NN` |
| iproute2     | [`seg6-mobile`](https://github.com/higebu/iproute2/tree/seg6-mobile)    | <SHA> | `7.0.0-srv6mupMM`  |
| FRR          | [`bgp-mup-safi-originate`](https://github.com/higebu/frr/tree/bgp-mup-safi-originate) | <SHA> | `10.8.0~dev+srv6mupP-0ubuntu1~resolute1` |

## Changes since v<PREV>

- One bullet per user-visible change (component + what it does).

For install instructions, asset descriptions, and test usage, see the
[README](https://github.com/higebu/srv6-mup-tests#bundle-install).
```

Save it as `/tmp/v${NEW}-notes.md`.

## Step 3 — pack the staging directory into a single tarball

`scripts/pack_release.sh` validates that all 11 expected files are
present in `$STAGE_DIR`, then packs them under
`srv6-mup-bundle-${VERSION}/` so users can grab everything in one
download:

```bash
VERSION=v${NEW} scripts/pack_release.sh
# writes ~/srv6-mup-bundle-v${NEW}.tar.gz (~50 MB)
```

## Step 4 — create the GitHub release

```bash
gh release create v${NEW} \
    --repo higebu/srv6-mup-tests \
    --title "v${NEW}" \
    --notes-file /tmp/v${NEW}-notes.md \
    /tmp/srv6-mup-release/bzImage-* \
    /tmp/srv6-mup-release/linux-image-*.deb \
    /tmp/srv6-mup-release/linux-headers-*.deb \
    /tmp/srv6-mup-release/linux-libc-dev_*.deb \
    /tmp/srv6-mup-release/iproute2_*.deb \
    /tmp/srv6-mup-release/frr_*.deb \
    /tmp/srv6-mup-release/frr-doc_*.deb \
    /tmp/srv6-mup-release/frr-pythontools_*.deb \
    /tmp/srv6-mup-release/frr-rpki-rtrlib_*.deb \
    /tmp/srv6-mup-release/frr-snmp_*.deb \
    /tmp/srv6-mup-release/frr-test-tools_*.deb \
    ~/srv6-mup-bundle-v${NEW}.tar.gz
```

## Step 5 — verify

```bash
gh release view v${NEW} --repo higebu/srv6-mup-tests \
    --json tagName,name,assets \
    --jq '{tag: .tagName, title: .name,
           assets: [.assets[] | "\(.size)\t\(.name)"]}'
```

Expect 12 assets (1 bzImage + 3 kernel debs + 1 iproute2 deb + 6 FRR
debs + 1 tarball) and a title of `vNN` matching the tag.

There is no `iproute2-doc` deb: Ubuntu folded the man pages into the
main package and made it `Breaks`/`Replaces: iproute2-doc` with no
version bound, so a doc deb cannot be co-installed.
