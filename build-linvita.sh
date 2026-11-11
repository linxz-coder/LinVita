#!/usr/bin/env bash
# Local iPhone device build. AltStore/AltServer supplies the developer signature.
set -euo pipefail
LINVITA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="${LINVITA_TOOLS_DIR:-$LINVITA_ROOT/../.tools}/bin:$PATH"
export LC_ALL=C
export LANG=C
for tool in cmake ninja xcodegen xcodebuild; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
cd "$LINVITA_ROOT"
cmake --preset ios-device
cmake --build --preset ios-device --target vita3k --parallel "${LINVITA_JOBS:-6}"
ios/Vita3K/scripts/stage-core.sh device
# A device-only target build does not depend on Xcode's connected-device or
# simulator destination inventory. The SDK and architecture remain iOS/arm64.
xcodebuild -project ios/Vita3K/Vita3K.xcodeproj -target Vita3K \
    -configuration Release -sdk iphoneos \
    SYMROOT="$LINVITA_ROOT/build/linvita-app" \
    OBJROOT="$LINVITA_ROOT/build/linvita-app-obj" \
    -jobs "${LINVITA_JOBS:-6}" CODE_SIGNING_ALLOWED=NO build
LINVITA_APP="$LINVITA_ROOT/build/linvita-app/Release-iphoneos/Vita3K.app"
LINVITA_OUT="${LINVITA_OUTPUT_DIR:-$LINVITA_ROOT/../artifacts}"
mkdir -p "$LINVITA_OUT"
LINVITA_STAGE="$(mktemp -d "$LINVITA_ROOT/build/linvita-package.XXXXXX")"
trap 'rm -rf -- "$LINVITA_STAGE"' EXIT
mkdir "$LINVITA_STAGE/Payload"
ditto --norsrc --noextattr "$LINVITA_APP" "$LINVITA_STAGE/Payload/LinVita.app"
# Ad-hoc signing records get-task-allow for sideload tools. It is not an
# installable developer signature and will be replaced by AltStore/AltServer.
codesign --force --sign - "$LINVITA_STAGE/Payload/LinVita.app/Frameworks/libVita3KCore.dylib"
codesign --force --sign - --entitlements ios/Vita3K/App/LinVita.entitlements \
    "$LINVITA_STAGE/Payload/LinVita.app"
codesign --verify --deep --strict "$LINVITA_STAGE/Payload/LinVita.app"
LINVITA_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$LINVITA_APP/Info.plist")"
LINVITA_IPA="LinVita-${LINVITA_VERSION}-test.ipa"
ditto -c -k --norsrc --noextattr --keepParent "$LINVITA_STAGE/Payload" "$LINVITA_STAGE/$LINVITA_IPA"
mv -f "$LINVITA_STAGE/$LINVITA_IPA" "$LINVITA_OUT/$LINVITA_IPA"
shasum -a 256 "$LINVITA_OUT/$LINVITA_IPA"
