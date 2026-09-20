//
//  ESPMemory.h
//  Đọc memory của game qua kernel (vmmapremotepage từng page).
//  Không dùng task_for_pid. Chạy trong app process đã có DarkSword KRW.
//

#ifndef ESPMemory_h
#define ESPMemory_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

// Mở context đọc cho process game. Trả về vmMap (0 nếu fail).
// Gọi từ ds_bridge_queue, sau khi ds_is_ready().
uint64_t ESPMemoryOpenVMMapForProc(uint64_t proc);

// Đọc len bytes từ địa chỉ ảo của game vào buf. Trả về YES nếu đọc đủ.
BOOL ESPMemoryRead(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len);

// Helpers
static inline uint64_t ESPReadU64(uint64_t vmMap, uint64_t addr, BOOL *ok) {
    uint64_t v = 0;
    BOOL r = ESPMemoryRead(vmMap, addr, &v, sizeof(v));
    if (ok) *ok = r;
    return v;
}
static inline uint32_t ESPReadU32(uint64_t vmMap, uint64_t addr, BOOL *ok) {
    uint32_t v = 0;
    BOOL r = ESPMemoryRead(vmMap, addr, &v, sizeof(v));
    if (ok) *ok = r;
    return v;
}

NS_ASSUME_NONNULL_END

#endif /* ESPMemory_h */
