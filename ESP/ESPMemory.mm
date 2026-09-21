//
//  ESPMemory.mm
//  Implementation: map từng page của game vào process mình rồi memcpy.
//

#import "ESPMemory.h"
#import "ESPConfig.h"
#import "ESPLog.h"
#import <mach/mach.h>
#include <mutex>

#if USE_DARKSWORD
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// ---- Đường đọc SIÊU NHANH qua TASK PORT (mach_vm_read_overwrite) ----
// Giống các cheat tham chiếu: lấy task port của game rồi đọc trực tiếp vào
// buffer của mình (bulk, micro giây, không tạo mapping/port mỗi lần đọc).
// DarkSword KRW chỉ là bàn đạp để lấy port. Nếu KHÔNG lấy được port (app cài
// sideload không có entitlement task_for_pid-allow/platform-application, hoặc
// chưa root) thì tự rớt về đường kernel page cache bên dưới — không hỏng gì.
static task_t s_gameTask = MACH_PORT_NULL;
static int s_gameTaskMode = 0; // 0 = none, 1 = task_for_pid, 2 = processor_set_tasks

// mach/processor_set API (không phải lúc nào cũng có prototype trong SDK).
// Bắt buộc extern "C": file này là Objective-C++ nên không có thì linker sẽ
// đi tìm symbol C++ (undefined).
extern "C" {
// <mach/mach_vm.h> báo "unsupported" trên SDK iOS -> tự khai báo prototype.
kern_return_t mach_vm_read_overwrite(mach_port_t target_task, mach_vm_address_t address,
                                     mach_vm_size_t size, mach_vm_address_t data,
                                     mach_vm_size_t *outsize);
kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);
kern_return_t pid_for_task(task_t task, int *pid);
kern_return_t processor_set_default(host_t host, processor_set_name_t *default_set);
kern_return_t host_processor_set_priv(host_priv_t host_priv, processor_set_name_t set_name, processor_set_t *set);
kern_return_t processor_set_tasks(processor_set_t ps, task_array_t *task_list, mach_msg_type_number_t *task_listCnt);
}

int ESPMemoryTaskPortMode(void) {
    return s_gameTaskMode;
}

void ESPMemoryCloseTaskPort(void) {
    if (s_gameTask != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self_, s_gameTask);
    }
    s_gameTask = MACH_PORT_NULL;
    s_gameTaskMode = 0;
}

// Mở task port cho pid game. Trả YES nếu lấy được (đọc qua mach_vm_read_overwrite).
BOOL ESPMemoryOpenTaskPort(pid_t pid) {
    if (pid <= 0) return NO;
    ESPMemoryCloseTaskPort();
    mach_port_t t = MACH_PORT_NULL;
    // Cách 1: task_for_pid (cần entitlement task_for_pid-allow hoặc platform).
    if (task_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS && t != MACH_PORT_NULL) {
        s_gameTask = t;
        s_gameTaskMode = 1;
        ESPLog("taskport OK mode=task_for_pid pid=%d", pid);
        return YES;
    }
    // Cách 2: duyệt processor_set_tasks (cần host_priv = root/platform).
    host_t host = mach_host_self();
    processor_set_name_t psn = MACH_PORT_NULL;
    processor_set_t ps = MACH_PORT_NULL;
    if (processor_set_default(host, &psn) == KERN_SUCCESS &&
        host_processor_set_priv(host, psn, &ps) == KERN_SUCCESS) {
        task_array_t tasks = NULL;
        mach_msg_type_number_t n = 0;
        if (processor_set_tasks(ps, &tasks, &n) == KERN_SUCCESS && tasks) {
            for (mach_msg_type_number_t i = 0; i < n; i++) {
                int tp = -1;
                if (pid_for_task(tasks[i], &tp) == KERN_SUCCESS && tp == pid) {
                    s_gameTask = tasks[i];
                    s_gameTaskMode = 2;
                } else {
                    mach_port_deallocate(mach_task_self_, tasks[i]);
                }
            }
            vm_deallocate(mach_task_self_, (vm_address_t)tasks, n * sizeof(task_t));
        }
        if (ps != MACH_PORT_NULL) mach_port_deallocate(mach_task_self_, ps);
        if (psn != MACH_PORT_NULL) mach_port_deallocate(mach_task_self_, psn);
    }
    if (host != MACH_PORT_NULL) mach_port_deallocate(mach_task_self_, host);
    if (s_gameTask != MACH_PORT_NULL) {
        ESPLog("taskport OK mode=processor_set_tasks pid=%d", pid);
        return YES;
    }
    ESPLog("taskport FAIL pid=%d (thiếu entitlement/root) -> dùng kernel", pid);
    return NO;
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
#define ESP_PAGE_CACHE_SIZE 96

struct ESPPageCacheEntry {
    uint64_t pageStart;    // địa chỉ page đã map (0 = slot trống)
    uint64_t localAddress; // mapping live của đúng page đó trong process mình
    uint64_t port;         // memory-entry port phải giữ cùng localAddress
    uint64_t lastUse;      // cho LRU
};
static ESPPageCacheEntry s_pageCache[ESP_PAGE_CACHE_SIZE];
static uint64_t s_pageCacheClock = 1; // tăng dần, trị lastUse

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
        *outLocal = e->localAddress;
        return YES;
    }
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

void ESPMemoryFlushPageCache(void) {
    std::lock_guard<std::mutex> readLock(s_espReadMutex);
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
    // Đường TASK PORT: đọc thẳng vào buffer, không lock, không mapping.
    if (s_gameTask != MACH_PORT_NULL) {
        mach_vm_size_t outSize = 0;
        kern_return_t kr = mach_vm_read_overwrite(s_gameTask,
                                                  (mach_vm_address_t)remoteAddr,
                                                  (mach_vm_size_t)len,
                                                  (mach_vm_address_t)(uintptr_t)buf,
                                                  &outSize);
        if (kr == KERN_SUCCESS && outSize == len) return YES;
        // fail (trang chưa resident / race) -> rớt xuống đường kernel.
    }
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
    // TASK PORT: 1 lần copyout cho cả cửa sổ (nhanh hơn nhiều so với map page).
    if (s_gameTask != MACH_PORT_NULL) {
        mach_vm_size_t outSize = 0;
        kern_return_t kr = mach_vm_read_overwrite(s_gameTask,
                                                  (mach_vm_address_t)remoteAddr,
                                                  (mach_vm_size_t)len,
                                                  (mach_vm_address_t)(uintptr_t)buf,
                                                  &outSize);
        if (kr == KERN_SUCCESS && outSize == len) return YES;
    }
    if ((uint64_t)PAGE_SIZE > ESP_MAX_PAGE) return NO;
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
BOOL ESPMemoryOpenTaskPort(pid_t pid) { (void)pid; return NO; }
int ESPMemoryTaskPortMode(void) { return 0; }
void ESPMemoryCloseTaskPort(void) {}
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
#endif
