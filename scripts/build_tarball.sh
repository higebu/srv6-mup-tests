#!/bin/bash
#
# Build the SRv6 MUP distribution tarball ~/srv6-mup-bundle.tar.gz from:
#   - Linux kernel at  $LINUX  (default: sibling ../linux of this repo)
#       built with `make bindeb-pkg` to produce linux-image / linux-headers /
#       linux-libc-dev .deb
#   - iproute2  at  $IPROUTE2  (default: sibling ../iproute2 of this repo)
#       repackaged inside an Ubuntu Noble Docker container so the resulting
#       deb satisfies Ubuntu 24.04 LTS (libc6 >= 2.38) targets.
#
# The default layout assumes:
#   <parent>/linux          (kernel source)
#   <parent>/iproute2       (iproute2 source)
#   <parent>/srv6-mup-tests (this repo)
# i.e. all three trees are siblings under a common parent.  Override
# $LINUX / $IPROUTE2 if your layout differs.
#   - selftests from $LINUX/tools/testing/selftests/net/srv6_*_test.sh
#       (plus lib.sh and lib/sh/defer.sh that they source)
#
# The Docker image $DOCKER_IMG (default srv6mup-build:noble) must already
# exist and have build-essential, dpkg-dev and debhelper installed; build it
# once with:
#
#   docker run --name srv6mup-build-noble ubuntu:24.04 bash -c 'apt-get update \
#       && apt-get install -y --no-install-recommends build-essential dpkg-dev \
#                              debhelper'
#   docker commit srv6mup-build-noble srv6mup-build:noble
#   docker rm srv6mup-build-noble
#
# Reference Ubuntu iproute2 .debs are needed once to copy the maintainer
# scripts and conffiles list out of (so the resulting package looks like a
# vanilla Ubuntu drop-in to apt).  Default location:
#   $REF_IPROUTE2_DEB     = ~/srv6-mup-bundle/iproute2_*.deb     (any version)
#   $REF_IPROUTE2_DOC_DEB = ~/srv6-mup-bundle/iproute2-doc_*.deb (any version)
# A previous version of the tarball is fine.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LINUX=${LINUX:-$ROOT/linux}
IPROUTE2=${IPROUTE2:-$ROOT/iproute2}
DOCKER_IMG=${DOCKER_IMG:-srv6mup-build:noble}
KERNEL_PKG_VER=${KERNEL_PKG_VER:-7.0.0-srv6mup-13}
IPROUTE2_PKG_TAG=${IPROUTE2_PKG_TAG:-srv6mup10}
OUT=${OUT:-$HOME/srv6-mup-bundle.tar.gz}
REF_IPROUTE2_DEB=${REF_IPROUTE2_DEB:-$HOME/srv6-mup-bundle/iproute2_*.deb}
REF_IPROUTE2_DOC_DEB=${REF_IPROUTE2_DOC_DEB:-$HOME/srv6-mup-bundle/iproute2-doc_*.deb}

INNER_BUILD=$HERE/_build_iproute2_inside_docker.sh

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/srv6-mup-bundle/selftests/lib/sh"

###############################################################################
# 1. Linux kernel deb
###############################################################################
echo "==> Building Linux kernel deb (KDEB_PKGVERSION=$KERNEL_PKG_VER) ..."
( cd "$LINUX" && make -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="$KERNEL_PKG_VER" )

# `make bindeb-pkg` writes the .deb files into the directory above the source
# tree, e.g. linux is at ~/ghq/github.com/higebu/linux so the .debs land in
# ~/ghq/github.com/higebu/.
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

# resolve reference debs (any matching file)
ref_deb=$(ls -1 $REF_IPROUTE2_DEB     2>/dev/null | head -1)
ref_doc=$(ls -1 $REF_IPROUTE2_DOC_DEB 2>/dev/null | head -1)
[ -n "$ref_deb" ] || { echo "no reference iproute2 .deb at $REF_IPROUTE2_DEB" >&2; exit 1; }
[ -n "$ref_doc" ] || { echo "no reference iproute2-doc .deb at $REF_IPROUTE2_DOC_DEB" >&2; exit 1; }

iproute2_out=$(mktemp -d)
docker run --rm \
    -v "$IPROUTE2:/src:ro" \
    -v "$iproute2_out:/out" \
    -v "$INNER_BUILD:/build.sh:ro" \
    -v "$ref_deb:/reference.deb:ro" \
    -v "$ref_doc:/reference-doc.deb:ro" \
    -e VERSION_TAG="$IPROUTE2_PKG_TAG" \
    "$DOCKER_IMG" bash /build.sh

cp "$iproute2_out"/iproute2_*.deb     "$stage/srv6-mup-bundle/"
cp "$iproute2_out"/iproute2-doc_*.deb "$stage/srv6-mup-bundle/"
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
# SRv6 Mobile User Plane (RFC 9433) for Ubuntu 24.04 LTS

A self-built kernel + iproute2 deb bundle that adds RFC 9433 SRv6 MUP
support (six behaviors, §6.2-§6.7) to any Ubuntu 24.04 LTS host.

Built from the upstream-bound patch series:

- Linux: <https://github.com/higebu/linux/tree/srv6-mup>
- iproute2: <https://github.com/higebu/iproute2/tree/srv6-mup>
- Test harness: <https://github.com/higebu/srv6-mup-tests>

## Bundle contents

- \`linux-image-${uname_r}_${KERNEL_PKG_VER}_amd64.deb\`
- \`linux-headers-${uname_r}_${KERNEL_PKG_VER}_amd64.deb\` (optional)
- \`linux-libc-dev_${KERNEL_PKG_VER}_amd64.deb\` (optional)
- \`iproute2_7.0.0-${IPROUTE2_PKG_TAG}_amd64.deb\`
- \`iproute2-doc_7.0.0-${IPROUTE2_PKG_TAG}_all.deb\` (optional)
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
