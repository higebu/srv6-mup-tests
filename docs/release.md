# Cutting an `srv6-mup-tests` bundle release

A "bundle release" on
[higebu/srv6-mup-tests](https://github.com/higebu/srv6-mup-tests/releases)
ships three independently-versioned components built for Ubuntu 24.04 LTS
(Noble) as the seg6-mobile reference stack:

| Component | Source branch | Build version |
|-----------|---------------|---------------|
| Linux kernel | [`higebu/linux b4/seg6-mobile`](https://github.com/higebu/linux/tree/b4/seg6-mobile) | `7.0.0-srv6mup-NN` |
| iproute2     | [`higebu/iproute2 b4/seg6-mobile`](https://github.com/higebu/iproute2/tree/b4/seg6-mobile) | `7.0.0-srv6mupMM`  |
| FRR          | [`higebu/frr seg6-mobile`](https://github.com/higebu/frr/tree/seg6-mobile)                 | `10.6.0~dev+srv6mupP-0ubuntu1~noble1` |

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
├── iproute2-doc_7.0.0-srv6mupMM_all.deb                     # iproute2
├── frr_10.6.0~dev+srv6mupP-0ubuntu1~noble1_amd64.deb        # FRR
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

```bash
KERNEL_PKG_VER=7.0.0-srv6mup-NN IPROUTE2_PKG_TAG=srv6mupMM \
    scripts/build_tarball.sh
mkdir -p /tmp/srv6-mup-release
tar xzf ~/srv6-mup-bundle.tar.gz -C /tmp/srv6-mup-release \
    --strip-components=1 \
    srv6-mup-bundle/linux-image-*.deb \
    srv6-mup-bundle/linux-headers-*.deb \
    srv6-mup-bundle/linux-libc-dev_*.deb \
    srv6-mup-bundle/iproute2_*.deb \
    srv6-mup-bundle/iproute2-doc_*.deb
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
FRR_PKG_TAG=srv6mupP scripts/build_frr_deb.sh
```

The script:

1. `git worktree add --detach /tmp/frr-deb-build seg6-mobile` against the
   sibling `../frr` tree.
2. `dch --newversion 10.6.0~dev+srv6mupP-0ubuntu1~noble1`.
3. Inside `srv6mup-build:noble`, enables `deb.frrouting.org` (for
   `libyang2-dev >= 2.1.128`), installs FRR build deps, runs
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
SRv6 Mobile User Plane (RFC 9433) Ubuntu 24.04 LTS deb bundle.

| Component    | Branch | Commit | Build version |
|--------------|--------|--------|---------------|
| Linux kernel | [`b4/seg6-mobile`](https://github.com/higebu/linux/tree/b4/seg6-mobile)    | <SHA> | `7.0.0-srv6mup-NN` |
| iproute2     | [`b4/seg6-mobile`](https://github.com/higebu/iproute2/tree/b4/seg6-mobile) | <SHA> | `7.0.0-srv6mupMM`  |
| FRR          | [`seg6-mobile`](https://github.com/higebu/frr/tree/seg6-mobile)            | <SHA> | `10.6.0~dev+srv6mupP-0ubuntu1~noble1` |

## Changes since v<PREV>

- One bullet per user-visible change (component + what it does).

For install instructions, asset descriptions, and harness usage, see the
[README](https://github.com/higebu/srv6-mup-tests#bundle-install-ubuntu-2404-lts).
```

Save it as `/tmp/v${NEW}-notes.md`.

## Step 3 — pack the staging directory into a single tarball

`scripts/pack_release.sh` validates that all 12 expected files are
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
    /tmp/srv6-mup-release/iproute2-doc_*.deb \
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

Expect 13 assets (1 bzImage + 3 kernel debs + 2 iproute2 debs + 6 FRR
debs + 1 tarball) and a title of `vNN` matching the tag.
