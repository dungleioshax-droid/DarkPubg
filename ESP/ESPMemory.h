//
//  ESPMemory.h
//  Đọc memory game DUY NHẤT qua task port (mach_vm_read_overwrite, syscall
//  thuần như aovcheat). Kernel Read (region map / vmmapremotepage) đã xoá sạch.
//  vmMap trong tham số chỉ còn để validate/callers cũ — đường đọc không dùng.
//  Không port -> read fail (không fallback). Chạy trong app đã dựng port.
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

// Đọc CHỈ từ vùng đã map (hoặc task port): KHÔNG map vùng mới, KHÔNG tạo port.
// Trả NO nếu page chưa nằm trong vùng nào. Dùng cho peek rẻ — ví dụ so VTable 8
// byte của actor đang có verdict cache để biết object có bị tái dùng địa chỉ không.
BOOL ESPMemoryReadCached(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len);

// Đọc dài an toàn: chia thành từng page; miss thì map CẢ VÙNG (nhiều page liên
// tiếp trong cùng vm_map_entry) 1 lần rồi giữ, không map/dealloc từng page.
BOOL ESPReadWindow(uint64_t vmMap, uint64_t remoteAddr, void *buf, uint64_t len);

// Xả toàn bộ vùng đã map (gọi khi world/game base đổi — mapping cũ của world
// cũ phải nhả cùng port để không tích port/mapping vô hạn).
void ESPMemoryFlushPageCache(void);

// Như trên nhưng KHÔNG BAO GIỜ BLOCK: nếu mutex đọc đang bận (scan nền đang
// map vùng) thì bỏ qua, để lần sau. Dùng cho đường refresh — xả ở đó mà chờ
// mutex thì chính tick vẽ bị treo (log thực tế: max=1425ms).
// Trả YES nếu đã xả.
BOOL ESPMemoryFlushPageCacheIfIdle(void);

// Đếm region hit/miss tích luỹ (chẩn đoán perf refresh).
void ESPMemoryCacheStats(uint64_t *hit, uint64_t *miss);

// Số vùng đang giữ mapping (dùng cho scan có ngân sách — vd dò GNames).
uint64_t ESPMemoryRegionCount(void);

// Đếm số lần đọc đi đường NHANH (task port + mach_vm_read_overwrite) so với
// đường kernel (vmmapremotepage). Log box perf in ra 2 số này để biết bản
// đang chạy có thật sự dùng được task port hay rớt về exploit read.
void ESPMemoryReadPathStats(uint64_t *taskReads, uint64_t *kernelReads);

// Đếm lần map VÙNG (map nhiều page liền nhau trong 1 lần, thay cho việc map
// từng page) — đây là bản kernel tương đương "đọc bulk" của aovcheat.
// maps = số lần map vùng thành công, pages = tổng page phủ, fails = số lần thử
// vùng lớn mà phải rơi về đọc 1 page (khác vm_map_entry / vượt object).
void ESPMemoryChunkStats(uint64_t *maps, uint64_t *pages, uint64_t *fails);

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
