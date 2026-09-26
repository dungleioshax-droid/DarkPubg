//
//  ESPMemory.mm
//  Implementation: map 1 lần cho cả VÙNG của vm_map_entry rồi memcpy.
//
//  CƠ CHẾ (thay cho page-cache LRU cũ):
//  Lần chạm đầu vào một vùng -> tìm vm_map_entry phủ địa chỉ, map MỘT LẦN
//  cả vùng liên tiếp (tối đa ESP_REGION_PAGES, cắt theo biên entry) bằng
//  vmmapremoterange và GIỮ VĨNH VIỄN. Từ đó mọi lần đọc trong vùng chỉ còn
//  memcpy — không còn allocate/make_memory_entry/refcount/map/dealloc mỗi lần,
//  không còn LRU đuổi slot (dealloc + hạ refcount) trên đường vẽ.
//
//  Vì sao bỏ LRU/dealloc: mapping này SHARE vm_object của game nên không tốn
//  thêm RAM vật lý; giữ lại hoàn toàn rẻ. Đổi lại nó bỏ hẳn hai thứ trước đây
//  gây giật + respring:
//    (1) map+dealloc liên tục (~37ms/vòng) khi cache miss/thrash;
//    (2) ghi kernel refcount (RMW không atomic) mỗi lần map VÀ mỗi lần evict —
//        đua với chính game -> vm_object free sớm -> panic/respring.
//  Giờ refcount chỉ bị bump 1 lần cho mỗi vùng (vài lần/trận), không bao giờ
//  bị hạ trên đường nóng (chỉ hạ khi xả toàn bộ lúc đổi world).
//

#import "ESPMemory.h"
#import "ESPConfig.h"
#import "ESPTask.h"
#import "ESPProvider.h"
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

// vmmapremoterange()/vmmapremotepage() không re-entrant: nó tạo memory entry rồi
// bump vm_object ref_count trong kernel bằng ds_kwrite32. Hai thread cùng map
// (ESP scan ở queue nền + HUD tick ở bridge queue) có thể ghi đè refcount của
// cùng vm_object -> vm_object bị free sớm -> panic/respring.
// Mọi đường map/đọc memory game phải đi qua mutex này.
static std::mutex s_espReadMutex;

// Chỉ nhận địa chỉ userspace của process game (4GB..0x3000_0000_0000).
// Pointer rác trong Actor array rơi xuống kernel walk sẽ treo/panic.
static inline BOOL ESPRemoteAddrUsable(uint64_t addr) {
    return addr >= 0x100000000ULL && addr < 0x300000000000ULL;
}

// ---- REGION MAP: 1 vùng = 1 lần map, giữ vĩnh viễn ----
// Mỗi vùng phủ tối đa ESP_REGION_PAGES page liên tiếp; vùng căn theo
// ESP_REGION_BYTES để các địa chỉ gần nhau rơi vào CÙNG vùng (không map chồng).
// Thực tế vm_map_entry của game khá nhỏ (~vài chục page) nên cỡ vùng bị BIÊN
// ENTRY chặn, không phải hằng số này; đặt lớn (1024 page) để entry lớn cũng
// được phủ trọn trong 1 lần map. Đây là lý do tăng hằng số không làm box lên
// nhanh hơn: nút thắt là số vm_map_entry, không phải kích thước tối đa.
#define ESP_REGION_PAGES 1024
#define ESP_REGION_BYTES ((uint64_t)ESP_REGION_PAGES * PAGE_SIZE)
// Trần số vùng giữ sống (mỗi vùng 1 mapping + 1 port). 512 vùng là quá đủ cho
// 1 trận; vượt thì ngừng map vùng mới (đọc mới sẽ không thành vùng lớn nữa).
#define ESP_REGION_MAX 512
// Trần byte mapping giữ sống. Mapping SHARE page vật lý của game nên không tốn
// RAM, nhưng chặn trên để không phình địa chỉ ảo/port vô hạn.
#define ESP_MAX_LIVE_BYTES (512ULL * 1024 * 1024)

struct ESPRegion {
    uint64_t base;         // page-align, mốc bắt đầu mapping
    uint64_t localAddress; // mapping live trong process mình
    uint64_t port;         // memory-entry port phải giữ cùng localAddress
    uint32_t pages;        // số page vùng này phủ
};
static ESPRegion s_regions[ESP_REGION_MAX];
static int s_regionCount = 0;
static uint64_t s_liveBytes = 0;
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

uint64_t ESPMemoryRegionCount(void) {
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    return (uint64_t)s_regionCount;
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

static inline uint64_t ESPRegionSpan(const ESPRegion *r) {
    return (uint64_t)(r->pages ? r->pages : 1) * PAGE_SIZE;
}

// Tìm vùng PHỦ pageStart. Mảng sắp theo base và các vùng KHÔNG chồng nhau nên
// chỉ cần tìm vùng cuối có base <= pageStart rồi kiểm tra nó có phủ không.
// KHÔNG lock — caller giữ mutex.
static ESPRegion *ESPRegionFind(uint64_t pageStart, uint64_t *outPageOffset) {
    int lo = 0, hi = s_regionCount - 1, cand = -1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        if (s_regions[mid].base <= pageStart) {
            cand = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if (cand < 0) return NULL;
    ESPRegion *r = &s_regions[cand];
    if (pageStart - r->base < ESPRegionSpan(r)) {
        if (outPageOffset) *outPageOffset = (pageStart - r->base) / PAGE_SIZE;
        return r;
    }
    return NULL;
}

// Chèn giữ nguyên thứ tự theo base (mảng nhỏ, miss rất thưa). KHÔNG lock.
static void ESPRegionInsert(uint64_t base, uint64_t local, uint64_t port, uint64_t pages) {
    int i = s_regionCount;
    while (i > 0 && s_regions[i - 1].base > base) {
        s_regions[i] = s_regions[i - 1];
        i--;
    }
    s_regions[i].base = base;
    s_regions[i].localAddress = local;
    s_regions[i].port = port;
    s_regions[i].pages = (uint32_t)pages;
    s_regionCount++;
}

// Nếu `base` rơi vào một vùng đã có thì nhích lên ngay sau vùng đó để không map
// chồng. (pageStart chắc chắn không bị vùng nào phủ vì đây là miss.)
// KHÔNG lock.
static uint64_t ESPRegionAvoidOverlap(uint64_t base, uint64_t pageStart) {
    for (int guard = 0; guard < 8; guard++) {
        uint64_t hitEnd = 0;
        for (int i = 0; i < s_regionCount; i++) {
            uint64_t s = s_regions[i].base;
            uint64_t e = s + ESPRegionSpan(&s_regions[i]);
            if (base >= s && base < e) { hitEnd = e; break; }
        }
        if (!hitEnd) break;
        base = hitEnd;
    }
    if (base > pageStart) return pageStart;
    return base;
}

// Lấy mapping live cho pageStart: hit thì memcpy, miss thì map CẢ VÙNG 1 lần
// rồi giữ vĩnh viễn. KHÔNG lock — caller giữ mutex.
static BOOL ESPRegionGetLocked(uint64_t vmMap, uint64_t pageStart, uint64_t *outLocal) {
    uint64_t pageOff = 0;
    ESPRegion *hit = ESPRegionFind(pageStart, &pageOff);
    if (hit) {
        s_cacheHit++;
        *outLocal = hit->localAddress + pageOff * PAGE_SIZE;
        return YES;
    }
    s_cacheMiss++;
    if (s_regionCount >= ESP_REGION_MAX) return NO;

    // Vùng lớn chỉ khi còn dưới trần và không degraded. Degraded -> map 1 page
    // (vẫn giữ vĩnh viễn) cho an toàn như DarkSwordMemoryProvider.
    BOOL allowLarge = (s_liveBytes < ESP_MAX_LIVE_BYTES) && ESPProviderShouldBulkMap();

    struct ESPShmem sh = {0};
    uint64_t base = pageStart;
    uint64_t pages = 1;
    if (allowLarge) {
        uint64_t entry = vmmapfindentry(vmMap, pageStart);
        uint64_t entryStart = 0, entryEnd = 0;
        if (entry) vmentrygetrange(entry, &entryStart, &entryEnd);
        if (entry && entryEnd > pageStart) {
            base = pageStart & ~(ESP_REGION_BYTES - 1);
            if (base < entryStart) base = entryStart; // entryStart đã page-align
            base = ESPRegionAvoidOverlap(base, pageStart);
            if (base <= pageStart && pageStart < entryEnd) {
                pages = (entryEnd - base) / PAGE_SIZE;
                if (pages > ESP_REGION_PAGES) pages = ESP_REGION_PAGES;
                // Vùng phải phủ pageStart (đề phòng sau khi nhích khỏi overlap).
                if (base + pages * PAGE_SIZE <= pageStart) pages = 0;
            } else {
                pages = 0;
            }
            // Vượt biên object (vmcreateshmemwithobjpages fail) -> giảm nửa dần.
            while (pages >= 1) {
                sh = vmmapremoterange(vmMap, base, pages);
                if (sh.used && sh.localAddress) break;
                if (pages == 1) break;
                pages /= 2;
            }
        }
    }
    if (!sh.used || !sh.localAddress) {
        if (allowLarge) s_chunkFails++;
        base = pageStart;
        pages = 1;
        sh = vmmapremotepage(vmMap, pageStart);
        if (!sh.used || !sh.localAddress) return NO;
    } else {
        s_chunkMaps++;
        s_chunkPages += pages;
    }

    ESPRegionInsert(base, sh.localAddress, sh.port, pages);
    s_liveBytes += (uint64_t)pages * PAGE_SIZE;
    *outLocal = sh.localAddress + (pageStart - base);
    return YES;
}

// KHÔNG lock — caller đã giữ s_espReadMutex.
static void ESPRegionFlushLocked(void) {
    for (int i = 0; i < s_regionCount; i++) {
        ESPRegion *r = &s_regions[i];
        if (r->localAddress) {
            mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)r->localAddress,
                               (mach_vm_size_t)ESPRegionSpan(r));
        }
        if (r->port) mach_port_deallocate(mach_task_self_, (mach_port_t)r->port);
        r->base = 0; r->localAddress = 0; r->port = 0; r->pages = 0;
    }
    s_regionCount = 0;
    s_liveBytes = 0;
}

void ESPMemoryFlushPageCache(void) {
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    ESPRegionFlushLocked();
}

BOOL ESPMemoryFlushPageCacheIfIdle(void) {
    // Trong transaction đọc: hoãn xả tới EndRead thay vì xả giữa lượt quét.
    if (ESPProviderDepth() > 0) { ESPProviderDeferFlush(); return NO; }
    (void)ESPProviderTakeFlushRequest(); // xả luôn phần đã hoãn (nếu có)
    std::unique_lock<std::mutex> readLock(s_espReadMutex, std::try_to_lock);
    if (!readLock.owns_lock()) return NO; // scan nền đang map vùng — để lần sau
    ESPRegionFlushLocked();
    return YES;
}

// ĐƯỜNG ĐỌC CHÍNH khi không có task port: mọi page đi qua region map. Lần đầu
// chạm vùng nào thì map 1 lần cả vùng (bulk) rồi giữ; các lần sau memcpy.
// KHÔNG lock — caller giữ s_espReadMutex.
static BOOL ESPReadCachedLocked(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    uint64_t off = 0;
    uint8_t *out = (uint8_t *)buf;
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        uint64_t pageOff = addr - pageStart;
        uint64_t local = 0;
        if (!ESPRegionGetLocked(vmMap, pageStart, &local)) return NO;
        uint64_t chunk = len - off;
        if (chunk > PAGE_SIZE - pageOff) chunk = PAGE_SIZE - pageOff;
        memcpy(out + off, (void *)(uintptr_t)(local + pageOff), (size_t)chunk);
        // Mapping là LIVE (share vm_object game) nên giữ trong vùng không làm
        // dữ liệu cũ — game ghi gì mình đọc thấy ngay.
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
    uint64_t off = 0;
    uint64_t pageOff = 0;
    uint8_t *out = (uint8_t *)buf;
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        pageOff = addr - pageStart;
        // CHỈ tìm trong vùng đã map — không map vùng mới: đường peek không được
        // phép làm phình số mapping (real match có thể 300+ actor).
        ESPRegion *r = ESPRegionFind(pageStart, NULL);
        if (!r) return NO;
        s_cacheHit++;
        uint64_t chunk = len - off;
        if (chunk > PAGE_SIZE - pageOff) chunk = PAGE_SIZE - pageOff;
        memcpy(out + off, (void *)(uintptr_t)(r->localAddress + pageOff), (size_t)chunk);
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
    BOOL okr = ESPReadCachedLocked(vmMap, remoteAddr, buf, len);
    ESPProviderNoteKernelRead(okr);
    return okr;
}

// 1 page là 4K hoặc 16K tuỳ build — chặn trên cho buffer trên stack.
#define ESP_MAX_PAGE 0x4000ULL
BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len) {
    if (!vmMap || !remoteAddr || !buf || !len) return NO;
    if (len > 0x40000) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr)) return NO;
    if (!ESPRemoteAddrUsable(remoteAddr + len - 1)) return NO;
    // Đường NHANH: 1 lần mach_vm_read_overwrite thay vì map.
    if (len <= 0x10000 && ESPTaskRead(remoteAddr, buf, len)) { s_taskReads++; return YES; }
    s_kernelReads++;
    // Không có task port: đi region map (1 lần/vùng). Cửa sổ 0xF00 của actor
    // trước đây map/lại mỗi lượt quét (~37ms/actor) — giờ lần đầu map cả vùng,
    // các lượt sau là memcpy thuần.
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
    BOOL okr = ESPReadCachedLocked(vmMap, remoteAddr, buf, len);
    ESPProviderNoteKernelRead(okr);
    return okr;
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
