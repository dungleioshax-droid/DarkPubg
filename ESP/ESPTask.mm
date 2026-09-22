//
//  ESPTask.mm
//  Port từ cách làm của aovcheat (đã dịch ngược): task_for_pid trực tiếp +
//  verify bằng task_info/pid_for_task, đọc bulk bằng vm_read_overwrite.
//  Esign qua được vì patch CS_GET_TASK_ALLOW lên proc GAME (phía target),
//  không cần entitlement đặc biệt phía app mình.
//

#import "ESPTask.h"
#import "ESPConfig.h"
#import "ESPLog.h"

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// CS_GET_TASK_ALLOW: cho phép process khác lấy task port (XNU csflags bit 2).
static const uint32_t kCSGetTaskAllow = 0x4;

static mach_port_t g_taskPort = MACH_PORT_NULL;
static pid_t g_taskPid = 0;
static CFAbsoluteTime g_taskRetryAt = 0;

mach_port_t ESPGameTaskPort(void) {
    return g_taskPort;
}

void ESPGameTaskReset(void) {
    if (g_taskPort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_taskPort);
        g_taskPort = MACH_PORT_NULL;
    }
    g_taskPid = 0;
    g_taskRetryAt = 0;
}

static uint64_t ESPGameProc(void) {
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) proc = procbyname("ShadowTrackerE");
    return proc;
}

BOOL ESPGameTaskEnsure(void) {
#if !USE_DARKSWORD
    return NO;
#else
    if (!ds_is_ready()) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    uint64_t proc = ESPGameProc();
    if (!proc) {
        if (g_taskPort) ESPGameTaskReset();
        return NO;
    }
    pid_t pid = (pid_t)ds_kread32(proc + off_proc_p_pid);
    if (pid <= 0) return NO;
    // Port cũ còn sống + đúng pid thì dùng tiếp (verify rẻ bằng pid_for_task).
    if (g_taskPort != MACH_PORT_NULL && g_taskPid == pid) {
        pid_t check = 0;
        if (pid_for_task(g_taskPort, &check) == KERN_SUCCESS && check == pid) {
            return YES;
        }
        ESPGameTaskReset();
    }
    // Throttle: task_for_pid fail thì đừng spam mỗi tick.
    if (now < g_taskRetryAt) return NO;
    if (!off_proc_p_csflags && !resolve_proc_p_csflags()) {
        ESPLog("gametask: no p_csflags offset (keep exploit reads)");
        g_taskRetryAt = now + 30.0;
        return NO;
    }
    // Patch CS_GET_TASK_ALLOW lên proc game (giữ nguyên các bit khác).
    uint32_t cs = ds_kread32(proc + off_proc_p_csflags);
    if (!(cs & kCSGetTaskAllow)) {
        ds_kwrite32(proc + off_proc_p_csflags, cs | kCSGetTaskAllow);
        uint32_t cs2 = ds_kread32(proc + off_proc_p_csflags);
        ESPLog("gametask: csflags 0x%x -> 0x%x", cs, cs2);
        if (!(cs2 & kCSGetTaskAllow)) {
            g_taskRetryAt = now + 30.0;
            return NO;
        }
    }
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        ESPLog("gametask: task_for_pid pid=%d kr=0x%x (%s)", pid, kr, mach_error_string(kr));
        g_taskRetryAt = now + 10.0;
        return NO;
    }
    pid_t check = 0;
    if (pid_for_task(task, &check) != KERN_SUCCESS || check != pid) {
        ESPLog("gametask: pid verify fail");
        mach_port_deallocate(mach_task_self(), task);
        g_taskRetryAt = now + 10.0;
        return NO;
    }
    if (g_taskPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), g_taskPort);
    g_taskPort = task;
    g_taskPid = pid;
    ESPLog("gametask: OK pid=%d task=0x%x", pid, task);
    return YES;
#endif
}

BOOL ESPTaskRead(uint64_t remoteAddr, void *buf, uint64_t len) {
#if !USE_DARKSWORD
    (void)remoteAddr; (void)buf; (void)len;
    return NO;
#else
    mach_port_t task = g_taskPort;
    if (task == MACH_PORT_NULL || !remoteAddr || !buf || !len) return NO;
    if (len > 0x10000) return NO;
    if (remoteAddr < 0x100000000ULL || remoteAddr > 0x300000000000ULL - len) return NO;
    mach_vm_size_t outSize = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, (mach_vm_address_t)remoteAddr,
                                              (mach_vm_size_t)len, (mach_vm_address_t)buf, &outSize);
    return kr == KERN_SUCCESS && outSize == (mach_vm_size_t)len;
#endif
}
