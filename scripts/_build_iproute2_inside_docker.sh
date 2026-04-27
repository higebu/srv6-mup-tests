#!/bin/bash
set -e
cp -r /src /build-src
cd /build-src
make clean 2>&1 | tail -1
./configure 2>&1 | tail -2
make -j$(nproc) 2>&1 | tail -2

STAGING=/tmp/staging
rm -rf "$STAGING"
mkdir -p "$STAGING"
make install DESTDIR="$STAGING" SBINDIR=/sbin BINDIR=/bin 2>&1 | tail -1

# stage etc files referenced as conffiles by Ubuntu's deb
mkdir -p "$STAGING/etc/iproute2"
for f in bpf_pinning ematch_map group nl_protos rt_dsfield rt_protos rt_realms rt_scopes rt_tables; do
  if [ ! -f "$STAGING/etc/iproute2/$f" ]; then
    if [ -f "/build-src/etc/iproute2/$f" ]; then
      install -m 0644 "/build-src/etc/iproute2/$f" "$STAGING/etc/iproute2/$f"
    else
      touch "$STAGING/etc/iproute2/$f"
    fi
  fi
done

# Reuse Ubuntu's control archive
mkdir -p /tmp/old-deb-extract
dpkg-deb -e /reference.deb /tmp/old-deb-extract/DEBIAN
cp -r /tmp/old-deb-extract/DEBIAN "$STAGING/"

NEW_VER="7.0.0-${VERSION_TAG:-srv6mup8}"
sed -i "s/^Version:.*/Version: ${NEW_VER}/" "$STAGING/DEBIAN/control"

# Drop conffiles that we did not install
if [ -f "$STAGING/DEBIAN/conffiles" ]; then
  : > "$STAGING/DEBIAN/conffiles.new"
  while read -r line; do
    line_clean="${line#/}"
    if [ -e "$STAGING/$line_clean" ]; then
      echo "$line" >> "$STAGING/DEBIAN/conffiles.new"
    fi
  done < "$STAGING/DEBIAN/conffiles"
  mv "$STAGING/DEBIAN/conffiles.new" "$STAGING/DEBIAN/conffiles"
fi

( cd "$STAGING" && find . -path ./DEBIAN -prune -o -type f -print | sed 's|^\./||' | xargs -d '\n' md5sum 2>/dev/null > DEBIAN/md5sums )

mkdir -p /out
dpkg-deb --build --root-owner-group "$STAGING" "/out/iproute2_${NEW_VER}_amd64.deb"

# Now build iproute2-doc deb (man pages + examples)
DOC_STAGING=/tmp/doc-staging
rm -rf "$DOC_STAGING"
mkdir -p "$DOC_STAGING/usr/share/doc/iproute2-doc"
mkdir -p "$DOC_STAGING/usr/share/man/man8"
mkdir -p "$DOC_STAGING/usr/share/man/man7"
# install man pages from our build
if [ -d /build-src/man/man8 ]; then
  for m in /build-src/man/man8/*.8; do
    [ -f "$m" ] && cp "$m" "$DOC_STAGING/usr/share/man/man8/"
  done
fi
if [ -d /build-src/man/man7 ]; then
  for m in /build-src/man/man7/*.7; do
    [ -f "$m" ] && cp "$m" "$DOC_STAGING/usr/share/man/man7/"
  done
fi
# gzip man pages per Debian policy
find "$DOC_STAGING/usr/share/man" -type f -name "*.[1-9]" -exec gzip -9n {} \;
# examples
if [ -d /build-src/examples ]; then
  cp -r /build-src/examples "$DOC_STAGING/usr/share/doc/iproute2-doc/"
fi

# Reuse Ubuntu doc deb's control archive
mkdir -p /tmp/old-doc-extract
dpkg-deb -e /reference-doc.deb /tmp/old-doc-extract/DEBIAN 2>/dev/null || true
if [ -f /tmp/old-doc-extract/DEBIAN/control ]; then
  cp -r /tmp/old-doc-extract/DEBIAN "$DOC_STAGING/"
  sed -i "s/^Version:.*/Version: ${NEW_VER}/" "$DOC_STAGING/DEBIAN/control"
else
  # Fallback: minimal control file
  mkdir -p "$DOC_STAGING/DEBIAN"
  cat > "$DOC_STAGING/DEBIAN/control" <<EOF
Package: iproute2-doc
Source: iproute2
Version: ${NEW_VER}
Architecture: all
Maintainer: Yuya Kusakabe <y-kusakabe@bbsakura.net>
Section: doc
Priority: optional
Multi-Arch: foreign
Homepage: https://wiki.linuxfoundation.org/networking/iproute2
Description: networking and traffic control tools - documentation
 The iproute2 suite is a collection of utilities for networking and
 traffic control.
 .
 This package contains the documentation including manual pages and
 examples.
EOF
fi

if [ -f "$DOC_STAGING/DEBIAN/conffiles" ]; then
  : > "$DOC_STAGING/DEBIAN/conffiles.new"
  while read -r line; do
    line_clean="${line#/}"
    if [ -e "$DOC_STAGING/$line_clean" ]; then
      echo "$line" >> "$DOC_STAGING/DEBIAN/conffiles.new"
    fi
  done < "$DOC_STAGING/DEBIAN/conffiles"
  mv "$DOC_STAGING/DEBIAN/conffiles.new" "$DOC_STAGING/DEBIAN/conffiles"
fi

( cd "$DOC_STAGING" && find . -path ./DEBIAN -prune -o -type f -print | sed 's|^\./||' | xargs -d '\n' md5sum 2>/dev/null > DEBIAN/md5sums )

dpkg-deb --build --root-owner-group "$DOC_STAGING" "/out/iproute2-doc_${NEW_VER}_all.deb"

ls -la /out/
