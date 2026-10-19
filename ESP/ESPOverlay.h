//
//  ESPOverlay.h
//  QBL-style draw list (frame + command buffer) — port từ QBLDrawList/DSOverlay.
//
//  1 frame (giống QBL):
//    1. Builder (DSBridge, mỗi tick) gom lệnh vẽ: rect / polyline / circle /
//       text vào buffer CPU — KHÔNG remote call nào trong lúc build.
//    2. ESPDrawFrameEnd() chốt frame.
//    3. Presenter (DSBridge) đọc ESPDrawFrameCommands()/Points() rồi bắn
//       remote call vào SpringBoard theo batch (mỗi style 1 shape layer, path
//       build bằng CGPathAddRects/CGPathAddLines nhiều primitive/lần).
//    4. ESPDrawFrameReset().
//
//  Primitive map 1-1 với QBLDrawList:
//    AddRect/AddRectFilled   -> ESPDrawAddRect(..., filled)
//    AddLine                 -> ESPDrawAddPolyline(2 điểm)
//    AddCircle(+Filled)      -> ESPDrawAddCircle(..., filled)
//    AddTriangleFilled       -> ESPDrawAddPolyline(3 điểm, closed=YES)
//    AddOutlinedText         -> ESPDrawAddText(..., outlined=YES)
//

#ifndef ESPOverlay_h
#define ESPOverlay_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ESPUE.h" // ESPBox2D dùng chung với engine

NS_ASSUME_NONNULL_BEGIN

// Pool overlay: 8 box player. Giữ nhỏ như bản cũ (RemoteCall 60Hz).
static const int ESPOverlayMaxBoxes = 8;

#define ESP_DRAW_MAX_COMMANDS 128
// 1024 điểm: 8 player × (xương ~29 + head dot 17 + tam giác 4 + snapline 2)
// vẫn dư; pool lớn hơn không tốn thêm remote call nào (1 write/frame).
#define ESP_DRAW_MAX_POINTS   1024

typedef enum {
    ESPDrawPrimRect = 1,
    ESPDrawPrimPolyline,
    ESPDrawPrimCircle,
    ESPDrawPrimText,
} ESPDrawPrim;

// 1 lệnh vẽ. Field tương ứng DSOverlayCommand của QBL (kind/rect/radius/width/
// color/filled/outlined/text/fontSize) + point pool cho polyline.
typedef struct {
    uint8_t prim;
    uint8_t filled;   // 1 = tô (rect/circle/triangle)
    uint8_t outlined; // 1 = chữ có viền (QBL AddOutlinedText)
    uint8_t align;    // text: 0=trái, 1=giữa, 2=phải
    uint8_t bucket;   // presenter: nhóm style (màu/kiểu) — do builder đặt
    uint32_t color;   // 0xAARRGGBB
    float width;      // độ dày nét
    float radius;     // circle
    CGRect rect;      // rect
    uint16_t pointStart; // polyline: index đầu trong ESPDrawFramePoints()
    uint16_t pointCount;
    float fontSize;   // text
    float tx, ty;     // text: điểm neo (theo align)
    char text[96];
} ESPDrawCommand;

#ifdef __cplusplus
extern "C" {
#endif

void ESPDrawFrameBegin(CGSize viewport);
void ESPDrawFrameEnd(void);
void ESPDrawFrameReset(void);

int ESPDrawFrameCount(void);
int ESPDrawFrameDropped(void);
const ESPDrawCommand * _Nullable ESPDrawFrameCommands(void);
const CGPoint * _Nullable ESPDrawFramePoints(void);
int ESPDrawFramePointCount(void);
CGSize ESPDrawFrameViewport(void);

// Trả về index lệnh vừa thêm, -1 nếu frame đầy/không hợp lệ (tăng dropped).
int ESPDrawAddRect(CGRect r, uint32_t color, float width, int bucket, BOOL filled);
int ESPDrawAddPolyline(const CGPoint *pts, int count, uint32_t color, float width,
                       int bucket, BOOL closed);
int ESPDrawAddCircle(CGPoint center, float radius, uint32_t color, float width,
                     int bucket, BOOL filled);
int ESPDrawAddText(const char *text, CGPoint pos, float fontSize, uint32_t color,
                   BOOL outlined, int align);

// Legacy API phase-1 (không còn dùng; giữ để không vỡ link cũ).
int ESPOverlayBoxCount(void);
int ESPOverlayGetBoxes(ESPBox2D *outBoxes, int maxCount);
void ESPOverlayClear(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* ESPOverlay_h */
