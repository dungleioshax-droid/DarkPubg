//
//  ESPTask.mm
//  Port từ cách làm của aovcheat (đã dịch ngược): task_for_pid trực tiếp +
//  verify bằng task_info/pid_for_task, đọc bulk bằng vm_read_overwrite.
//  Esign qua được vì patch CS_GET_TASK_ALLOW lên proc GAME (phía target),
//  không cần entitlement đặc biệt phía app mình.
//
//  Điểm quan trọng học từ aovcheat (cachedKyriosPtr/cachedGameFrameworkAddr):
//  mọi pointer hệ thống (proc, pid, task port) phải CACHE và chỉ verify thưa.
//  Trước đây ESPGameTaskEnsure() chạy mỗi tick 60Hz, mỗi lần đều gọi
//  procbyname() (walk cả proclist bằng kernel read) + đọc pid -> tự tạo tải
//  kernel ngay trong đường vẽ box, làm box giật dù task port đang sống.
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

// Verify port bằng pid_for_task (rẻ) mỗi 2s; giữa 2 lần verify thì đường đọc
// hoàn toàn không chạm kernel (đúng kiểu pointer cache của aovcheat).
static const CFAbsoluteTime kTaskVerifyInterval = 2.0;
// Read fail liên tiếp bao nhiêu lần thì coi port héo (game restart) và xả.
static const int kTaskReadFailLimit = 64;

static mach_port_t g_taskPort = MACH_PORT_NULL;
static pid_t g_taskPid = 0;
static uint64_t g_taskProc = 0;           // proc game đã cache (procbyname rất đắt)
static CFAbsoluteTime g_taskRetryAt = 0;  // throttle khi lấy port fail
static CFAbsoluteTime g_taskVerifyAt = 0; // hạn verify port kế tiếp
static int g_taskReadFails = 0;           // read fail liên tiếp

mach_port_t ESPGameTaskPort(void) {
    return g_taskPort;
}

void ESPGameTaskReset(void) {
    if (g_taskPort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_taskPort);
        g_taskPort = MACH_PORT_NULL;
    }
    g_taskPid = 0;
    g_taskProc = 0;
    g_taskRetryAt = 0;
    g_taskVerifyAt = 0;
    g_taskReadFails = 0;
}

// Chỉ gọi khi KHÔNG có cache (đắt: walk proclist).
static uint64_t ESPGameProcResolve(void) {
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
    // 1) Đường nhanh: port đã verify trong `kTaskVerifyInterval` giây qua.
    //    Không procbyname, không kernel read — đây là thứ khiến tick 60Hz rẻ.
    if (g_taskPort != MACH_PORT_NULL && now < g_taskVerifyAt) return YES;
    // 2) Verify port cũ (pid_for_task là syscall rẻ, không phải kernel read).
    if (g_taskPort != MACH_PORT_NULL) {
        pid_t check = 0;
        if (pid_for_task(g_taskPort, &check) == KERN_SUCCESS && check == g_taskPid) {
            g_taskVerifyAt = now + kTaskVerifyInterval;
            g_taskReadFails = 0;
            return YES;
        }
        ESPGameTaskReset();
    }
    if (now < g_taskRetryAt) return NO;
    // 3) Cần lấy port: chỉ dùng proc cache, chỉ resolve proclist nếu chưa có.
    uint64_t proc = g_taskProc;
    pid_t pid = 0;
    if (proc) pid = (pid_t)ds_kread32(proc + off_proc_p_pid);
    if (!proc || pid <= 0) {
        proc = ESPGameProcResolve();
        if (!proc) {
            if (g_taskPort) ESPGameTaskReset();
            g_taskProc = 0;
            g_taskRetryAt = now + 2.0;
            return NO;
        }
        pid = (pid_t)ds_kread32(proc + off_proc_p_pid);
        if (pid <= 0) {
            g_taskProc = 0;
            g_taskRetryAt = now + 5.0;
            return NO;
        }
        g_taskProc = proc;
    }
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
    g_taskVerifyAt = now + kTaskVerifyInterval;
    g_taskReadFails = 0;
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
    if (kr == KERN_SUCCESS && outSize == (mach_vm_size_t)len) {
        g_taskReadFails = 0;
        return YES;
    }
    // Fail liên tục trên địa chỉ hợp lệ thường là port héo (game restart /
    // process chết) -> xả cache để lần ensure sau lấy lại port mới.
    if (++g_taskReadFails >= kTaskReadFailLimit) {
        ESPLog("gametask: read fail x%d -> reset port", g_taskReadFails);
        ESPGameTaskReset();
    }
    return NO;
#endif
}
