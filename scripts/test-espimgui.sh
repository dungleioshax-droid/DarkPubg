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

cxx="${CXX:-c++}"
outdir="${TMPDIR:-/tmp}"
common="-std=c++17 -O1 -g -Wall -Wextra -Wno-unused-parameter -pthread -I. -IVendor/imgui"

# 1) Protocol shared memory + translator draw list (ImGui core = TU riêng).
# shellcheck disable=SC2086
"$cxx" $common \
    tests/esprender_shm_test.cpp \
    Vendor/imgui/imgui.cpp \
    Vendor/imgui/imgui_draw.cpp \
    Vendor/imgui/imgui_tables.cpp \
    Vendor/imgui/imgui_widgets.cpp \
    -o "$outdir/ds-espimgui-test"
"$outdir/ds-espimgui-test"

# 2) Đúng kiểu TU amalgam của imguirender/DSEspImGui.mm (header ESP trước,
#    rồi 4 file imgui*.cpp trong cùng TU) — bắt lỗi thứ tự include như lần
#    CI "Build Release" đã fail.
# shellcheck disable=SC2086
"$cxx" $common tests/imgui_amalgam_check.cpp -o "$outdir/ds-espimgui-amalgam"
"$outdir/ds-espimgui-amalgam"
