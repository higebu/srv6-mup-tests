# Building the SRv6 MUP distribution tarball

`scripts/build_tarball.sh` produces
`~/srv6-mup-bundle.tar.gz`, a `.deb` bundle that installs the SRv6 MUP
kernel + iproute2 patches on any Ubuntu 24.04 LTS host (bare metal,
LXC containers, EC2, lab nodes — anywhere
`apt-get install -y ./*.deb` works):

```
srv6-mup-bundle/
├── linux-image-...srv6mup-NN_amd64.deb
├── linux-headers-...srv6mup-NN_amd64.deb
├── linux-libc-dev_...srv6mup-NN_amd64.deb
├── iproute2_7.0.0-srv6mupMM_amd64.deb
├── iproute2-doc_7.0.0-srv6mupMM_all.deb
├── README.md
└── selftests/
    ├── lib.sh
    ├── lib/sh/defer.sh
    └── srv6_*_test.sh        (×6)
```

## Prerequisites (host)

- `make`, `gcc`, kernel build deps (the same toolchain that builds the
  `srv6-mup` Linux branch; if `make -j$(nproc) bzImage` works in
  `~/ghq/github.com/higebu/linux`, you're fine).
- `docker` — the iproute2 deb is built inside an Ubuntu 24.04 (Noble)
  container so the resulting binary links against `libc6 (>= 2.38)`,
  matching Ubuntu 24.04 LTS targets.
- A reference Ubuntu iproute2 deb pair to crib the maintainer scripts /
  conffiles list from. The previous bundle in `~/srv6-mup-bundle/` is fine;
  see `REF_IPROUTE2_DEB` / `REF_IPROUTE2_DOC_DEB` env vars below.

### One-time Docker image setup

The build script invokes the container image `srv6mup-build:noble`.
Bootstrap it once with:

```bash
docker run --name srv6mup-build-noble ubuntu:24.04 bash -c '
    apt-get update &&
    apt-get install -y --no-install-recommends \
        build-essential dpkg-dev debhelper'
docker commit srv6mup-build-noble srv6mup-build:noble
docker rm srv6mup-build-noble
```

## Running

The defaults match the workspace layout used during this project:

```bash
~/ghq/github.com/higebu/srv6-mup-tests/scripts/build_tarball.sh
```

Output: `~/srv6-mup-bundle.tar.gz` (~28 MB) plus a printout of its file
list.

### Customising

All knobs are env vars (defaults in parentheses):

- `LINUX`              — Linux source tree (`~/ghq/github.com/higebu/linux`)
- `IPROUTE2`           — iproute2 source tree (`~/ghq/github.com/higebu/iproute2`)
- `DOCKER_IMG`         — container image for the iproute2 build (`srv6mup-build:noble`)
- `KERNEL_PKG_VER`     — `KDEB_PKGVERSION` for `make bindeb-pkg`
                          (e.g. `7.0.0-srv6mup-13`)
- `IPROUTE2_PKG_TAG`   — version-tag suffix for the iproute2 deb's
                          `Version:` field (e.g. `srv6mup10` →
                          deb version `7.0.0-srv6mup10`)
- `REF_IPROUTE2_DEB`   — path/glob to a previous iproute2 deb to copy
                          DEBIAN/control / md5sums / postinst from
                          (default `~/srv6-mup-bundle/iproute2_*.deb`)
- `REF_IPROUTE2_DOC_DEB` — same idea for the iproute2-doc deb
- `OUT`                — output tarball path (`~/srv6-mup-bundle.tar.gz`)

For example, to bump the version tags:

```bash
KERNEL_PKG_VER=7.0.0-srv6mup-14 IPROUTE2_PKG_TAG=srv6mup11 \
    ~/ghq/github.com/higebu/srv6-mup-tests/scripts/build_tarball.sh
```

## How the iproute2 deb is built

`scripts/_build_iproute2_inside_docker.sh` runs **inside** the Noble
container and:

1. `make` the iproute2 source tree.
2. `make install DESTDIR=...` into a staging directory (`/sbin`, `/bin`,
   `/usr/share/man`, `/usr/share/doc/iproute2-doc`, `/etc/iproute2`).
3. Copy the `DEBIAN/` directory **out of a reference Ubuntu iproute2 deb**
   (control, conffiles, postinst, templates …) and rewrite the
   `Version:` field.
4. Drop entries from the reference `conffiles` list whose paths are not
   actually shipped (a few BPF-related conffiles); otherwise `dpkg-deb
   --build` aborts with "conffile X does not appear in package".
5. Recompute `DEBIAN/md5sums`.
6. `dpkg-deb --build` to produce `iproute2_<ver>_amd64.deb`.
7. Repeat for `iproute2-doc_<ver>_all.deb` (just the man pages and
   examples).

The reference deb's maintainer-script content (`postinst`, `templates`,
…) is intentionally reused unchanged so the resulting package looks
identical to a stock Ubuntu deb to apt — `apt-get install -y ./*.deb`
on the target node Just Works without prompting.

## Why Docker for iproute2

The `srv6-mup` branch lives in `~/ghq/github.com/higebu/iproute2` and is
typically built on the host (Debian 12 = bookworm = libc6 2.36).
The Ubuntu 24.04 LTS target is Noble (= libc6 2.38), and dpkg refuses
to install a binary that `Depends: libc6 (>= 2.38)` against a 2.36 host
or vice versa. Building inside an `ubuntu:24.04` image side-steps the
mismatch.

The kernel deb does not have this constraint — `make bindeb-pkg`
produces a deb that has no userspace ABI tied into it, so we build it
directly on the host.

## Quick sanity-check after rebuilding

```bash
tar tzf ~/srv6-mup-bundle.tar.gz | sort
```

should list 5 \*.deb files, README.md, and 7 selftest files (6 scripts +
`lib.sh` + `lib/sh/defer.sh`).

To smoke-test the deb on the local box (without installing system-wide),
the selftests in the bundle can be run inside `vng` against the same
kernel source: see [`selftests.md`](selftests.md).
