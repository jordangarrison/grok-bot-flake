#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash curl jq coreutils gnused nix dpkg
#
# Bump package.nix to the current stable Grok Bot release.
#
# Upstream's Linux update feed is empty (`linux-x64` answers 204 for every
# version), but the download namespace and build id are shared across
# platforms. Read those values from the darwin-arm64 feed, then rebuild and
# validate the Linux .deb URL.
#
# Pass a .deb URL to pin an exact build instead:
#   ./update.sh https://downloads.cursor.com/grokbot/stable/<buildId>/linux/x64/Grok_Bot_<version>.deb

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

FEED_PLATFORM="darwin-arm64"
# Keep a stable updater identity so staged-rollout bucketing is deterministic
# across ephemeral CI runners.
FEED_CLIENT_ID="07d67027-2556-4c0e-9fd9-e0bde18922ca"
FEED_URL="https://api2.cursor.sh/updates/api/update/${FEED_PLATFORM}/sand/0.0.1/${FEED_CLIENT_ID}/stable"

parse_download_location() {
  local url="$1"

  download_base="$(sed -En 's|^(https://downloads\.cursor\.com/[^/]+/stable)/[^/]+/.*$|\1|p' <<<"$url")"
  build_id="$(sed -En 's|^https://downloads\.cursor\.com/[^/]+/stable/([^/]+)/.*$|\1|p' <<<"$url")"

  if [[ ! "$download_base" =~ ^https://downloads\.cursor\.com/[a-z0-9-]+/stable$ ]] \
    || [[ ! "$build_id" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: could not parse a valid download namespace and build id out of: $url" >&2
    exit 1
  fi
}

case $# in
  0)
    echo "checking $FEED_URL" >&2
    response="$(curl --retry 3 --retry-all-errors -fsSL "$FEED_URL")"
    version="$(jq -er '.name // .version' <<<"$response")"
    feed_artifact_url="$(jq -er '.url' <<<"$response")"
    parse_download_location "$feed_artifact_url"
    deb_url="${download_base}/${build_id}/linux/x64/Grok_Bot_${version}.deb"
    ;;
  1)
    deb_url="$1"
    version="$(sed -En 's|.*/Grok_Bot_([^/]+)\.deb$|\1|p' <<<"$deb_url")"
    parse_download_location "$deb_url"
    if [ -z "$version" ]; then
      echo "error: could not parse version out of: $deb_url" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [Grok_Bot_<version>.deb URL]" >&2
    exit 2
    ;;
esac

if [[ ! "$version" =~ ^[0-9][0-9A-Za-z._+~-]*$ ]]; then
  echo "error: invalid release version: $version" >&2
  exit 1
fi

current_download_base="$(sed -n 's/^  downloadBase = "\(.*\)";$/\1/p' package.nix)"
current_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)"
current_build_id="$(sed -n 's/^  buildId = "\(.*\)";$/\1/p' package.nix)"
current_hash="$(sed -n 's/^    hash = "\(.*\)";$/\1/p' package.nix)"

if [ -z "$current_download_base" ] || [ -z "$current_version" ] \
  || [ -z "$current_build_id" ] || [ -z "$current_hash" ]; then
  echo "error: could not read the current release metadata from package.nix" >&2
  exit 1
fi

echo "prefetching $deb_url" >&2
prefetch="$(nix store prefetch-file --json --hash-type sha256 "$deb_url")"
hash="$(jq -er '.hash' <<<"$prefetch")"
deb_path="$(jq -er '.storePath' <<<"$prefetch")"

package_name="$(dpkg-deb -f "$deb_path" Package)"
package_version="$(dpkg-deb -f "$deb_path" Version)"
package_architecture="$(dpkg-deb -f "$deb_path" Architecture)"

case "$package_name" in
  sand | grok-bot) ;;
  *)
    echo "error: expected package 'sand' or 'grok-bot', got '$package_name'" >&2
    exit 1
    ;;
esac
if [ "$package_version" != "$version" ]; then
  echo "error: feed version '$version' does not match .deb version '$package_version'" >&2
  exit 1
fi
if [ "$package_architecture" != "amd64" ]; then
  echo "error: expected amd64 .deb, got '$package_architecture'" >&2
  exit 1
fi

if [ "$download_base" = "$current_download_base" ] \
  && [ "$version" = "$current_version" ] \
  && [ "$build_id" = "$current_build_id" ] \
  && [ "$hash" = "$current_hash" ]; then
  echo "already at $version ($build_id)"
  exit 0
fi

echo "$current_version ($current_build_id) -> $version ($build_id)" >&2

sed -i \
  -e "s|^  downloadBase = \".*\";$|  downloadBase = \"${download_base}\";|" \
  -e "s|^  buildId = \".*\";$|  buildId = \"${build_id}\";|" \
  -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
  -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
  package.nix

updated_download_base="$(sed -n 's/^  downloadBase = "\(.*\)";$/\1/p' package.nix)"
updated_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)"
updated_build_id="$(sed -n 's/^  buildId = "\(.*\)";$/\1/p' package.nix)"
updated_hash="$(sed -n 's/^    hash = "\(.*\)";$/\1/p' package.nix)"

if [ "$updated_download_base" != "$download_base" ] \
  || [ "$updated_version" != "$version" ] \
  || [ "$updated_build_id" != "$build_id" ] \
  || [ "$updated_hash" != "$hash" ]; then
  echo "error: failed to write all release metadata to package.nix" >&2
  exit 1
fi

echo "package.nix updated to $version"
