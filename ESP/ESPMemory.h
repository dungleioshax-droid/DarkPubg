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

// ---- Task port (đường đọc siêu nhanh: mach_vm_read_overwrite) ----
// Thử lấy task port của game (task_for_pid, rồi processor_set_tasks). Lấy
// được thì mọi lần ESPMemoryRead/ESPReadWindow đọc bulk trực tiếp (µs, không
// lock, không mapping). Không lấy được (sideload/không root) thì tự rớt về
// đường kernel page cache — không hỏng gì. An toàn gọi lại nhiều lần.
BOOL ESPMemoryOpenTaskPort(pid_t pid);
// 0 = chưa có port, 1 = task_for_pid, 2 = processor_set_tasks.
int ESPMemoryTaskPortMode(void);
void ESPMemoryCloseTaskPort(void);

// Đọc len bytes từ địa chỉ ảo của game vào buf. Trả về YES nếu đọc đủ.
BOOL ESPMemoryRead(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len);

// Đọc dài an toàn: chia thành từng page và mỗi lần chỉ map ĐÚNG 1 page tại địa
// chỉ page-align (vmmapremotepage chỉ map được 1 page; đọc vượt page trong 1
// lần gọi sẽ fail ở chunk thứ 2 — log thực tế: đọc 0xF00 byte luôn fail nên
// phải rơi xuống ~11 lần đọc lẻ/actor, pass quét 20s).
BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len);

// Xả toàn bộ page cache (gọi khi world/game base đổi — mapping cũ của world
// cũ phải nhả cùng port để không tích port/mapping vô hạn).
void ESPMemoryFlushPageCache(void);

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
