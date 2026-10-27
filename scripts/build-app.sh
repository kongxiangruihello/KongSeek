#!/bin/bash
# Builds KongSeek.app into ./build and, with --install, copies it to /Applications.
#
#   scripts/build-app.sh             build only
#   scripts/build-app.sh --install   build, quit the running copy, install, launch
#   scripts/build-app.sh --test      run the unit tests first
#
# Signing: uses a code-signing certificate named "KongSeek Local Signing", or the
# "KongFetch Local Signing" one you may already have (or $KONGSEEK_SIGN_IDENTITY),
# so macOS keeps folder-access permissions across updates. Otherwise signs ad hoc.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p build
log="$root/build/build.log"
exec > >(tee "$log") 2>&1

install=0
test=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --test) test=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

echo "== KongSeek build $(date '+%Y-%m-%d %H:%M:%S') =="
sw_vers -productVersion | sed 's/^/macOS /'
xcrun swift --version 2>&1 | head -1

if [[ $test -eq 1 ]]; then
  echo "== tests =="
  xcrun swift test
fi

echo "== compile =="
xcrun swift build -c release --product KongSeek
bin_dir="$(xcrun swift build -c release --show-bin-path)"

# Assemble outside the project folder: files in iCloud-synced folders pick up
# extended attributes that codesign rejects.
staging="$(mktemp -d "${TMPDIR:-/tmp}/kongseek-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/KongSeek.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/KongSeek" "$app/Contents/MacOS/KongSeek"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
build_number="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
# Where this build came from, for the in-app updater (设置 › 通用). The commit is
# recorded only when the folder has no local changes, so it describes the code exactly.
plutil -insert KSSourceRoot -string "$root" "$app/Contents/Info.plist"
commit=""
if [[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
  commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -n "$commit" ]]; then
  plutil -insert KSSourceCommit -string "$commit" "$app/Contents/Info.plist"
  echo "Source: $root @ ${commit:0:7}"
else
  echo "Source: $root (local changes; commit not recorded)"
fi

echo "== icon =="
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

xattr -cr "$app"

echo "== sign =="
identity=""
for candidate in "${KONGSEEK_SIGN_IDENTITY:-}" "KongSeek Local Signing" "KongFetch Local Signing"; do
  [[ -z "$candidate" ]] && continue
  if security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$candidate\""; then
    identity="$candidate"
    break
  fi
done
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --identifier com.kongxiangrui.KongSeek "$app"
  echo "Signed with stable identity: $identity"
else
  codesign --force --sign - --identifier com.kongxiangrui.KongSeek "$app"
  echo "WARNING: no local signing certificate found; signed ad hoc."
  echo "         macOS may ask again for folder access after every update."
fi
codesign --verify --strict "$app" || echo "NOTE: codesign --verify reported a trust warning (normal for a self-signed certificate)."

rm -rf "$root/build/KongSeek.app"
ditto "$app" "$root/build/KongSeek.app"
echo "Built: $root/build/KongSeek.app"

if [[ $install -eq 1 ]]; then
  echo "== install =="
  osascript -e 'tell application id "com.kongxiangrui.KongSeek" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x KongSeek >/dev/null 2>&1 || true
  rm -rf /Applications/KongSeek.app
  ditto "$app" /Applications/KongSeek.app
  open /Applications/KongSeek.app
  echo "Installed: /Applications/KongSeek.app"
fi
