#!/bin/bash
# Decide what to build: the newest linux source package Debian publishes on
# the 6.12 line (trixie + trixie-security) and the newest 7.x (forky/sid) whose
# minor OpenZFS declares support for, each against the latest OpenZFS release.
# Only versions in Debian's archive are ever built. Skips anything published.
# Prints GITHUB_OUTPUT lines: zfs=<tag> and matrix=<json>.
set -euo pipefail
ZFS_GIT=https://github.com/openzfs/zfs.git

# .99 tags are master placeholders that outrank real releases in a sort.
zfs=$(git ls-remote --tags --refs "$ZFS_GIT" 'zfs-*' | awk -F/ '{print $NF}' |
  grep -E '^zfs-[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '\.99$' | sort -V | tail -1)
max=$(curl -fsSL "https://raw.githubusercontent.com/openzfs/zfs/${zfs}/META" |
  awk '/^Linux-Maximum:/{print $2}')
[[ -n $zfs && -n $max ]] || { echo "cannot resolve zfs tag / Linux-Maximum" >&2; exit 1; }

# Plain revisions only (6.12.113-1): no ~exp/~bpo or +debNuN oddities.
# ponytail: a +debNuN-only security version would be skipped; widen the regex if Debian ever does that.
sources() { curl -fsSL "$1/dists/$2/main/source/Sources.xz" | xz -dc |
  awk '/^Package: /{p=($2=="linux")} p && /^Version: /{print $2}'; }
# Each index separately: a security mirror hiccup must fail the plan, not
# quietly make an older 6.12 look newest.
vers=""
for idx in "https://deb.debian.org/debian trixie" "https://deb.debian.org/debian forky" \
  "https://deb.debian.org/debian sid" "https://security.debian.org/debian-security trixie-security"; do
  v=$(sources $idx) && [[ -n $v ]] || { echo "cannot read linux versions from $idx" >&2; exit 1; }
  vers+="$v"$'\n'
done
vers=$(grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+$' <<<"$vers" | grep -E '^(6\.12[.-]|7\.)' | sort -u)
newest() { grep -E "^$1[.-]" <<<"$vers" | sort -t- -k1,1V -k2,2n | tail -1; }

minor7=$(grep -oE '^7\.[0-9]+' <<<"$vers" | sort -uV |
  awk -v max="$max" '{split($1,v,"."); split(max,m,".");
    if (v[1] < m[1] || (v[1] == m[1] && v[2] <= m[2])) print $1}' | tail -1)

matrix=()
for d in "$(newest '6\.12')" ${minor7:+"$(newest "${minor7//./\\.}")"}; do
  rel="${d}-${zfs}"
  if gh release view "$rel" >/dev/null 2>&1; then
    echo "skip $rel (published)" >&2
  else
    matrix+=("{\"dver\":\"$d\",\"rel\":\"$rel\"}")
  fi
done
echo "zfs=$zfs"
echo "matrix=[$(IFS=,; echo "${matrix[*]}")]"
