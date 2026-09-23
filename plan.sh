#!/bin/bash
# Decide what to build: the newest 6.12.y (the LTS line Debian 13 tracks) and
# the newest 7.x stable release OpenZFS declares support for, each against the
# latest OpenZFS release. Skips anything already published as a release.
# Prints GITHUB_OUTPUT lines: zfs=<tag> and matrix=<json>.
set -euo pipefail
STABLE=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
ZFS_GIT=https://github.com/openzfs/zfs.git

# .99 tags are master placeholders that outrank real releases in a sort.
zfs=$(git ls-remote --tags --refs "$ZFS_GIT" 'zfs-*' | awk -F/ '{print $NF}' |
  grep -E '^zfs-[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '\.99$' | sort -V | tail -1)
max=$(curl -fsSL "https://raw.githubusercontent.com/openzfs/zfs/${zfs}/META" |
  awk '/^Linux-Maximum:/{print $2}')
[[ -n $zfs && -n $max ]] || { echo "cannot resolve zfs tag / Linux-Maximum" >&2; exit 1; }

tags=$(git ls-remote --tags --refs "$STABLE" 'v6.12*' 'v7.*' | awk -F/ '{print $NF}')
newest() { grep -E "^v$1(\.[0-9]+)?$" <<<"$tags" | sort -V | tail -1; }

# Newest 7.x minor that OpenZFS supports, then its newest point release.
# Release tags only: a v7.N-rc1 must not make 7.N look available.
minor7=$(grep -E '^v7\.[0-9]+(\.[0-9]+)?$' <<<"$tags" | grep -oE '^v7\.[0-9]+' | sort -uV |
  awk -v max="$max" '{split(substr($1,2),v,"."); split(max,m,".");
    if (v[1] < m[1] || (v[1] == m[1] && v[2] <= m[2])) print substr($1,2)}' | tail -1)

matrix=()
for k in "$(newest 6\\.12)" ${minor7:+"$(newest "${minor7//./\\.}")"}; do
  rel="${k#v}-${zfs}"
  if gh release view "$rel" >/dev/null 2>&1; then
    echo "skip $rel (published)" >&2
  else
    matrix+=("{\"ktag\":\"$k\",\"rel\":\"$rel\"}")
  fi
done
echo "zfs=$zfs"
echo "matrix=[$(IFS=,; echo "${matrix[*]}")]"
