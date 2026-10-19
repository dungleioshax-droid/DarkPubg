//
//  ESPOverlay.mm
//  QBL-style draw list — CPU buffer, không remote call (phase: build frame).
//  Presenter nằm trong DSBridge.mm (nơi duy nhất giữ RemoteCall).
//

#import "ESPOverlay.h"
#include <string.h>
#include <math.h>

static ESPDrawCommand s_cmds[ESP_DRAW_MAX_COMMANDS];
static CGPoint s_pts[ESP_DRAW_MAX_POINTS];
static int s_cmdCount = 0;
static int s_ptCount = 0;
static int s_dropped = 0;
static CGSize s_viewport = {0, 0};
static BOOL s_open = NO;

static inline BOOL espd_finite2(CGFloat x, CGFloat y) {
    return isfinite(x) && isfinite(y);
}

void ESPDrawFrameBegin(CGSize viewport) {
    s_viewport = viewport;
    s_cmdCount = 0;
    s_ptCount = 0;
    s_dropped = 0;
    s_open = YES;
}

void ESPDrawFrameEnd(void) {
    s_open = NO;
}

void ESPDrawFrameReset(void) {
    s_cmdCount = 0;
    s_ptCount = 0;
    s_dropped = 0;
    s_open = NO;
}

int ESPDrawFrameCount(void) { return s_cmdCount; }
int ESPDrawFrameDropped(void) { return s_dropped; }
const ESPDrawCommand *ESPDrawFrameCommands(void) { return s_cmdCount > 0 ? s_cmds : NULL; }
const CGPoint *ESPDrawFramePoints(void) { return s_ptCount > 0 ? s_pts : NULL; }
int ESPDrawFramePointCount(void) { return s_ptCount; }
CGSize ESPDrawFrameViewport(void) { return s_viewport; }

static ESPDrawCommand *espd_alloc(uint8_t prim) {
    if (!s_open) { s_dropped++; return NULL; }
    if (s_cmdCount >= ESP_DRAW_MAX_COMMANDS) { s_dropped++; return NULL; }
    ESPDrawCommand *c = &s_cmds[s_cmdCount++];
    memset(c, 0, sizeof(*c));
    c->prim = prim;
    c->width = 1.0f;
    return c;
}

int ESPDrawAddRect(CGRect r, uint32_t color, float width, int bucket, BOOL filled) {
    if (!espd_finite2(r.origin.x, r.origin.y) ||
        !espd_finite2(r.size.width, r.size.height)) {
        s_dropped++;
        return -1;
    }
    // Rect suy biến (w/h <= 0) là rác w2s — bỏ, không để setFrame/path lỗi.
    if (r.size.width <= 0.0 || r.size.height <= 0.0 ||
        r.size.width > 20000.0 || r.size.height > 20000.0) {
        s_dropped++;
        return -1;
    }
    ESPDrawCommand *c = espd_alloc(ESPDrawPrimRect);
    if (!c) return -1;
    c->rect = r;
    c->color = color;
    c->width = (width > 0.1f) ? width : 1.0f;
    c->bucket = (uint8_t)(bucket & 0xFF);
    c->filled = filled ? 1 : 0;
    return s_cmdCount - 1;
}

int ESPDrawAddPolyline(const CGPoint *pts, int count, uint32_t color, float width,
                       int bucket, BOOL closed) {
    if (!pts || count < 2) { s_dropped++; return -1; }
    if (count > 64) count = 64; // 1 polyline quá dài = lỗi builder
    int need = count + (closed ? 1 : 0);
    if (s_ptCount + need > ESP_DRAW_MAX_POINTS) { s_dropped++; return -1; }
    for (int i = 0; i < count; i++) {
        if (!espd_finite2(pts[i].x, pts[i].y)) { s_dropped++; return -1; }
    }
    ESPDrawCommand *c = espd_alloc(ESPDrawPrimPolyline);
    if (!c) return -1;
    int start = s_ptCount;
    for (int i = 0; i < count; i++) s_pts[s_ptCount++] = pts[i];
    // closed: lặp điểm đầu để CGPathAddLines tự khép (tam giác AI mark).
    if (closed) s_pts[s_ptCount++] = pts[0];
    c->pointStart = (uint16_t)start;
    c->pointCount = (uint16_t)(s_ptCount - start);
    c->color = color;
    c->width = (width > 0.1f) ? width : 1.0f;
    c->bucket = (uint8_t)(bucket & 0xFF);
    return s_cmdCount - 1;
}

int ESPDrawAddCircle(CGPoint center, float radius, uint32_t color, float width,
                     int bucket, BOOL filled) {
    if (!espd_finite2(center.x, center.y) || !isfinite(radius)) { s_dropped++; return -1; }
    if (radius < 0.5f) radius = 0.5f;
    if (radius > 200.0f) { s_dropped++; return -1; }
    (void)filled; // kiểu tô/viền do bucket của presenter quyết định
    // Presenter chỉ build path bằng CGPathAddLines/CGPathAddRects (tham số
    // pointer + count — an toàn qua RemoteCall), nên circle được xấp xỉ bằng
    // đa giác 16 cạnh khép kín. Bán kính nhỏ (head dot 2-3pt) nhìn y hệt tròn.
    const int kSeg = 16;
    CGPoint poly[kSeg];
    for (int i = 0; i < kSeg; i++) {
        double a = (double)i * (2.0 * M_PI / (double)kSeg);
        poly[i] = CGPointMake(center.x + cos(a) * radius, center.y + sin(a) * radius);
    }
    return ESPDrawAddPolyline(poly, kSeg, color, width, bucket, YES);
}

int ESPDrawAddText(const char *text, CGPoint pos, float fontSize, uint32_t color,
                   BOOL outlined, int align) {
    if (!text) return -1;
    if (!espd_finite2(pos.x, pos.y) || !isfinite(fontSize)) { s_dropped++; return -1; }
    ESPDrawCommand *c = espd_alloc(ESPDrawPrimText);
    if (!c) return -1;
    strncpy(c->text, text, sizeof(c->text) - 1);
    c->text[sizeof(c->text) - 1] = '\0';
    c->tx = (float)pos.x;
    c->ty = (float)pos.y;
    c->fontSize = (fontSize >= 8.0f && fontSize <= 40.0f) ? fontSize : 14.0f;
    c->color = color;
    c->outlined = outlined ? 1 : 0;
    c->align = (uint8_t)((align < 0 || align > 2) ? 1 : align);
    return s_cmdCount - 1;
}

// ---- legacy phase-1 API ----
int ESPOverlayBoxCount(void) { return 0; }
int ESPOverlayGetBoxes(ESPBox2D *outBoxes, int maxCount) {
    (void)outBoxes; (void)maxCount;
    return 0;
}
void ESPOverlayClear(void) { ESPDrawFrameReset(); }
