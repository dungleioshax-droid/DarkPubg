//
//  imgui_amalgam_check.cpp
//  Kiểm tra đúng kiểu "một translation unit" mà imguirender/DSEspImGui.mm dùng:
//  header ESP (kéo imgui.h vào) được include TRƯỚC, rồi 4 file imgui*.cpp được
//  nhúng trong CÙNG TU.
//
//  Vì sao cần test này: CI "Build Release" từng fail chính vì thứ tự đó —
//  imgui.cpp -> imgui_internal.h #error "Please '#define
//  IMGUI_DEFINE_MATH_OPERATORS' _BEFORE_ including imgui.h!", kéo theo hàng
//  chục lỗi "invalid operands to binary expression ('ImVec2' and 'float')".
//  Test này chạy được ở máy local (không cần iOS SDK) nên lỗi đó không quay lại.
//
#define IMGUI_DEFINE_MATH_OPERATORS 1

#include <cstdio>
#include <cstring>

#include "ESP/ESPRenderShm.h"
#include "ESP/ESPRenderImGuiDraw.h"

#include "imgui.cpp"
#include "imgui_draw.cpp"
#include "imgui_tables.cpp"
#include "imgui_widgets.cpp"

int main() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.DisplaySize = ImVec2(430.0f, 932.0f);
    io.DeltaTime = 1.0f / 60.0f;
    ImFont *font = io.Fonts->AddFontDefault();
    // Backend renderer build atlas lần đầu (Metal: ImGui_ImplMetal_NewFrame).
    unsigned char *px = NULL;
    int tw = 0, th = 0;
    io.Fonts->GetTexDataAsRGBA32(&px, &tw, &th);
    if (!px || tw <= 0) {
        printf("FAIL: font atlas không build được\n");
        return 1;
    }

    ESPRsFrame f;
    ESPRsFrameReset(&f);
    f.viewportW = 932.0f;
    f.viewportH = 430.0f;
    f.orientation = ESPRsOrientLandscapeLeft;
    f.flags = ESP_RSHM_FLAG_VISIBLE;
    f.publishTime = 1.0;
    f.pointCount = 2;
    f.points[0] = {10.0f, 10.0f};
    f.points[1] = {60.0f, 60.0f};

    ESPRsCmd rect;
    memset(&rect, 0, sizeof(rect));
    rect.prim = ESPRsPrimRect;
    rect.color = 0xFF00FF00u;
    rect.rx = 10.0f;
    rect.ry = 10.0f;
    rect.rw = 50.0f;
    rect.rh = 90.0f;
    rect.width = 1.5f;
    ESPRsFrameAddCmd(&f, &rect);

    ESPRsCmd line;
    memset(&line, 0, sizeof(line));
    line.prim = ESPRsPrimPolyline;
    line.color = 0xFFFF0000u;
    line.width = 1.0f;
    line.pointStart = 0;
    line.pointCount = 2;
    ESPRsFrameAddCmd(&f, &line);

    ESPRsCmd text;
    memset(&text, 0, sizeof(text));
    text.prim = ESPRsPrimText;
    text.color = 0xFFFFFFFFu;
    text.align = 1;
    text.fontSize = 12.0f;
    text.outlined = 1;
    text.tx = 100.0f;
    text.ty = 100.0f;
    strcpy(text.text, "[T3] Player\n42m");
    ESPRsFrameAddCmd(&f, &text);

    ImGui::NewFrame();
    ESPRsDrawStats st = ESPImGuiAppendFrame(ImGui::GetBackgroundDrawList(), &f,
                                            430.0f, 932.0f, font);
    ImGui::Render();
    ImDrawData *dd = ImGui::GetDrawData();
    int cmds = dd ? dd->CmdListsCount : 0;
    int vtx = dd ? dd->TotalVtxCount : 0;
    printf("amalgam TU: drawn=%d skipped=%d cmdLists=%d vtx=%d\n",
           st.drawn, st.skipped, cmds, vtx);
    ImGui::DestroyContext();

    if (st.drawn != 3 || st.skipped != 0 || cmds <= 0 || vtx <= 0) {
        printf("FAIL: amalgam TU không render đủ primitive\n");
        return 1;
    }
    printf("OK: amalgam TU (ESP headers -> imgui.cpp) biên dịch và render được\n");
    return 0;
}
