# hyprdebian-kernel

Debian's kernel with OpenZFS compiled in (`CONFIG_ZFS=y`, no module, no dkms),
published as GitHub Releases: image + headers debs and the matching ZFS
userland tarball. A root-on-ZFS machine that installs only these kernels can
never boot a kernel that has no ZFS.

## What gets built

Each release is Debian's own `linux` source package for one version, rebuilt
like this (`build.sh`):

1. fetch `linux_<version>.dsc` and its files from Debian's main or security
   pool (snapshot.debian.org for versions no longer there) and unpack it with
   `dpkg-source -x`. That gives the exact patched tree Debian builds from, all
   of `debian/patches` applied, with checksums checked against the .dsc;
2. take that package's own amd64 config, merged from the same fragments
   Debian's `rules.real` uses (`debian_linux.config_v2` + `kconfig.py`), so a
   7.x kernel gets 7.x's config and not trixie's;
3. OpenZFS grafted in with `copy-builtin`, then `make bindeb-pkg`.

The build checks that `CONFIG_ZFS=y` and `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT=y`
are both in the final config. Lockdown under Secure Boot comes from Debian's
patches; a plain kernel.org kernel doesn't have it.

Differences from Debian's own binary package: no debug info (so no BTF), no Debian signing
certs in the trusted keyring, `LOCALVERSION=-stripped`, and ZFS built in.
In-tree modules are signed with a throwaway key that the build generates and
that is gone when the container exits. Debian's build does the same. The build
fails if that private key ends up in a deb. This CI signs nothing else and
holds no keys: the boot chain (UKI) is signed on each machine with that
machine's MOK key.

## Which versions get built

`plan.sh` runs weekly and on demand (workflow_dispatch). It reads the
archive's source indices and picks:

- **6.12** (trixie's line): the newest version in trixie or trixie-security;
- **7.x** (forky/sid): the newest version whose minor is at or below the
  latest OpenZFS release's `Linux-Maximum`.

Only plain revisions (`6.12.113-1`) count. A version that already has a
release is skipped.

**Lag.** A kernel.org point release shows up here only after Debian has
uploaded it (trixie gets 6.12 updates through trixie-security and point
releases), usually days and sometimes weeks later. Debian may skip some point releases
entirely. The weekly schedule adds up to 7 days on top of that. A 7.x minor
also has to wait for OpenZFS to raise `Linux-Maximum`. If you need a kernel
sooner, run the workflow by hand once Debian has published it.

## Naming

- Release tag: `<debian version>-<zfs tag>`, for example `6.12.113-1-zfs-2.4.4`.
- Packages: `linux-image-<upstream>-stripped` and `linux-headers-<upstream>-stripped`,
  the same names as before. Package version: `<debian version>-zfs<zfs version>`,
  for example `6.12.113-1-zfs2.4.4`. It sorts above the older `6.12.111-zfs2.4.4`
  form. A new Debian revision or a newer ZFS on the same kernel also sorts as an
  upgrade.

**Break for consumers that match release tags:** releases before this change
were tagged `<upstream>-<zfs tag>` (`6.12.111-zfs-2.4.4`). The Debian revision
now sits between the version and `-zfs-`. A tag regex like
`^6\.12\.[0-9.]+-zfs-` (debian13-stripped `build-rootfs.sh`) no longer matches
new releases, so it quietly keeps picking the last old-style one. Allow an
optional `-<rev>`, for example `^6\.12\.[0-9.]+(-[0-9]+)?-zfs-`.

## Running a build locally

```bash
docker run --rm -v "$PWD:/src" debian:trixie /src/build.sh 6.12.113-1 zfs-2.4.4 /src/out
```
