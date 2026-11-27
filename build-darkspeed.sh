#!/bin/sh

set -eu

version=$(./get-version.sh)
archive_path="${DARKSPEED_ARCHIVE_PATH:-$PWD/DarkPubg.xcarchive}"
package_dir="$PWD/packages"
package_path="$package_dir/DarkPubg_${version}.ipa"
temporary_dir=$(mktemp -d)
bridge_entry="$PWD/darksword/DSBridge.mm"
bridge_fragments="
darksword/DSBridgeExploit.inc.mm
darksword/DSBridgeESP.inc.mm
darksword/DSBridgePUBG.inc.mm
"

cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

verify_bridge_fragments() {
    for relative_path in $bridge_fragments; do
        fragment_path="$PWD/$relative_path"
        include_name=$(basename "$relative_path")
        if [ ! -f "$fragment_path" ]; then
            echo "Missing DSBridge fragment: $relative_path" >&2
            exit 1
        fi
        if ! grep -q "#include \"$include_name\"" "$bridge_entry"; then
            echo "DSBridge.mm does not include $include_name" >&2
            exit 1
        fi
    done
}

verify_bridge_fragments

if command -v sips >/dev/null 2>&1 && [ -f "$PWD/supports/Assets.xcassets/AppIcon.appiconset/AppIcon.jpg" ]; then
    sips -s format png -z 180 180 "$PWD/supports/Assets.xcassets/AppIcon.appiconset/AppIcon.jpg" --out "$PWD/Resources/icon.png" >/dev/null
fi

set -- clean archive \
    -scheme DarkPubg \
    -project DarkPubg.xcodeproj \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    -xcconfig supports/darksword.xcconfig \
    PRODUCT_BUNDLE_IDENTIFIER=vn.pubgmobile.darksword \
    CODE_SIGN_ENTITLEMENTS=supports/entitlements-darksword.plist \
    IPHONEOS_DEPLOYMENT_TARGET=16.0

# -allowProvisioningUpdates makes xcodebuild phone Apple for a profile. On a CI
# runner with no signed-in account that either stalls or fails the build, so it
# is only passed when we are actually signing.
if [ "${DARKSPEED_UNSIGNED:-0}" = "1" ]; then
    set -- "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
else
    set -- "$@" -allowProvisioningUpdates
fi

echo "Building DarkPubg $version"
echo "Using split DSBridge fragments:"
for relative_path in $bridge_fragments; do
    echo "  $relative_path"
done
xcodebuild "$@"

application_path="$archive_path/Products/Applications/DarkPubg.app"
if [ ! -d "$application_path" ]; then
    echo "Archive does not contain DarkPubg.app" >&2
    exit 1
fi

mkdir -p "$temporary_dir/Payload" "$package_dir"
cp -R "$application_path" "$temporary_dir/Payload/DarkPubg.app"
rm -f "$package_path"
(cd "$temporary_dir" && /usr/bin/zip -qry "$package_path" Payload)

if [ "${DARKSPEED_UNSIGNED:-0}" = "1" ]; then
    echo "Wrote $package_path (unsigned; sign it before installation)"
else
    echo "Wrote $package_path"
fi
