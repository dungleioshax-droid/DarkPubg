//
//  ESPOverlay.h
//  Stub vẽ ESP Box trên SpringBoard (phase 2).
//  Phase 1: chưa vẽ, chỉ giữ API để DSBridge gọi không crash.
//

#ifndef ESPOverlay_h
#define ESPOverlay_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Pool overlay trên SpringBoard. Mỗi box = 4 viền mỏng + 1 label khoảng cách.
// Giữ pool nhỏ để RemoteCall 1Hz không quá tải: 8 box = 32 viền + 8 label.
static const int ESPOverlayMaxBoxes = 8;

#import "ESPUE.h" // ESPBox2D dùng chung với engine

#ifdef __cplusplus
extern "C" {
#endif

// Trả về số box hiện tại (phase 1 luôn 0 — chưa vẽ để tránh loạn SpringBoard).
int ESPOverlayBoxCount(void);

// Fill tối đa maxCount box vào outBoxes. Phase 1 trả về 0.
int ESPOverlayGetBoxes(ESPBox2D *outBoxes, int maxCount);

// Xoá overlay (phase 2). Phase 1 no-op.
void ESPOverlayClear(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* ESPOverlay_h */
