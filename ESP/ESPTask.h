//
//  ESPTask.h
//  Task port của game: thử task_for_pid trực tiếp, nếu không được thì DỰNG
//  port giả từ kernel (ghi ip_kobject của port mình thành task game) —
//  không cần patch CS_GET_TASK_ALLOW nên chạy cả khi proc_ro read-only
//  (iOS 16+). Đọc bulk bằng mach_vm_read_overwrite: syscall thuần, không còn
//  exploit dance từng page. Không cần entitlement đặc biệt trên app (Esign
//  vẫn qua) vì mọi thứ làm ở phía target/kernel đã có KRW.
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

// XPC helper (process tách, kiểu DSGames ExternalESPReader): resolve proc +
// fabricate port thô, không chạm cache globals. Helper gọi hai hàm này.
uint64_t ESPTaskResolveGameProc(void);
mach_port_t ESPTaskFabricatePortForProc(uint64_t proc, pid_t pid);

// Client: xin port game từ helper qua XPC. Trả port (caller sở hữu) hoặc
// MACH_PORT_NULL nếu helper chưa sẵn/không có. Tự fallback về đường
// in-process — gọi hàm này trước, fail thì fabrication tại chỗ như cũ.
mach_port_t ESPTaskCopyPortFromHelper(pid_t pid);

// Đọc bulk qua task port (mach_vm_read_overwrite). NO nếu chưa có port/fail.
BOOL ESPTaskRead(uint64_t remoteAddr, void *buf, uint64_t len);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* ESPTask_h */
