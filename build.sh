#!/bin/bash
# Build Debian's kernel from Debian's own source package (the .dsc, unpacked
# with dpkg-source: the exact patched tree Debian builds from, configured with
# that package's own amd64 config) with OpenZFS compiled BUILTIN (CONFIG_ZFS=y
# — no module, no dkms) as image+headers debs, plus the matching ZFS userland
# tarball from the SAME zfs tree.
# Runs as root inside a throwaway debian:trixie container, never on a host.
# Usage: build.sh <Debian version, e.g. 6.12.113-1> <zfs tag> <outdir>
set -euo pipefail
DVER=$1 ZFS_TAG=$2 OUT=$3
LOCALVERSION=-stripped
W=/build KSRC=/build/linux ZSRC=/build/zfs DPKG=/build/debian-pkg
mkdir -p "$W" "$OUT"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends git ca-certificates curl \
  build-essential bc flex bison libssl-dev libelf-dev debhelper rsync cpio \
  kmod python3 python3-dacite libdw-dev zstd xz-utils autoconf automake libtool gettext pkg-config uuid-dev \
  libblkid-dev libtirpc-dev zlib1g-dev libaio-dev libattr1-dev libudev-dev >/dev/null

git clone -q --depth 1 --branch "$ZFS_TAG" https://github.com/openzfs/zfs.git "$ZSRC"

# --- Debian's source package -------------------------------------------------
# Current versions sit in the main or security pool; anything older only on
# snapshot.debian.org. dpkg-source checks every file against the .dsc
# checksums (the signature it can only warn about: no keyring in here).
mkdir -p "$W/src" && cd "$W/src"
POOLS="https://deb.debian.org/debian/pool/main/l/linux
https://security.debian.org/debian-security/pool/updates/main/l/linux"
fetch() { local b; for b in $POOLS; do curl -fsSLO "$b/$1" 2>/dev/null && return; done; return 1; }
dsc=linux_$DVER.dsc
if fetch "$dsc"; then
  for f in $(awk '/^Files:/{f=1; next} /^[^ ]/{f=0} f{print $3}' "$dsc"); do
    fetch "$f" || { echo "cannot fetch $f" >&2; exit 1; }
  done
else
  curl -fsSL "https://snapshot.debian.org/mr/package/linux/$DVER/srcfiles?fileinfo=1" |
    python3 -c 'import json, sys
for h, info in json.load(sys.stdin)["fileinfo"].items(): print(h, info[0]["name"])' |
    while read -r hash name; do
      curl -fsSL --retry 3 -o "$name" "https://snapshot.debian.org/file/$hash"
    done
fi
[[ -f $dsc ]] || { echo "Debian source linux $DVER not found" >&2; exit 1; }
dpkg-source -x "$dsc" "$KSRC"
cd "$KSRC"

# --- config: the tag's own amd64 flavour config, merged the way Debian's
# rules.real does it (kconfig.py over the fragment list gencontrol uses) ------
# bindeb-pkg writes its own ./debian, so Debian's packaging moves aside first.
mv debian "$DPKG"; rm -rf .pc
export PYTHONPATH=$DPKG/lib/python
frags=()
for c in $(python3 -m debian_linux.config_v2 "$DPKG/config" |
  awk '/Debianarch:/{a=$2} /Featureset:/{f=$2} /Flavour:/{fl=$2}
    /Config:/ && a=="amd64" && f=="none" && fl=="amd64"{$1=""; print}'); do
  [[ -f $DPKG/config/$c ]] && frags+=("$DPKG/config/$c")
done
(( ${#frags[@]} )) || { echo "no amd64 config fragments in linux $DVER" >&2; exit 1; }
python3 "$DPKG/bin/kconfig.py" .config "${frags[@]}"
# Clear any Debian signing cert references. The module signing key is the
# kernel's auto-generated throwaway one, as in Debian's own build: it signs the
# in-tree modules and dies with this container (checked below).
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --disable DEBUG_INFO_DWARF5 \
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
# Lockdown under Secure Boot is a Debian patch; the config must keep it on.
scripts/config --enable ZFS --enable LOCK_DOWN_IN_EFI_SECURE_BOOT
make olddefconfig
for opt in ZFS LOCK_DOWN_IN_EFI_SECURE_BOOT; do
  grep -q "^CONFIG_$opt=y" .config || { echo "CONFIG_$opt=y did not stick" >&2; exit 1; }
done
# Package version carries the Debian revision and the zfs release, so a new
# Debian revision or a newer zfs on the same kernel still upgrades
# (6.12.113-2-zfs2.4.4 > 6.12.113-1-zfs2.4.5 > 6.12.113-1-zfs2.4.4).
make -j"$(nproc)" LOCALVERSION="$LOCALVERSION" \
  KDEB_PKGVERSION="${DVER}-zfs${ZFS_TAG#zfs-}" bindeb-pkg
for deb in "$W"/linux-{image,headers}-*"$LOCALVERSION"_*.deb; do
  if dpkg-deb -c "$deb" | grep -q 'signing_key\.pem'; then
    echo "$deb carries the module signing key" >&2; exit 1
  fi
  cp -v "$deb" "$OUT"/
done

# --- matching userland (tools only, no module) -------------------------------
cd "$ZSRC"
make distclean >/dev/null 2>&1 || true
# Every path pinned under /usr: the target rootfs is merged-usr.
# --enable-systemd / --disable-sysvinit: configure decides systemd support by
# running `systemctl --version` on the BUILD machine, and this runs in a bare
# debian:trixie container that has no systemctl. So every tarball shipped only
# /etc/init.d/zfs-* and none of zfs-mount.service, zfs-import-cache.service,
# zfs.target or the mount generator; the target (systemd PID 1) never mounted
# any dataset but root, and a split layout booted with /home unmounted.
# SysV scripts off so systemd sees one set of units, not wrappers beside them.
./configure --with-config=user --prefix=/usr --sysconfdir=/etc \
  --enable-systemd --disable-sysvinit \
  --with-udevdir=/usr/lib/udev --with-udevruledir=/usr/lib/udev/rules.d \
  --with-mounthelperdir=/usr/sbin \
  --with-systemdunitdir=/usr/lib/systemd/system \
  --with-systemdgeneratordir=/usr/lib/systemd/system-generators
make -j"$(nproc)"
DEST="$W/zfs-userland"
make install DESTDIR="$DEST"
tar -C "$DEST" --owner=root --group=root -czf "$OUT/zfs-userland.tar.gz" .
ls -l "$OUT"
