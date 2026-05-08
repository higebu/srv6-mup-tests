#!/bin/bash
#
# Build the SRv6 MUP FRR Ubuntu Noble debs from the seg6-mobile branch of
# the sibling FRR tree (default: <parent>/frr).
#
# The build runs inside the same srv6mup-build:noble container used by
# scripts/build_tarball.sh (see docs/build-tarball.md for one-time
# bootstrap), with FRR's own apt repo enabled so libyang2-dev (>= 2.1.128)
# is available.
#
# Inputs (env vars, defaults in parens):
#   FRR              FRR source tree                (~/ghq/github.com/higebu/frr,
#                                                    falls back to <parent>/frr)
#   FRR_BRANCH       Branch / ref to build          (seg6-mobile)
#   FRR_PKG_TAG      Version tag suffix             (srv6mupN; required
#                                                    monotonically-bumped
#                                                    string like srv6mup2)
#   FRR_DCH_MSG      Changelog entry                ("BGP-MUP SAFI + SRv6
#                                                    Mobile User Plane
#                                                    (<branch>)")
#   DEBEMAIL         Maintainer email               (yuya.kusakabe@gmail.com)
#   DEBFULLNAME      Maintainer full name           (Yuya Kusakabe)
#   DOCKER_IMG       Build container image          (srv6mup-build:noble)
#   OUT_DIR          Where finished debs are placed (/tmp/srv6-mup-release)
#   WORK_DIR         Temporary worktree path        (/tmp/frr-deb-build)
#
# The script:
#   1. Creates a detached worktree of $FRR at $FRR_BRANCH in $WORK_DIR.
#   2. Runs dch --newversion 10.6.0~dev+${FRR_PKG_TAG}-0ubuntu1~noble1.
#   3. Inside $DOCKER_IMG, enables deb.frrouting.org, installs build deps,
#      runs dpkg-buildpackage -b -us -uc, copies the resulting *.deb
#      out to $WORK_DIR/_artifacts.
#   4. Copies _artifacts/*.deb into $OUT_DIR.
#   5. Removes the worktree (sudo rm -rf because dpkg-buildpackage runs as
#      root inside the container and leaves root-owned files behind).
#
# Idempotent: re-running with the same FRR_PKG_TAG fails at step 2
# (dch refuses to add a duplicate entry); bump FRR_PKG_TAG to rebuild.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

FRR=${FRR:-${ROOT}/frr}
[ -d "$FRR/.git" ] || FRR=$HOME/ghq/github.com/higebu/frr
[ -d "$FRR/.git" ] || { echo "FRR tree not found (set \$FRR)" >&2; exit 1; }

FRR_BRANCH=${FRR_BRANCH:-seg6-mobile}
FRR_PKG_TAG=${FRR_PKG_TAG:?set FRR_PKG_TAG (e.g. srv6mup2)}
FRR_DCH_MSG=${FRR_DCH_MSG:-"BGP-MUP SAFI + SRv6 Mobile User Plane (${FRR_BRANCH})"}
DEBEMAIL=${DEBEMAIL:-yuya.kusakabe@gmail.com}
DEBFULLNAME=${DEBFULLNAME:-Yuya Kusakabe}
DOCKER_IMG=${DOCKER_IMG:-srv6mup-build:noble}
OUT_DIR=${OUT_DIR:-/tmp/srv6-mup-release}
WORK_DIR=${WORK_DIR:-/tmp/frr-deb-build}

VER="10.6.0~dev+${FRR_PKG_TAG}-0ubuntu1~noble1"

mkdir -p "$OUT_DIR"

if [ -e "$WORK_DIR" ]; then
    echo "Removing stale $WORK_DIR" >&2
    sudo rm -rf "$WORK_DIR"
    git -C "$FRR" worktree prune
fi

echo "==> git worktree add $WORK_DIR ($FRR_BRANCH)"
git -C "$FRR" worktree add --detach "$WORK_DIR" "$FRR_BRANCH"

echo "==> dch --newversion $VER"
( cd "$WORK_DIR" && DEBEMAIL="$DEBEMAIL" DEBFULLNAME="$DEBFULLNAME" \
    dch --force-bad-version --newversion "$VER" \
        --distribution noble --force-distribution "$FRR_DCH_MSG" )
head -1 "$WORK_DIR/debian/changelog"

mkdir -p "$WORK_DIR/_artifacts"

echo "==> dpkg-buildpackage inside $DOCKER_IMG"
docker run --rm -v "$WORK_DIR":/build -w /build "$DOCKER_IMG" bash -c '
    set -e
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl ca-certificates >/dev/null 2>&1
    curl -fsSL https://deb.frrouting.org/frr/keys.gpg \
        -o /usr/share/keyrings/frr.gpg
    echo "deb [signed-by=/usr/share/keyrings/frr.gpg] https://deb.frrouting.org/frr noble frr-stable" \
        > /etc/apt/sources.list.d/frr.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bison chrpath flex gawk install-info \
        libc-ares-dev libcap-dev libelf-dev libjson-c-dev libpam0g-dev \
        libpcre2-dev libprotobuf-c-dev libpython3-dev libreadline-dev \
        librtr-dev libsnmp-dev libssh-dev libyang2-dev lsb-base pkg-config \
        protobuf-c-compiler python3 python3-dev python3-pytest python3-sphinx \
        sphinx-common texinfo autoconf automake libtool pkgconf >/dev/null
    dpkg-buildpackage -b -us -uc
    cp /*.deb /build/_artifacts/
'

echo "==> cp _artifacts/*.deb $OUT_DIR/"
# The container may have left _artifacts/ owned by root; fix ownership so
# the host user can move/delete the files.
sudo chown -R "$(id -u):$(id -g)" "$WORK_DIR/_artifacts"
# Drop any older srv6mup* frr debs from the staging dir before copying.
rm -f "$OUT_DIR"/frr*srv6mup*-0ubuntu1*.deb || true
cp "$WORK_DIR/_artifacts/"*.deb "$OUT_DIR/"

echo "==> git worktree remove $WORK_DIR"
sudo rm -rf "$WORK_DIR"
git -C "$FRR" worktree prune

echo
echo "FRR debs ($VER) staged in $OUT_DIR:"
ls -la "$OUT_DIR"/frr*"${FRR_PKG_TAG}"*.deb
