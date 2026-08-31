#!/bin/bash
#
# Build the SRv6 MUP distribution tarball ~/srv6-mup-bundle.tar.gz from:
#   - Linux kernel built in $LINUX (default: sibling ../linux-ubuntu2604, a
#       git worktree of $LINUX_SRC) with `make bindeb-pkg` to produce
#       linux-image / linux-headers / linux-libc-dev .deb.  The worktree is
#       synced to $LINUX_SRC's HEAD and its .config comes from
#       $KERNEL_CONFIG, so a vng-generated config in the development tree
#       cannot reach a release -- see docs/build-tarball.md "Release kernel
#       config".
#   - iproute2  at  $IPROUTE2  (default: sibling ../iproute2 of this repo)
#       repackaged inside an srv6mup-build:$UBUNTU_SUITE container so the
#       resulting deb matches that Ubuntu release's libc6 and layout.
#
# The default layout assumes:
#   <parent>/linux          (kernel source)
#   <parent>/iproute2       (iproute2 source)
#   <parent>/srv6-mup-tests (this repo)
# i.e. all three trees are siblings under a common parent.  Override
# $LINUX / $IPROUTE2 if your layout differs.
#   - kernel config from $KERNEL_CONFIG (default: ../configs/kernel-release.config).
#       The generated config is written back to $KERNEL_CONFIG so olddefconfig
#       drift lands in git as a reviewable diff.
#   - selftests from $LINUX/tools/testing/selftests/net/srv6_*_test.sh
#       (plus lib.sh and lib/sh/defer.sh that they source)
#
# The Docker image $DOCKER_IMG (default srv6mup-build:resolute) must already
# exist; see docs/build-tarball.md for the bootstrap recipe.
#
# Reference Ubuntu iproute2 .debs are needed once to copy the maintainer
# scripts and conffiles list out of (so the resulting package looks like a
# vanilla Ubuntu drop-in to apt).  Default location:
#   $REF_IPROUTE2_DEB = ~/srv6-mup-bundle/iproute2_*.deb (any version)
# A previous version of the tarball is fine.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LINUX_SRC=${LINUX_SRC:-$ROOT/linux}
LINUX=${LINUX:-$ROOT/linux-ubuntu2604}
IPROUTE2=${IPROUTE2:-$ROOT/iproute2}
UBUNTU_SUITE=${UBUNTU_SUITE:-resolute}
DOCKER_IMG=${DOCKER_IMG:-srv6mup-build:${UBUNTU_SUITE}}
KERNEL_PKG_VER=${KERNEL_PKG_VER:-7.0.0-srv6mup-13}
KERNEL_CONFIG=${KERNEL_CONFIG:-$HERE/../configs/kernel-release.config}
IPROUTE2_PKG_TAG=${IPROUTE2_PKG_TAG:-srv6mup10}
OUT=${OUT:-$HOME/srv6-mup-bundle.tar.gz}
REF_IPROUTE2_DEB=${REF_IPROUTE2_DEB:-$HOME/srv6-mup-bundle/iproute2_*.deb}

INNER_BUILD=$HERE/_build_iproute2_inside_docker.sh

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/srv6-mup-bundle/selftests/lib/sh"

###############################################################################
# 1. Linux kernel deb
###############################################################################
echo "==> Building Linux kernel deb (KDEB_PKGVERSION=$KERNEL_PKG_VER) ..."
# The kernel is built in its own git worktree, never in the development tree.
# vng rewrites the development tree's .config with a minimal config every time
# a selftest or an e2e scenario runs, and v55 was first published with a
# kernel built from one: 15 modules instead of 6825, no igc and no i40e, so a
# machine relying on either NIC came up with no network.  A separate worktree
# also keeps both trees incrementally buildable.
[ -r "$KERNEL_CONFIG" ] || { echo "no release kernel config at $KERNEL_CONFIG" >&2; exit 1; }

if [ "$LINUX" != "$LINUX_SRC" ]; then
    sha=$(git -C "$LINUX_SRC" rev-parse HEAD)
    if [ ! -d "$LINUX" ]; then
        echo "==> Creating release build worktree $LINUX at $sha ..."
        git -C "$LINUX_SRC" worktree add --detach "$LINUX" "$sha"
    elif [ "$(git -C "$LINUX" rev-parse HEAD)" != "$sha" ]; then
        echo "==> Syncing $LINUX to $sha ..."
        git -C "$LINUX" checkout --detach "$sha"
    fi
fi

cp "$KERNEL_CONFIG" "$LINUX/.config"
( cd "$LINUX" && make olddefconfig )

# Fail loudly rather than shipping a kernel the target machines cannot use.
for sym in CONFIG_IPV6_SEG6_MOBILE=y CONFIG_IGC=m CONFIG_I40E=m; do
    grep -qx "$sym" "$LINUX/.config" ||
        { echo "release kernel config is missing $sym" >&2; exit 1; }
done

# The release .config carries CONFIG_DEBUG_INFO, so bindeb-pkg would also
# emit a ~1.3 GB linux-image-*-dbg deb and trip the one-deb-per-kind check
# below; the nokerneldbg build profile skips it.
( cd "$LINUX" && DEB_BUILD_PROFILES=pkg.linux-upstream.nokerneldbg \
      make -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="$KERNEL_PKG_VER" )

# olddefconfig answers whatever Kconfig symbols the kernel gained since the
# last release; write the result back so each release's config change shows
# up as a reviewable diff instead of drifting silently.
cp "$LINUX/.config" "$KERNEL_CONFIG"

# `make bindeb-pkg` writes the .deb files into the directory above the source
# tree, e.g. linux-ubuntu2604 is under seg6-mobile/ so the .debs land there.
LINUX_DEBS_DIR=$(dirname "$LINUX")
shopt -s nullglob
linux_image=( "$LINUX_DEBS_DIR"/linux-image-*"$KERNEL_PKG_VER"_amd64.deb )
linux_headers=( "$LINUX_DEBS_DIR"/linux-headers-*"$KERNEL_PKG_VER"_amd64.deb )
linux_libc_dev=( "$LINUX_DEBS_DIR"/linux-libc-dev_"$KERNEL_PKG_VER"_amd64.deb )
shopt -u nullglob

if [ ${#linux_image[@]} -ne 1 ] || [ ${#linux_headers[@]} -ne 1 ] || [ ${#linux_libc_dev[@]} -ne 1 ]; then
    echo "expected exactly one linux-image/headers/libc-dev .deb for ${KERNEL_PKG_VER}, got:" >&2
    printf '  %s\n' "${linux_image[@]}" "${linux_headers[@]}" "${linux_libc_dev[@]}" >&2
    exit 1
fi

cp "${linux_image[0]}"    "$stage/srv6-mup-bundle/"
cp "${linux_headers[0]}"  "$stage/srv6-mup-bundle/"
cp "${linux_libc_dev[0]}" "$stage/srv6-mup-bundle/"

uname_r=$(basename "${linux_image[0]}" .deb | sed -e 's/^linux-image-//' -e "s/_${KERNEL_PKG_VER}_amd64$//")

###############################################################################
# 2. iproute2 deb (built inside Ubuntu Noble Docker for libc compat)
###############################################################################
echo "==> Building iproute2 deb in $DOCKER_IMG (VERSION_TAG=$IPROUTE2_PKG_TAG) ..."

# resolve the reference deb (any matching file)
ref_deb=$(ls -1 $REF_IPROUTE2_DEB 2>/dev/null | head -1)
[ -n "$ref_deb" ] || { echo "no reference iproute2 .deb at $REF_IPROUTE2_DEB" >&2; exit 1; }

iproute2_out=$(mktemp -d)
docker run --rm \
    -v "$IPROUTE2:/src:ro" \
    -v "$iproute2_out:/out" \
    -v "$INNER_BUILD:/build.sh:ro" \
    -v "$ref_deb:/reference.deb:ro" \
    -e VERSION_TAG="$IPROUTE2_PKG_TAG" \
    "$DOCKER_IMG" bash /build.sh

cp "$iproute2_out"/iproute2_*.deb "$stage/srv6-mup-bundle/"
rm -rf "$iproute2_out"

###############################################################################
# 3. Selftests
###############################################################################
echo "==> Copying selftests from $LINUX/tools/testing/selftests/net/ ..."
sft="$LINUX/tools/testing/selftests/net"
for t in srv6_end_m_gtp4_e_test.sh srv6_end_m_gtp6_d_test.sh \
         srv6_end_m_gtp6_d_di_test.sh srv6_end_m_gtp6_e_test.sh \
         srv6_end_map_test.sh srv6_h_m_gtp4_d_test.sh; do
    cp "$sft/$t" "$stage/srv6-mup-bundle/selftests/"
done
cp "$sft/lib.sh"            "$stage/srv6-mup-bundle/selftests/"
cp "$sft/lib/sh/defer.sh"   "$stage/srv6-mup-bundle/selftests/lib/sh/"

###############################################################################
# 4. README
###############################################################################
cat > "$stage/srv6-mup-bundle/README.md" <<EOF
# SRv6 Mobile User Plane (RFC 9433) for Ubuntu 26.04 LTS

A self-built kernel + iproute2 deb bundle that adds RFC 9433 SRv6 MUP
support (six behaviors, Section 6.2 to 6.7) to any Ubuntu 26.04 LTS
host.  libcares2, libpcre2-posix3 and libyang3 all come from the
resolute archive's main component, so no extra apt source is needed.

Built from the upstream-bound patch series:

- Linux: <https://github.com/higebu/linux/tree/srv6-mup>
- iproute2: <https://github.com/higebu/iproute2/tree/srv6-mup>
- Test scripts: <https://github.com/higebu/srv6-mup-tests>

## Bundle contents

- \`linux-image-${uname_r}_${KERNEL_PKG_VER}_amd64.deb\`
- \`linux-headers-${uname_r}_${KERNEL_PKG_VER}_amd64.deb\` (optional)
- \`linux-libc-dev_${KERNEL_PKG_VER}_amd64.deb\` (optional)
- \`iproute2_7.0.0-${IPROUTE2_PKG_TAG}_amd64.deb\`
- \`selftests/srv6_*_test.sh\`

## Install

\`\`\`bash
sudo apt-get install -y ./*.deb
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux ${uname_r}"
sudo reboot
\`\`\`

After reboot, verify with \`uname -r\` (expect \`${uname_r}\`),
then pin the new kernel as default in \`/etc/default/grub\`.

## Selftests

\`\`\`bash
sudo apt-get install -y python3-scapy tcpdump
cd selftests
for t in srv6_*_test.sh; do echo "=== \$t ==="; sudo bash ./\$t; done
\`\`\`

All six tests are expected to pass.
EOF

###############################################################################
# 5. Pack
###############################################################################
echo "==> Packing $OUT ..."
( cd "$stage" && tar czf "$OUT" srv6-mup-bundle/ )

ls -la "$OUT"
echo
echo "Contents:"
tar tzf "$OUT" | sort
