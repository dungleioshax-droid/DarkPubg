//
//  ESPEngine.h
//  Quét UWorld -> Actors, trả về text cho HUD.
//

#ifndef ESPEngine_h
#define ESPEngine_h

#import <Foundation/Foundation.h>
#import "ESPUE.h"

NS_ASSUME_NONNULL_BEGIN

// Quét 1 lần (đồng bộ, NẶNG — chỉ gọi từ hàng đợi nền ESP, không gọi từ UI/tick).
// gameBase = DSBridgeGameBase(). Trả về struct thô, không chạm UI.
ESPScanResult ESPEngineScan(uint64_t gameBase);

// Đặt lịch quét nền nếu cache cũ (không block, gộp lịch). Gọi thoải mái từ tick/UI.
void ESPEngineRequestScan(uint64_t gameBase);

// Text ngắn cho HUD SpringBoard, vd: @"ESP: 123 actors / 8 players" hoặc @"ESP: --".
// KHÔNG quét đồng bộ nữa — chỉ đọc cache + đặt lịch quét nền.
NSString *ESPEngineStatusText(uint64_t gameBase);

// Text cache KHÔNG quét (dùng cho UI main thread — không bao giờ block).
// Trả @"ESP: --" nếu chưa có cache.
NSString *ESPEngineCachedStatusText(void);

// Dòng trạng thái quét cho màn hình app (cache, không block):
// @"scan 45% 12s" đang quét, @"scan ok 4/452 8.2s", @"scan fail E62 3.1s", @"scan idle".
NSString *ESPEngineScanInfoText(void);

// Số players thô (để HUD khác dùng nếu cần).
uint32_t ESPEnginePlayerCount(uint64_t gameBase);

// Camera hiện tại (đọc từ PlayerCameraManager). NO nếu fail.
BOOL ESPEngineCamera(uint64_t gameBase, ESPCamera *outCam);

// WorldToScreen: world (cm, UE) -> screen game landscape points.
// screenW/H là size game landscape (vd 844x390). Trả NO nếu sau lưng / ngoài xa.
BOOL ESPWorldToScreen(ESPVector world, ESPCamera cam, float screenW, float screenH, float *outX, float *outY, float *outDist);

// Quét + project ra boxes 2D. Trả về số box (0..max). Lọc: distance<350m, trong màn hình.
int ESPEngineBoxes(uint64_t gameBase, float screenW, float screenH, ESPBox2D *outBoxes, int maxBoxes);

// NHANH: không phân loại lại actor — chỉ đọc lại camera + vị trí của các actor
// đã biết (ESPTrackedActor từ lượt quét gần nhất) rồi project ra màn hình.
// ESP_REFRESH_HZ lần/giây, chỉ tốn ~2 lần đọc kernel/actor. Trả về số box.
int ESPEngineRefreshBoxes(uint64_t gameBase, float screenW, float screenH, ESPBox2D *outBoxes, int maxBoxes);

// Bridge báo số box đang vẽ (để hiển thị B<nn> trên dòng scan của app).
void ESPBoxCounterSet(int n);

// Diag pipeline của lần gọi Boxes/RefreshBoxes gần nhất, vd:
// @"R trk=8 hid=1 pos=0 w2s=5 h=1 ok=2", @"F camFail". Dùng khi B=0 mà P>0.
const char *ESPEngineLastBoxDiag(void);

NS_ASSUME_NONNULL_END

#endif /* ESPEngine_h */
