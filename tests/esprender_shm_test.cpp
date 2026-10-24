//
//  esprender_shm_test.cpp
//  Test cho kênh dữ liệu + translator ImGui của ESP (chạy được trên Linux/macOS):
//
//      ./scripts/test-espimgui.sh
//
//  Bao gồm:
//    1. ESPRsShm: create -> publish -> read, double-buffer lật đúng, reader
//       trước khi có frame phải trả false.
//    2. ESPImGuiAppendFrame: rect/polyline/text được vẽ, rect NaN và rect
//       ngoài màn hình bị bỏ, text có outline sinh nhiều vertex hơn text
//       không outline.
//    3. Map toạ độ landscape -> cửa sổ (orientation) đúng phép xoay ±90°.
//    4. Stress 2 thread (writer publish liên tục / reader đọc) — không được
//       đọc ra frame rách (cmdCount/pointCount luôn khớp, magic luôn đúng).
//

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "ESP/ESPRenderShm.h"
#include "ESP/ESPRenderImGuiDraw.h"

static int g_failures = 0;

#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);                     \
            printf(__VA_ARGS__);                                            \
            printf("\n");                                                   \
            g_failures++;                                                   \
        }                                                                   \
    } while (0)

static const char *kShmPath = "/tmp/ds-esp-imgui-test.shm";

static void test_shm_roundtrip(void) {
    unlink(kShmPath);
    ESPRsShm *shm = ESPRsShmOpen(kShmPath);
    CHECK(shm != NULL, "ESPRsShmOpen returned NULL");
    if (!shm) return;
    CHECK(shm->magic == ESP_RSHM_MAGIC, "magic not initialised");
    CHECK(ESPRsShmSize() >= sizeof(ESPRsFrame) * 2, "shm too small: %zu", ESPRsShmSize());

    ESPRsFrame read;
    CHECK(!ESPRsShmRead(shm, &read), "read before first publish must fail");

    ESPRsFrame w;
    ESPRsFrameReset(&w);
    w.cmdCount = 3;
    w.pointCount = 2;
    w.viewportW = 932.0f;
    w.viewportH = 430.0f;
    w.orientation = ESPRsOrientLandscapeLeft;
    w.flags = ESP_RSHM_FLAG_VISIBLE;
    w.frameId = 42;
    w.publishTime = 123.5;
    w.points[0] = {1.0f, 2.0f};
    w.points[1] = {3.0f, 4.0f};
    ESPRsShmPublish(shm, &w);

    CHECK(ESPRsShmRead(shm, &read), "read after publish failed");
    CHECK(read.frameId == 42, "frameId %llu", (unsigned long long)read.frameId);
    CHECK(read.cmdCount == 3 && read.pointCount == 2, "counts %u/%u", read.cmdCount, read.pointCount);
    CHECK(read.orientation == ESPRsOrientLandscapeLeft, "orientation %d", read.orientation);
    CHECK(read.points[1].x == 3.0f && read.points[1].y == 4.0f, "point payload wrong");
    CHECK(read.slotIndex < ESP_RSHM_SLOTS, "slotIndex %u", read.slotIndex);

    // Publish lần 2 phải lật sang slot khác (double buffer).
    uint32_t firstSlot = read.slotIndex;
    w.frameId = 43;
    ESPRsShmPublish(shm, &w);
    CHECK(ESPRsShmRead(shm, &read), "read #2 failed");
    CHECK(read.frameId == 43, "frameId #2 %llu", (unsigned long long)read.frameId);
    CHECK(read.slotIndex != firstSlot, "double buffer did not flip (slot %u)", read.slotIndex);

    // Mở lại bằng path (process thứ 2) phải thấy cùng dữ liệu.
    ESPRsShm *shm2 = ESPRsShmOpen(kShmPath);
    CHECK(shm2 != NULL, "second open failed");
    if (shm2) {
        ESPRsFrame r2;
        CHECK(ESPRsShmRead(shm2, &r2), "second process read failed");
        CHECK(r2.frameId == 43, "second process frameId %llu", (unsigned long long)r2.frameId);
        ESPRsShmClose(shm2);
    }
    ESPRsShmClose(shm);
    unlink(kShmPath);
}

static void test_map_point(void) {
    const float landW = 932.0f, landH = 430.0f;
    const ImVec2 c(215.0f, 466.0f); // tâm cửa sổ portrait 430x932

    ImVec2 p = ESPRsMapPoint(10.0f, 20.0f, landW, landH, c, ESPRsOrientPortrait);
    CHECK(p.x == 10.0f && p.y == 20.0f, "portrait must not remap (%f,%f)", p.x, p.y);

    // LandscapeLeft: xoay +90° (công thức ds_esp_map_point).
    const float dx = 100.0f - landW * 0.5f;
    const float dy = 100.0f - landH * 0.5f;
    p = ESPRsMapPoint(100.0f, 100.0f, landW, landH, c, ESPRsOrientLandscapeLeft);
    CHECK(fabsf(p.x - (c.x + dy)) < 0.01f && fabsf(p.y - (c.y - dx)) < 0.01f,
          "landscapeLeft map (%f,%f)", p.x, p.y);

    p = ESPRsMapPoint(100.0f, 100.0f, landW, landH, c, ESPRsOrientLandscapeRight);
    CHECK(fabsf(p.x - (c.x - dy)) < 0.01f && fabsf(p.y - (c.y + dx)) < 0.01f,
          "landscapeRight map (%f,%f)", p.x, p.y);

    // Rect map = bbox 4 góc; xoay 90° thì width/height đổi chỗ.
    ImVec2 pmin, pmax;
    ESPRsMapRect(0.0f, 0.0f, 100.0f, 50.0f, landW, landH, c,
                 ESPRsOrientLandscapeLeft, &pmin, &pmax);
    CHECK(fabsf((pmax.x - pmin.x) - 50.0f) < 0.01f, "mapped rect w=%f", pmax.x - pmin.x);
    CHECK(fabsf((pmax.y - pmin.y) - 100.0f) < 0.01f, "mapped rect h=%f", pmax.y - pmin.y);
}

static ESPRsFrame make_frame(void) {
    ESPRsFrame f;
    ESPRsFrameReset(&f);
    f.viewportW = 932.0f;
    f.viewportH = 430.0f;
    f.orientation = ESPRsOrientPortrait;
    f.flags = ESP_RSHM_FLAG_VISIBLE;
    f.publishTime = 1.0;
    f.pointCount = 3;
    f.points[0] = {10.0f, 10.0f};
    f.points[1] = {20.0f, 20.0f};
    f.points[2] = {10.0f, 10.0f};

    ESPRsCmd rect;
    memset(&rect, 0, sizeof(rect));
    rect.prim = ESPRsPrimRect;
    rect.color = 0xFF00FF00u;
    rect.rx = 10.0f;
    rect.ry = 10.0f;
    rect.rw = 40.0f;
    rect.rh = 80.0f;
    rect.width = 1.5f;
    ESPRsFrameAddCmd(&f, &rect);

    ESPRsCmd poly;
    memset(&poly, 0, sizeof(poly));
    poly.prim = ESPRsPrimPolyline;
    poly.color = 0xFFFF0000u;
    poly.width = 1.0f;
    poly.pointStart = 0;
    poly.pointCount = 3;
    ESPRsFrameAddCmd(&f, &poly);

    ESPRsCmd text;
    memset(&text, 0, sizeof(text));
    text.prim = ESPRsPrimText;
    text.color = 0xFFFFFFFFu;
    text.align = 1;
    text.fontSize = 12.0f;
    text.tx = 30.0f;
    text.ty = 100.0f;
    text.outlined = 1;
    strcpy(text.text, "[T3] Player\n42m");
    ESPRsFrameAddCmd(&f, &text);

    // Rác: rect NaN và rect khổng lồ ngoài màn hình.
    ESPRsCmd nanRect;
    memset(&nanRect, 0, sizeof(nanRect));
    nanRect.prim = ESPRsPrimRect;
    nanRect.color = 0xFFFFFFFFu;
    nanRect.rx = NAN;
    nanRect.ry = 0.0f;
    nanRect.rw = 10.0f;
    nanRect.rh = 10.0f;
    ESPRsFrameAddCmd(&f, &nanRect);

    ESPRsCmd farRect;
    memset(&farRect, 0, sizeof(farRect));
    farRect.prim = ESPRsPrimRect;
    farRect.color = 0xFFFFFFFFu;
    farRect.rx = 100000.0f;
    farRect.ry = 0.0f;
    farRect.rw = 10.0f;
    farRect.rh = 10.0f;
    ESPRsFrameAddCmd(&f, &farRect);
    return f;
}

// Vẽ 1 frame ESP trong 1 frame ImGui thật (NewFrame -> draw list -> Render),
// đúng như renderer chạy trên máy.
static ESPRsDrawStats render_esp_frame(const ESPRsFrame *f) {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(430.0f, 932.0f);
    io.DeltaTime = 1.0f / 60.0f;
    ImGui::NewFrame();
    ImFont *font = io.Fonts->Fonts.empty() ? NULL : io.Fonts->Fonts[0];
    ESPRsDrawStats st = ESPImGuiAppendFrame(ImGui::GetBackgroundDrawList(), f,
                                            430.0f, 932.0f, font);
    st.vertices = ImGui::GetBackgroundDrawList()->VtxBuffer.Size;
    ImGui::Render();
    return st;
}

static void test_append_frame(void) {
    ESPRsFrame f = make_frame();
    ESPRsDrawStats st = render_esp_frame(&f);
    CHECK(st.drawn == 3, "drawn=%d (want 3: rect+polyline+text)", st.drawn);
    CHECK(st.skipped == 2, "skipped=%d (want 2: NaN + offscreen)", st.skipped);
    CHECK(st.vertices > 0, "no vertices emitted");

    const int withOutline = st.vertices;
    ESPRsFrame f2 = make_frame();
    f2.cmds[2].outlined = 0;
    ESPRsDrawStats st2 = render_esp_frame(&f2);
    CHECK(st2.drawn == 3, "drawn no-outline=%d", st2.drawn);
    CHECK(withOutline > st2.vertices,
          "outline must add vertices (%d vs %d)", withOutline, st2.vertices);

    // Frame rỗng: không vẽ gì, không crash.
    ESPRsFrame empty;
    ESPRsFrameReset(&empty);
    ESPRsDrawStats st3 = render_esp_frame(&empty);
    CHECK(st3.drawn == 0 && st3.skipped == 0, "empty frame drawn=%d skipped=%d",
          st3.drawn, st3.skipped);
}

static void test_concurrent(void) {
    unlink(kShmPath);
    ESPRsShm *shm = ESPRsShmOpen(kShmPath);
    CHECK(shm != NULL, "stress: open failed");
    if (!shm) return;

    std::atomic<bool> stop(false);
    std::atomic<int> bad(0), reads(0);

    std::thread writer([&] {
        for (uint64_t i = 1; i <= 20000; i++) {
            ESPRsFrame f;
            ESPRsFrameReset(&f);
            f.frameId = i;
            f.cmdCount = 5;
            f.pointCount = 7;
            f.flags = ESP_RSHM_FLAG_VISIBLE;
            f.publishTime = (double)i;
            for (int k = 0; k < 5; k++) {
                f.cmds[k].prim = ESPRsPrimRect;
                f.cmds[k].rx = (float)k;
            }
            for (int k = 0; k < 7; k++) {
                f.points[k].x = (float)i;
                f.points[k].y = (float)k;
            }
            ESPRsShmPublish(shm, &f);
        }
        stop.store(true, std::memory_order_release);
    });

    std::thread reader([&] {
        while (!stop.load(std::memory_order_acquire)) {
            ESPRsFrame r;
            if (!ESPRsShmRead(shm, &r)) continue;
            reads.fetch_add(1, std::memory_order_relaxed);
            // Frame phải nhất quán: counts và payload cùng thế hệ.
            if (r.cmdCount != 5 || r.pointCount != 7) bad.fetch_add(1);
            if (r.points[0].x != (float)r.frameId) bad.fetch_add(1);
            if (r.cmds[4].rx != 4.0f) bad.fetch_add(1);
        }
    });

    writer.join();
    reader.join();

    CHECK(reads.load() > 0, "stress: no successful reads");
    CHECK(bad.load() == 0, "stress: %d torn/inconsistent reads", bad.load());
    ESPRsShmClose(shm);
    unlink(kShmPath);
}

int main(void) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL; // test không được ghi imgui.ini vào repo
    io.DisplaySize = ImVec2(430.0f, 932.0f);
    io.Fonts->AddFontDefault();
    io.Fonts->Build();

    test_shm_roundtrip();
    test_map_point();
    test_append_frame();
    test_concurrent();

    ImGui::DestroyContext();

    printf("sizeof(ESPRsFrame)=%zu sizeof(ESPRsCmd)=%zu shm=%zu\n",
           sizeof(ESPRsFrame), sizeof(ESPRsCmd), ESPRsShmSize());
    if (g_failures) {
        printf("FAILED: %d check(s)\n", g_failures);
        return 1;
    }
    printf("OK: esprender shm + imgui draw tests passed\n");
    return 0;
}
