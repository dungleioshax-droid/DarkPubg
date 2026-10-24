#!/bin/sh
#
# Build + chạy test cho renderer ImGui ESP ở máy local (Linux/macOS).
# Không cần Xcode/iOS SDK: chỉ compile ImGui core + protocol + translator
# (phần Metal/UIKit nằm trong imguirender/DSEspImGui.mm, chỉ CI macOS build được).
#
#   ./scripts/test-espimgui.sh
#
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

out="${TMPDIR:-/tmp}/ds-espimgui-test"
cxx="${CXX:-c++}"

"$cxx" -std=c++17 -O1 -g \
    -Wall -Wextra -Wno-unused-parameter \
    -pthread \
    -I. -IVendor/imgui \
    tests/esprender_shm_test.cpp \
    Vendor/imgui/imgui.cpp \
    Vendor/imgui/imgui_draw.cpp \
    Vendor/imgui/imgui_tables.cpp \
    Vendor/imgui/imgui_widgets.cpp \
    -o "$out"

"$out"
