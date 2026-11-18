#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/repo" "$test_root/bin"
cp "$repo_root/update.sh" "$repo_root/package.nix" "$repo_root/package-darwin.nix" "$test_root/repo/"
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
export TEST_DARWIN_HASH="$(sed -n 's/^    hash = "\(.*\)";$/\1/p' "$repo_root/package-darwin.nix")"
export TEST_DARWIN_ZIP="$test_root/grok-bot.zip"
write_zip() {
  python3 - "$TEST_DARWIN_ZIP" "$1" <<'PYTHON'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("Grok Bot.app/Contents/Info.plist", plistlib.dumps({
        "CFBundleShortVersionString": sys.argv[2],
        "CFBundleIdentifier": "com.anysphere.sand",
        "CFBundleExecutable": "Grok Bot",
    }))
PYTHON
}
write_zip "$TEST_VERSION"

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
  if [[ "$url" == */darwin-arm64/*/Grok_Bot_*.zip ]]; then
    printf '{"hash":"%s","storePath":"%s"}\n' "$TEST_DARWIN_HASH" "$TEST_DARWIN_ZIP"
    exit 0
  fi
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

cmp "$repo_root/package-darwin.nix" "$test_root/repo/package-darwin.nix"

# A Linux release bump must pin the same macOS version and its own hash.
export TEST_VERSION=9.9.9
export TEST_DEB_FILENAME="grok-bot_${TEST_VERSION}_amd64.deb"
export TEST_DARWIN_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
write_zip "$TEST_VERSION"
(
  cd "$test_root/repo"
  PATH="$test_root/bin:$PATH" GROK_BOT_UPDATE_ENV=1 ./update.sh
)
grep -Fq 'version = "9.9.9";' "$test_root/repo/package.nix"
grep -Fq 'version = "9.9.9";' "$test_root/repo/package-darwin.nix"
grep -Fq "$TEST_DARWIN_HASH" "$test_root/repo/package-darwin.nix"

# A stale/mismatched macOS artifact must leave both package pins unchanged.
cp "$test_root/repo/package.nix" "$test_root/linux.before"
cp "$test_root/repo/package-darwin.nix" "$test_root/darwin.before"
export TEST_VERSION=9.9.10
export TEST_DEB_FILENAME="grok-bot_${TEST_VERSION}_amd64.deb"
if (
  cd "$test_root/repo"
  PATH="$test_root/bin:$PATH" GROK_BOT_UPDATE_ENV=1 ./update.sh
) >"$test_root/mismatch.log" 2>&1; then
  echo "error: updater accepted a mismatched macOS version" >&2
  exit 1
fi
grep -Fq 'macOS version' "$test_root/mismatch.log"
cmp "$test_root/linux.before" "$test_root/repo/package.nix"
cmp "$test_root/darwin.before" "$test_root/repo/package-darwin.nix"
echo "PASS: feed fallback, joint release update, mismatched macOS artifact rejection"
