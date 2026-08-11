#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash curl jq coreutils gnused nix
#
# Bump package.nix to the current stable Grok Bot release.
#
# Upstream's Linux update feed is empty (`linux-x64` answers 204 for every
# version), but the build id in the URL is shared across platforms, so we read
# it from the darwin-arm64 feed and rebuild the Linux .deb URL from it.
#
# Pass a .deb URL to pin an exact build instead:
#   ./update.sh https://downloads.cursor.com/sand/stable/<buildId>/linux/x64/Grok_Bot_<version>.deb

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

FEED_PLATFORM="darwin-arm64"
FEED_URL="https://api2.cursor.sh/updates/api/update/${FEED_PLATFORM}/sand/0.0.1/$(cat /proc/sys/kernel/random/uuid)/stable"

if [ $# -ge 1 ]; then
  deb_url="$1"
  version="$(sed -n 's|.*/Grok_Bot_\(.*\)\.deb$|\1|p' <<<"$deb_url")"
  build_id="$(sed -n 's|.*/sand/stable/\([^/]*\)/.*|\1|p' <<<"$deb_url")"
  if [ -z "$version" ] || [ -z "$build_id" ]; then
    echo "error: could not parse version and build id out of: $deb_url" >&2
    exit 1
  fi
else
  echo "checking $FEED_URL" >&2
  response="$(curl -fsSL "$FEED_URL")"
  version="$(jq -er '.name' <<<"$response")"
  build_id="$(jq -er '.url' <<<"$response" | sed -n 's|.*/sand/stable/\([^/]*\)/.*|\1|p')"
  if [ -z "$build_id" ]; then
    echo "error: could not parse build id out of: $response" >&2
    exit 1
  fi
  deb_url="https://downloads.cursor.com/sand/stable/${build_id}/linux/x64/Grok_Bot_${version}.deb"
fi

current_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)"
current_build_id="$(sed -n 's/^  buildId = "\(.*\)";$/\1/p' package.nix)"

if [ "$version" = "$current_version" ] && [ "$build_id" = "$current_build_id" ]; then
  echo "already at $version ($build_id)"
  exit 0
fi

echo "$current_version ($current_build_id) -> $version ($build_id)" >&2
echo "prefetching $deb_url" >&2
hash="$(nix store prefetch-file --json --hash-type sha256 "$deb_url" | jq -er '.hash')"

sed -i \
  -e "s|^  buildId = \".*\";$|  buildId = \"${build_id}\";|" \
  -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
  -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
  package.nix

echo "package.nix updated to $version"
