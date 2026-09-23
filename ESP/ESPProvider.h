//
//  ESPProvider.h
//  Port DarkSwordMemoryProvider (Fl0rkFF) semantics: read transactions,
//  degraded mode on consecutive kernel-read failures, diagnostics.
//  Lớp bọc TRÊN ESPMemory/ESPTask — không thay đường đọc, chỉ điều tiết:
//  hoãn xả cache giữa lượt quét, bỏ bulk-map + bóp discover khi degraded.
//

#ifndef ESPProvider_h
#define ESPProvider_h

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif

// Transaction đọc (lồng được). Khi depth > 0, yêu cầu xả page cache bị hoãn
// tới EndRead — chống xả mapping ngay giữa lượt quét (họ respring/panic).
void ESPProviderBeginRead(void);
void ESPProviderEndRead(void);
int ESPProviderDepth(void);

// Báo kết quả 1 op đọc đường kernel (vmmapremotepage). Đường task port rẻ,
// không báo. Gọi từ ESPMemoryRead/ESPReadWindow sau khi đã thử kernel.
void ESPProviderNoteKernelRead(BOOL ok);

// Chẩn đoán (kiểu diagnosticModuleScanCount / diagnosticIsDegraded của nó).
void ESPProviderNoteFullScan(void); // cuối ESPEngineScan
BOOL ESPProviderIsDegraded(void);
uint64_t ESPProviderFailureCount(void); // consecutive failures hiện tại
uint64_t ESPProviderFullScanCount(void);

// Điều tiết khi degraded.
BOOL ESPProviderShouldBulkMap(void); // NO khi degraded: chỉ map 1 page
int ESPProviderDiscoverBudget(void); // ESP_DISCOVER_BUDGET, degraded -> nhỏ

// Reset trạng thái (world/match đổi, tắt HUD). KHÔNG flush (caller đã flush).
void ESPProviderShutdown(void);

// Nội bộ cho ESPMemory: hoãn/lấy yêu cầu flush.
void ESPProviderDeferFlush(void);
BOOL ESPProviderTakeFlushRequest(void);

#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END

#endif /* ESPProvider_h */
