//
//  ESPEngine.h
//  Quét UWorld -> Actors, trả về text cho HUD.
//

#ifndef ESPEngine_h
#define ESPEngine_h

#import <Foundation/Foundation.h>
#import "ESPUE.h"

NS_ASSUME_NONNULL_BEGIN

// Quét 1 lần (đồng bộ, gọi từ ds_bridge_queue). gameBase = DSBridgeGameBase().
// Trả về struct thô, không chạm UI.
ESPScanResult ESPEngineScan(uint64_t gameBase);

// Text ngắn cho HUD SpringBoard, vd: @"ESP: 123 actors / 8 players" hoặc @"ESP: --".
NSString *ESPEngineStatusText(uint64_t gameBase);

// Số players thô (để HUD khác dùng nếu cần).
uint32_t ESPEnginePlayerCount(uint64_t gameBase);

NS_ASSUME_NONNULL_END

#endif /* ESPEngine_h */
