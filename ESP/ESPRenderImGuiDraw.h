//
//  ESPRenderImGuiDraw.h
//  Chuyển 1 ESPRsFrame (ESP/ESPRenderShm.h) thành lệnh ImGui draw list.
//
//  Đây là toàn bộ "phần khó" của renderer, cố tình tách ra thành C++ THUẦN
//  (chỉ Dear ImGui, không Metal/UIKit) để:
//    - dùng chung cho process overlay (imguirender/DSEspImGui.mm);
//    - test được trên Linux/macOS: tests/esprender_shm_test.cpp compile ImGui
//      core + header này rồi assert số vertex/primitive sinh ra.
//
//  Hệ toạ độ: commands ở hệ game-landscape (frame->viewportW/H). Renderer map
//  sang hệ cửa sổ của nó bằng cùng công thức ds_esp_map_point/ds_esp_map_rect
//  trong darksword/DSBridge.mm — nhờ vậy app không cần biết overlay đang ở
//  orientation nào, và ESP không bị lệch khi xoay máy.
//

#ifndef ESPRenderImGuiDraw_h
#define ESPRenderImGuiDraw_h

#include <math.h>
#include <string.h>

#include "../Vendor/imgui/imgui.h"
#include "ESPRenderShm.h"

typedef struct {
    int drawn;   // số lệnh được vẽ
    int skipped; // số lệnh bị bỏ (NaN, ngoài màn hình, dữ liệu rác)
    int vertices;
} ESPRsDrawStats;

static inline ImU32 ESPRsColor(uint32_t argb) {
    // 0xAARRGGBB -> IM_COL32(r,g,b,a)
    return IM_COL32((int)((argb >> 16) & 0xFFu),
                    (int)((argb >> 8) & 0xFFu),
                    (int)(argb & 0xFFu),
                    (int)((argb >> 24) & 0xFFu));
}

static inline ImVec2 ESPRsMapPoint(float x, float y, float landW, float landH,
                                   ImVec2 winCenter, int orientation) {
    const bool left = (orientation == ESPRsOrientLandscapeLeft);
    const bool right = (orientation == ESPRsOrientLandscapeRight);
    if (!left && !right) return ImVec2(x, y);
    const float dx = x - landW * 0.5f;
    const float dy = y - landH * 0.5f;
    if (left) return ImVec2(winCenter.x + dy, winCenter.y - dx);
    return ImVec2(winCenter.x - dy, winCenter.y + dx);
}

// Bbox của 4 góc đã map — đúng cho phép xoay ±90° (viền box).
static inline void ESPRsMapRect(float rx, float ry, float rw, float rh,
                               float landW, float landH, ImVec2 winCenter,
                               int orientation, ImVec2 *outMin, ImVec2 *outMax) {
    float x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    for (int k = 0; k < 4; k++) {
        const float px = (k & 1) ? (rx + rw) : rx;
        const float py = (k & 2) ? (ry + rh) : ry;
        const ImVec2 p = ESPRsMapPoint(px, py, landW, landH, winCenter, orientation);
        if (k == 0) {
            x0 = x1 = p.x;
            y0 = y1 = p.y;
            continue;
        }
        if (p.x < x0) x0 = p.x;
        if (p.x > x1) x1 = p.x;
        if (p.y < y0) y0 = p.y;
        if (p.y > y1) y1 = p.y;
    }
    *outMin = ImVec2(x0, y0);
    *outMax = ImVec2(x1, y1);
}

static inline bool ESPRsFinite(float v) {
    return isfinite(v);
}

// Vẽ 1 frame ESP lên draw list. `winW/winH` = kích thước cửa sổ overlay (pt).
// `font` = font atlas của renderer (NULL thì dùng font mặc định của context).
static inline ESPRsDrawStats ESPImGuiAppendFrame(ImDrawList *dl, const ESPRsFrame *f,
                                                 float winW, float winH,
                                                 ImFont *font) {
    ESPRsDrawStats st = {0, 0, 0};
    if (!dl || !f) return st;
    if (f->cmdCount == 0) return st;

    const ImVec2 winCenter(winW * 0.5f, winH * 0.5f);
    const float landW = (f->viewportW > 1.0f) ? f->viewportW : winW;
    const float landH = (f->viewportH > 1.0f) ? f->viewportH : winH;
    // Cull rộng hơn viewport 64pt (giống ds_qbl_present) để box nửa ngoài
    // màn hình vẫn vẽ, còn toạ độ rác (sau lưng/camera lỗi) bị bỏ.
    const float cullX0 = -64.0f, cullY0 = -64.0f;
    const float cullX1 = winW + 64.0f, cullY1 = winH + 64.0f;
    const float maxRectW = winW * 3.0f, maxRectH = winH * 3.0f;
    ImFont *fnt = font ? font : ImGui::GetFont();

    const uint32_t ncmds = (f->cmdCount > ESP_RSHM_MAX_CMDS) ? ESP_RSHM_MAX_CMDS : f->cmdCount;
    for (uint32_t i = 0; i < ncmds; i++) {
        const ESPRsCmd *c = &f->cmds[i];
        switch (c->prim) {
            case ESPRsPrimRect: {
                if (!ESPRsFinite(c->rx) || !ESPRsFinite(c->ry) ||
                    !ESPRsFinite(c->rw) || !ESPRsFinite(c->rh)) {
                    st.skipped++;
                    continue;
                }
                if (c->rw < 0.5f || c->rh < 0.5f || c->rw > maxRectW || c->rh > maxRectH) {
                    st.skipped++;
                    continue;
                }
                ImVec2 pmin, pmax;
                ESPRsMapRect(c->rx, c->ry, c->rw, c->rh, landW, landH, winCenter,
                             f->orientation, &pmin, &pmax);
                if (pmax.x < cullX0 || pmin.x > cullX1 ||
                    pmax.y < cullY0 || pmin.y > cullY1) {
                    st.skipped++;
                    continue;
                }
                const ImU32 col = ESPRsColor(c->color);
                if (c->filled) {
                    dl->AddRectFilled(pmin, pmax, col);
                } else {
                    const float w = (c->width > 0.0f) ? c->width : 1.0f;
                    dl->AddRect(pmin, pmax, col, 0.0f, 0, w);
                }
                st.drawn++;
                break;
            }
            case ESPRsPrimPolyline: {
                if (!f->points || c->pointCount < 2 || c->pointCount > 128) {
                    st.skipped++;
                    continue;
                }
                if ((uint32_t)c->pointStart + c->pointCount > f->pointCount) {
                    st.skipped++;
                    continue;
                }
                ImVec2 pts[128];
                int n = 0;
                bool bad = false;
                float minX = 1e18f, maxX = -1e18f, minY = 1e18f, maxY = -1e18f;
                for (int k = 0; k < (int)c->pointCount; k++) {
                    const ESPRsPoint *sp = &f->points[c->pointStart + k];
                    if (!ESPRsFinite(sp->x) || !ESPRsFinite(sp->y)) {
                        bad = true;
                        break;
                    }
                    ImVec2 p = ESPRsMapPoint(sp->x, sp->y, landW, landH, winCenter, f->orientation);
                    // Clamp 3x viewport: path khổng lồ từng làm nghẽn compositor.
                    if (p.x < -landW) p.x = -landW;
                    if (p.x > landW * 2.0f) p.x = landW * 2.0f;
                    if (p.y < -landH) p.y = -landH;
                    if (p.y > landH * 2.0f) p.y = landH * 2.0f;
                    pts[n++] = p;
                    if (p.x < minX) minX = p.x;
                    if (p.x > maxX) maxX = p.x;
                    if (p.y < minY) minY = p.y;
                    if (p.y > maxY) maxY = p.y;
                }
                if (bad || n < 2) {
                    st.skipped++;
                    continue;
                }
                if (maxX < cullX0 || minX > cullX1 || maxY < cullY0 || minY > cullY1) {
                    st.skipped++;
                    continue;
                }
                const float w = (c->width > 0.0f) ? c->width : 1.0f;
                dl->AddPolyline(pts, n, ESPRsColor(c->color),
                                c->closed ? ImDrawFlags_Closed : 0, w);
                st.drawn++;
                break;
            }
            case ESPRsPrimCircle: {
                if (!ESPRsFinite(c->tx) || !ESPRsFinite(c->ty) ||
                    !ESPRsFinite(c->radius) || c->radius <= 0.0f || c->radius > 200.0f) {
                    st.skipped++;
                    continue;
                }
                const ImVec2 p = ESPRsMapPoint(c->tx, c->ty, landW, landH, winCenter, f->orientation);
                if (p.x < cullX0 || p.x > cullX1 || p.y < cullY0 || p.y > cullY1) {
                    st.skipped++;
                    continue;
                }
                const ImU32 col = ESPRsColor(c->color);
                if (c->filled) {
                    dl->AddCircleFilled(p, c->radius, col);
                } else {
                    const float w = (c->width > 0.0f) ? c->width : 1.0f;
                    dl->AddCircle(p, c->radius, col, 0, w);
                }
                st.drawn++;
                break;
            }
            case ESPRsPrimText: {
                if (!c->text[0] || !fnt) {
                    st.skipped++;
                    continue;
                }
                if (!ESPRsFinite(c->tx) || !ESPRsFinite(c->ty)) {
                    st.skipped++;
                    continue;
                }
                ImVec2 p = ESPRsMapPoint(c->tx, c->ty, landW, landH, winCenter, f->orientation);
                if (p.x < cullX0 || p.x > cullX1 || p.y < cullY0 || p.y > cullY1) {
                    st.skipped++;
                    continue;
                }
                float size = (c->fontSize > 1.0f) ? c->fontSize : 12.0f;
                char text[ESP_RSHM_TEXT_CAP];
                memcpy(text, c->text, sizeof(text));
                text[ESP_RSHM_TEXT_CAP - 1] = '\0';
                // Neo giữa theo chiều ngang, neo đáy theo chiều dọc (label nằm
                // dưới box như renderer UILabel cũ).
                const ImVec2 ts = fnt->CalcTextSizeA(size, FLT_MAX, 0.0f, text);
                switch (c->align) {
                    case 1: p.x -= ts.x * 0.5f; break;
                    case 2: p.x -= ts.x; break;
                    default: break;
                }
                p.y -= ts.y;
                const ImU32 col = ESPRsColor(c->color);
                if (c->outlined) {
                    // ImGui không có outline sẵn: vẽ 4 bản đen lệch 1pt dưới.
                    const ImU32 shadow = IM_COL32(0, 0, 0, (int)((c->color >> 24) & 0xFFu));
                    dl->AddText(fnt, size, ImVec2(p.x - 1.0f, p.y), shadow, text);
                    dl->AddText(fnt, size, ImVec2(p.x + 1.0f, p.y), shadow, text);
                    dl->AddText(fnt, size, ImVec2(p.x, p.y - 1.0f), shadow, text);
                    dl->AddText(fnt, size, ImVec2(p.x, p.y + 1.0f), shadow, text);
                }
                dl->AddText(fnt, size, p, col, text);
                st.drawn++;
                break;
            }
            default:
                st.skipped++;
                break;
        }
    }
    st.vertices = dl->VtxBuffer.Size;
    return st;
}

#endif /* ESPRenderImGuiDraw_h */
