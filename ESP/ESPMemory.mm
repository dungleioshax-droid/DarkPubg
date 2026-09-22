//
//  ESPMemory.mm
//  Implementation: map từng page của game vào process mình rồi memcpy.
//

#import "ESPMemory.h"
#import "ESPConfig.h"
#import "ESPTask.h"
#import <mach/mach.h>
#include <atomic>
#include <mutex>

#if USE_DARKSWORD
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

struct ESPShmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool used;
};
extern "C" struct ESPShmem vmmapremotepage(uint64_t vmMap, uint64_t address);
extern "C" kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);

// vmmapremotepage() không re-entrant: nó tạo memory entry rồi bump
// vm_object ref_count trong kernel bằng ds_kwrite32. Hai thread cùng đọc
// (ESP scan ở queue nền + HUD tick ở bridge queue) có thể ghi đè refcount
// của cùng vm_object -> vm_object bị free sớm -> panic/respring.
// Mọi đường đọc memory game phải đi qua mutex này.
static std::mutex s_espReadMutex;

// Chỉ nhận địa chỉ userspace của process game (4GB..0x3000_0000_0000).
// Pointer rác trong Actor array rơi xuống kernel walk sẽ treo/panic.
static inline BOOL ESPRemoteAddrUsable(uint64_t addr) {
    return addr >= 0x100000000ULL && addr < 0x300000000000ULL;
}

// ---- Đường đọc NHANH: page cache của PROCESS GAME ----
// vmmapremotepage() tạo 1 mapping LIVE (share vm_object của game, giữ bằng
// ref_count) => game ghi gì mình đọc thấy ngay. Nó đắt ở chỗ: tạo memory
// entry + bump refcount bằng kernel write + map + dealloc + 1 port mỗi lần
// gọi. Mỗi mapping chỉ phủ ĐÚNG 1 page nên cache theo địa chỉ page chính xác:
// dữ liệu nóng (statics, mảng actors, camera, root địch) sau lần chạm đầu chỉ
// còn memcpy thuần. Đọc cửa sổ lớn (0xF00/actor lúc phân loại) đi đường trực
// tiếp không cache để không đuổi dữ liệu nóng khỏi cache.
#define ESP_PAGE_CACHE_SIZE 256

struct ESPPageCacheEntry {
    uint64_t pageStart;    // địa chỉ page đã map (0 = slot trống)
    uint64_t localAddress; // mapping live của đúng page đó trong process mình
    uint64_t port;         // memory-entry port phải giữ cùng localAddress
    uint64_t lastUse;      // cho LRU
};
static ESPPageCacheEntry s_pageCache[ESP_PAGE_CACHE_SIZE];
static uint64_t s_pageCacheClock = 1; // tăng dần, trị lastUse
// Đếm hit/miss để chẩn đoán vì sao refresh chậm (log box perf).
static uint64_t s_cacheHit = 0;
static uint64_t s_cacheMiss = 0;
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

// Tìm trong cache theo page CHÍNH XÁC. KHÔNG lock — caller giữ mutex.
static ESPPageCacheEntry *ESPPageCacheFind(uint64_t pageStart) {
    for (int i = 0; i < ESP_PAGE_CACHE_SIZE; i++) {
        ESPPageCacheEntry *e = &s_pageCache[i];
        if (e->pageStart == pageStart) {
            e->lastUse = s_pageCacheClock;
            return e;
        }
    }
    return NULL;
}

// Lấy mapping live cho pageStart (cache -> miss thì map mới + đưa vào cache).
// KHÔNG lock — caller giữ mutex.
static BOOL ESPPageCacheGet(uint64_t vmMap, uint64_t pageStart,
                            uint64_t *outLocal) {
    ESPPageCacheEntry *e = ESPPageCacheFind(pageStart);
    if (e) {
        s_cacheHit++;
        *outLocal = e->localAddress;
        return YES;
    }
    s_cacheMiss++;
    // Miss: map page mới bằng vmmapremotepage (đường đang chạy được).
    struct ESPShmem sh = vmmapremotepage(vmMap, pageStart);
    if (!sh.used || !sh.localAddress) return NO;
    // Đưa vào slot LRU (hoặc slot trống).
    ESPPageCacheEntry *victim = &s_pageCache[0];
    for (int i = 0; i < ESP_PAGE_CACHE_SIZE; i++) {
        if (!s_pageCache[i].pageStart) { victim = &s_pageCache[i]; break; }
        if (s_pageCache[i].lastUse < victim->lastUse) victim = &s_pageCache[i];
    }
    if (victim->pageStart) {
        // Nhả mapping + port của slot bị đuổi.
        if (victim->localAddress) {
            mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)victim->localAddress, PAGE_SIZE);
        }
        if (victim->port) mach_port_deallocate(mach_task_self_, (mach_port_t)victim->port);
        victim->localAddress = 0; victim->port = 0; victim->pageStart = 0;
    }
    victim->pageStart = pageStart;
    victim->localAddress = sh.localAddress;
    victim->port = sh.port;
    victim->lastUse = s_pageCacheClock;
    *outLocal = sh.localAddress;
    return YES;
}

// KHÔNG lock — caller đã giữ s_espReadMutex.
static void ESPPageCacheFlushLocked(void) {
    for (int i = 0; i < ESP_PAGE_CACHE_SIZE; i++) {
        ESPPageCacheEntry *e = &s_pageCache[i];
        if (e->pageStart) {
            if (e->localAddress) {
                mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)e->localAddress, PAGE_SIZE);
            }
            if (e->port) mach_port_deallocate(mach_task_self_, (mach_port_t)e->port);
            e->pageStart = 0; e->localAddress = 0; e->port = 0; e->lastUse = 0;
        }
    }
}

void ESPMemoryFlushPageCache(void) {
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    ESPPageCacheFlushLocked();
}

BOOL ESPMemoryFlushPageCacheIfIdle(void) {
    std::unique_lock<std::mutex> readLock(s_espReadMutex, std::try_to_lock);
    if (!readLock.owns_lock()) return NO; // scan nền đang map page — để lần sau
    ESPPageCacheFlushLocked();
    return YES;
}

// Đường trực tiếp: map -> memcpy -> nhả ngay, KHÔNG qua cache. Dùng cho đọc
// stream (cửa sổ 0xF00/actor lúc phân loại). KHÔNG lock — caller giữ mutex.
static BOOL ESPReadDirectLocked(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    uint64_t off = 0;
    uint8_t *out = (uint8_t *)buf;
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        uint64_t pageOff = addr - pageStart;
        struct ESPShmem sh = vmmapremotepage(vmMap, pageStart);
        if (!sh.used || !sh.localAddress) return NO;
        uint64_t chunk = len - off;
        if (chunk > PAGE_SIZE - pageOff) chunk = PAGE_SIZE - pageOff;
        memcpy(out + off, (void *)(uintptr_t)(sh.localAddress + pageOff), (size_t)chunk);
        mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)sh.localAddress, PAGE_SIZE);
        // vmmapremotepage tạo 1 memory-entry port cho mỗi page — phải nhả,
        // không là leak hàng nghìn port/scan rồi bị Jetsam kill app.
        if (sh.port) mach_port_deallocate(mach_task_self_, (mach_port_t)sh.port);
        off += chunk;
    }
    return YES;
}

uint64_t ESPMemoryOpenVMMapForProc(uint64_t proc) {
    if (!proc) return 0;
    if (!ds_is_ready()) return 0;
    uint64_t task = taskbyproc(proc);
    if (!task) return 0;
    uint64_t vmMap = task_get_vm_map(task);
    return vmMap;
}

BOOL ESPMemoryRead(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    if (!vmMap || !remoteAddr || !buf || !len) return NO;
    if (len > 0x10000) return NO; // chặn đọc quá lớn 1 lần
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    // Đường NHANH (như aovcheat): task port game + mach_vm_read_overwrite bulk.
    // Không cần mutex (không đụng vmmapremotepage). Fail thì rơi xuống exploit.
    if (ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    s_kernelReads++;
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    s_pageCacheClock++;
    // Đọc dài hơn 1 page (cửa sổ 0xF00 lúc phân loại actor) là stream: đi
    // đường trực tiếp, không làm bẩn cache dữ liệu nóng.
    if (len > (uint64_t)PAGE_SIZE) {
        return ESPReadDirectLocked(vmMap, remoteAddr, buf, len);
    }
    uint64_t off = 0;
    uint8_t *out = (uint8_t *)buf;
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        uint64_t pageOff = addr - pageStart;
        uint64_t local = 0;
        if (!ESPPageCacheGet(vmMap, pageStart, &local)) return NO;
        uint64_t chunk = len - off;
        if (chunk > PAGE_SIZE - pageOff) chunk = PAGE_SIZE - pageOff;
        memcpy(out + off, (void *)(uintptr_t)(local + pageOff), (size_t)chunk);
        // Mapping là LIVE (share vm_object game) nên giữ trong cache không
        // làm dữ liệu cũ — game ghi gì mình đọc thấy ngay. Chỉ nhả khi bị
        // đuổi khỏi cache hoặc flush.
        off += chunk;
    }
    return YES;
}

// 1 page là 4K hoặc 16K tuỳ build — chặn trên cho buffer trên stack.
#define ESP_MAX_PAGE 0x4000ULL

BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    if (!vmMap || !remoteAddr || !buf || !len) return NO;
    if (len > 0x40000) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    if ((uint64_t)PAGE_SIZE > ESP_MAX_PAGE) return NO;
    // Đường NHANH: 1 lần mach_vm_read_overwrite thay vì map từng page.
    if (len <= 0x10000 && ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    s_kernelReads++;
    uint8_t pageBuf[ESP_MAX_PAGE];
    uint8_t *out = (uint8_t *)buf;
    uint64_t off = 0;
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        uint64_t pageOff = addr - pageStart;
        uint64_t chunk = (uint64_t)PAGE_SIZE - pageOff;
        if (chunk > len - off) chunk = len - off;
        // đọc nguyên 1 page từ địa chỉ page-align, đường trực tiếp (không
        // cache) — cửa sổ 0xF00 chỉ đọc 1 lần/actor lúc phân loại.
        if (!ESPReadDirectLocked(vmMap, pageStart, pageBuf, (uint64_t)PAGE_SIZE)) return NO;
        memcpy(out + off, pageBuf + pageOff, (size_t)chunk);
        off += chunk;
    }
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
void ESPMemoryFlushPageCache(void) {
}
BOOL ESPMemoryFlushPageCacheIfIdle(void) {
    return NO;
}
void ESPMemoryCacheStats(uint64_t *hit, uint64_t *miss) {
    if (hit) *hit = 0;
    if (miss) *miss = 0;
}
void ESPMemoryReadPathStats(uint64_t *taskReads, uint64_t *kernelReads) {
    if (taskReads) *taskReads = 0;
    if (kernelReads) *kernelReads = 0;
}
#endif
