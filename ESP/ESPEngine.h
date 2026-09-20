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

// Camera hiện tại (đọc từ PlayerCameraManager). NO nếu fail.
BOOL ESPEngineCamera(uint64_t gameBase, ESPCamera *outCam);

// WorldToScreen: world (cm, UE) -> screen game landscape points.
// screenW/H là size game landscape (vd 844x390). Trả NO nếu sau lưng / ngoài xa.
BOOL ESPWorldToScreen(ESPVector world, ESPCamera cam, float screenW, float screenH, float *outX, float *outY, float *outDist);

// Quét + project ra boxes 2D. Trả về số box (0..max). Lọc: distance<350m, trong màn hình.
int ESPEngineBoxes(uint64_t gameBase, float screenW, float screenH, ESPBox2D *outBoxes, int maxBoxes);

NS_ASSUME_NONNULL_END

#endif /* ESPEngine_h */
