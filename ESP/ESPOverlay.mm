//
//  ESPOverlay.mm
//  Phase 1 stub — không tạo view để giữ SpringBoard ổn định.
//  Phase 2 sẽ: tạo UIWindow overlay + pool UIView viền (top/bottom/left/right) + UILabel distance,
//  update từ ds_update_rate qua RemoteCall.
//

#import "ESPOverlay.h"

int ESPOverlayBoxCount(void) {
    return 0;
}

int ESPOverlayGetBoxes(ESPBox2D *outBoxes, int maxCount) {
    (void)outBoxes; (void)maxCount;
    return 0;
}

void ESPOverlayClear(void) {
}
