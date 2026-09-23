#!/bin/bash
# Build one stable kernel with OpenZFS compiled BUILTIN (CONFIG_ZFS=y — no
# module, no dkms) as image+headers debs, plus the matching ZFS userland
# tarball from the SAME zfs tree. Mirrors debian13-stripped/build-kernel.sh.
# Runs as root inside a throwaway debian:trixie container, never on a host.
# Usage: build.sh <kernel tag, e.g. v6.12.111> <zfs tag> <outdir>
set -euo pipefail
KTAG=$1 ZFS_TAG=$2 OUT=$3
LOCALVERSION=-stripped
W=/build KSRC=/build/linux ZSRC=/build/zfs
mkdir -p "$W" "$OUT"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends git ca-certificates \
  build-essential bc flex bison libssl-dev libelf-dev debhelper rsync cpio \
  kmod python3 autoconf automake libtool gettext pkg-config uuid-dev \
  libblkid-dev libtirpc-dev zlib1g-dev libaio-dev libattr1-dev libudev-dev >/dev/null

git clone -q --depth 1 --branch "$KTAG" \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KSRC"
git clone -q --depth 1 --branch "$ZFS_TAG" https://github.com/openzfs/zfs.git "$ZSRC"

# --- config seed: Debian's own amd64 kernel config (the real image package
# behind the linux-image-amd64 metapackage), unpacked, not installed ---------
cd "$W"
img=$(apt-cache depends linux-image-amd64 | awk '/Depends: linux-image-[0-9]/{print $2; exit}')
apt-get download -qq "$img"
dpkg -x "${img}"_*.deb seed
cd "$KSRC"
cp "$W"/seed/boot/config-* .config
# Debian's config points at Debian's signing certs — clear or the build dies.
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 \
  --disable DEBUG_INFO_BTF --enable DEBUG_INFO_NONE
scripts/config --set-str LOCALVERSION "" --disable LOCALVERSION_AUTO
make olddefconfig
make -j"$(nproc)" prepare

# --- graft zfs into the kernel tree ------------------------------------------
cd "$ZSRC"
sh autogen.sh
./configure --enable-linux-builtin --with-linux="$KSRC"
./copy-builtin "$KSRC"

# --- kernel debs -------------------------------------------------------------
cd "$KSRC"
scripts/config --enable ZFS
make olddefconfig
grep -q '^CONFIG_ZFS=y' .config || { echo "CONFIG_ZFS=y did not stick" >&2; exit 1; }
# Package version carries the zfs release, so rebuilding the same kernel
# against a newer zfs still upgrades (e.g. 6.12.111-zfs2.4.5 > 6.12.111-zfs2.4.4).
make -j"$(nproc)" LOCALVERSION="$LOCALVERSION" \
  KDEB_PKGVERSION="${KTAG#v}-zfs${ZFS_TAG#zfs-}" bindeb-pkg
cp -v "$W"/linux-{image,headers}-*"$LOCALVERSION"_*.deb "$OUT"/

# --- matching userland (tools only, no module) -------------------------------
cd "$ZSRC"
make distclean >/dev/null 2>&1 || true
# Every path pinned under /usr: the target rootfs is merged-usr.
./configure --with-config=user --prefix=/usr --sysconfdir=/etc \
  --with-udevdir=/usr/lib/udev --with-udevruledir=/usr/lib/udev/rules.d \
  --with-mounthelperdir=/usr/sbin \
  --with-systemdunitdir=/usr/lib/systemd/system \
  --with-systemdgeneratordir=/usr/lib/systemd/system-generators
make -j"$(nproc)"
DEST="$W/zfs-userland"
make install DESTDIR="$DEST"
tar -C "$DEST" --owner=root --group=root -czf "$OUT/zfs-userland.tar.gz" .
ls -l "$OUT"
