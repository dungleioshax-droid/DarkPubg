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

// Box 2D đã project ra màn hình (phase 2 sẽ fill từ W2S).
typedef struct {
    CGRect rect;        // toạ độ màn hình (points)
    float distance;     // mét
    int health;         // 0-100, -1 nếu chưa đọc
    BOOL isEnemy;
} ESPBox;

#ifdef __cplusplus
extern "C" {
#endif

// Trả về số box hiện tại (phase 1 luôn 0 — chưa vẽ để tránh loạn SpringBoard).
int ESPOverlayBoxCount(void);

// Fill tối đa maxCount box vào outBoxes. Phase 1 trả về 0.
int ESPOverlayGetBoxes(ESPBox *outBoxes, int maxCount);

// Xoá overlay (phase 2). Phase 1 no-op.
void ESPOverlayClear(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* ESPOverlay_h */
