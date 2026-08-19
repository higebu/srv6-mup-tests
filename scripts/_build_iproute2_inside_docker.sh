#!/bin/bash
# pipefail matters: the build steps below pipe through `tail`, so without
# it a failing configure/make is masked and an empty .deb is produced.
set -e
set -o pipefail
cp -r /src /build-src
cd /build-src
make clean 2>&1 | tail -1
./configure 2>&1 | tail -2
make -j$(nproc) 2>&1 | tail -2

STAGING=/tmp/staging
rm -rf "$STAGING"
mkdir -p "$STAGING"
make install DESTDIR="$STAGING" SBINDIR=/usr/sbin BINDIR=/usr/bin 2>&1 | tail -1

# Reproduce the stock Ubuntu split.  This is not cosmetic: the DEBIAN/
# control archive cribbed from the stock deb further down carries a
# postinst that setcaps /bin/ip, which only resolves once ip really is
# in /usr/bin.  iproute2's install rule puts everything in SBINDIR.
mkdir -p "$STAGING/usr/bin"
for b in ip lnstat ctstat rtstat netshaper nstat rdma routel ss; do
  mv "$STAGING/usr/sbin/$b" "$STAGING/usr/bin/$b"
done
ln -s ../bin/ip "$STAGING/usr/sbin/ip"
# The standalone ifstat package owns /usr/bin/ifstat; stock iproute2
# leaves it out.
rm -f "$STAGING/usr/sbin/ifstat"

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

ls -la /out/
