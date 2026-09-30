#!/bin/sh
# Build DSPortHelper (XPC service) bằng clang trực tiếp — KHÔNG đụng project
# chính (tránh vỡ build app). Nhúng vào Payload/DarkSpeed.app/XPCServices/.
# Usage: ./Helper/build-helper.sh <Payload dir chứa DarkSpeed.app>
# Chạy từ repo root (như build-darkspeed.sh).

set -eu

payload_dir="${1:?usage: build-helper.sh <Payload dir>}"
app_dir="$payload_dir/DarkSpeed.app"
xpc_dir="$app_dir/XPCServices/com.huami.darkspeed.porthelper.xpc"

if [ ! -d "$app_dir" ]; then
    echo "build-helper: $app_dir not found" >&2
    exit 1
fi

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"

mkdir -p "$xpc_dir"
"$CC" -arch arm64e \
    -miphoneos-version-min=16.0 -isysroot "$SDKROOT" \
    -fobjc-arc -fblocks -DUSE_DARKSWORD=1 \
    -I darksword -I ESP \
    -I headers \
    -I Vendor/darksword-headers -I Vendor/darksword-lib/choma \
    -I Vendor/darksword-kexploit -I Vendor/darksword-kexploit/pe \
    -I Vendor/darksword-kexploit/TaskRop \
    Helper/DSPortHelper-main.m \
    ESP/ESPTask.mm ESP/ESPLog.mm \
    Vendor/darksword-kexploit/darksword.m \
    Vendor/darksword-kexploit/offsets.m \
    Vendor/darksword-kexploit/pe/sbx.m \
    Vendor/darksword-kexploit/pe/vfs.m \
    Vendor/darksword-kexploit/pe/vnode.m \
    Vendor/darksword-kexploit/TaskRop/exc.m \
    Vendor/darksword-kexploit/TaskRop/findcachedataoff.m \
    Vendor/darksword-kexploit/TaskRop/pac.m \
    Vendor/darksword-kexploit/TaskRop/RemoteCall.m \
    Vendor/darksword-kexploit/TaskRop/thread.m \
    Vendor/darksword-kexploit/TaskRop/vm.m \
    Vendor/darksword-kexploit/utils.m \
    -L Vendor/darksword-lib-thin -lxpf -lgrabkernel2 \
    -Wl,-rpath,@loader_path/../../Frameworks \
    -framework Foundation -framework CoreFoundation -framework IOKit \
    -o "$xpc_dir/DSPortHelper"
cp Helper/Info.plist "$xpc_dir/Info.plist"
echo "Embedded DSPortHelper into $xpc_dir"
