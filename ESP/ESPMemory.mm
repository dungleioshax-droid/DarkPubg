//
//  ESPMemory.mm
//  Implementation: map từng page của game vào process mình rồi memcpy.
//

#import "ESPMemory.h"
#import "ESPConfig.h"
#import <mach/mach.h>

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
    uint64_t off = 0;
    uint8_t *out = (uint8_t *)buf;
    while (off < len) {
        uint64_t addr = remoteAddr + off;
        uint64_t pageStart = addr & ~(uint64_t)(PAGE_SIZE - 1);
        uint64_t pageOff = addr - pageStart;
        struct ESPShmem sh = vmmapremotepage(vmMap, pageStart);
        if (!sh.used || !sh.localAddress) {
            return NO;
        }
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
#endif
