//
//  ESPProvider.mm
//  Port DarkSwordMemoryProvider (Fl0rkFF): transaction + degraded + diagnostics.
//  Hot path (NoteKernelRead) chỉ dùng atomics relaxed — rẻ cỡ ~ns/read.
//

#import "ESPProvider.h"
#import "ESPMemory.h"
#import "ESPTask.h"
#import "ESPLog.h"
#import "ESPConfig.h"
#include <atomic>

#if USE_DARKSWORD

static std::atomic<int> s_depth{0};
static std::atomic<uint64_t> s_fails{0};
static std::atomic<uint64_t> s_recover{0};
static std::atomic<uint64_t> s_scans{0};
static std::atomic<bool> s_degraded{false};
static std::atomic<bool> s_flushPending{false};

void ESPProviderBeginRead(void) {
    s_depth.fetch_add(1, std::memory_order_relaxed);
}

void ESPProviderEndRead(void) {
    int d = s_depth.fetch_sub(1, std::memory_order_relaxed);
    if (d <= 1) {
        s_depth.store(0, std::memory_order_relaxed);
        // Hết transaction: xả phần đã hoãn (blocking, hiếm — world đổi hoặc
        // vừa vào degraded). Không giữ lock nào ở đây nên không deadlock.
        if (s_flushPending.exchange(false, std::memory_order_relaxed)) {
            ESPMemoryFlushPageCache();
        }
    }
}

int ESPProviderDepth(void) {
    return s_depth.load(std::memory_order_relaxed);
}

void ESPProviderNoteKernelRead(BOOL ok) {
    if (ok) {
        if (s_degraded.load(std::memory_order_relaxed)) {
            uint64_t r = s_recover.fetch_add(1, std::memory_order_relaxed) + 1;
            if (r >= ESP_PROVIDER_RECOVER_READS) {
                s_degraded.store(false, std::memory_order_relaxed);
                s_fails.store(0, std::memory_order_relaxed);
                s_recover.store(0, std::memory_order_relaxed);
                ESPLog("PROVIDER recovered ok=%llu", (unsigned long long)r);
            }
        } else {
            s_fails.store(0, std::memory_order_relaxed);
        }
        return;
    }
    s_recover.store(0, std::memory_order_relaxed);
    uint64_t f = s_fails.fetch_add(1, std::memory_order_relaxed) + 1;
    if (f >= ESP_PROVIDER_DEGRADE_FAILS &&
        !s_degraded.exchange(true, std::memory_order_relaxed)) {
        // Vào degraded 1 lần duy nhất: đọc kernel đang fail hàng loạt
        // (world đổi/game restart) — đúng lúc dễ respring nhất. Bỏ bulk-map,
        // bóp discover, resolve lại task port, xả cache héo 1 lần.
        ESPLog("PROVIDER degraded fails=%llu: giam bulk/discover, reset task port",
               (unsigned long long)f);
        ESPGameTaskReset();
        s_flushPending.store(true, std::memory_order_relaxed);
    }
}

void ESPProviderNoteFullScan(void) {
    s_scans.fetch_add(1, std::memory_order_relaxed);
}

BOOL ESPProviderIsDegraded(void) {
    return s_degraded.load(std::memory_order_relaxed) ? YES : NO;
}

uint64_t ESPProviderFailureCount(void) {
    return s_fails.load(std::memory_order_relaxed);
}

uint64_t ESPProviderFullScanCount(void) {
    return s_scans.load(std::memory_order_relaxed);
}

BOOL ESPProviderShouldBulkMap(void) {
    return s_degraded.load(std::memory_order_relaxed) ? NO : YES;
}

int ESPProviderDiscoverBudget(void) {
    return s_degraded.load(std::memory_order_relaxed)
        ? ESP_PROVIDER_DEGRADED_BUDGET : ESP_DISCOVER_BUDGET;
}

void ESPProviderShutdown(void) {
    // Reset trạng thái (world/match mới, tắt HUD). Không flush ở đây —
    // caller đã flush. Không đụng depth (transaction đang mở vẫn hợp lệ).
    s_degraded.store(false, std::memory_order_relaxed);
    s_fails.store(0, std::memory_order_relaxed);
    s_recover.store(0, std::memory_order_relaxed);
    s_flushPending.store(false, std::memory_order_relaxed);
}

void ESPProviderDeferFlush(void) {
    s_flushPending.store(true, std::memory_order_relaxed);
}

BOOL ESPProviderTakeFlushRequest(void) {
    return s_flushPending.exchange(false, std::memory_order_relaxed) ? YES : NO;
}

#else
// Simulator / non-DarkSword: stub để link được.
void ESPProviderBeginRead(void) {}
void ESPProviderEndRead(void) {}
int ESPProviderDepth(void) { return 0; }
void ESPProviderNoteKernelRead(BOOL ok) { (void)ok; }
void ESPProviderNoteFullScan(void) {}
BOOL ESPProviderIsDegraded(void) { return NO; }
uint64_t ESPProviderFailureCount(void) { return 0; }
uint64_t ESPProviderFullScanCount(void) { return 0; }
BOOL ESPProviderShouldBulkMap(void) { return YES; }
int ESPProviderDiscoverBudget(void) { return ESP_DISCOVER_BUDGET; }
void ESPProviderShutdown(void) {}
void ESPProviderDeferFlush(void) {}
BOOL ESPProviderTakeFlushRequest(void) { return NO; }
#endif
