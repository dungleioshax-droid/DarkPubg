//
//  ESPTask.mm
//  Dual-path đọc memory game (kernrw35):
//    - Route A: task_for_pid (cần entitlement task_for_pid-allow — TrollStore).
//    - Route B: host_processor_set_priv + processor_set_tasks + pid_for_task
//      (kiểu Archive.zip pid.mm — cần context root/jb).
//  Được port -> mọi read đi mach_vm_read_overwrite (1 syscall, không mapping,
//  không refcount race, không dead-mapping, không lock convoy khi map).
//  Trượt cả 2 (Esign mobile thường) -> rớt về kernel region-map như cũ.
//  Thử 1 lần lúc enable + re-validate rẻ mỗi Ensure (pid_for_pid); attempt
//  full throttle 5s. Port chết (game restart) -> read fail -> Reset, Ensure
//  sau lấy lại. Không bao giờ block đường đọc: fail là về region ngay.
//

#import "ESPTask.h"
#import "ESPLog.h"
#include <libproc.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>

// mach_vm.h bị iOS SDK chặn — khai tay (pattern đã dùng cho mach_vm_deallocate).
extern "C" kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
                                               mach_vm_address_t address,
                                               mach_vm_size_t size,
                                               mach_vm_address_t data,
                                               mach_vm_size_t *outsize);
// Route B (host-priv): khai tay theo Archive.zip pid.h.
extern "C" kern_return_t processor_set_default(host_t host,
                                              processor_set_name_t *pset);
extern "C" kern_return_t host_processor_set_priv(host_t host_priv,
                                                processor_set_name_t set_name,
                                                processor_set_t *set);
extern "C" kern_return_t processor_set_tasks(processor_set_t processor_set,
                                             task_array_t *task_list,
                                             mach_msg_type_number_t *task_listCnt);

static pthread_mutex_t s_taskMutex = PTHREAD_MUTEX_INITIALIZER;
static task_t s_gameTask = MACH_PORT_NULL;
static pid_t s_gamePid = 0;
static CFAbsoluteTime s_lastTryAt = 0;
static BOOL s_failLogged = NO;
static pid_t s_okLoggedPid = 0;
static int s_okLoggedRoute = 0;
// Esign mobile thường: cả 2 route đều trượt vĩnh viễn -> thử 5 lần rồi thôi
// cả session (khỏi proc_listallpids mỗi 5s vô ích). Reset khi Reset() (world
// đổi/disable) để máy TrollStore resign entitlement vẫn có cơ hội.
static int s_giveUpFails = 0;

static pid_t ESPTaskFindGamePid(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > 100000) return 0;
    pid_t *pids = (pid_t *)malloc((size_t)count * sizeof(pid_t));
    if (!pids) return 0;
    int got = proc_listallpids(pids, count * (int)sizeof(pid_t));
    pid_t found = 0;
    if (got > 0) {
        if (got > count) got = count;
        char name[1024];
        for (int i = 0; i < got; i++) {
            if (pids[i] <= 0) continue;
            memset(name, 0, sizeof(name));
            if (proc_name(pids[i], name, sizeof(name) - 1) <= 0) continue;
            if (strstr(name, "ShadowTrackerExtra") != NULL) { found = pids[i]; break; }
        }
    }
    free(pids);
    return found;
}

// Route A: task_for_pid trực tiếp (TrollStore + entitlement).
static task_t ESPTaskTryRouteA(pid_t pid) {
    task_t t = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &t) != KERN_SUCCESS || t == MACH_PORT_NULL) {
        return MACH_PORT_NULL;
    }
    int p2 = 0;
    if (pid_for_task(t, &p2) != KERN_SUCCESS || p2 != pid) {
        mach_port_deallocate(mach_task_self(), t);
        return MACH_PORT_NULL;
    }
    return t;
}

// Route B: host-priv enumeration (Archive.zip — jb/root context).
static task_t ESPTaskTryRouteB(pid_t pid) {
    host_t host = mach_host_self();
    processor_set_name_t pset = MACH_PORT_NULL;
    if (processor_set_default(host, &pset) != KERN_SUCCESS) return MACH_PORT_NULL;
    processor_set_t psetCtl = MACH_PORT_NULL;
    task_t found = MACH_PORT_NULL;
    if (host_processor_set_priv(host, pset, &psetCtl) == KERN_SUCCESS) {
        task_array_t tasks = NULL;
        mach_msg_type_number_t n = 0;
        if (processor_set_tasks(psetCtl, &tasks, &n) == KERN_SUCCESS && tasks) {
            for (mach_msg_type_number_t i = 0; i < n; i++) {
                int p2 = 0;
                if (pid_for_task(tasks[i], &p2) == KERN_SUCCESS && p2 == pid) {
                    found = tasks[i];
                } else if (tasks[i] != MACH_PORT_NULL) {
                    mach_port_deallocate(mach_task_self(), tasks[i]);
                }
            }
            vm_deallocate(mach_task_self(), (vm_address_t)tasks,
                          (vm_size_t)n * sizeof(task_t));
        }
    }
    return found;
}

mach_port_t ESPGameTaskPort(void) {
    pthread_mutex_lock(&s_taskMutex);
    task_t t = s_gameTask;
    pthread_mutex_unlock(&s_taskMutex);
    return t;
}

BOOL ESPGameTaskEnsure(void) {
    pthread_mutex_lock(&s_taskMutex);
    // Port cache còn sống? (re-validate rẻ: 1 syscall).
    if (s_gameTask != MACH_PORT_NULL) {
        int p = 0;
        if (pid_for_task(s_gameTask, &p) == KERN_SUCCESS && p == s_gamePid && p > 0) {
            pthread_mutex_unlock(&s_taskMutex);
            return YES;
        }
        mach_port_deallocate(mach_task_self(), s_gameTask);
        s_gameTask = MACH_PORT_NULL;
        s_gamePid = 0;
    }
    // Throttle attempt full (Ensure chạy mỗi tick 40Hz).
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - s_lastTryAt < 5.0) {
        pthread_mutex_unlock(&s_taskMutex);
        return NO;
    }
    if (s_giveUpFails >= 100) {
        // kernrw52e: bỏ give-up — keep trying vm_read (task port) mỗi 2s.
        // Esign mobile thường fail, nhưng region-map fallback vẫn chạy song song.
        pthread_mutex_unlock(&s_taskMutex);
        return NO;
    }
    s_lastTryAt = now;
    pid_t pid = ESPTaskFindGamePid();
    task_t t = MACH_PORT_NULL;
    int route = 0;
    if (pid > 0) {
        t = ESPTaskTryRouteA(pid);
        if (t != MACH_PORT_NULL) {
            route = 1;
        } else {
            t = ESPTaskTryRouteB(pid);
            if (t != MACH_PORT_NULL) route = 2;
        }
    }
    if (t != MACH_PORT_NULL) {
        s_gameTask = t;
        s_gamePid = pid;
        if (s_okLoggedPid != pid || s_okLoggedRoute != route) {
            s_okLoggedPid = pid;
            s_okLoggedRoute = route;
            ESPLog("task port OK route=%s pid=%d (read -> mach_vm_read_overwrite)",
                   route == 1 ? "task_for_pid" : "host-priv", (int)pid);
        }
        pthread_mutex_unlock(&s_taskMutex);
        return YES;
    }
    if (!s_failLogged) {
        s_failLogged = YES;
        ESPLog("task port FAIL (Esign mobile?) - fallback kernel region-map");
    }
    if (++s_giveUpFails == 5) {
        ESPLog("task port unavailable x5 - region-map only for this session");
    }
    pthread_mutex_unlock(&s_taskMutex);
    return NO;
}

void ESPGameTaskReset(void) {
    pthread_mutex_lock(&s_taskMutex);
    if (s_gameTask != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), s_gameTask);
        s_gameTask = MACH_PORT_NULL;
        s_gamePid = 0;
    }
    // Cho thử lại sau world đổi/disable (máy resign entitlement giữa chừng).
    s_giveUpFails = 0;
    s_lastTryAt = 0;
    pthread_mutex_unlock(&s_taskMutex);
}

BOOL ESPTaskRead(uint64_t remoteAddr, void *buf, uint64_t len) {
    if (!remoteAddr || !buf || !len || len > 0x40000) return NO;
    if (remoteAddr < 0x100000000ULL) return NO; // ngoài userspace game
    pthread_mutex_lock(&s_taskMutex);
    task_t t = s_gameTask;
    pthread_mutex_unlock(&s_taskMutex);
    if (t == MACH_PORT_NULL) return NO;
    mach_vm_size_t out = 0;
    kern_return_t kr = mach_vm_read_overwrite(t, (mach_vm_address_t)remoteAddr,
                                              (mach_vm_size_t)len,
                                              (mach_vm_address_t)buf, &out);
    if (kr == KERN_SUCCESS && out == (mach_vm_size_t)len) return YES;
    return NO;
}
