#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/repo" "$test_root/bin"
cp "$repo_root/update.sh" "$repo_root/package.nix" "$test_root/repo/"
cp "$test_root/repo/package.nix" "$test_root/package.nix.before"

current_download_base="$(sed -n 's/^  downloadBase = "\(.*\)";$/\1/p' "$repo_root/package.nix")"
current_build_id="$(sed -n 's/^  buildId = "\(.*\)";$/\1/p' "$repo_root/package.nix")"
current_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$repo_root/package.nix")"
current_deb_file="$(sed -n 's/^  debFile = "\(.*\)";$/\1/p' "$repo_root/package.nix")"
current_hash="$(sed -n 's/^    hash = "\(.*\)";$/\1/p' "$repo_root/package.nix")"
current_deb_filename="${current_deb_file//\$\{finalAttrs.version\}/$current_version}"

export TEST_DOWNLOAD_BASE="$current_download_base"
export TEST_BUILD_ID="$current_build_id"
export TEST_VERSION="$current_version"
export TEST_DEB_FILENAME="$current_deb_filename"
export TEST_HASH="$current_hash"

cat >"$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"

case "$url" in
  */linux-x64/*)
    printf '{"version":"%s","url":"%s/linux-x64/%s/Sand-%s-x86_64.AppImage.zsync"}\n' \
      "$TEST_VERSION" "$TEST_DOWNLOAD_BASE" "$TEST_VERSION" "$TEST_VERSION"
    ;;
  */linux-arm64/*)
    printf '{"version":"%s","url":"%s/%s/linux/arm64/Sand-%s-aarch64.AppImage.zsync"}\n' \
      "$TEST_VERSION" "$TEST_DOWNLOAD_BASE" "$TEST_BUILD_ID" "$TEST_VERSION"
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
EOF

cat >"$test_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1 $2" = "store prefetch-file" ]; then
  url="${!#}"
  if [ "${url##*/}" = "$TEST_DEB_FILENAME" ]; then
    printf '{"hash":"%s","storePath":"/tmp/mock-grok-bot.deb"}\n' "$TEST_HASH"
    exit 0
  fi
  exit 1
fi

echo "unexpected nix invocation: $*" >&2
exit 1
EOF

cat >"$test_root/bin/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
field="${!#}"

case "$field" in
  Package) printf '%s\n' grok-bot ;;
  Version) printf '%s\n' "$TEST_VERSION" ;;
  Architecture) printf '%s\n' amd64 ;;
  *)
    echo "unexpected dpkg-deb field: $field" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$test_root/bin/"*

output="$({
  cd "$test_root/repo"
  PATH="$test_root/bin:$PATH" GROK_BOT_UPDATE_ENV=1 ./update.sh
} 2>&1)"

printf '%s\n' "$output"
grep -Fq 'warning: linux-x64 feed returned an unsupported artifact URL' <<<"$output"
grep -Fq '/linux-arm64/' <<<"$output"
grep -Fq "already at $current_version ($current_build_id)" <<<"$output"
cmp "$test_root/package.nix.before" "$test_root/repo/package.nix"
