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
extern "C" struct ESPShmem vmmapremoterange(uint64_t vmMap, uint64_t address, uint64_t pages);
extern "C" uint64_t vmmapfindentry(uint64_t vmMap, uint64_t address);
extern "C" void vmentrygetrange(uint64_t entry, uint64_t *startout, uint64_t *endout);
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
// 512 slot = 512 x PAGE_SIZE (16KB) ~ 8MB pinned: đủ giữ page của MỌI actor
// (kể cả trận 300+ actor) + camera + statics + mảng actors, để lượt quét đầy đủ
// và probe VTable không phải map lại page nào (map page là ~37ms/vòng — đo từ
// log: lượt quét 132 actor ngốn 5.0s khi cache bị xả).
#define ESP_PAGE_CACHE_SIZE 512

// ---- BULK MAP: đọc như aovcheat nhưng bằng đường kernel ----
// aovcheat đọc cả cụm bằng 1 vm_read_overwrite qua task port. Không có task
// port thì cách tương đương: map NHIỀU page liên tiếp trong 1 lần mach_vm_map
// (vmmapremoterange) thay vì map từng page — mỗi lần map tốn ~37ms nên lượt
// quét đầu (≈137 actor ≈ 137 page) từ ~5s xuống còn vài chục lần map.
// Chỉ áp dụng khi cả cụm nằm trong CÙNG vm_map_entry (cùng vm_object) — ngoài
// ra tự rơi về map từng page.
#define ESP_CHUNK_PAGES 16
// Trần mapping giữ sống: vượt thì không bulk nữa (map từng page) để không phình
// địa chỉ ảo/port. 16MB = 1024 page, quá đủ cho page nóng của 1 trận.
#define ESP_MAX_LIVE_BYTES (16ULL * 1024 * 1024)

struct ESPPageCacheEntry {
    uint64_t pageStart;    // page đầu tiên đã map (0 = slot trống)
    uint64_t localAddress; // mapping live của cụm đó trong process mình
    uint64_t port;         // memory-entry port phải giữ cùng localAddress
    uint64_t lastUse;      // cho LRU
    uint32_t pages;        // số page mapping này phủ (1 = map lẻ)
};
static ESPPageCacheEntry s_pageCache[ESP_PAGE_CACHE_SIZE];
static uint64_t s_pageCacheClock = 1; // tăng dần, trị lastUse
static uint64_t s_liveBytes = 0;      // tổng byte đang map giữ sống
// Đếm hit/miss để chẩn đoán vì sao refresh chậm (log box perf).
static uint64_t s_cacheHit = 0;
static uint64_t s_cacheMiss = 0;
// Đếm bulk map (bao nhiêu lần gọi, bao nhiêu page phủ, bao nhiêu lần fail).
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

// Tìm entry PHỦ pageStart (mapping có thể phủ nhiều page). KHÔNG lock —
// caller giữ mutex. Trả offset page trong mapping qua outPageOffset.
static ESPPageCacheEntry *ESPPageCacheFind(uint64_t pageStart,
                                           uint64_t *outPageOffset) {
    for (int i = 0; i < ESP_PAGE_CACHE_SIZE; i++) {
        ESPPageCacheEntry *e = &s_pageCache[i];
        if (!e->pageStart) continue;
        uint64_t span = (uint64_t)(e->pages ? e->pages : 1) * PAGE_SIZE;
        if (pageStart >= e->pageStart && pageStart - e->pageStart < span) {
            e->lastUse = s_pageCacheClock;
            if (outPageOffset) *outPageOffset = (pageStart - e->pageStart) / PAGE_SIZE;
            return e;
        }
    }
    return NULL;
}

// Số page liên tiếp có thể bulk-map từ chunkStart mà vẫn nằm trong cùng
// vm_map_entry (cùng object). 0/1 = không bulk được.
// vmmapfindentry() đi tuần tự danh sách entry (2 kernel read/entry) nên cache
// lại kết quả theo địa chỉ chunk: các miss liên tiếp thường rơi vào CÙNG entry
// (nhiều actor cùng vùng nhớ) -> chỉ walk 1 lần cho cả cụm.
#define ESP_SPAN_CACHE 32
struct ESPVMSpan {
    uint64_t chunk;
    uint64_t start;
    uint64_t end;
};
static ESPVMSpan s_spanCache[ESP_SPAN_CACHE];
static int s_spanNext = 0;

static uint64_t ESPChunkPageCount(uint64_t vmMap, uint64_t chunkStart) {
    uint64_t start = 0, end = 0;
    for (int i = 0; i < ESP_SPAN_CACHE; i++) {
        if (s_spanCache[i].chunk == chunkStart) {
            start = s_spanCache[i].start;
            end = s_spanCache[i].end;
            goto have_span;
        }
    }
    {
        uint64_t entry = vmmapfindentry(vmMap, chunkStart);
        if (!entry) return 0;
        vmentrygetrange(entry, &start, &end);
        s_spanCache[s_spanNext] = (ESPVMSpan){chunkStart, start, end};
        s_spanNext = (s_spanNext + 1) % ESP_SPAN_CACHE;
    }
have_span:
    if (end <= chunkStart) return 0;
    uint64_t fit = (end - chunkStart) / PAGE_SIZE;
    if (fit > ESP_CHUNK_PAGES) fit = ESP_CHUNK_PAGES;
    return fit;
}

// Lấy mapping live cho pageStart (cache -> miss thì map mới + đưa vào cache).
// KHÔNG lock — caller giữ mutex.
static BOOL ESPPageCacheGet(uint64_t vmMap, uint64_t pageStart,
                            uint64_t *outLocal) {
    uint64_t pageOff = 0;
    ESPPageCacheEntry *e = ESPPageCacheFind(pageStart, &pageOff);
    if (e) {
        s_cacheHit++;
        *outLocal = e->localAddress + pageOff * PAGE_SIZE;
        return YES;
    }
    s_cacheMiss++;
    // (1) BULK: map cả cụm page trong 1 lần (xem ESP_CHUNK_PAGES). Chỉ khi còn
    //     dưới trần mapping giữ sống.
    struct ESPShmem sh = {0};
    uint64_t chunkStart = pageStart;
    uint64_t chunkPages = 1;
    BOOL triedBulk = NO;
    uint64_t chunkStartAligned = pageStart & ~(uint64_t)(ESP_CHUNK_PAGES * PAGE_SIZE - 1);
    if (s_liveBytes < ESP_MAX_LIVE_BYTES) {
        uint64_t fit = ESPChunkPageCount(vmMap, chunkStartAligned);
        if (fit > 1) {
            triedBulk = YES;
            sh = vmmapremoterange(vmMap, chunkStartAligned, fit);
            if (sh.used && sh.localAddress) {
                chunkStart = chunkStartAligned;
                chunkPages = fit;
                s_chunkMaps++;
                s_chunkPages += fit;
            }
        }
    }
    // (2) Không bulk được (khác entry / vượt object / hết trần) -> map 1 page
    //     đúng như đường cũ.
    if (!sh.used || !sh.localAddress) {
        if (triedBulk) s_chunkFails++;
        sh = vmmapremotepage(vmMap, pageStart);
        if (!sh.used || !sh.localAddress) return NO;
        chunkStart = pageStart;
        chunkPages = 1;
    }
    // Đưa vào slot LRU (hoặc slot trống).
    ESPPageCacheEntry *victim = &s_pageCache[0];
    for (int i = 0; i < ESP_PAGE_CACHE_SIZE; i++) {
        if (!s_pageCache[i].pageStart) { victim = &s_pageCache[i]; break; }
        if (s_pageCache[i].lastUse < victim->lastUse) victim = &s_pageCache[i];
    }
    if (victim->pageStart) {
        // Nhả mapping + port của slot bị đuổi.
        uint64_t victimBytes = (uint64_t)(victim->pages ? victim->pages : 1) * PAGE_SIZE;
        if (victim->localAddress) {
            mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)victim->localAddress, victimBytes);
        }
        if (victim->port) mach_port_deallocate(mach_task_self_, (mach_port_t)victim->port);
        s_liveBytes = s_liveBytes > victimBytes ? s_liveBytes - victimBytes : 0;
        victim->localAddress = 0; victim->port = 0; victim->pageStart = 0; victim->pages = 0;
    }
    victim->pageStart = chunkStart;
    victim->localAddress = sh.localAddress;
    victim->port = sh.port;
    victim->pages = (uint32_t)chunkPages;
    victim->lastUse = s_pageCacheClock;
    s_liveBytes += (uint64_t)chunkPages * PAGE_SIZE;
    *outLocal = sh.localAddress + (pageStart - chunkStart);
    return YES;
}

// KHÔNG lock — caller đã giữ s_espReadMutex.
static void ESPPageCacheFlushLocked(void) {
    for (int i = 0; i < ESP_PAGE_CACHE_SIZE; i++) {
        ESPPageCacheEntry *e = &s_pageCache[i];
        if (e->pageStart) {
            if (e->localAddress) {
                uint64_t bytes = (uint64_t)(e->pages ? e->pages : 1) * PAGE_SIZE;
                mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)e->localAddress, bytes);
            }
            if (e->port) mach_port_deallocate(mach_task_self_, (mach_port_t)e->port);
            e->pageStart = 0; e->localAddress = 0; e->port = 0; e->lastUse = 0; e->pages = 0;
        }
    }
    s_liveBytes = 0;
    // Bounds của vm_map_entry cũng phải quên: world/map đổi thì entry cũ không
    // còn đúng, dùng lại sẽ bulk-map nhầm vùng.
    for (int i = 0; i < ESP_SPAN_CACHE; i++) s_spanCache[i] = (ESPVMSpan){0, 0, 0};
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

// ĐƯỜNG ĐỌC DUY NHẤT khi không có task port: mọi page đi qua page cache (và
// lần miss thì thử bulk-map cả cụm). Đây là chỗ khiến lượt quét đầy đủ
// (≈137 actor) rẻ hơn nhiều so với map từng page: cụm actor nằm gần nhau
// trong cùng vm_map_entry sẽ được map 1 lần cho cả cụm.
// KHÔNG lock — caller giữ s_espReadMutex.
static BOOL ESPReadCachedLocked(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
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
        // làm dữ liệu cũ — game ghi gì mình đọc thấy ngay.
        off += chunk;
    }
    return YES;
}

BOOL ESPMemoryReadCached(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    if (!vmMap || !remoteAddr || !buf || !len) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    // Task port có thì dùng luôn (còn rẻ hơn cache).
    if (ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    uint64_t pageOff = 0;
    uint64_t off = 0;
    uint8_t *out = (uint8_t *)buf;
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        pageOff = addr - pageStart;
        // CHỈ tìm trong cache — không gọi vmmapremotepage: đường peek không được
        // phép làm phình số mapping (real match có thể 300+ actor).
        ESPPageCacheEntry *e = ESPPageCacheFind(pageStart, NULL);
        if (!e) return NO;
        s_cacheHit++;
        uint64_t chunk = len - off;
        if (chunk > PAGE_SIZE - pageOff) chunk = PAGE_SIZE - pageOff;
        memcpy(out + off, (void *)(uintptr_t)(e->localAddress + pageOff), (size_t)chunk);
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
    return ESPReadCachedLocked(vmMap, remoteAddr, buf, len);
}

// 1 page là 4K hoặc 16K tuỳ build — chặn trên cho buffer trên stack.
#define ESP_MAX_PAGE 0x4000ULL
BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    if (!vmMap || !remoteAddr || !buf || !len) return NO;
    if (len > 0x40000) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    // Đường NHANH: 1 lần mach_vm_read_overwrite thay vì map từng page.
    if (len <= 0x10000 && ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    s_kernelReads++;
    // Không có task port: đi page cache + bulk map (xem ESP_CHUNK_PAGES). Cửa
    // sổ 0xF00 của actor trước đây map/lại mỗi lượt quét (~37ms/actor ≈ 5s cho
    // 137 actor) — giờ cụm actor gần nhau chỉ tốn 1 lần map, lượt sau là memcpy.
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    s_pageCacheClock++;
    return ESPReadCachedLocked(vmMap, remoteAddr, buf, len);
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
