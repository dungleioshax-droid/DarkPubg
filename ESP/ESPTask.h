//
//  ESPTask.h
//  Dual-path đọc memory game (kernrw35):
//    - Route A: task_for_pid (TrollStore + entitlement task_for_pid-allow).
//    - Route B: host_processor_set_priv + processor_set_tasks (jb/root).
//  Được port -> mọi read đi mach_vm_read_overwrite (1 syscall, không mapping,
//  không refcount race, không dead-mapping, không lock convoy khi map).
//  Trượt cả 2 (Esign mobile thường) -> rớt về kernel region-map (ESPMemory).
//

#ifndef ESPTask_h
#define ESPTask_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Port task game đang cache (MACH_PORT_NULL nếu chưa có).
mach_port_t ESPGameTaskPort(void);

// Đảm bảo có task port: tìm proc game -> patch csflags nếu thiếu
// CS_GET_TASK_ALLOW -> task_for_pid -> verify pid_for_task. Throttle trong
// (fail thì thôi, gọi lại sau). Gọi định kỳ từ worker, KHÔNG gọi từ scan sâu.
BOOL ESPGameTaskEnsure(void);

// Xả port cache (game restart / world đổi / read fail liên tục).
void ESPGameTaskReset(void);

// Đọc bulk qua task port (mach_vm_read_overwrite). NO nếu chưa có port/fail.
BOOL ESPTaskRead(uint64_t remoteAddr, void *buf, uint64_t len);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* ESPTask_h */
