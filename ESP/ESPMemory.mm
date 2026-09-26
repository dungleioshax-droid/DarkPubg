//
//  ESPMemory.mm
//  Đọc memory game DUY NHẤT qua task port (mach_vm_read_overwrite, như aovcheat).
//  Kernel Read (region map/vmmapremotepage) đã XOÁ SẠCH — nó là nguồn lag.
//  Giữ lại kernel read metadata tối thiểu (tìm proc/task/pid) để dựng port;
//  đó là 1 lần mỗi session, không phải đường nóng.
//

#import "ESPMemory.h"
#import "ESPConfig.h"
#import "ESPTask.h"
#import "ESPProvider.h"
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <atomic>
#include <mutex>
#include <string.h>

#if USE_DARKSWORD
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// Mutex giữ cho API flush (giờ là no-op nhưng callers vẫn gọi) + tương lai.
// Đường đọc task port lock-free, không cần mutex.
static std::mutex s_espReadMutex;

// Chỉ nhận địa chỉ userspace của process game (4GB..0x3000_0000_0000).
// Pointer rác trong Actor array rơi xuống kernel walk sẽ treo/panic.
static inline BOOL ESPRemoteAddrUsable(uint64_t addr) {
    return addr >= 0x100000000ULL && addr < 0x300000000000ULL;
}

// ---- ĐÃ XOÁ Kernel Read (region map/vmmapremotepage): mọi read đi task port.
// Giữ lại counters để API stats/log không đổi (đọc luôn 0 ở đường kernel).
// Đếm hit/miss để chẩn đoán (log box perf).
static uint64_t s_cacheHit = 0;
static uint64_t s_cacheMiss = 0;
// Đếm lần map vùng: maps = số lần map thành công, pages = tổng page phủ,
// fails = số lần thử vùng lớn phải rơi về vùng nhỏ/map 1 page.
static uint64_t s_chunkMaps = 0;
static uint64_t s_chunkPages = 0;
static uint64_t s_chunkFails = 0;
// Đếm đường đọc: task port (nhanh) vs kernel exploit (chậm). Atomic vì cả
// scan queue lẫn timer bridge queue đều đọc.
static std::atomic<uint64_t> s_taskReads{0};
static std::atomic<uint64_t> s_kernelReads{0};

void ESPMemoryCacheStats(uint64_t *hit, uint64_t *miss) {
    if (hit) *hit = s_cacheHit;
    if (miss) *miss = s_cacheMiss;
}

void ESPMemoryReadPathStats(uint64_t *taskReads, uint64_t *kernelReads) {
    if (taskReads) *taskReads = s_taskReads.load();
    if (kernelReads) *kernelReads = s_kernelReads.load();
}

void ESPMemoryChunkStats(uint64_t *maps, uint64_t *pages, uint64_t *fails) {
    if (maps) *maps = s_chunkMaps;
    if (pages) *pages = s_chunkPages;
    if (fails) *fails = s_chunkFails;
}

// (ESPRegionSpan/Find/Insert/AvoidOverlap/GetLocked/ReadCachedLocked đã xoá
// cùng Kernel Read — mọi read đi ESPTaskRead.)
uint64_t ESPMemoryRegionCount(void) {
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    return 0;
}

uint64_t ESPMemoryOpenVMMapForProc(uint64_t proc) {
    if (!proc) return 0;
    if (!ds_is_ready()) return 0;
    uint64_t task = taskbyproc(proc);
    if (!ds_isvalid(task)) return 0;
    uint64_t vmMap = task_get_vm_map(task);
    if (!ds_isvalid(vmMap)) return 0;
    return vmMap;
}

BOOL ESPMemoryRead(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    (void)vmMap; // không dùng vmMap nữa: đọc duy nhất qua task port (syscall)
    if (!remoteAddr || !buf || !len) return NO;
    if (len > 0x10000) return NO; // chặn đọc quá lớn 1 lần
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    // DUY NHẤT đường này (như aovcheat): task port game + mach_vm_read_overwrite.
    // Không port -> NO (không fallback Kernel Read nữa). Không cần mutex.
    if (ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    ESPProviderNoteKernelRead(NO);
    return NO;
}

// Đọc dài: task port lo hết, không chia page/map gì cả.
BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    (void)vmMap;
    if (!remoteAddr || !buf || !len) return NO;
    if (len > 0x40000) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    if (ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    ESPProviderNoteKernelRead(NO);
    return NO;
}

// Peek rẻ: giờ tương đương ESPMemoryRead (không còn cache region nào).
BOOL ESPMemoryReadCached(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    return ESPMemoryRead(vmMap, remoteAddr, buf, len);
}

// Không còn cache region nào để xả — giữ hàm cho callers cũ (no-op).
void ESPMemoryFlushPageCache(void) {
}

BOOL ESPMemoryFlushPageCacheIfIdle(void) {
    // Trong transaction đọc: vẫn tôn trọng defer của provider.
    if (ESPProviderDepth() > 0) { ESPProviderDeferFlush(); return NO; }
    (void)ESPProviderTakeFlushRequest();
    return YES;
}
#else
// Simulator / non-DarkSword: không có kernel RW — stub để link được.
uint64_t ESPMemoryOpenVMMapForProc(uint64_t proc) {
    (void)proc;
    return 0;
}
BOOL ESPMemoryRead(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    (void)vmMap; (void)remoteAddr; (void)buf; (void)len;
    return NO;
}
BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    (void)vmMap; (void)remoteAddr; (void)buf; (void)len;
    return NO;
}
BOOL ESPMemoryReadCached(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    (void)vmMap; (void)remoteAddr; (void)buf; (void)len;
    return NO;
}
void ESPMemoryFlushPageCache(void) {
}
BOOL ESPMemoryFlushPageCacheIfIdle(void) {
    return NO;
}
void ESPMemoryCacheStats(uint64_t *hit, uint64_t *miss) {
    if (hit) *hit = 0;
    if (miss) *miss = 0;
}
uint64_t ESPMemoryRegionCount(void) {
    return 0;
}
void ESPMemoryReadPathStats(uint64_t *taskReads, uint64_t *kernelReads) {
    if (taskReads) *taskReads = 0;
    if (kernelReads) *kernelReads = 0;
}
void ESPMemoryChunkStats(uint64_t *maps, uint64_t *pages, uint64_t *fails) {
    if (maps) *maps = 0;
    if (pages) *pages = 0;
    if (fails) *fails = 0;
}
#endif
