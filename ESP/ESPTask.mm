//
//  ESPTask.mm
//  Port từ cách làm của aovcheat (đã dịch ngược): task_for_pid trực tiếp +
//  verify bằng task_info/pid_for_task, đọc bulk bằng vm_read_overwrite.
//  Esign qua được vì patch CS_GET_TASK_ALLOW lên proc GAME (phía target),
//  không cần entitlement đặc biệt phía app mình.
//  Đọc bulk bằng vm_read_overwrite (SDK iOS không khai báo mach_vm_read_overwrite).
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
#include <mutex>
#include <unistd.h>
#include <dlfcn.h>

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// CS_GET_TASK_ALLOW: cho phép process khác lấy task port (XNU csflags bit 2).
static const uint32_t kCSGetTaskAllow = 0x4;
// Bộ bit "đủ để debuggable" theo mọi bản kpatch csflags: bật GET_TASK_ALLOW +
// DEBUGGED, bỏ HARD/KILL/RESTRICT/REQUIRE_LV (các bit chặn debug).
static const uint32_t kCSDebugged = 0x10000000;
static const uint32_t kCSHard = 0x100;
static const uint32_t kCSKill = 0x200;
static const uint32_t kCSRestrict = 0x800;
static const uint32_t kCSRequireLV = 0x2000;

// csops(CS_OPS_STATUS) trả ĐÚNG giá trị p_csflags của process -> dùng để xác
// nhận offset tìm được bằng đọc-only (không đoán, không ghi kernel mò).
// Không khai báo trực tiếp: header SDK thiếu extern "C" nên build ObjC++ sẽ đi
// tìm symbol đã C++-mangle -> link fail ("found '_csops' in
// libsystem_kernel.dylib"). Lấy qua dlsym cho khỏi phụ thuộc khai báo.
#define ESP_CS_OPS_STATUS 0 /* return status */
typedef int (*ESPCsopsFn)(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static ESPCsopsFn ESPTaskCSOps(void) {
    static ESPCsopsFn fn = NULL;
    static bool tried = false;
    if (!tried) {
        tried = true;
        fn = (ESPCsopsFn)dlsym(RTLD_DEFAULT, "csops");
    }
    return fn;
}

// ---- Định vị p_csflags ----
// iOS 16+ KHÔNG còn p_csflags trong `proc`: nó nằm trong `proc_ro`
// (bsd/sys/proc_ro.h). Đường kernelcache không đi được vì libxpf trong app chỉ
// có 7 item kernelStruct.* (không có proc.p_csflags) -> resolve luôn trả 0 ->
// task port chưa bao giờ bật, mọi read vẫn map page từng cái.
//
// Layout proc_ro (đúng cho cả iOS 16-18 lẫn 26):
//   pr_proc 0x00, pr_task 0x08, p_uniqueid 0x10, p_idversion 0x18,
//   [iOS 26: p_orig_ppid 0x1c, p_orig_ppidversion 0x20]
//   p_csflags = p_ucred - 4, p_ucred, syscall_filter_mask, p_platform_data
// => p_csflags = off_proc_ro_p_ucred - 4 (offsets.m đã có p_ucred cho từng bản).
//
// Xác nhận bằng csops(getpid()): nếu u32 tại offset ứng viên trong proc_ro của
// CHÍNH MÌNH bằng đúng csflags của mình thì chắc chắn đúng chỗ (thuần đọc).
static uint64_t g_csAddr = 0;   // địa chỉ kernel p_csflags của proc game
static uint64_t g_csProc = 0;   // proc tương ứng (proc đổi thì tìm lại)
static uint32_t g_csOff = 0;    // offset trong proc (cũ) hoặc proc_ro (mới)
static BOOL g_csInRO = NO;      // YES = offset nằm trong proc_ro
static BOOL g_csLoaded = NO;
// YES = offset đã được xác nhận chắc chắn (bảng offsets hoặc csops so khớp).
// NO = mới là suy từ layout -> nếu task_for_pid vẫn fail thì xoá để tìm lại.
static BOOL g_csVerified = NO;

static NSString *const kCSExtraKeyOff = @"esp.cs_off";
static NSString *const kCSExtraKeyRO = @"esp.cs_in_ro";

static inline BOOL ESPTaskIsKernelPtr(uint64_t v) {
    return (v >> 48) == 0xffffULL; // con trỏ kernel heap/text
}

static BOOL ESPTaskOurCSFlags(uint32_t *out) {
    ESPCsopsFn csops = ESPTaskCSOps();
    if (!csops) return NO;
    uint32_t v = 0;
    if (csops(getpid(), ESP_CS_OPS_STATUS, &v, sizeof(v)) != 0) return NO;
    if (!v) return NO; // không có bit nào: không dùng làm mốc xác nhận
    *out = v;
    return YES;
}

static void ESPTaskSaveCSLocation(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:@(g_csOff) forKey:kCSExtraKeyOff];
    [d setObject:@(g_csInRO ? 1 : 0) forKey:kCSExtraKeyRO];
    [d synchronize];
}

// Quên vị trí đã cache (patch không dính -> chỗ đó không phải csflags).
static void ESPTaskForgetCSFlags(void) {
    g_csOff = 0;
    g_csInRO = NO;
    g_csAddr = 0;
    g_csVerified = NO;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kCSExtraKeyOff];
    [d removeObjectForKey:kCSExtraKeyRO];
    [d synchronize];
}

// Trả địa chỉ kernel của p_csflags trong proc đã cho (0 = không tìm được).
static uint64_t ESPTaskCSFlagsAddr(uint64_t proc) {
    if (!proc) return 0;
    if (!g_csLoaded) {
        g_csLoaded = YES;
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        g_csOff = (uint32_t)[[d objectForKey:kCSExtraKeyOff] unsignedIntValue];
        g_csInRO = [[d objectForKey:kCSExtraKeyRO] boolValue];
    }
    if (g_csAddr && g_csProc == proc) return g_csAddr;
    // (1) Layout cũ (< iOS 16): p_csflags nằm trong proc.
    if (!g_csInRO) {
        uint32_t off = g_csOff ? g_csOff : off_proc_p_csflags;
        if (!off) off = resolve_proc_p_csflags();
        if (off) {
            if (!g_csOff) { g_csOff = off; g_csInRO = NO; ESPTaskSaveCSLocation(); }
            g_csVerified = YES; // từ kernelcache/bảng offsets: đáng tin
            g_csProc = proc;
            g_csAddr = proc + off;
            return g_csAddr;
        }
    }
    // (2) iOS 16+: csflags trong proc_ro.
    if (!off_proc_p_proc_ro) return 0;
    uint64_t ro = ds_kread64(proc + off_proc_p_proc_ro);
    if (!ESPTaskIsKernelPtr(ro)) return 0;
    if (g_csInRO && g_csOff) {
        g_csProc = proc;
        g_csAddr = ro + g_csOff;
        return g_csAddr;
    }
    // Ứng viên, ưu tiên công thức layout (ngay trước p_ucred).
    uint32_t cands[5];
    int n = 0;
    if (off_proc_ro_p_ucred >= 4) cands[n++] = off_proc_ro_p_ucred - 4;
    cands[n++] = 0x1C;
    cands[n++] = 0x24;
    cands[n++] = 0x20;
    cands[n++] = 0x18;
    // Xác nhận đọc-only bằng csflags của chính mình (đọc từ đúng proc_ro của
    // mình) — không cần ghi kernel để dò.
    uint32_t self = 0;
    uint64_t ourProc = ds_get_our_proc();
    if (ourProc) {
        uint64_t ourRO = ds_kread64(ourProc + off_proc_p_proc_ro);
        if (ESPTaskIsKernelPtr(ourRO) && ESPTaskOurCSFlags(&self)) {
            for (int i = 0; i < n; i++) {
                if (ds_kread32(ourRO + cands[i]) == self) {
                    g_csOff = cands[i];
                    g_csInRO = YES;
                    g_csVerified = YES;
                    ESPTaskSaveCSLocation();
                    ESPLog("gametask: csflags @ proc_ro+0x%x (csops 0x%x xac nhan)",
                           g_csOff, self);
                    g_csProc = proc;
                    g_csAddr = ro + g_csOff;
                    return g_csAddr;
                }
            }
            ESPLog("gametask: csops=0x%x but no matching offset in proc_ro", self);
        }
    }
    // (3) csops không dùng được: tin công thức layout, task_for_pid là bước
    // xác nhận cuối (patch không dính thì xoá cache để lần sau tìm lại).
    if (off_proc_ro_p_ucred >= 4) {
        g_csOff = off_proc_ro_p_ucred - 4;
        g_csInRO = YES;
        ESPTaskSaveCSLocation();
        ESPLog("gametask: csflags @ proc_ro+0x%x (layout, csops NA)", g_csOff);
        g_csProc = proc;
        g_csAddr = ro + g_csOff;
        return g_csAddr;
    }
    return 0;
}

// Verify port bằng pid_for_task (rẻ) mỗi 2s; giữa 2 lần verify thì đường đọc
// hoàn toàn không chạm kernel (đúng kiểu pointer cache của aovcheat).
static const CFAbsoluteTime kTaskVerifyInterval = 2.0;
// Read fail liên tiếp bao nhiêu lần thì coi port héo (game restart) và xả.
static const int kTaskReadFailLimit = 64;
// Nhịp kiểm tra proc game còn sống (chống UAF fake port, xem dưới).
static const CFAbsoluteTime kTaskProcAliveInterval = 0.5;

// ---- FAKE TASK PORT (cơ chế khác thay Kernel Read) ----
// task_for_pid chết trên iOS 16+ (proc_ro read-only, không patch được
// csflags). Thay vì exploit dance từng page, dựng 1 task port GIẢ:
// cấp port của mình rồi ghi đè ip_kobject = task game + ip_bits =
// ACTIVE|TASK. Sau đó mach_vm_read_overwrite là syscall thuần (~µs).
// Khác task port thật ở 1 điểm: port giả KHÔNG giữ ref lên task game —
// game chết mà còn gọi vào port là UAF -> panic. Chống bằng 2 lớp:
//  (1) verify/đọc đều check proc pid trước (đọc kernel thuần, không panic);
//  (2) reset LUÔN khôi phục ip_kobject/bits gốc trước khi huỷ port.
static const uint32_t kIPCPortIPBitsOff = 0; // io_bits là field đầu ipc_object
static const uint32_t kIOBitsActiveTask = 0x80000002; // IO_BITS_ACTIVE | IKOT_TASK
static mach_port_t s_fakePort = MACH_PORT_NULL;
static uint64_t s_fakeKobj = 0;
static uint32_t s_fakeOrigBits = 0;
static uint64_t s_fakeOrigKobj = 0;
static CFAbsoluteTime s_procAliveAt = 0;
static BOOL s_procAlive = NO;
static int s_tfpFails = 0;
static BOOL s_tfpSkip = NO;

static mach_port_t g_taskPort = MACH_PORT_NULL;
static pid_t g_taskPid = 0;
static uint64_t g_taskProc = 0;           // proc game đã cache (procbyname rất đắt)
static CFAbsoluteTime g_taskRetryAt = 0;  // throttle khi lấy port fail
static CFAbsoluteTime g_taskVerifyAt = 0; // hạn verify port kế tiếp
static int g_taskReadFails = 0;           // read fail liên tiếp

// Ensure() được gọi từ 2 thread (tick vẽ 60Hz + scan nền). Serialize để hai
// đường không cùng patch csflags / cùng lấy port. Đường ĐỌC (ESPTaskRead)
// KHÔNG lock — nó chỉ gọi syscall nên rẻ và không chặn nhau.
static std::mutex s_taskEnsureMutex;

mach_port_t ESPGameTaskPort(void) {
    return g_taskPort;
}

static void ESPGameTaskResetLocked(void) {
    if (s_fakePort != MACH_PORT_NULL) {
        // Port giả: khôi phục ip_kobject/bits gốc TRƯỚC khi huỷ — nếu không
        // kernel đi theo kobject giả lúc GC port -> panic.
        if (s_fakeKobj && ESPTaskIsKernelPtr(s_fakeKobj)) {
            ds_kwrite32(s_fakeKobj + kIPCPortIPBitsOff, s_fakeOrigBits);
            if (off_ipc_port_ip_kobject) {
                ds_kwrite64(s_fakeKobj + off_ipc_port_ip_kobject, s_fakeOrigKobj);
            }
        }
        mach_port_destroy(mach_task_self(), s_fakePort);
        if (g_taskPort == s_fakePort) g_taskPort = MACH_PORT_NULL;
        s_fakePort = MACH_PORT_NULL;
        s_fakeKobj = 0;
    }
    if (g_taskPort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_taskPort);
        g_taskPort = MACH_PORT_NULL;
    }
    g_taskPid = 0;
    g_taskProc = 0;
    g_taskRetryAt = 0;
    g_taskVerifyAt = 0;
    g_taskReadFails = 0;
    s_procAliveAt = 0;
    s_procAlive = NO;
    // Proc game đổi (restart) -> địa chỉ csflags cache không còn đúng; offset
    // đã tìm được vẫn giữ (lần sau chỉ cần đọc lại proc_ro của proc mới).
    g_csAddr = 0;
    g_csProc = 0;
}

// Dựng fake task port cho proc/pid game (xem chú thích ở trên). Trả về port
// hoặc MACH_PORT_NULL. Chỉ gọi khi đang giữ s_taskEnsureMutex.
static mach_port_t ESPFabricateTaskPort(uint64_t proc, pid_t pid) {
    if (!proc || pid <= 0) return MACH_PORT_NULL;
    if (!off_ipc_port_ip_kobject || !off_task_map || !off_proc_p_proc_ro ||
        !off_proc_ro_pr_task) {
        return MACH_PORT_NULL; // thiếu offsets -> không dám ghi kernel
    }
    // Task game + cross-check 2 chiều (proc_ro->task phải khớp taskbyproc,
    // task->map phải là con trỏ kernel) — ghi nhầm task là panic ngay.
    uint64_t task = taskbyproc(proc);
    if (!ESPTaskIsKernelPtr(task)) return MACH_PORT_NULL;
    uint64_t ro = ds_kread64(proc + off_proc_p_proc_ro);
    if (!ESPTaskIsKernelPtr(ro)) return MACH_PORT_NULL;
    uint64_t prTask = ds_kread64(ro + off_proc_ro_pr_task);
    if (prTask != task) {
        ESPLog("gametask: fake port task mismatch (proc_ro task != taskbyproc)");
        return MACH_PORT_NULL;
    }
    uint64_t map = ds_kread64(task + off_task_map);
    if (!ESPTaskIsKernelPtr(map)) return MACH_PORT_NULL;
    // Cấp port của mình (receive + send).
    mach_port_t name = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &name) != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }
    if (mach_port_insert_right(mach_task_self(), name, name, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_destroy(mach_task_self(), name);
        return MACH_PORT_NULL;
    }
    uint64_t kobj = task_get_ipc_port_kobject(task_self(), name);
    if (!ESPTaskIsKernelPtr(kobj)) {
        mach_port_destroy(mach_task_self(), name);
        return MACH_PORT_NULL;
    }
    // Chưa ai khác biết port này nên 2 ghi này an toàn tuyệt đối.
    uint32_t origBits = ds_kread32(kobj + kIPCPortIPBitsOff);
    uint64_t origKobj = ds_kread64(kobj + off_ipc_port_ip_kobject);
    ds_kwrite32(kobj + kIPCPortIPBitsOff, kIOBitsActiveTask);
    ds_kwrite64(kobj + off_ipc_port_ip_kobject, task);
    // Xác nhận cổng thật sự trỏ đúng task (syscall, không panic).
    pid_t check = 0;
    if (pid_for_task(name, &check) != KERN_SUCCESS || check != pid) {
        ds_kwrite32(kobj + kIPCPortIPBitsOff, origBits);
        ds_kwrite64(kobj + off_ipc_port_ip_kobject, origKobj);
        mach_port_destroy(mach_task_self(), name);
        ESPLog("gametask: fake port verify fail pid=%d", pid);
        return MACH_PORT_NULL;
    }
    s_fakePort = name;
    s_fakeKobj = kobj;
    s_fakeOrigBits = origBits;
    s_fakeOrigKobj = origKobj;
    ESPLog("gametask: fake task port OK pid=%d port=0x%x", pid, name);
    return name;
}

void ESPGameTaskReset(void) {
    std::lock_guard<std::mutex> resetLock(s_taskEnsureMutex);
    ESPGameTaskResetLocked();
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
    std::lock_guard<std::mutex> ensureLock(s_taskEnsureMutex);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // 1) Đường nhanh: port đã verify trong `kTaskVerifyInterval` giây qua.
    //    Không procbyname, không kernel read — đây là thứ khiến tick 60Hz rẻ.
    if (g_taskPort != MACH_PORT_NULL && now < g_taskVerifyAt) return YES;
    // 2) Verify port cũ. Port THẬT: pid_for_task (syscall rẻ). Port GIẢ:
    // KHÔNG được pid_for_task khi nghi game chết (task không giữ ref, UAF) —
    // check proc pid bằng đọc kernel thuần trước, khác là xả ngay.
    if (g_taskPort != MACH_PORT_NULL) {
        if (s_fakePort == g_taskPort) {
            pid_t p = (g_taskProc && off_proc_p_pid)
                ? (pid_t)ds_kread32(g_taskProc + off_proc_p_pid) : 0;
            if (p == g_taskPid && p > 0) {
                g_taskVerifyAt = now + kTaskVerifyInterval;
                g_taskReadFails = 0;
                return YES;
            }
            ESPGameTaskResetLocked();
        } else {
            pid_t check = 0;
            if (pid_for_task(g_taskPort, &check) == KERN_SUCCESS && check == g_taskPid) {
                g_taskVerifyAt = now + kTaskVerifyInterval;
                g_taskReadFails = 0;
                return YES;
            }
            ESPGameTaskResetLocked();
        }
    }
    if (now < g_taskRetryAt) return NO;
    // 3) Cần lấy port: chỉ dùng proc cache, chỉ resolve proclist nếu chưa có.
    uint64_t proc = g_taskProc;
    pid_t pid = 0;
    if (proc) pid = (pid_t)ds_kread32(proc + off_proc_p_pid);
    if (!proc || pid <= 0) {
        proc = ESPGameProcResolve();
        if (!proc) {
            if (g_taskPort) ESPGameTaskResetLocked();
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
        // Proc mới (game restart): cho task_for_pid thử lại từ đầu — rẻ
        // (1 syscall) và chắc chắn nếu install có entitlement.
        s_tfpFails = 0;
        s_tfpSkip = NO;
    }
    // 4) Thử lấy port TRƯỚC khi patch: nếu app có entitlement (TrollStore /
    //    ldid) thì không cần ghi kernel lần nào. Esign/không entitlement:
    //    fail là vĩnh viễn (không đổi theo install) — 3 lần liên tiếp thì
    //    bỏ qua hẳn, đỡ 1 syscall fail mỗi retry. Reset khi gặp proc mới.
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = KERN_FAILURE;
    if (!s_tfpSkip) {
        kr = task_for_pid(mach_task_self(), pid, &task);
        if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
            task = MACH_PORT_NULL;
            if (++s_tfpFails >= 3 && !s_tfpSkip) {
                s_tfpSkip = YES;
                ESPLog("gametask: task_for_pid unavailable (Esign?), fabricated port only");
            }
        } else {
            s_tfpFails = 0;
        }
    }
    if ((kr != KERN_SUCCESS || task == MACH_PORT_NULL) && ds_is_ready()) {
        // 4b) Dựng fake task port qua kernel — không cần patch csflags nên
        // chạy cả khi proc_ro read-only (iOS 16+). Thử TRƯỚC khi patch vì
        // nhẹ và chắc chắn hơn (patch vùng read-only vừa vô ích vừa rủi ro).
        // Throttle theo g_taskRetryAt như mọi đường fail khác.
        task = ESPFabricateTaskPort(proc, pid);
        kr = (task == MACH_PORT_NULL) ? KERN_FAILURE : KERN_SUCCESS;
    }
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        // 5) Chưa được -> patch csflags của proc GAME rồi thử lại. Đây là chỗ
        //    trước đây luôn fail ("no p_csflags offset") nên box phải map page.
        uint64_t csAddr = ESPTaskCSFlagsAddr(proc);
        if (!csAddr) {
            ESPLog("gametask: no p_csflags offset (keep exploit reads)");
            g_taskRetryAt = now + 30.0;
            return NO;
        }
        uint32_t cs = ds_kread32(csAddr);
        if (!(cs & kCSGetTaskAllow)) {
            if (g_csInRO) {
                // proc_ro là READ-ONLY (KTRR): ghi không dính + có thể gây
                // panic/respring -> TUYỆT ĐỐI không ghi. Chỉ thử task_for_pid
                // trực tiếp bên dưới (có entitlement thì vẫn qua).
                ESPLog("gametask: csflags in proc_ro (read-only), skip patch");
            } else {
                uint32_t patched = (cs | kCSGetTaskAllow | kCSDebugged) &
                                   ~(kCSHard | kCSKill | kCSRestrict | kCSRequireLV);
                ds_kwrite32(csAddr, patched);
                uint32_t cs2 = ds_kread32(csAddr);
                ESPLog("gametask: csflags 0x%x -> 0x%x @0x%llx", cs, cs2,
                       (unsigned long long)csAddr);
                if (!(cs2 & kCSGetTaskAllow)) {
                    // Ghi không dính (vùng bị bảo vệ / sai chỗ) -> lần sau tìm lại.
                    ESPLog("gametask: csflags write did not stick, forgetting offset");
                    ESPTaskForgetCSFlags();
                    g_taskRetryAt = now + 30.0;
                    return NO;
                }
            }
        }
        task = MACH_PORT_NULL;
        kr = task_for_pid(mach_task_self(), pid, &task);
    }
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        ESPLog("gametask: task_for_pid pid=%d kr=0x%x (%s) cs=0x%x", pid, kr,
               mach_error_string(kr), g_csOff);
        // Offset mới chỉ SUY từ layout mà vẫn không lấy được port -> lần sau
        // tìm lại bằng csops thay vì ghi lại đúng chỗ đó mãi.
        if (g_csOff && !g_csVerified) ESPTaskForgetCSFlags();
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
    // Port giả không giữ ref lên task game: game chết giữa 2 lần verify (2s)
    // mà vẫn đọc vào port là UAF -> panic. Chặn bằng proc pid cache 0.5s
    // (1 kernel read rẻ cho cả chùm read, chỉ khi dùng fake port).
    if (task == s_fakePort && s_fakePort != MACH_PORT_NULL) {
        CFAbsoluteTime nowR = CFAbsoluteTimeGetCurrent();
        if (nowR - s_procAliveAt >= kTaskProcAliveInterval) {
            s_procAliveAt = nowR;
            pid_t p = (g_taskProc && off_proc_p_pid)
                ? (pid_t)ds_kread32(g_taskProc + off_proc_p_pid) : 0;
            s_procAlive = (p == g_taskPid && p > 0);
            if (!s_procAlive) ESPGameTaskReset();
        }
        if (!s_procAlive) return NO;
    }
    // vm_read_overwrite (không phải mach_vm_read_overwrite — SDK iOS không khai
    // báo tiền tố mach_vm_*; trên arm64 vm_size_t đã là 64-bit nên tương đương).
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(task, (vm_address_t)remoteAddr,
                                         (vm_size_t)len, (vm_address_t)buf, &outSize);
    if (kr == KERN_SUCCESS && outSize == (vm_size_t)len) {
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
