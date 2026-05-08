#!/bin/bash
#
# Pack the staged release artifacts in $STAGE_DIR (default
# /tmp/srv6-mup-release) into a single tarball for attachment to the
# bundle-vNN GitHub release.
#
# Inputs (env vars, defaults in parens):
#   VERSION      Bundle release tag, e.g. v28           (required)
#   STAGE_DIR    Directory holding the 12 release files (/tmp/srv6-mup-release)
#   OUT          Output tarball path                    (~/srv6-mup-bundle-${VERSION}.tar.gz)
#
# The tarball expands into a single top-level directory
# `srv6-mup-bundle-${VERSION}/` so that `tar xzf` does not litter the
# user's CWD.  A short README.md inside the directory points at the
# matching GitHub release for the per-file table.

set -euo pipefail

VERSION=${VERSION:?set VERSION (e.g. v28)}
STAGE_DIR=${STAGE_DIR:-/tmp/srv6-mup-release}
OUT=${OUT:-$HOME/srv6-mup-bundle-${VERSION}.tar.gz}

[ -d "$STAGE_DIR" ] || { echo "STAGE_DIR not found: $STAGE_DIR" >&2; exit 1; }

# Sanity-check the expected 12 artifacts before packing.
required=(
    bzImage-*
    linux-image-*.deb
    linux-headers-*.deb
    linux-libc-dev_*.deb
    iproute2_*.deb
    iproute2-doc_*.deb
    frr_*.deb
    frr-doc_*.deb
    frr-pythontools_*.deb
    frr-rpki-rtrlib_*.deb
    frr-snmp_*.deb
    frr-test-tools_*.deb
)
shopt -s nullglob
for pat in "${required[@]}"; do
    matches=( "$STAGE_DIR"/$pat )
    [ ${#matches[@]} -ge 1 ] || { echo "missing: $STAGE_DIR/$pat" >&2; exit 1; }
done
shopt -u nullglob

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

bundle="$stage/srv6-mup-bundle-${VERSION}"
mkdir -p "$bundle"

# Copy via cp -L in case STAGE_DIR contains symlinks.
cp -L "$STAGE_DIR"/* "$bundle/"

cat > "$bundle/README.md" <<EOF
# SRv6 MUP bundle ${VERSION}

The same artifacts published as individual assets at
<https://github.com/higebu/srv6-mup-tests/releases/tag/${VERSION}>,
packed into a single tarball.

See the GitHub release notes for the per-file table, source-branch
commit SHAs, install instructions, and verification steps.

\`\`\`bash
sudo apt-get install -y ./linux-*.deb ./iproute2*.deb
# FRR (after adding the FRR apt repo for libyang2 >= 2.1.128 - see
# release notes):
sudo apt-get install -y ./frr*.deb
\`\`\`
EOF

echo "==> packing $OUT"
( cd "$stage" && tar czf "$OUT" "srv6-mup-bundle-${VERSION}/" )
ls -la "$OUT"
echo
echo "Contents:"
tar tzf "$OUT" | sort
