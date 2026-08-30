#!/usr/bin/env bash
#
# Bump package.nix to the current stable Grok Bot release.
#
# The Linux update feed advertises an AppImage zsync URL, not the .deb, but
# the download namespace and build id are shared across Linux artifacts. Read
# those values from linux-x64 (falling back to linux-arm64), rebuild the .deb
# URL, and probe the filenames upstream has used.
#
# Pass a .deb URL to pin an exact build instead:
#   ./update.sh https://downloads.cursor.com/grokbot/stable/<buildId>/linux/x64/grok-bot_<version>_amd64.deb

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# Run with tools from this flake's locked nixpkgs input. Unlike a nix-shell
# shebang, this does not require CI or users to configure a NIX_PATH/channel.
if [[ "${GROK_BOT_UPDATE_ENV:-}" != 1 ]]; then
  exec nix shell --inputs-from . \
    nixpkgs#bash \
    nixpkgs#curl \
    nixpkgs#jq \
    nixpkgs#coreutils \
    nixpkgs#gnused \
    nixpkgs#nix \
    nixpkgs#dpkg \
    --command env GROK_BOT_UPDATE_ENV=1 bash ./update.sh "$@"
fi

# Keep a stable updater identity so staged-rollout bucketing is deterministic
# across ephemeral CI runners.
FEED_CLIENT_ID="07d67027-2556-4c0e-9fd9-e0bde18922ca"
FEED_PLATFORMS=(linux-x64 linux-arm64)

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

parse_version_from_deb_url() {
  local url="$1"
  version="$(sed -En 's|.*/Grok_Bot_([^/]+)\.deb$|\1|p' <<<"$url")"
  if [ -z "$version" ]; then
    version="$(sed -En 's|.*/grok-bot_([^/]+)_amd64\.deb$|\1|p' <<<"$url")"
  fi
}

deb_file_nix_from_url() {
  local url="$1"
  local filename="${url##*/}"
  local replacement='${finalAttrs.version}'
  printf '%s\n' "${filename//${version}/${replacement}}"
}

http_head_ok() {
  local url="$1"
  local code
  code="$(curl --retry 3 --retry-all-errors -sS -o /dev/null -w '%{http_code}' -I "$url" || true)"
  [ "$code" = "200" ]
}

resolve_linux_deb_url() {
  local candidates=(
    "${download_base}/${build_id}/linux/x64/grok-bot_${version}_amd64.deb"
    "${download_base}/${build_id}/linux/x64/Grok_Bot_${version}.deb"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    echo "probing $candidate" >&2
    if http_head_ok "$candidate"; then
      deb_url="$candidate"
      return 0
    fi
  done

  echo "error: no Linux amd64 .deb found for $version ($build_id)" >&2
  printf 'tried:\n' >&2
  printf '  %s\n' "${candidates[@]}" >&2
  exit 1
}

fetch_feed() {
  local platform="$1"
  local url="https://api2.cursor.sh/updates/api/update/${platform}/sand/0.0.1/${FEED_CLIENT_ID}/stable"
  echo "checking $url" >&2
  local body code
  body="$(mktemp)"
  code="$(curl --retry 3 --retry-all-errors -sS -o "$body" -w '%{http_code}' "$url" || true)"
  if [ "$code" = "200" ] && [ -s "$body" ]; then
    cat "$body"
    rm -f "$body"
    return 0
  fi
  rm -f "$body"
  return 1
}

case $# in
  0)
    response=""
    for platform in "${FEED_PLATFORMS[@]}"; do
      if response="$(fetch_feed "$platform")"; then
        break
      fi
    done
    if [ -z "$response" ]; then
      echo "error: no Linux update feed returned a usable response" >&2
      exit 1
    fi
    version="$(jq -er '.name // .version' <<<"$response")"
    feed_artifact_url="$(jq -er '.url' <<<"$response")"
    parse_download_location "$feed_artifact_url"
    resolve_linux_deb_url
    ;;
  1)
    deb_url="$1"
    parse_version_from_deb_url "$deb_url"
    parse_download_location "$deb_url"
    if [ -z "$version" ]; then
      echo "error: could not parse version out of: $deb_url" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [linux amd64 .deb URL]" >&2
    exit 2
    ;;
esac

if [[ ! "$version" =~ ^[0-9][0-9A-Za-z._+~-]*$ ]]; then
  echo "error: invalid release version: $version" >&2
  exit 1
fi

deb_file_nix="$(deb_file_nix_from_url "$deb_url")"
if [[ ! "$deb_file_nix" =~ \$\{finalAttrs\.version\} ]]; then
  echo "error: could not derive a Nix debFile template from: $deb_url" >&2
  exit 1
fi

current_download_base="$(sed -n 's/^  downloadBase = "\(.*\)";$/\1/p' package.nix)"
current_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)"
current_build_id="$(sed -n 's/^  buildId = "\(.*\)";$/\1/p' package.nix)"
current_deb_file="$(sed -n 's/^  debFile = "\(.*\)";$/\1/p' package.nix)"
current_hash="$(sed -n 's/^    hash = "\(.*\)";$/\1/p' package.nix)"

if [ -z "$current_download_base" ] || [ -z "$current_version" ] \
  || [ -z "$current_build_id" ] || [ -z "$current_deb_file" ] \
  || [ -z "$current_hash" ]; then
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
  && [ "$deb_file_nix" = "$current_deb_file" ] \
  && [ "$hash" = "$current_hash" ]; then
  echo "already at $version ($build_id)"
  exit 0
fi

echo "$current_version ($current_build_id) -> $version ($build_id)" >&2

sed -i \
  -e "s|^  downloadBase = \".*\";$|  downloadBase = \"${download_base}\";|" \
  -e "s|^  buildId = \".*\";$|  buildId = \"${build_id}\";|" \
  -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
  -e "s|^  debFile = \".*\";$|  debFile = \"${deb_file_nix}\";|" \
  -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
  package.nix

updated_download_base="$(sed -n 's/^  downloadBase = "\(.*\)";$/\1/p' package.nix)"
updated_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)"
updated_build_id="$(sed -n 's/^  buildId = "\(.*\)";$/\1/p' package.nix)"
updated_deb_file="$(sed -n 's/^  debFile = "\(.*\)";$/\1/p' package.nix)"
updated_hash="$(sed -n 's/^    hash = "\(.*\)";$/\1/p' package.nix)"

if [ "$updated_download_base" != "$download_base" ] \
  || [ "$updated_version" != "$version" ] \
  || [ "$updated_build_id" != "$build_id" ] \
  || [ "$updated_deb_file" != "$deb_file_nix" ] \
  || [ "$updated_hash" != "$hash" ]; then
  echo "error: failed to write all release metadata to package.nix" >&2
  exit 1
fi

echo "package.nix updated to $version"
