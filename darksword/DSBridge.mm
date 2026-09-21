//
//  DSBridge.mm
//  DarkSpeed
//

#import "DSBridge.h"
#import "HUDHelper.h"
#import "HUDPresetPosition.h"
#import "SpringBoardServices.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern "C" CFIndex CARenderServerGetDirtyFrameCount(void *);

NSString * const DSBridgeProgressNotification = @"com.huami.darkspeed.dsbridge.progress";

static os_unfair_lock g_errorLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_dsLastError = @"";
static NSString *g_dsStage = @"Waiting to start";
#if USE_DARKSWORD
static std::atomic_bool g_dsReady(false);
static std::atomic_bool g_dsRunning(false);
static std::atomic_bool g_hudRequested(false);
static std::atomic_bool g_hudActive(false);
static std::atomic<double> g_dsProgress(0.0);
#endif

static NSString *ds_localized(NSString *key) {
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

static void ds_post_progress(void) {
    notify_post("com.huami.darkspeed.dsbridge.progress");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSBridgeProgressNotification object:nil];
    });
}

static NSString *ds_checkpoint_log_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *library = paths.firstObject;
    return library.length ? [library stringByAppendingPathComponent:@"DSBridge.log"] : nil;
}

static void ds_append_checkpoint(NSString *message) {
    NSString *path = ds_checkpoint_log_path();
    if (!path.length || !message.length) return;
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle synchronizeFile];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

#if USE_DARKSWORD
static void ds_set_stage(NSString *stage) {
    NSString *next = [stage copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsStage = next;
    os_unfair_lock_unlock(&g_errorLock);
    os_log(OS_LOG_DEFAULT, "[DSBridge] stage: %{public}@", next);
    ds_append_checkpoint(next);
    ds_post_progress();
}
#endif

static void ds_set_error(NSString *message) {
    NSString *next = [message copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsLastError = next;
    os_unfair_lock_unlock(&g_errorLock);
    if (next.length > 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] %{public}@", next);
        ds_append_checkpoint([ds_localized(@"Error: ") stringByAppendingString:next]);
        notify_post(NOTIFY_RELOAD_APP);
    }
    ds_post_progress();
}

#if USE_DARKSWORD

#import "DSRemoteCall.h"
#import <mach/mach.h>
#import <mach-o/loader.h>
#import "ESPEngine.h"
#import "ESPConfig.h"
#import "ESPOverlay.h"
#import "ESPMemory.h"
#import "ESPLog.h"

// These vendored headers are plain C/Objective-C. Keep C linkage from this .mm.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// Forward declarations from TaskRop/vm.m (avoid pulling the full RemoteCall.h
// which clashes with our DSRemoteCall.h shim). Layout must match
// `struct vmshmem` in Vendor/darksword-kexploit/TaskRop/RemoteCall.h.
struct vmshmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool used;
};
extern "C" void vmmapiterateentries(uint64_t vmmapptr,
    void (^itblock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop));
extern "C" struct vmshmem vmmapremotepage(uint64_t vmMap, uint64_t address);
extern "C" kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);

static const NSInteger kDSSpringBoardHUDTag = 0x54534844; // "TSHD"
static const CGFloat kDSHUDMinFontSize = 9.0;
static const CGFloat kDSHUDMaxFontSize = 10.0;
static const CGFloat kDSHUDMinCornerRadius = 4.5;
static const CGFloat kDSHUDMaxCornerRadius = 5.0;
static const CGFloat kDSHUDInactiveOpacity = 0.667;
static const NSTimeInterval kDSHUDFocusDuration = 3.0;
static const double kDSHUDWindowLevel = 10000010.0;
static const CACornerMask kDSCornerMaskBottom =
    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
static const CACornerMask kDSCornerMaskAll =
    kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;

static RemoteCall *g_springBoard = nil;
static uint64_t g_remoteContainer = 0;
static uint64_t g_remoteBlurView = 0;
static uint64_t g_remoteBlurEffect = 0;
static uint64_t g_remoteLabel = 0;
static uint64_t g_remoteSecureField = 0;
static uint64_t g_remoteSecureCanvas = 0;
static uint64_t g_remoteWindow = 0;
static uint64_t g_remoteWindowScene = 0;
static pid_t g_remoteWindowPid = 0;
// ESP overlay (box thật): window full-screen + container xoay theo orientation
// + pool ESPOverlayMaxBoxes*(4 viền + 1 label). Intentionally leak như HUD.
static uint64_t g_espWindow = 0;
static uint64_t g_espContainer = 0;
static uint64_t g_espBorders[ESPOverlayMaxBoxes][4] = {{0}};
static uint64_t g_espLabels[ESPOverlayMaxBoxes] = {0};
static BOOL g_espHiddenCache[ESPOverlayMaxBoxes] = {0};
static BOOL g_espWindowHiddenCache = YES;
// Cache frame/text từng box cho tick 8Hz (đứng yên thì 0 remote call).
// Reset cùng views ở ds_finish_disable (views mới = địa chỉ mới).
static CGRect g_espLastRect[ESPOverlayMaxBoxes][5]; // 0-3 viền, 4 label
static char g_espLastDist[ESPOverlayMaxBoxes][16];
static BOOL g_espRectValid[ESPOverlayMaxBoxes] = {NO};
static CGRect g_espLastContainerBounds = CGRectZero;
static dispatch_source_t g_rateTimer = nil;
// Timer riêng cho ESP overlay 8Hz (box mượt) — tách khỏi timer HUD text 1Hz.
// Trước đây overlay ăn theo tick 1Hz nên box giật từng giây.
static dispatch_source_t g_espTimer = nil;
// Timer present nội suy 12Hz (lerp prev->tgt), rẻ (toán thuần + IPC cached).
static dispatch_source_t g_espPresentTimer = nil;
static AVAudioPlayer *g_keepAlivePlayer = nil;
static uint64_t g_previousInput = 0;
static uint64_t g_previousOutput = 0;
static CFAbsoluteTime g_previousSampleTime = 0;
static CFAbsoluteTime g_focusUntil = 0;
static CFIndex g_previousDirtyFrameCount = 0;
static BOOL g_needsFPSBaselineReset = YES;
static std::atomic<int> g_remoteOrientation(UIInterfaceOrientationUnknown);
// Orientation của app FOREGROUND (game) theo SpringBoard — khác
// g_remoteOrientation (scene của chính SpringBoard, kẹt portrait).
// Poll 1Hz trong ds_update_rate, ESP tick chỉ đọc (rẻ).
static std::atomic<int> g_foregroundOrientation(UIInterfaceOrientationUnknown);
static int g_reloadHUDToken = -1;
static int g_lockStateToken = -1;
static NSUInteger g_lastPresentationSignature = 0;
static CGRect g_lastWindowFrame = CGRectNull;
static CGRect g_lastLabelFrame = CGRectNull;
static BOOL g_lastWindowHidden = NO;
static CGFloat g_lastContainerAlpha = -1.0;
static CGFloat g_lastFontSize = -1.0;
static BOOL g_lastInverted = NO;
static BOOL g_lastHideAtSnapshot = NO;
static NSMutableDictionary<NSString *, NSNumber *> *g_remoteSelectorCache = nil;
static NSMutableDictionary<NSString *, NSNumber *> *g_remoteClassCache = nil;
static std::atomic<int> g_kernelPrefetchState(0); // 0 idle, 1 running, 2 ready, 3 failed
static dispatch_group_t g_kernelPrefetchGroup = nil;
static std::atomic<int> g_networkWarmupState(0); // 0 idle, 1 waiting, 2 ready, 3 timed out
static dispatch_group_t g_networkWarmupGroup = nil;
static const NSTimeInterval kDSNetworkWarmupTimeout = 180.0;
static const NSTimeInterval kDSNetworkRetryDelay = 3.0;

static const uint64_t kDSRemoteTextScratchOffset = 0x1000;
static const size_t kDSRemoteTextScratchCapacity = 0x800;

static void ds_update_rate(void);
static void ds_stop_keepalive(void);

typedef struct {
    BOOL landscape;
    BOOL centered;
    BOOL centeredMost;
    BOOL singleLine;
    BOOL bitrate;
    BOOL arrowPrefixes;
    BOOL inverted;
    BOOL followsRotation;
    BOOL hideAtSnapshot;
    BOOL displayFPS;
    BOOL passthrough;
    CGFloat fontSize;
    CGFloat cornerRadius;
    CGFloat inactiveOpacity;
    NSInteger numberOfLines;
    NSTextAlignment alignment;
    CACornerMask maskedCorners;
    CGRect windowFrame;
    CGRect blurFrame;
    CGRect labelFrame;
} DSHUDPresentation;

static dispatch_queue_t ds_bridge_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.huami.darkspeed.darksword", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void ds_bridge_log(const char *message) {
    if (message && message[0]) {
        os_log(OS_LOG_DEFAULT, "[DSBridge] %{public}s", message);
    }
}

// Feed the native progress callback into the controller UI so startup shows
// measured progress instead of an indeterminate spinner.
static void ds_bridge_progress(double progress) {
    g_dsProgress.store(progress);
    ds_post_progress();
}

static uint64_t ds_env_u64(const char *name) {
    const char *value = getenv(name);
    return value && value[0] ? strtoull(value, NULL, 0) : 0;
}

static int ds_env_int(const char *name, int fallback) {
    const char *value = getenv(name);
    return value && value[0] ? (int)strtol(value, NULL, 0) : fallback;
}

static BOOL ds_has_symbol_offsets(void) {
    return kernel_symbol_offsets_are_current();
}

static dispatch_group_t ds_kernel_prefetch_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_kernelPrefetchGroup = dispatch_group_create();
    });
    return g_kernelPrefetchGroup;
}

static dispatch_group_t ds_network_warmup_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_networkWarmupGroup = dispatch_group_create();
    });
    return g_networkWarmupGroup;
}

static BOOL ds_mark_network_warmup_ready(void) {
    int expected = 1;
    if (!g_networkWarmupState.compare_exchange_strong(expected, 2)) return NO;
    dispatch_group_leave(ds_network_warmup_group());
    return YES;
}

static void ds_start_kernel_prefetch(BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || ds_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        ds_set_stage(ds_localized(@"System data is ready"));
        return;
    }

    int state = g_kernelPrefetchState.load();
    while (state != 1 && state != 2) {
        if (state == 3 && !retryFailed) return;
        if (g_kernelPrefetchState.compare_exchange_weak(state, 1)) break;
    }
    if (state == 1 || state == 2) return;

    ds_set_error(@"");
    ds_set_stage(ds_localized(@"Caching kernelcache"));
    dispatch_group_t group = ds_kernel_prefetch_group();
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = dlkcache();
        g_kernelPrefetchState.store(ready ? 2 : 3);
        if (ready) {
            os_log(OS_LOG_DEFAULT, "[DSBridge] kernelcache prefetch ready");
            ds_mark_network_warmup_ready();
            ds_set_error(@"");
            ds_set_stage(ds_localized(@"Kernelcache cached"));
        } else {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] kernelcache prefetch failed");
            if (g_networkWarmupState.load() == 1) {
                ds_set_stage(ds_localized(@"Requesting network access"));
            } else {
                ds_set_stage(ds_localized(@"Kernelcache cache failed"));
            }
        }
        dispatch_group_leave(group);
    });
}

static BOOL ds_wait_for_kernel_attempt(CFAbsoluteTime deadline) {
    if (ds_has_symbol_offsets()) return YES;
    if (g_kernelPrefetchState.load() != 1) return NO;

    NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
    if (remaining <= 0.0) return NO;
    long waitResult = dispatch_group_wait(
        ds_kernel_prefetch_group(),
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    if (waitResult != 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] kernelcache prefetch timed out");
        return NO;
    }
    return ds_has_symbol_offsets();
}

static BOOL ds_wait_for_kernel_prefetch(NSTimeInterval timeout, BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || ds_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        return YES;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    DSBridgeWarmUpNetworkAndPrefetchKernelCache();
    ds_start_kernel_prefetch(retryFailed);
    if (ds_wait_for_kernel_attempt(deadline)) return YES;

    // Some regions show a first-network-access prompt while others do not.
    // Only wait for that optional path after a real kernelcache request has
    // failed; a successful real request is authoritative on every device.
    if (g_networkWarmupState.load() == 1) {
        NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
        if (remaining <= 0.0) return NO;
        long networkWaitResult = dispatch_group_wait(
            ds_network_warmup_group(),
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if (networkWaitResult != 0) {
            os_log_error(OS_LOG_DEFAULT,
                         "[DSBridge] network warm-up timed out while enabling HUD");
            return NO;
        }
    }
    if (ds_has_symbol_offsets()) return YES;
    if (g_networkWarmupState.load() != 2) return NO;

    ds_start_kernel_prefetch(retryFailed);
    return ds_wait_for_kernel_attempt(deadline);
}

static void ds_probe_network_until_ready(CFAbsoluteTime startedAt, NSUInteger attempt) {
    if (g_networkWarmupState.load() != 1) return;

    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
    ds_set_stage([NSString stringWithFormat:ds_localized(@"Waiting for network (%.0f seconds, attempt %lu)"),
                  elapsed, (unsigned long)attempt]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://api.appledb.dev/ios/main.json.xz"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:8.0];
    request.HTTPMethod = @"HEAD";
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            BOOL httpOK = !httpResponse ||
                (httpResponse.statusCode >= 200 && httpResponse.statusCode < 400);
            if (!error && response && httpOK) {
                if (!ds_mark_network_warmup_ready()) return;
                os_log(OS_LOG_DEFAULT, "[DSBridge] network access ready after %.0fs",
                       CFAbsoluteTimeGetCurrent() - startedAt);
                ds_set_error(@"");
                ds_set_stage(ds_localized(@"Network connected; preparing kernelcache"));
                ds_start_kernel_prefetch(YES);
                return;
            }

            NSTimeInterval totalElapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
            if (g_networkWarmupState.load() != 1) return;
            if (totalElapsed >= kDSNetworkWarmupTimeout) {
                int expected = 1;
                if (!g_networkWarmupState.compare_exchange_strong(expected, 3)) return;
                NSString *detail = error.localizedDescription;
                if (!detail.length && httpResponse) {
                    detail = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
                }
                if (!detail.length) detail = ds_localized(@"No valid response");
                os_log_error(OS_LOG_DEFAULT,
                             "[DSBridge] network warm-up timed out: %{public}@", detail);
                ds_set_stage(ds_localized(@"Network wait timed out"));
                ds_set_error([NSString stringWithFormat:
                    ds_localized(@"Could not connect after waiting %.0f seconds: %@\nCheck DarkSpeed network access and your connection, then retry."),
                    totalElapsed, detail]);
                dispatch_group_leave(ds_network_warmup_group());
                return;
            }

            ds_set_stage([NSString stringWithFormat:
                ds_localized(@"Network is not ready; waited %.0f seconds. Retrying in %.0f seconds"),
                totalElapsed, kDSNetworkRetryDelay]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kDSNetworkRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ds_probe_network_until_ready(startedAt, attempt + 1);
            });
        }] resume];
}

void DSBridgeWarmUpNetworkAndPrefetchKernelCache(void) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || ds_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        ds_set_error(@"");
        ds_set_stage(ds_localized(@"System data is ready"));
        return;
    }

    BOOL shouldStartProbe = NO;
    int expected = 0;
    if (g_networkWarmupState.compare_exchange_strong(expected, 1)) {
        shouldStartProbe = YES;
    } else if (expected == 3) {
        expected = 3;
        shouldStartProbe = g_networkWarmupState.compare_exchange_strong(expected, 1);
    }

    if (shouldStartProbe) {
        ds_set_error(@"");
        ds_set_stage(ds_localized(@"Requesting network access"));
        dispatch_group_enter(ds_network_warmup_group());
        ds_probe_network_until_ready(CFAbsoluteTimeGetCurrent(), 1);
    }

    // The real request is the source of truth. Devices that do not present a
    // regional network prompt can proceed immediately instead of being gated
    // on the separate permission/connectivity probe.
    ds_start_kernel_prefetch(YES);
}

static void ds_fail_enable(NSString *reason) {
    os_log_error(OS_LOG_DEFAULT, "[DSBridge] enable failed: %{public}@", reason);
    g_hudRequested.store(false);
    g_hudActive.store(false);
    g_dsRunning.store(false);
    g_dsProgress.store(0.0);
    ds_stop_keepalive();
    ds_set_stage(ds_localized(@"Startup failed"));
    ds_set_error(reason ?: @"");
    ds_post_progress();
}

static NSDictionary *ds_hud_preferences(void) {
    NSMutableDictionary *preferences = [[NSDictionary
        dictionaryWithContentsOfFile:JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)] mutableCopy]
        ?: [NSMutableDictionary dictionary];

    // The original app keeps the advanced font/offset values in its standard
    // defaults rather than the HUD plist. Merge them into the remote snapshot
    // so the renderer has exactly one source of truth.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (HUDUserDefaultsKey key in @[
        HUDUserDefaultsKeyUsesCustomFontSize,
        HUDUserDefaultsKeyRealCustomFontSize,
        HUDUserDefaultsKeyUsesCustomOffset,
        HUDUserDefaultsKeyRealCustomOffsetX,
        HUDUserDefaultsKeyRealCustomOffsetY,
    ]) {
        id value = [defaults objectForKey:key];
        if (value) preferences[key] = value;
    }
    return preferences;
}

// MARK: - Base Game (ShadowTrackerExtra / PUBG Mobile)

static NSString * const kDSDefaultGameProcessName = @"ShadowTrackerExtra";
static const NSTimeInterval kDSGameBaseCacheTTL = 30.0; // base ít đổi (ASLR theo lần mở game) — quét thưa để đỡ panic
static uint64_t g_gameBase = 0;
static pid_t g_gamePid = 0;
static NSString *g_gameFoundName = nil;
static CFAbsoluteTime g_gameBaseCheckedAt = 0;
static BOOL g_gameBaseChecking = NO;

static NSString *ds_game_process_name_from_prefs(NSDictionary *prefs) {
    id raw = prefs ? prefs[HUDUserDefaultsKeyBaseGameName] : nil;
    if ([raw isKindOfClass:NSString.class] && [(NSString *)raw length] > 0) {
        return (NSString *)raw;
    }
    id stdRaw = [NSUserDefaults.standardUserDefaults objectForKey:HUDUserDefaultsKeyBaseGameName];
    if ([stdRaw isKindOfClass:NSString.class] && [(NSString *)stdRaw length] > 0) {
        return (NSString *)stdRaw;
    }
    return kDSDefaultGameProcessName;
}

static BOOL ds_show_base_game_from_prefs(NSDictionary *prefs) {
    NSNumber *n = prefs ? prefs[HUDUserDefaultsKeyShowBaseGame] : nil;
    if (n) return n.boolValue;
    return [NSUserDefaults.standardUserDefaults boolForKey:HUDUserDefaultsKeyShowBaseGame];
}

// p_comm is truncated (MAXCOMLEN 16), so "ShadowTrackerExtra" (18 chars)
// never matches with strcmp. Try exact first, then prefix/substring via proclist.
static uint64_t ds_find_game_proc(const char *wanted, pid_t *outPid, NSString **outFoundName) {
    if (outPid) *outPid = 0;
    if (outFoundName) *outFoundName = nil;
    if (!wanted || !wanted[0]) return 0;
    if (!ds_is_ready()) return 0;

    uint64_t proc = procbyname(wanted);
    if (proc) {
        if (outPid) *outPid = (pid_t)ds_kread32(proc + off_proc_p_pid);
        if (outFoundName) *outFoundName = [NSString stringWithUTF8String:wanted];
        return proc;
    }

    // Prefix of the truncated p_comm (first 15 chars) + full substring search.
    size_t wantedLen = strlen(wanted);
    size_t prefixLen = wantedLen > 15 ? 15 : wantedLen;
    char prefix[32] = {0};
    if (prefixLen > 0) {
        strncpy(prefix, wanted, prefixLen);
        proc = procbyname(prefix);
        if (proc) {
            if (outPid) *outPid = (pid_t)ds_kread32(proc + off_proc_p_pid);
            if (outFoundName) {
                char tmp[33] = {0};
                ds_kread(proc + off_proc_p_name, tmp, 32);
                *outFoundName = [NSString stringWithUTF8String:tmp];
            }
            return proc;
        }
    }

    int count = 0;
    proc_entry_t *list = proclist("", &count);
    if (!list) return 0;
    uint64_t best = 0;
    pid_t bestPid = 0;
    NSString *bestName = nil;
    // Pass 1: prefix match. Pass 2: substring "Shadow"/wanted.
    for (int pass = 0; pass < 2 && !best; pass++) {
        for (int i = 0; i < count; i++) {
            const char *n = list[i].name;
            if (!n || !n[0]) continue;
            BOOL match = NO;
            if (pass == 0) {
                match = (prefixLen > 0 && strncmp(n, prefix, prefixLen) == 0);
            } else {
                match = (strstr(n, prefix) != NULL) || (strstr(n, "Shadow") != NULL);
            }
            if (match) {
                uint64_t p = procbypid(list[i].pid);
                if (!p) continue;
                best = p;
                bestPid = list[i].pid;
                bestName = [NSString stringWithUTF8String:n];
                break;
            }
        }
    }
    free_proclist(list);
    if (best) {
        if (outPid) *outPid = bestPid;
        if (outFoundName) *outFoundName = bestName;
    }
    return best;
}

static uint64_t ds_scan_process_base(uint64_t vmMap) {
    if (!vmMap) return 0;
    __block uint64_t found = 0;
    // Pass 1: entries that look like a file-backed __TEXT (alias == 0), like decrypt.m.
    // Pass 2: any mapping with MH_MAGIC_64.
    for (int pass = 0; pass < 2 && !found; pass++) {
        vmmapiterateentries(vmMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
            if (found) return;
            if (start < 0x100000000ULL) return;
            if (start >= 0xFFFFFF8000000000ULL) return;
            if (end <= start || (end - start) < 0x4000) return;
            if (pass == 0 && off_vm_map_entry_vme_alias) {
                uint64_t raw = ds_kread64(entry + off_vm_map_entry_vme_alias);
                if ((raw >> 12) != 0) return;
            }
            struct vmshmem shmem = vmmapremotepage(vmMap, start);
            if (!shmem.used || !shmem.localAddress) return;
            uint32_t magic = *(volatile uint32_t *)(uintptr_t)shmem.localAddress;
            mach_vm_deallocate(mach_task_self_, (mach_vm_address_t)shmem.localAddress, PAGE_SIZE);
            if (shmem.port) mach_port_deallocate(mach_task_self_, (mach_port_t)shmem.port);
            if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
                found = start;
                *stop = YES;
            }
        });
    }
    return found;
}

static void ds_refresh_game_base_locked(NSString *wantedName) {
    if (g_gameBaseChecking) return;
    g_gameBaseChecking = YES;
    @try {
        const char *cname = wantedName.UTF8String;
        if (!cname || !cname[0]) cname = kDSDefaultGameProcessName.UTF8String;
        pid_t pid = 0;
        NSString *foundName = nil;
        uint64_t proc = ds_find_game_proc(cname, &pid, &foundName);
        if (!proc) {
            // Keep last known base for display stability, but mark pid 0 = not running.
            g_gamePid = 0;
            g_gameFoundName = nil;
            // If we never found a base, clear it; otherwise keep stale base with "stale" status.
            if (g_gameBase == 0) {
                g_gameFoundName = nil;
            }
            g_gameBaseCheckedAt = CFAbsoluteTimeGetCurrent();
            return;
        }
        uint64_t task = taskbyproc(proc);
        uint64_t vmMap = task ? task_get_vm_map(task) : 0;
        uint64_t base = ds_scan_process_base(vmMap);
        if (base) {
            g_gameBase = base;
            g_gamePid = pid;
            g_gameFoundName = foundName ?: wantedName;
        } else {
            // Process running but base scan failed — keep old base if any.
            g_gamePid = pid;
            if (g_gameBase == 0) g_gameFoundName = foundName;
        }
        g_gameBaseCheckedAt = CFAbsoluteTimeGetCurrent();
    } @finally {
        g_gameBaseChecking = NO;
    }
}

static void ds_ensure_game_base(NSDictionary *prefs) {
    if (!ds_is_ready()) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_gameBaseCheckedAt < kDSGameBaseCacheTTL && g_gameBaseCheckedAt > 0) return;
    NSString *wanted = ds_game_process_name_from_prefs(prefs);
    ds_refresh_game_base_locked(wanted);
}

uint64_t DSBridgeGameBase(void) {
#if USE_DARKSWORD
    return g_gameBase;
#else
    return 0;
#endif
}

NSString *DSBridgeGameProcessName(void) {
    NSDictionary *prefs = nil;
#if USE_DARKSWORD
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
#endif
    NSString *name = prefs ? ds_game_process_name_from_prefs(prefs) : kDSDefaultGameProcessName;
    return name ?: kDSDefaultGameProcessName;
}

NSString *DSBridgeGameStatus(void) {
#if USE_DARKSWORD
    NSDictionary *prefs = nil;
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    if (prefs && !ds_show_base_game_from_prefs(prefs)) return @"";
    if (!ds_is_ready()) return @"Base: wait…";
    // Refresh synchronously only when stale; called from UI (Settings) or HUD timer.
    ds_ensure_game_base(prefs);
    if (g_gameBase) {
        if (g_gamePid > 0) {
            return [NSString stringWithFormat:@"Base: 0x%llX", (unsigned long long)g_gameBase];
        }
        return [NSString stringWithFormat:@"Base: 0x%llX (stale)", (unsigned long long)g_gameBase];
    }
    return @"Base: --";
#else
    return @"";
#endif
}

NSString *DSBridgeGameCachedStatus(void) {
#if USE_DARKSWORD
    NSDictionary *prefs = nil;
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    if (prefs && !ds_show_base_game_from_prefs(prefs)) return @"";
    if (!ds_is_ready()) return @"Base: wait…";
    if (g_gameBase) {
        if (g_gamePid > 0) {
            return [NSString stringWithFormat:@"Base: 0x%llX", (unsigned long long)g_gameBase];
        }
        return [NSString stringWithFormat:@"Base: 0x%llX (stale)", (unsigned long long)g_gameBase];
    }
    return @"Base: --";
#else
    return @"";
#endif
}

void DSBridgeRefreshGameBase(void) {
#if USE_DARKSWORD
    g_gameBaseCheckedAt = 0;
    NSDictionary *prefs = nil;
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    ds_ensure_game_base(prefs ?: @{});
#endif
}

// MARK: - ESP Box (isolated ESP/ folder)

static BOOL ds_show_esp_from_prefs(NSDictionary *prefs) {
    NSNumber *n = prefs ? prefs[HUDUserDefaultsKeyShowESPBox] : nil;
    if (n) return n.boolValue;
    return [NSUserDefaults.standardUserDefaults boolForKey:HUDUserDefaultsKeyShowESPBox];
}

NSString *DSBridgeESPStatus(void) {
#if USE_DARKSWORD
    NSDictionary *prefs = nil;
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    if (prefs && !ds_show_esp_from_prefs(prefs)) return @"";
    if (!ds_show_base_game_from_prefs(prefs)) {
        // ESP cần base — nếu Base Game tắt, báo để user bật.
        // Vẫn thử scan bằng base cache nếu có.
    }
    if (!ds_is_ready()) return @"ESP: wait…";
    ds_ensure_game_base(prefs);
    if (!g_gameBase) return @"ESP: --";
    @try {
        NSString *s = ESPEngineStatusText(g_gameBase);
        return s ?: @"ESP: --";
    } @catch (__unused NSException *e) {
        return @"ESP: --";
    }
#else
    return @"";
#endif
}

uint32_t DSBridgeESPCount(void) {
#if USE_DARKSWORD
    if (!g_gameBase || !ds_is_ready()) return 0;
    @try {
        return ESPEnginePlayerCount(g_gameBase);
    } @catch (__unused NSException *e) {
        return 0;
    }
#else
    return 0;
#endif
}

NSString *DSBridgeESPCachedStatus(void) {
#if USE_DARKSWORD
    NSDictionary *prefs = nil;
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    if (prefs && !ds_show_esp_from_prefs(prefs)) return @"";
    @try {
        NSString *s = ESPEngineCachedStatusText();
        if (s.length == 0) return @"ESP: --";
        return s;
    } @catch (__unused NSException *e) {
        return @"ESP: --";
    }
#else
    return @"";
#endif
}

NSString *DSBridgeESPScanInfo(void) {
#if USE_DARKSWORD
    @try {
        NSString *s = ESPEngineScanInfoText();
        return s ?: @"scan idle";
    } @catch (__unused NSException *e) {
        return @"scan idle";
    }
#else
    return @"scan sim";
#endif
}

static void ds_append_wav_value(NSMutableData *data, const void *value, NSUInteger size) {
    [data appendBytes:value length:size];
}

static NSURL *ds_silent_wav_url(void) {
    NSURL *cache = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [cache URLByAppendingPathComponent:@"darkspeed-silent.wav"];
}

static BOOL ds_write_silent_wav(NSURL *url, NSError **error) {
    const uint32_t sampleRate = 8000;
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint16_t blockAlign = channels * (bitsPerSample / 8);
    const uint32_t byteRate = sampleRate * blockAlign;
    const uint32_t dataSize = sampleRate * blockAlign;
    const uint32_t riffSize = 36 + dataSize;
    const uint32_t formatSize = 16;
    const uint16_t pcmFormat = 1;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    ds_append_wav_value(wav, &riffSize, sizeof(riffSize));
    [wav appendBytes:"WAVEfmt " length:8];
    ds_append_wav_value(wav, &formatSize, sizeof(formatSize));
    ds_append_wav_value(wav, &pcmFormat, sizeof(pcmFormat));
    ds_append_wav_value(wav, &channels, sizeof(channels));
    ds_append_wav_value(wav, &sampleRate, sizeof(sampleRate));
    ds_append_wav_value(wav, &byteRate, sizeof(byteRate));
    ds_append_wav_value(wav, &blockAlign, sizeof(blockAlign));
    ds_append_wav_value(wav, &bitsPerSample, sizeof(bitsPerSample));
    [wav appendBytes:"data" length:4];
    ds_append_wav_value(wav, &dataSize, sizeof(dataSize));
    [wav increaseLengthBy:dataSize];
    return [wav writeToURL:url options:NSDataWritingAtomic error:error];
}

static BOOL ds_start_keepalive(void) {
    __block BOOL started = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (g_keepAlivePlayer.playing) {
            started = YES;
            return;
        }

        NSError *error = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        if (![session setCategory:AVAudioSessionCategoryPlayback
                             mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionMixWithOthers
                            error:&error] ||
            ![session setActive:YES error:&error]) {
            ds_set_error([NSString stringWithFormat:ds_localized(@"Background keep-alive failed: %@"), error.localizedDescription]);
            return;
        }

        NSURL *wavURL = ds_silent_wav_url();
        if (![[NSFileManager defaultManager] fileExistsAtPath:wavURL.path] &&
            !ds_write_silent_wav(wavURL, &error)) {
            ds_set_error([NSString stringWithFormat:ds_localized(@"Background resource preparation failed: %@"), error.localizedDescription]);
            return;
        }

        g_keepAlivePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:wavURL error:&error];
        g_keepAlivePlayer.numberOfLoops = -1;
        g_keepAlivePlayer.volume = 0.0f;
        [g_keepAlivePlayer prepareToPlay];
        started = [g_keepAlivePlayer play];
        if (!started) {
            ds_set_error([NSString stringWithFormat:ds_localized(@"Background keep-alive playback failed: %@"), error.localizedDescription]);
            g_keepAlivePlayer = nil;
        }
    });
    return started;
}

static void ds_stop_keepalive(void) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [g_keepAlivePlayer stop];
        g_keepAlivePlayer = nil;
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:nil];
    });
}

static void ds_read_network_bytes(uint64_t *input, uint64_t *output) {
    *input = 0;
    *output = 0;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return;

    for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
        if (!interface->ifa_name || !interface->ifa_addr || !interface->ifa_data) continue;
        if (interface->ifa_addr->sa_family != AF_LINK) continue;
        if (!(interface->ifa_flags & IFF_UP) && !(interface->ifa_flags & IFF_RUNNING)) continue;
        if (strncmp(interface->ifa_name, "en", 2) && strncmp(interface->ifa_name, "pdp_ip", 6)) continue;

        struct if_data *data = (struct if_data *)interface->ifa_data;
        *input += data->ifi_ibytes;
        *output += data->ifi_obytes;
    }
    freeifaddrs(interfaces);
}

static BOOL ds_pref_bool(NSDictionary *preferences, HUDUserDefaultsKey key) {
    return [preferences[key] boolValue];
}

static CGFloat ds_pref_double(NSDictionary *preferences, HUDUserDefaultsKey key,
                              CGFloat fallback) {
    NSNumber *number = preferences[key];
    return number ? number.doubleValue : fallback;
}

static NSString *ds_format_speed(double bytes, BOOL bitrate, BOOL focused) {
    double value = bitrate ? bytes * 8.0 : bytes;
    double kilo = bitrate ? 1000.0 : 1024.0;
    double mega = kilo * kilo;
    double giga = mega * kilo;
    NSString *suffix = focused ? @"" : @"/s";
    NSString *kiloUnit = bitrate ? @"Kb" : @"KB";
    NSString *megaUnit = bitrate ? @"Mb" : @"MB";
    NSString *gigaUnit = bitrate ? @"Gb" : @"GB";

    if (value < kilo) {
        return [NSString stringWithFormat:@"0\u00a0%@%@", kiloUnit, suffix];
    }
    if (value < mega) {
        return [NSString stringWithFormat:@"%.0f\u00a0%@%@", value / kilo, kiloUnit, suffix];
    }
    if (value < giga) {
        return [NSString stringWithFormat:@"%.2f\u00a0%@%@", value / mega, megaUnit, suffix];
    }
    return [NSString stringWithFormat:@"%.2f\u00a0%@%@", value / giga, gigaUnit, suffix];
}

static UIInterfaceOrientation ds_interface_orientation(void) {
    UIInterfaceOrientation remoteOrientation =
        (UIInterfaceOrientation)g_remoteOrientation.load();
    if (remoteOrientation != UIInterfaceOrientationUnknown) {
        return remoteOrientation;
    }
    __block UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            orientation = windowScene.interfaceOrientation;
            break;
        }
    });
    return orientation;
}

static void ds_screen_geometry(CGRect *bounds, UIEdgeInsets *safeInsets) {
    __block CGRect currentBounds = UIScreen.mainScreen.bounds;
    __block UIEdgeInsets currentInsets = UIEdgeInsetsZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            currentBounds = windowScene.coordinateSpace.bounds;
            for (UIWindow *window in windowScene.windows) {
                if (window.safeAreaInsets.top > currentInsets.top) {
                    currentInsets = window.safeAreaInsets;
                }
            }
            break;
        }
    });
    if (bounds) *bounds = currentBounds;
    if (safeInsets) *safeInsets = currentInsets;
}

static NSString *ds_base_game_line_for_prefs(NSDictionary *preferences) {
    if (!ds_show_base_game_from_prefs(preferences)) return nil;
    ds_ensure_game_base(preferences);
    if (g_gameBase) {
        if (g_gamePid > 0) {
            return [NSString stringWithFormat:@"Base: 0x%llX", (unsigned long long)g_gameBase];
        }
        return [NSString stringWithFormat:@"Base: 0x%llX (stale)", (unsigned long long)g_gameBase];
    }
    return @"Base: --";
}

static NSString *ds_esp_line_for_prefs(NSDictionary *preferences) {
    if (!ds_show_esp_from_prefs(preferences)) return nil;
    if (!ds_is_ready()) return @"ESP: wait…";
    ds_ensure_game_base(preferences);
    if (!g_gameBase) return @"ESP: --";
    @try {
        NSString *s = ESPEngineStatusText(g_gameBase);
        return s.length ? s : @"ESP: --";
    } @catch (__unused NSException *e) {
        return @"ESP: --";
    }
}

static NSString *ds_display_text(NSDictionary *preferences,
                                 BOOL centered,
                                 BOOL focused,
                                 double down,
                                 double up) {
    NSString *main = nil;
    if (ds_pref_bool(preferences, HUDUserDefaultsKeyDisplayMode)) {
        CFIndex current = CARenderServerGetDirtyFrameCount(NULL);
        if (g_needsFPSBaselineReset) {
            g_previousDirtyFrameCount = current;
            g_needsFPSBaselineReset = NO;
            main = @"0 FPS";
        } else {
            CFIndex frameDiff = MAX((CFIndex)0, current - g_previousDirtyFrameCount);
            g_previousDirtyFrameCount = current;
            CGFloat maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
            main = [NSString stringWithFormat:@"%.0f FPS", MIN((CGFloat)frameDiff, maximumFPS)];
        }
    } else {
        BOOL bitrate = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBitrate);
        BOOL alternateArrows = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesArrowPrefixes);
        BOOL incomingOnly = ds_pref_bool(preferences, HUDUserDefaultsKeySingleLineMode);
        NSString *downloadPrefix = alternateArrows ? @"↓" : @"▼";
        NSString *uploadPrefix = alternateArrows ? @"↑" : @"▲";
        NSString *download = [NSString stringWithFormat:@"%@\u00a0%@",
                              downloadPrefix, ds_format_speed(down, bitrate, focused)];
        if (incomingOnly) {
            main = download;
        } else {
            NSString *upload = [NSString stringWithFormat:@"%@\u00a0%@",
                                uploadPrefix, ds_format_speed(up, bitrate, focused)];
            main = centered
                ? [NSString stringWithFormat:@"%@\t%@", download, upload]
                : [NSString stringWithFormat:@"%@\n%@", upload, download];
        }
    }

    NSString *baseLine = ds_base_game_line_for_prefs(preferences);
    if (baseLine) {
        main = [main stringByAppendingFormat:@"\n%@", baseLine];
    }
    NSString *espLine = ds_esp_line_for_prefs(preferences);
    if (espLine) {
        main = [main stringByAppendingFormat:@"\n%@", espLine];
    }
    return main;
}

static DSHUDPresentation ds_hud_presentation(NSDictionary *preferences,
                                             NSString *text) {
    DSHUDPresentation presentation = {};
    UIInterfaceOrientation orientation = ds_interface_orientation();
    presentation.landscape = UIInterfaceOrientationIsLandscape(orientation);

    HUDUserDefaultsKey modeKey = presentation.landscape
        ? HUDUserDefaultsKeySelectedModeLandscape
        : HUDUserDefaultsKeySelectedMode;
    NSNumber *storedMode = preferences[modeKey];
    HUDPresetPosition mode = storedMode
        ? (HUDPresetPosition)storedMode.integerValue
        : HUDPresetPositionTopCenter;
    presentation.centered =
        mode == HUDPresetPositionTopCenter || mode == HUDPresetPositionTopCenterMost;
    presentation.centeredMost = mode == HUDPresetPositionTopCenterMost;
    presentation.singleLine = ds_pref_bool(preferences, HUDUserDefaultsKeySingleLineMode);
    presentation.bitrate = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBitrate);
    presentation.arrowPrefixes = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesArrowPrefixes);
    presentation.inverted = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesInvertedColor);
    presentation.followsRotation = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesRotation);
    presentation.hideAtSnapshot = ds_pref_bool(preferences, HUDUserDefaultsKeyHideAtSnapshot);
    presentation.displayFPS = ds_pref_bool(preferences, HUDUserDefaultsKeyDisplayMode);
    presentation.passthrough = ds_pref_bool(preferences, HUDUserDefaultsKeyPassthroughMode);

    BOOL customFont = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomFontSize);
    if (customFont) {
        presentation.fontSize = MIN(MAX(ds_pref_double(
            preferences, HUDUserDefaultsKeyRealCustomFontSize, kDSHUDMinFontSize), 8.0), 12.0);
        presentation.cornerRadius = presentation.fontSize / 2.0;
    } else {
        BOOL large = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesLargeFont);
        presentation.fontSize = large ? kDSHUDMaxFontSize : kDSHUDMinFontSize;
        presentation.cornerRadius = large ? kDSHUDMaxCornerRadius : kDSHUDMinCornerRadius;
    }
    presentation.inactiveOpacity = presentation.inverted ? 1.0 : kDSHUDInactiveOpacity;
    NSInteger baseLines = ds_show_base_game_from_prefs(preferences) ? 1 : 0;
    NSInteger espLines = ds_show_esp_from_prefs(preferences) ? 1 : 0;
    presentation.numberOfLines = (presentation.centered || presentation.singleLine ? 1 : 2) + baseLines + espLines;
    presentation.alignment = presentation.centered ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    presentation.maskedCorners =
        presentation.centeredMost && !presentation.landscape
            ? kDSCornerMaskBottom
            : kDSCornerMaskAll;

    UIFontWeight weight = presentation.inverted ? UIFontWeightMedium : UIFontWeightRegular;
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:presentation.fontSize weight:weight];
    CGRect measured = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                        options:NSStringDrawingUsesLineFragmentOrigin |
                                                NSStringDrawingUsesFontLeading
                                     attributes:@{NSFontAttributeName: font}
                                        context:nil];
    CGSize labelSize = CGSizeMake(ceil(measured.size.width), ceil(measured.size.height));
    if (labelSize.width < 1) labelSize.width = 1;
    if (labelSize.height < 1) labelSize.height = ceil(font.lineHeight);
    CGSize hudSize = CGSizeMake(labelSize.width + 8.0, labelSize.height + 4.0);

    CGRect screenBounds;
    UIEdgeInsets safeInsets;
    ds_screen_geometry(&screenBounds, &safeInsets);
    CGFloat realOffsetX = 0;
    CGFloat realOffsetY = 0;
    if (ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomOffset)) {
        realOffsetX = -ds_pref_double(preferences, HUDUserDefaultsKeyRealCustomOffsetX, 0);
        realOffsetY = ds_pref_double(preferences, HUDUserDefaultsKeyRealCustomOffsetY, 0);
    }

    CGFloat x = CGRectGetMidX(screenBounds) - hudSize.width / 2.0;
    if (mode == HUDPresetPositionTopLeft) {
        x = CGRectGetMinX(screenBounds) + safeInsets.left + 10.0 + realOffsetX;
    } else if (mode == HUDPresetPositionTopRight) {
        x = CGRectGetMaxX(screenBounds) - safeInsets.right - 10.0 - hudSize.width + realOffsetX;
    }

    CGFloat y;
    if (presentation.centeredMost && !presentation.landscape) {
        y = CGRectGetMinY(screenBounds);
    } else if (presentation.landscape) {
        CGFloat minimumTop = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? 30.0 : 10.0;
        minimumTop += realOffsetY;
        NSNumber *saved = preferences[HUDUserDefaultsKeyCurrentLandscapePositionY];
        CGFloat topConstant = (!presentation.centered && saved) ? saved.doubleValue : minimumTop;
        y = CGRectGetMinY(screenBounds) + topConstant;
    } else {
        CGFloat minimumTop;
        if (safeInsets.top >= 51.0) minimumTop = -8.0;
        else if (safeInsets.top > 30.0) minimumTop = -12.0;
        else minimumTop = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? 30.0 : 20.0;
        minimumTop += realOffsetY;
        NSNumber *saved = preferences[HUDUserDefaultsKeyCurrentPositionY];
        CGFloat topConstant = (!presentation.centered && saved) ? saved.doubleValue : minimumTop;
        y = CGRectGetMinY(screenBounds) + safeInsets.top + topConstant;
    }

    presentation.windowFrame = CGRectMake(round(x), round(y), hudSize.width, hudSize.height);
    presentation.blurFrame = CGRectMake(0, 0, hudSize.width, hudSize.height);
    presentation.labelFrame = CGRectMake(4, 2, labelSize.width, labelSize.height);
    return presentation;
}

static void ds_reset_remote_symbol_cache(void) {
    g_remoteSelectorCache = [NSMutableDictionary dictionary];
    g_remoteClassCache = [NSMutableDictionary dictionary];
}

static uint64_t ds_remote_sel(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    if (!g_remoteSelectorCache) g_remoteSelectorCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = g_remoteSelectorCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_sel(process, name);
    if (value) g_remoteSelectorCache[key] = @(value);
    return value;
}

static uint64_t ds_remote_class(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    if (!g_remoteClassCache) g_remoteClassCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = g_remoteClassCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_getClass(process, name);
    if (value) g_remoteClassCache[key] = @(value);
    return value;
}

// The rate label changes every second. Keep its UTF-8 bytes in one reserved
// page instead of doing remote malloc/write/free for every sample. The latter
// eventually filled RemoteCall's finite shared-page cache and turned a failed
// write into a bogus Objective-C selector inside SpringBoard.
static uint64_t ds_remote_create_string(RemoteCall *process, NSString *value) {
    if (!process || !process.trojanMem || !value) return 0;
    const char *utf8 = value.UTF8String;
    if (!utf8) return 0;
    size_t length = strlen(utf8) + 1;
    if (length > kDSRemoteTextScratchCapacity) return 0;

    uint64_t scratch = process.trojanMem + kDSRemoteTextScratchOffset;
    if (![process remote_write:scratch from:utf8 size:length]) return 0;

    uint64_t stringClass = ds_remote_class(process, "NSString");
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t init = ds_remote_sel(process, "initWithUTF8String:");
    if (!stringClass || !alloc || !init) return 0;
    uint64_t object = remote_msg(process, stringClass, alloc, 0, 0, 0, 0);
    if (!object) return 0;
    uint64_t string = remote_msg(process, object, init, scratch, 0, 0, 0);
    if (!string) {
        uint64_t release = ds_remote_sel(process, "release");
        if (release) remote_msg(process, object, release, 0, 0, 0, 0);
    }
    return string;
}

static BOOL ds_perform_on_springboard_main(RemoteCall *process, uint64_t target,
                                           uint64_t selector, uint64_t argument,
                                           BOOL waitUntilDone) {
    if (!process || !process.trojanMem || !target || !selector) return NO;
    uint64_t perform = ds_remote_sel(process, "performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!perform) return NO;
    // a0=selector, a1=object, a2=waitUntilDone (BOOL as uint64 on little-endian).
    remote_msg(process, target, perform, selector, argument, waitUntilDone ? 1 : 0, 0);
    return process.trojanMem != 0;
}

static BOOL ds_remote_set_text_on_main(RemoteCall *process, uint64_t label,
                                       NSString *text) {
    uint64_t remoteText = ds_remote_create_string(process, text);
    if (!remoteText) return NO;
    BOOL sent = ds_perform_on_springboard_main(
        process, label, ds_remote_sel(process, "setText:"), remoteText, YES);
    uint64_t release = ds_remote_sel(process, "release");
    if (release && process.trojanMem) {
        remote_msg(process, remoteText, release, 0, 0, 0, 0);
    }
    return sent;
}

typedef struct {
    const void *bytes;
    uint64_t size;
} DSRemoteArgument;

// RemoteCall's doRemoteCallSyncOnMainThread assumes task->threads.next is the
// main thread. On iOS 17 it can be RemoteCall's newly-created pthread instead,
// which makes UIView initialization abort SpringBoard under
// CA_ASSERT_MAIN_THREAD_TRANSACTIONS. Build an NSInvocation on the call thread,
// then synchronously ask NSObject to invoke it on SpringBoard's real main thread.
static BOOL ds_remote_invoke_on_main_result(RemoteCall *process, uint64_t target,
                                            uint64_t selector,
                                            const DSRemoteArgument *arguments,
                                            NSUInteger argumentCount,
                                            void *result,
                                            NSUInteger resultSize) {
    if (!process || !target || !selector || !process.trojanMem) return NO;

    uint64_t poolClass = ds_remote_class(process, "NSAutoreleasePool");
    uint64_t allocSelector = ds_remote_sel(process, "alloc");
    uint64_t initSelector = ds_remote_sel(process, "init");
    uint64_t drainSelector = ds_remote_sel(process, "drain");
    uint64_t autoreleasePool = poolClass && allocSelector && initSelector && drainSelector
        ? remote_msg(process,
                     remote_msg(process, poolClass, allocSelector, 0, 0, 0, 0),
                     initSelector, 0, 0, 0, 0)
        : 0;
    if (!autoreleasePool) return NO;

    @try {

    uint64_t signature = remote_msg(process, target,
                                    ds_remote_sel(process, "methodSignatureForSelector:"),
                                    selector, 0, 0, 0);
    if (!process.trojanMem) return NO;
    uint64_t invocationClass = ds_remote_class(process, "NSInvocation");
    uint64_t invocation = signature && invocationClass
        ? remote_msg(process, invocationClass,
                     ds_remote_sel(process, "invocationWithMethodSignature:"),
                     signature, 0, 0, 0)
        : 0;
    if (!invocation || !process.trojanMem) return NO;

    remote_msg(process, invocation, ds_remote_sel(process, "setTarget:"), target, 0, 0, 0);
    if (!process.trojanMem) return NO;
    remote_msg(process, invocation, ds_remote_sel(process, "setSelector:"), selector, 0, 0, 0);
    if (!process.trojanMem) return NO;

    uint64_t scratch = process.trojanMem + 0x800;
    for (NSUInteger index = 0; index < argumentCount; index++) {
        if (!arguments[index].bytes || arguments[index].size == 0 ||
            ![process remote_write:scratch
                              from:arguments[index].bytes
                              size:arguments[index].size]) {
            return NO;
        }
        remote_msg(process, invocation, ds_remote_sel(process, "setArgument:atIndex:"),
                   scratch, index + 2, 0, 0);
        if (!process.trojanMem) return NO;
        scratch += (arguments[index].size + 15) & ~15ULL;
    }

    ds_perform_on_springboard_main(process, invocation,
                                   ds_remote_sel(process, "invoke"), 0, YES);
    if (!process.trojanMem) return NO;
    if (result && resultSize > 0) {
        uint64_t resultScratch = process.trojanMem + 0xC00;
        memset(result, 0, resultSize);
        if (![process remote_write:resultScratch from:result size:resultSize]) return NO;
        remote_msg(process, invocation, ds_remote_sel(process, "getReturnValue:"),
                   resultScratch, 0, 0, 0);
        if (!process.trojanMem) return NO;
        if (![process remoteRead:resultScratch to:result size:resultSize]) return NO;
    }
    return YES;
    } @finally {
        if (process.trojanMem) {
            remote_msg(process, autoreleasePool, drainSelector, 0, 0, 0, 0);
        }
    }
}

static BOOL ds_remote_invoke_on_main(RemoteCall *process, uint64_t target,
                                     uint64_t selector,
                                     const DSRemoteArgument *arguments,
                                     NSUInteger argumentCount) {
    return ds_remote_invoke_on_main_result(process, target, selector,
                                           arguments, argumentCount, NULL, 0);
}

static BOOL ds_remote_invoke_noarg_on_main(RemoteCall *process, uint64_t target,
                                           const char *selectorName) {
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    NULL, 0);
}

static uint64_t ds_remote_get_object_on_main(RemoteCall *process, uint64_t target,
                                             const char *selectorName) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName), NULL, 0,
        &result, sizeof(result));
    return invoked ? result : 0;
}

static uint64_t ds_remote_get_retained_object_on_main(
    RemoteCall *process, uint64_t target, const char *selectorName,
    const DSRemoteArgument *arguments, NSUInteger argumentCount) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName),
        arguments, argumentCount, &result, sizeof(result));
    if (!invoked || !result || !process.trojanMem) return 0;

    // Retain immediately after the synchronous main-thread return. This keeps
    // factory results alive across later performSelector turns and prevents the
    // dangling-object crash seen with the former UIColor factory result.
    remote_msg(process, result, ds_remote_sel(process, "retain"), 0, 0, 0, 0);
    return process.trojanMem ? result : 0;
}

static BOOL ds_remote_set_u64_on_main(RemoteCall *process, uint64_t target,
                                      const char *selectorName, uint64_t value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static uint64_t ds_remote_get_u64_on_main(RemoteCall *process, uint64_t target,
                                          const char *selectorName) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName), NULL, 0,
        &result, sizeof(result));
    return invoked ? result : 0;
}

static BOOL ds_remote_set_double_on_main(RemoteCall *process, uint64_t target,
                                         const char *selectorName, double value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static BOOL ds_remote_set_rect_on_main(RemoteCall *process, uint64_t target,
                                       const char *selectorName, CGRect value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static BOOL ds_remote_set_point_on_main(RemoteCall *process, uint64_t target,
                                        const char *selectorName, CGPoint value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

// Map 1 điểm từ hệ game-landscape sang hệ portrait-window, quay quanh tâm màn
// hình. LandscapeLeft = R(-90°), LandscapeRight = R(+90°).
static inline CGPoint ds_esp_map_point(CGPoint p, CGFloat landW, CGFloat landH,
                                       CGPoint winCenter, int orientation) {
    BOOL left = (orientation == UIInterfaceOrientationLandscapeLeft);
    BOOL right = (orientation == UIInterfaceOrientationLandscapeRight);
    if (!left && !right) return p;
    CGFloat dx = p.x - landW * 0.5, dy = p.y - landH * 0.5;
    if (left) return CGPointMake(winCenter.x + dy, winCenter.y - dx);
    return CGPointMake(winCenter.x - dy, winCenter.y + dx);
}
static inline CGRect ds_esp_map_rect(CGRect r, CGFloat landW, CGFloat landH,
                                     CGPoint winCenter, int orientation) {
    // Bbox của 4 góc đã map — đúng cho hình học xoay ±90° (viền box).
    // KHÔNG dùng cho label text (phải giữ ngang — xem chỗ gọi).
    CGFloat x0 = CGFLOAT_MAX, y0 = CGFLOAT_MAX;
    CGFloat x1 = -CGFLOAT_MAX, y1 = -CGFLOAT_MAX;
    for (int k = 0; k < 4; k++) {
        CGPoint wp = ds_esp_map_point(
            CGPointMake((k & 1) ? CGRectGetMaxX(r) : r.origin.x,
                        (k & 2) ? CGRectGetMaxY(r) : r.origin.y),
            landW, landH, winCenter, orientation);
        if (wp.x < x0) x0 = wp.x;
        if (wp.x > x1) x1 = wp.x;
        if (wp.y < y0) y0 = wp.y;
        if (wp.y > y1) y1 = wp.y;
    }
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

// Orientation THẬT của game cho ESP overlay, theo thứ tự tin cậy:
// 1) SpringBoard.activeInterfaceOrientation — bám app foreground thật
//    (poll 1Hz, cache atomic). Đây là nguồn chính khi chơi game.
// 2) UIDevice landscape — đúng khi app nhận được accelerometer.
// 3) Landscape đã thấy lần cuối (game không tự xoay giữa trận).
// 4) Portrait/unknown — container không xoay (chỉ thấy dải giữa, còn hơn
//    đoán sai sign rồi xoay 180° làm toàn bộ box sai).
// NOTE: UIDevice landscape <-> interface landscape NGƯỢC nhau.
static int g_espLastLandscape = UIInterfaceOrientationUnknown; // chỉ chạm từ bridge queue
static int ds_esp_game_orientation(void) {
    int fg = g_foregroundOrientation.load();
    if (fg == UIInterfaceOrientationLandscapeLeft || fg == UIInterfaceOrientationLandscapeRight) {
        g_espLastLandscape = fg;
        return fg;
    }
    UIDeviceOrientation dev = UIDevice.currentDevice.orientation;
    int mapped = UIInterfaceOrientationUnknown;
    switch (dev) {
        case UIDeviceOrientationLandscapeLeft: mapped = UIInterfaceOrientationLandscapeRight; break;
        case UIDeviceOrientationLandscapeRight: mapped = UIInterfaceOrientationLandscapeLeft; break;
        default: break;
    }
    if (mapped == UIInterfaceOrientationLandscapeLeft || mapped == UIInterfaceOrientationLandscapeRight) {
        g_espLastLandscape = mapped;
        return mapped;
    }
    if (g_espLastLandscape == UIInterfaceOrientationLandscapeLeft ||
        g_espLastLandscape == UIInterfaceOrientationLandscapeRight) {
        return g_espLastLandscape;
    }
    int remote = g_remoteOrientation.load();
    if (remote == UIInterfaceOrientationLandscapeLeft || remote == UIInterfaceOrientationLandscapeRight) {
        g_espLastLandscape = remote;
        return remote;
    }
    return (int)ds_interface_orientation();
}

// Poll orientation foreground từ SpringBoard (fail-safe: selector lạ/không
// tồn tại thì remote trả 0, bỏ qua). Gọi 1Hz từ ds_update_rate.
static void ds_poll_foreground_orientation(RemoteCall *process) {
    if (!process || !process.trojanMem) return;
    uint64_t sbClass = ds_remote_class(process, "SpringBoard");
    if (!sbClass) return;
    uint64_t sbApp = ds_remote_get_object_on_main(process, sbClass, "sharedApplication");
    uint64_t o = sbApp ? ds_remote_get_u64_on_main(process, sbApp, "activeInterfaceOrientation") : 0;
    // Diag 1 lần mỗi khi raw đổi (kể cả 0) để biết selector có tồn tại không.
    static uint64_t s_fgDbgRaw = (uint64_t)-1;
    static uint64_t s_fgDbgApp = (uint64_t)-1;
    if (o != s_fgDbgRaw || (sbApp != 0) != (s_fgDbgApp != 0)) {
        s_fgDbgRaw = o;
        s_fgDbgApp = sbApp;
        ESPLog("fgPoll raw=%llu sbApp=%s", (unsigned long long)o, sbApp ? "ok" : "nil");
    }
    if (o >= (uint64_t)UIInterfaceOrientationPortrait &&
        o <= (uint64_t)UIInterfaceOrientationLandscapeRight) {
        g_foregroundOrientation.store((int)o);
    }
}

static uint64_t ds_remote_font(RemoteCall *process, CGFloat size, BOOL medium) {
    uint64_t fontClass = ds_remote_class(process, "UIFont");
    if (!fontClass) return 0;
    double pointSize = size;
    double weight = medium ? UIFontWeightMedium : UIFontWeightRegular;
    DSRemoteArgument arguments[] = {
        { &pointSize, sizeof(pointSize) },
        { &weight, sizeof(weight) },
    };
    return ds_remote_get_retained_object_on_main(
        process, fontClass, "monospacedDigitSystemFontOfSize:weight:",
        arguments, 2);
}

static uint64_t ds_remote_secure_canvas(RemoteCall *process, uint64_t textField) {
    uint64_t canvasClass = ds_remote_class(process, "_UITextLayoutCanvasView");
    uint64_t subviews = ds_remote_get_retained_object_on_main(
        process, textField, "subviews", NULL, 0);
    if (!canvasClass || !subviews) return 0;

    uint64_t count = ds_remote_get_u64_on_main(process, subviews, "count");
    count = MIN(count, 16);
    for (uint64_t index = 0; index < count; index++) {
        DSRemoteArgument argument = { &index, sizeof(index) };
        uint64_t view = 0;
        if (!ds_remote_invoke_on_main_result(
                process, subviews, ds_remote_sel(process, "objectAtIndex:"),
                &argument, 1, &view, sizeof(view)) || !view) {
            continue;
        }
        uint64_t viewClass = ds_remote_get_object_on_main(process, view, "class");
        if (viewClass == canvasClass) return view;
    }
    return 0;
}

static BOOL ds_apply_snapshot_container(RemoteCall *process, BOOL hideAtSnapshot) {
    if (!process || !g_remoteWindow || !g_remoteContainer) return NO;
    BOOL canHide = g_remoteSecureField && g_remoteSecureCanvas;
    BOOL shouldHide = hideAtSnapshot && canHide;
    if (g_remoteSecureField) {
        ds_remote_set_u64_on_main(process, g_remoteSecureField,
                                  "setSecureTextEntry:", shouldHide ? 1 : 0);
    }
    uint64_t parent = shouldHide ? g_remoteSecureCanvas : g_remoteWindow;
    ds_perform_on_springboard_main(process, parent,
                                   ds_remote_sel(process, "addSubview:"),
                                   g_remoteContainer, YES);
    g_lastHideAtSnapshot = hideAtSnapshot;
    if (hideAtSnapshot && !canHide) {
        ds_append_checkpoint(ds_localized(@"Screenshot-hiding container unavailable; using normal display"));
    }
    return !hideAtSnapshot || canHide;
}

// The HUD lives in its own UIWindow anchored to SBMainWorkspace.mainWindowScene
// Adding to whatever keyWindow we can find is
// unreliable — that window may be hidden, tiny, or off-screen.
static uint64_t ds_create_springboard_hud(RemoteCall *process) {
    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    NSString *text = ds_display_text(preferences, probe.centered, YES, 0, 0);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);

    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t workspaceClass = ds_remote_class(process, "SBMainWorkspace");
    uint64_t windowClass = ds_remote_class(process, "UIWindow");
    uint64_t viewClass = ds_remote_class(process, "UIView");
    uint64_t labelClass = ds_remote_class(process, "UILabel");
    uint64_t textFieldClass = ds_remote_class(process, "UITextField");
    uint64_t colorClass = ds_remote_class(process, "UIColor");
    if (!workspaceClass || !windowClass || !viewClass ||
        !labelClass || !textFieldClass || !colorClass) return 0;

    uint64_t workspace = ds_remote_get_object_on_main(
        process, workspaceClass, "sharedInstance");
    uint64_t scene = workspace
        ? ds_remote_get_object_on_main(process, workspace, "mainWindowScene")
        : 0;
    if (!scene) return 0;

    uint64_t window = remote_msg(process, windowClass, alloc, 0, 0, 0, 0);
    uint64_t container = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    uint64_t label = remote_msg(process, labelClass, alloc, 0, 0, 0, 0);
    uint64_t secureField = remote_msg(process, textFieldClass, alloc, 0, 0, 0, 0);
    // Safety renderer: keep the SpringBoard hierarchy to plain UIKit objects.
    // UIVisualEffectView/CABackdropLayer is intentionally not used here because
    // it starts extra render-server work immediately after RemoteCall setup.
    uint64_t blurView = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    if (!window || !container || !label || !secureField || !blurView) return 0;
    if (!ds_remote_invoke_noarg_on_main(process, window, "init") ||
        !ds_remote_invoke_noarg_on_main(process, container, "init") ||
        !ds_remote_invoke_noarg_on_main(process, label, "init") ||
        !ds_remote_invoke_noarg_on_main(process, secureField, "init") ||
        !ds_remote_invoke_noarg_on_main(process, blurView, "init")) {
        return 0;
    }

    ds_remote_set_rect_on_main(process, window, "setFrame:", presentation.windowFrame);
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setWindowScene:"), scene, YES);
    // Match the original hosted HUD. Status-bar level is below SpringBoard's
    // CoverSheet, so it disappears as soon as the device enters the lock UI.
    ds_remote_set_double_on_main(process, window, "setWindowLevel:", kDSHUDWindowLevel);
    ds_remote_set_u64_on_main(process, window, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, window, "setOpaque:", 0);

    ds_remote_set_rect_on_main(process, container, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, blurView, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, label, "setFrame:", presentation.labelFrame);
    ds_remote_set_rect_on_main(process, secureField, "setFrame:", presentation.blurFrame);

    uint64_t clear = ds_remote_get_object_on_main(process, colorClass, "clearColor");
    uint64_t white = ds_remote_get_object_on_main(process, colorClass, "whiteColor");
    uint64_t black = ds_remote_get_object_on_main(process, colorClass, "blackColor");
    // Do not pass autoreleased factory results across separate main-thread
    // performSelector turns. The prior colorWithWhite:alpha: result was already
    // dead by setBackgroundColor:, producing SIGBUS in object_getClass.
    uint64_t safeBackground = ds_remote_get_object_on_main(
        process, colorClass, "darkGrayColor");
    if (!clear || !white || !black || !safeBackground) return 0;

    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, secureField,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "setBackgroundColor:"),
                                   presentation.inverted ? white : safeBackground, YES);
    ds_remote_set_u64_on_main(process, container, "setTag:", (uint64_t)kDSSpringBoardHUDTag);
    ds_remote_set_u64_on_main(process, container, "setHidden:", 0);
    ds_remote_set_u64_on_main(process, container, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, container, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, blurView, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, secureField, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, secureField, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, secureField, "setOpaque:", 0);
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setTextColor:"),
                                   presentation.inverted ? black : white, YES);
    ds_remote_set_u64_on_main(process, label, "setNumberOfLines:",
                              (uint64_t)presentation.numberOfLines);
    ds_remote_set_u64_on_main(process, label, "setHidden:", 0);
    uint64_t font = ds_remote_font(process, presentation.fontSize,
                                   presentation.inverted);
    if (!font) return 0;
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setFont:"), font, YES);
    ds_remote_set_u64_on_main(process, label, "setAdjustsFontSizeToFitWidth:", 0);
    ds_remote_set_u64_on_main(process, label, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, label, "setTextAlignment:",
                              (uint64_t)presentation.alignment);
    ds_remote_set_double_on_main(process, label, "setAlpha:", 0.85);

    uint64_t layer = ds_remote_get_object_on_main(process, blurView, "layer");
    if (layer) {
        ds_remote_set_double_on_main(process, layer, "setCornerRadius:",
                                     presentation.cornerRadius);
        ds_remote_set_u64_on_main(process, layer, "setMasksToBounds:", 1);
        ds_remote_set_u64_on_main(process, layer, "setMaskedCorners:",
                                  (uint64_t)presentation.maskedCorners);
    }
    ds_remote_set_double_on_main(process, container, "setAlpha:", 1.0);

    if (!process.trojanMem) return 0;
    if (!ds_remote_set_text_on_main(process, label, text)) return 0;
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "addSubview:"), label, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "addSubview:"), blurView, YES);
    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "addSubview:"), secureField, YES);

    g_remoteWindow = window;
    g_remoteContainer = container;
    g_remoteSecureField = secureField;
    g_remoteSecureCanvas = ds_remote_secure_canvas(process, secureField);
    ds_apply_snapshot_container(process, presentation.hideAtSnapshot);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);

    g_remoteWindowScene = scene;
    g_remoteWindowPid = process.pid;
    g_remoteBlurView = blurView;
    g_remoteBlurEffect = 0;
    g_lastPresentationSignature = preferences.description.hash ^
                                  (NSUInteger)ds_interface_orientation();
    g_lastWindowFrame = presentation.windowFrame;
    g_lastLabelFrame = presentation.labelFrame;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = 1.0;
    g_lastFontSize = presentation.fontSize;
    g_lastInverted = presentation.inverted;
    g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
    return label;
}

// Never release remote UIViews: dealloc on a hijacked thread crashes SpringBoard
// (same CA main-thread assert). removeFromSuperview + hide, and intentionally
// leak the tiny view hierarchy for the lifetime of the remote session.
static const NSInteger kDSESPOverlayTag = 0x45535042; // "ESPB"
static const double kDSESPWindowLevel = kDSHUDWindowLevel - 10.0;
static const CGFloat kDSESPBorder = 2.0;

static void ds_esp_overlay_hide(RemoteCall *process) {
    if (!process || !g_espWindow) return;
    if (!g_espWindowHiddenCache) {
        ds_remote_set_u64_on_main(process, g_espWindow, "setHidden:", 1);
        g_espWindowHiddenCache = YES;
    }
}

static BOOL ds_esp_overlay_ensure(RemoteCall *process, CGRect portraitBounds) {
    if (!process || !process.trojanMem) return NO;
    if (g_espWindow && g_espContainer) {
        BOOL ok = YES;
        for (int i = 0; i < ESPOverlayMaxBoxes && ok; i++) {
            for (int e = 0; e < 4 && ok; e++) ok = g_espBorders[i][e] != 0;
            ok = ok && g_espLabels[i] != 0;
        }
        if (ok) return YES;
    }
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t workspaceClass = ds_remote_class(process, "SBMainWorkspace");
    uint64_t windowClass = ds_remote_class(process, "UIWindow");
    uint64_t viewClass = ds_remote_class(process, "UIView");
    uint64_t labelClass = ds_remote_class(process, "UILabel");
    uint64_t colorClass = ds_remote_class(process, "UIColor");
    if (!workspaceClass || !windowClass || !viewClass || !labelClass || !colorClass) return NO;

    uint64_t workspace = ds_remote_get_object_on_main(process, workspaceClass, "sharedInstance");
    uint64_t scene = workspace ? ds_remote_get_object_on_main(process, workspace, "mainWindowScene") : g_remoteWindowScene;
    if (!scene) return NO;

    uint64_t window = remote_msg(process, windowClass, alloc, 0, 0, 0, 0);
    uint64_t container = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    if (!window || !container) return NO;
    if (!ds_remote_invoke_noarg_on_main(process, window, "init") ||
        !ds_remote_invoke_noarg_on_main(process, container, "init")) return NO;

    ds_remote_set_rect_on_main(process, window, "setFrame:", portraitBounds);
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setWindowScene:"), scene, YES);
    ds_remote_set_double_on_main(process, window, "setWindowLevel:", kDSESPWindowLevel);
    ds_remote_set_u64_on_main(process, window, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, window, "setOpaque:", 0);
    uint64_t clear = ds_remote_get_object_on_main(process, colorClass, "clearColor");
    uint64_t red = ds_remote_get_object_on_main(process, colorClass, "redColor");
    uint64_t white = ds_remote_get_object_on_main(process, colorClass, "whiteColor");
    if (!clear || !red || !white) return NO;
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_remote_set_u64_on_main(process, container, "setTag:", (uint64_t)kDSESPOverlayTag);
    ds_remote_set_u64_on_main(process, container, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, container, "setHidden:", 0);
    ds_remote_set_rect_on_main(process, container, "setFrame:", portraitBounds);

    uint64_t font = ds_remote_font(process, 9.0, NO);
    if (!font) return NO;

    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        for (int e = 0; e < 4; e++) {
            uint64_t v = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
            if (!v || !ds_remote_invoke_noarg_on_main(process, v, "init")) return NO;
            ds_perform_on_springboard_main(process, v, ds_remote_sel(process, "setBackgroundColor:"), red, YES);
            ds_remote_set_u64_on_main(process, v, "setHidden:", 1);
            ds_remote_set_u64_on_main(process, v, "setUserInteractionEnabled:", 0);
            ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "addSubview:"), v, YES);
            g_espBorders[i][e] = v;
        }
        uint64_t lb = remote_msg(process, labelClass, alloc, 0, 0, 0, 0);
        if (!lb || !ds_remote_invoke_noarg_on_main(process, lb, "init")) return NO;
        ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setTextColor:"), white, YES);
        ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
        ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setFont:"), font, YES);
        ds_remote_set_u64_on_main(process, lb, "setTextAlignment:", 1);
        ds_remote_set_u64_on_main(process, lb, "setNumberOfLines:", 1);
        ds_remote_set_u64_on_main(process, lb, "setHidden:", 1);
        ds_remote_set_u64_on_main(process, lb, "setUserInteractionEnabled:", 0);
        ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "addSubview:"), lb, YES);
        g_espLabels[i] = lb;
        g_espHiddenCache[i] = YES;
    }

    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "addSubview:"), container, YES);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);
    g_espWindow = window;
    g_espContainer = container;
    g_espWindowHiddenCache = NO;
    g_espLastContainerBounds = CGRectZero;
    return YES;
}

static void ds_esp_overlay_update(RemoteCall *process, ESPBox2D *boxes, int count,
                                  CGRect portraitBounds, int orientation) {
    if (!process || !process.trojanMem) return;
    if (!g_espWindow || !g_espContainer) {
        if (!ds_esp_overlay_ensure(process, portraitBounds)) return;
    }
    // Show/hide window
    BOOL wantHidden = (count <= 0);
    if (wantHidden != g_espWindowHiddenCache) {
        ds_remote_set_u64_on_main(process, g_espWindow, "setHidden:", wantHidden ? 1 : 0);
        g_espWindowHiddenCache = wantHidden;
    }
    if (wantHidden) {
        // Hide stale boxes once
        for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
            if (!g_espHiddenCache[i]) {
                for (int e = 0; e < 4; e++) ds_remote_set_u64_on_main(process, g_espBorders[i][e], "setHidden:", 1);
                ds_remote_set_u64_on_main(process, g_espLabels[i], "setHidden:", 1);
                g_espHiddenCache[i] = YES;
            }
        }
        return;
    }
    // Game PUBG luôn render landscape: W = cạnh dài, H = cạnh ngắn — KHÔNG suy
    // từ orientation (SpringBoard scene kẹt portrait). Phải khớp EXACT với
    // landW/H dùng trong W2S ở ds_esp_tick, không thì box lệch/hụt.
    CGFloat landW = MAX(portraitBounds.size.width, portraitBounds.size.height);
    CGFloat landH = MIN(portraitBounds.size.width, portraitBounds.size.height);
    CGPoint winCenter = CGPointMake(CGRectGetMidX(portraitBounds), CGRectGetMidY(portraitBounds));
    // Container: full portrait, KHÔNG xoay — remote setTransform: không có tác
    // dụng trên SpringBoard (log orient=3 nhưng box vẫn ra dải dọc). Thay vào
    // đó xoay TỌA ĐỘ từng box sang hệ portrait-window ngay tại đây
    // (ds_esp_map_rect, công thức đã verify bằng vector).
    if (!CGRectEqualToRect(g_espLastContainerBounds, portraitBounds)) {
        ds_remote_set_rect_on_main(process, g_espContainer, "setFrame:", portraitBounds);
        g_espLastContainerBounds = portraitBounds;
    }
    int n = MIN(count, ESPOverlayMaxBoxes);
    // Cache frame/text từng box: ở 8Hz, cảnh đứng yên thì skip hết remote
    // call (mỗi setFrame là 1 vòng IPC sang SpringBoard main). Chỉ gửi khi
    // rect lệch > 0.5pt hoặc text khoảng cách đổi.
    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        BOOL hide = (i >= n);
        if (hide != g_espHiddenCache[i]) {
            for (int e = 0; e < 4; e++) ds_remote_set_u64_on_main(process, g_espBorders[i][e], "setHidden:", hide ? 1 : 0);
            ds_remote_set_u64_on_main(process, g_espLabels[i], "setHidden:", hide ? 1 : 0);
            g_espHiddenCache[i] = hide;
        }
        if (hide) { g_espRectValid[i] = NO; continue; }
        ESPBox2D b = boxes[i];
        // Clamp nhẹ để không vẽ rác ngoài container
        if (b.w < 4 || b.h < 8) { g_espRectValid[i] = NO; continue; }
        CGRect top = ds_esp_map_rect(CGRectMake(b.x, b.y, b.w, kDSESPBorder), landW, landH, winCenter, orientation);
        CGRect bottom = ds_esp_map_rect(CGRectMake(b.x, b.y + b.h - kDSESPBorder, b.w, kDSESPBorder), landW, landH, winCenter, orientation);
        CGRect left = ds_esp_map_rect(CGRectMake(b.x, b.y, kDSESPBorder, b.h), landW, landH, winCenter, orientation);
        CGRect right = ds_esp_map_rect(CGRectMake(b.x + b.w - kDSESPBorder, b.y, kDSESPBorder, b.h), landW, landH, winCenter, orientation);
        // Label mét LUÔN vẽ ngang theo mép trên của box ĐÃ MAP: nếu xoay cả
        // rect label (dẹt ngang) theo ±90° nó thành dải dọc 14pt, chữ bị cắt
        // mất. Tính anchor top-center ở hệ game rồi map điểm, dựng rect ngang.
        CGPoint anchor = ds_esp_map_point(CGPointMake(b.x + b.w * 0.5, b.y),
                                          landW, landH, winCenter, orientation);
        CGFloat mappedW = fabs(CGRectGetMaxX(right) - CGRectGetMinX(left));
        if (!(mappedW >= 4)) mappedW = b.w; // fallback portrait/edge
        CGRect lf = CGRectMake(anchor.x - (mappedW + 40.0) * 0.5, anchor.y - 16.0,
                               mappedW + 40.0, 14.0);
        char distTxt[16] = {0};
        snprintf(distTxt, sizeof(distTxt), "%.0fm", b.distance);
        CGRect want[5] = { top, bottom, left, right, lf };
        BOOL same = g_espRectValid[i] && strcmp(g_espLastDist[i], distTxt) == 0;
        for (int e = 0; same && e < 5; e++) {
            CGRect o = g_espLastRect[i][e], w = want[e];
            if (fabs(o.origin.x - w.origin.x) > 0.5 || fabs(o.origin.y - w.origin.y) > 0.5 ||
                fabs(o.size.width - w.size.width) > 0.5 || fabs(o.size.height - w.size.height) > 0.5) {
                same = NO;
            }
        }
        if (same) continue; // đứng yên: 0 remote call
        ds_remote_set_rect_on_main(process, g_espBorders[i][0], "setFrame:", top);
        ds_remote_set_rect_on_main(process, g_espBorders[i][1], "setFrame:", bottom);
        ds_remote_set_rect_on_main(process, g_espBorders[i][2], "setFrame:", left);
        ds_remote_set_rect_on_main(process, g_espBorders[i][3], "setFrame:", right);
        NSString *dist = [NSString stringWithFormat:@"%.0fm", b.distance];
        ds_remote_set_text_on_main(process, g_espLabels[i], dist);
        ds_remote_set_rect_on_main(process, g_espLabels[i], "setFrame:", lf);
        for (int e = 0; e < 5; e++) g_espLastRect[i][e] = want[e];
        snprintf(g_espLastDist[i], sizeof(g_espLastDist[i]), "%s", distTxt);
        g_espRectValid[i] = YES;
    }
}

static void ds_remove_springboard_hud(RemoteCall *process) {
    if (!g_remoteWindow || g_remoteWindowPid != process.pid) return;
    if (g_remoteContainer) {
        ds_perform_on_springboard_main(process, g_remoteContainer,
                                       ds_remote_sel(process, "removeFromSuperview"), 0, YES);
    }
    ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", 1);
}

static BOOL ds_apply_remote_presentation(RemoteCall *process,
                                         const DSHUDPresentation *presentation,
                                         NSString *text,
                                         BOOL focused,
                                         BOOL applyStyle) {
    if (!process || !presentation || !g_remoteWindow || !g_remoteContainer ||
        !g_remoteBlurView || !g_remoteLabel) {
        return NO;
    }

    if (!CGRectEqualToRect(g_lastWindowFrame, presentation->windowFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteWindow, "setFrame:",
                                   presentation->windowFrame);
        ds_remote_set_rect_on_main(process, g_remoteContainer, "setFrame:",
                                   presentation->blurFrame);
        ds_remote_set_rect_on_main(process, g_remoteBlurView, "setFrame:",
                                   presentation->blurFrame);
        if (g_remoteSecureField) {
            ds_remote_set_rect_on_main(process, g_remoteSecureField, "setFrame:",
                                       presentation->blurFrame);
        }
        g_lastWindowFrame = presentation->windowFrame;
    }
    if (!CGRectEqualToRect(g_lastLabelFrame, presentation->labelFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteLabel, "setFrame:",
                                   presentation->labelFrame);
        g_lastLabelFrame = presentation->labelFrame;
    }

    BOOL hideForLandscape = presentation->landscape && !presentation->followsRotation;
    BOOL shouldHide = hideForLandscape;
    if (shouldHide != g_lastWindowHidden) {
        ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", shouldHide ? 1 : 0);
        g_lastWindowHidden = shouldHide;
    }
    if (applyStyle) {
        ds_remote_set_u64_on_main(process, g_remoteLabel, "setNumberOfLines:",
                                  (uint64_t)presentation->numberOfLines);
        ds_remote_set_u64_on_main(process, g_remoteLabel, "setTextAlignment:",
                                  (uint64_t)presentation->alignment);

        uint64_t colorClass = ds_remote_class(process, "UIColor");
        uint64_t white = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "whiteColor") : 0;
        uint64_t black = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "blackColor") : 0;
        uint64_t darkGray = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "darkGrayColor") : 0;
        uint64_t textColor = presentation->inverted ? black : white;
        uint64_t backgroundColor = presentation->inverted ? white : darkGray;
        if (textColor && backgroundColor) {
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setTextColor:"), textColor, YES);
            ds_perform_on_springboard_main(process, g_remoteBlurView,
                                           ds_remote_sel(process, "setBackgroundColor:"),
                                           backgroundColor, YES);
        }

        if (fabs(g_lastFontSize - presentation->fontSize) > 0.001 ||
            g_lastInverted != presentation->inverted) {
            uint64_t font = ds_remote_font(process, presentation->fontSize,
                                           presentation->inverted);
            if (!font) return NO;
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setFont:"), font, YES);
            g_lastFontSize = presentation->fontSize;
            g_lastInverted = presentation->inverted;
        }

        uint64_t layer = ds_remote_get_object_on_main(process, g_remoteBlurView, "layer");
        if (layer) {
            ds_remote_set_double_on_main(process, layer, "setCornerRadius:",
                                         presentation->cornerRadius);
            ds_remote_set_u64_on_main(process, layer, "setMaskedCorners:",
                                      (uint64_t)presentation->maskedCorners);
        }

        if (g_lastHideAtSnapshot != presentation->hideAtSnapshot) {
            ds_apply_snapshot_container(process, presentation->hideAtSnapshot);
        }
    }
    CGFloat alpha = focused ? 1.0 : presentation->inactiveOpacity;
    if (fabs(g_lastContainerAlpha - alpha) > 0.001) {
        ds_remote_set_double_on_main(process, g_remoteContainer, "setAlpha:", alpha);
        g_lastContainerAlpha = alpha;
    }

    if (!process.trojanMem) return NO;
    return ds_remote_set_text_on_main(process, g_remoteLabel, text);
}

static void ds_update_rate(void) {
    if (!g_hudRequested.load() || !g_hudActive.load() || !g_springBoard || !g_remoteLabel) return;

    uint64_t input = 0;
    uint64_t output = 0;
    ds_read_network_bytes(&input, &output);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double interval = g_previousSampleTime > 0 ? MAX(now - g_previousSampleTime, 0.1) : 1.0;
    double down = g_previousSampleTime > 0 && input >= g_previousInput ? (input - g_previousInput) / interval : 0;
    double up = g_previousSampleTime > 0 && output >= g_previousOutput ? (output - g_previousOutput) / interval : 0;
    g_previousInput = input;
    g_previousOutput = output;
    g_previousSampleTime = now;

    if (g_remoteWindowScene) {
        uint64_t orientation = ds_remote_get_u64_on_main(
            g_springBoard, g_remoteWindowScene, "interfaceOrientation");
        if (orientation <= UIInterfaceOrientationLandscapeRight) {
            g_remoteOrientation.store((int)orientation);
        }
        // Orientation foreground (game) cho ESP overlay — scene của SpringBoard
        // kẹt portrait nên phải hỏi riêng activeInterfaceOrientation.
        ds_poll_foreground_orientation(g_springBoard);
    }

    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    BOOL focused = now < g_focusUntil;
    NSString *text = ds_display_text(
        preferences, probe.centered, focused,
        focused ? (double)input : down,
        focused ? (double)output : up);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);
    NSUInteger presentationSignature = preferences.description.hash ^
                                       (NSUInteger)ds_interface_orientation();
    BOOL applyStyle = presentationSignature != g_lastPresentationSignature;

    @try {
        if (!ds_apply_remote_presentation(
                g_springBoard, &presentation, text, focused, applyStyle)) {
            @throw [NSException exceptionWithName:@"DSRemoteHUDUpdate"
                                           reason:@"remote presentation update failed"
                                         userInfo:nil];
        }
        g_lastPresentationSignature = presentationSignature;
    } @catch (NSException *exception) {
        ds_set_error([NSString stringWithFormat:@"SpringBoard HUD update failed: %@", exception.reason]);
        g_hudActive.store(false);
    }

    // ESP overlay chạy timer RIÊNG 8Hz (ds_esp_tick) để box mượt — timer HUD
    // này giữ 1Hz cho text. Xem ds_esp_tick bên dưới.
}

// Tag build cho ESP overlay — ĐỔI mỗi lần sửa đường vẽ để log cho biết user
// đang chạy bản nào (box tick in kèm tag).
#define DS_ESP_BUILD_TAG "lbl1"

// Mẫu refresh để nội suy (chỉ chạm từ worker queue).
typedef struct {
    ESPBox2D boxes[ESPOverlayMaxBoxes];
    int count;
    uint64_t gen;      // thế hệ tracked (đổi -> snap, không lerp)
    CFAbsoluteTime t;
    CGRect bounds;
    int orient;
} DSESPSample;
static DSESPSample s_prev = {0}; // mẫu cũ (valid khi count > 0)
static DSESPSample s_tgt = {0};  // mẫu mới (đích nội suy)
static CFAbsoluteTime s_lastPresentedT = 0; // tgt.t đã present tới đích

// ESP Box thật trên SpringBoard (RemoteCall) 8Hz: chỉ chạy khi toggle ESP Box
// ON. Vị trí refresh ESP_REFRESH_HZ lần/giây bằng ESPEngineRefreshBoxes (rẻ),
// lượt quét đầy đủ vẫn theo TTL riêng của engine. Remote call được cache:
// setHidden chỉ khi đổi trạng thái, setFrame/setText chỉ khi rect/text đổi
// (xem ds_esp_overlay_update) nên tick đứng yên tốn ~0 call.
//
// Kernel read mỗi refresh ~125ms (đo thực tế) nên refresh chạy trên WORKER
// QUEUE RIÊNG — trước đây chạy chung bridge queue serial làm nghẽn cả HUD
// text. Worker chỉ đọc memory rồi async sang bridge để IPC (nhanh).
static dispatch_queue_t ds_esp_work_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huami.darkspeed.esp-tick", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

typedef struct {
    ESPBox2D boxes[ESPOverlayMaxBoxes];
    int count;
    CGRect bounds;
    int orient;
} DSESPFrame;

static std::atomic_bool s_espBusy{false}; // refresh trước chưa xong thì skip tick
static BOOL s_espHideSent = NO; // đã gửi hide lên bridge (tránh spam async), chỉ chạm từ worker

// Present lên SpringBoard — CHẠY TRÊN BRIDGE QUEUE (RemoteCall không thread-safe).
static void ds_esp_present(DSESPFrame *frame) {
    if (!frame) return;
    @try {
        if (frame->count < 0) {
            // Lệnh hide từ worker.
            if (g_espWindow) ds_esp_overlay_hide(g_springBoard);
        } else {
            if ((!g_espWindow || !g_espContainer) &&
                !ds_esp_overlay_ensure(g_springBoard, frame->bounds)) {
                // Ensure fail đã log bên worker, bỏ tick này.
            } else {
                ds_esp_overlay_update(g_springBoard, frame->boxes, frame->count,
                                      frame->bounds, frame->orient);
            }
        }
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP present failed: %{public}@", exception.reason);
    }
    free(frame);
}

static void ds_esp_tick(void) {
    if (!g_hudRequested.load() || !g_hudActive.load() || !g_springBoard) return;
    NSDictionary *preferences = nil;
    @try { preferences = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    if (!preferences) preferences = @{};
    if (!ds_show_esp_from_prefs(preferences) || !g_gameBase) {
        if (!s_espHideSent) {
            s_espHideSent = YES;
            s_prev.count = 0;
            s_tgt.count = 0;
            dispatch_async(ds_bridge_queue(), ^{
                if (g_espWindow) ds_esp_overlay_hide(g_springBoard);
            });
        }
        return;
    }
    s_espHideSent = NO;
    // Chống overlap: refresh trước chậm hơn interval thì bỏ tick này (không
    // dồn queue, không present sai thứ tự).
    bool expected = false;
    if (!s_espBusy.compare_exchange_strong(expected, true)) return;
    @try {
        CGRect sbBounds = CGRectZero;
        ds_screen_geometry(&sbBounds, NULL);
        if (CGRectIsNull(sbBounds) || sbBounds.size.width <= 0) {
            s_espBusy.store(false);
            return;
        }
        static ESPBox2D s_boxes[ESPOverlayMaxBoxes];
        static CFAbsoluteTime s_lastRefresh = 0;
        // GIỮ count qua các tick bị throttle để overlay không hide oan.
        static int s_lastCount = 0;
        static BOOL s_zeroHidden = NO; // đã gửi hide cho đợt count=0 hiện tại
        static CFAbsoluteTime s_lastZeroLog = 0;
        static CFAbsoluteTime s_lastEnsureFailLog = 0;
        static CFAbsoluteTime s_lastPerfLog = 0;
        static BOOL s_espBoxLogged = NO;
        CFAbsoluteTime now2 = CFAbsoluteTimeGetCurrent();
        int orient = ds_esp_game_orientation();
        double minInterval = 1.0 / (double)ESP_REFRESH_HZ;
        // Khai báo ngoài if throttle: block snap/lerp bên dưới dùng cả khi
        // tick này không refresh (giữ mẫu cũ để present timer nội suy tiếp).
        uint64_t gen = 0;
        int count = 0;
        BOOL didRefresh = NO;
        if (now2 - s_lastRefresh >= minInterval) {
            s_lastRefresh = now2;
            didRefresh = YES;
            // Game landscape: W = cạnh dài (khớp với overlay update).
            float landW = (float)MAX(CGRectGetWidth(sbBounds), CGRectGetHeight(sbBounds));
            float landH = (float)MIN(CGRectGetWidth(sbBounds), CGRectGetHeight(sbBounds));
            gen = 0;
            count = ESPEngineRefreshBoxes(g_gameBase, landW, landH,
                                          s_boxes, ESPOverlayMaxBoxes, &gen);
            int fromFull = 0;
            if (count == 0) {
                // Chưa có tracked actor (mới vào trận / lượt quét đầu):
                // dùng đường đầy đủ để khởi tạo danh sách theo dõi.
                count = ESPEngineBoxes(g_gameBase, landW, landH,
                                       s_boxes, ESPOverlayMaxBoxes);
                if (count > 0) {
                    fromFull = 1;
                    gen = ESPEngineTrackedGen();
                }
            }
            s_lastCount = count;
            ESPBoxCounterSet(count);
            // Log 1 lần mỗi khi bật để biết kẹt ở đâu (xem ESP.log).
            if (!s_espBoxLogged) {
                s_espBoxLogged = YES;
                ESPLog("box tick: %s count=%d orient=%d fg=%d dev=%ld sb=%.0fx%.0f land=%.0fx%.0f %s",
                       DS_ESP_BUILD_TAG,
                       count, orient, g_foregroundOrientation.load(),
                       (long)UIDevice.currentDevice.orientation,
                       (double)CGRectGetWidth(sbBounds),
                       (double)CGRectGetHeight(sbBounds),
                       (double)landW, (double)landH,
                       ESPEngineLastBoxDiag());
            }
                    // B=0 dai dẳng mà P>0: log diag pipeline 10s/lần để biết gãy
                    // ở camera (camFail) / vị trí (pos) / project (w2s) / size (h).
                    if (count == 0 && now2 - s_lastZeroLog > 10.0) {
                        s_lastZeroLog = now2;
                        ESPLog("box tick0: %s orient=%d fg=%d dev=%ld land=%.0fx%.0f",
                               ESPEngineLastBoxDiag(), orient, g_foregroundOrientation.load(),
                               (long)UIDevice.currentDevice.orientation,
                               (double)landW, (double)landH);
                    }
                    // Perf refresh 10s/lần (luôn): biết lag có phải do kernel
                    // read chậm không (avg/max ms mỗi lần refresh).
                    if (now2 - s_lastPerfLog > 10.0) {
                        s_lastPerfLog = now2;
                        ESPLog("box perf: %s count=%d", ESPEngineBoxPerfText(), count);
                    }
        }
        // Snap hay nội suy: cùng gen + cùng count + cùng orient mới lerp theo
        // index được (tracked order ổn định); còn lại snap present ngay.
        // Chỉ xử lý khi tick này CÓ refresh (didRefresh) — tick throttle giữ
        // nguyên mẫu cũ để present timer nội suy tiếp, không hide oan.
        if (didRefresh && count > 0) {
            s_zeroHidden = NO;
            if (s_prev.count == count && s_prev.gen == gen && gen != 0 &&
                s_prev.orient == orient) {
                // Đích nội suy cho present timer 12Hz (không present ở đây).
                memcpy(s_tgt.boxes, s_boxes, sizeof(s_boxes));
                s_tgt.count = count;
                s_tgt.gen = gen;
                s_tgt.t = now2;
                s_tgt.bounds = sbBounds;
                s_tgt.orient = orient;
            } else {
                DSESPFrame *frame = (DSESPFrame *)malloc(sizeof(DSESPFrame));
                if (frame) {
                    memcpy(frame->boxes, s_boxes, sizeof(s_boxes));
                    frame->count = count;
                    frame->bounds = sbBounds;
                    frame->orient = orient;
                    dispatch_async(ds_bridge_queue(), ^{
                        ds_esp_present(frame);
                    });
                }
                s_lastPresentedT = now2;
                memcpy(s_prev.boxes, s_boxes, sizeof(s_boxes));
                s_prev.count = count;
                s_prev.gen = gen;
                s_prev.t = now2;
                s_prev.bounds = sbBounds;
                s_prev.orient = orient;
                s_tgt = s_prev;
            }
        } else if (didRefresh && !s_zeroHidden && count == 0) {
            // Hết box: hide 1 lần (không spam mỗi tick).
            s_zeroHidden = YES;
            s_prev.count = 0;
            s_tgt.count = 0;
            DSESPFrame *frame = (DSESPFrame *)malloc(sizeof(DSESPFrame));
            if (frame) {
                frame->count = 0;
                frame->bounds = sbBounds;
                frame->orient = orient;
                dispatch_async(ds_bridge_queue(), ^{
                    ds_esp_present(frame);
                });
            }
        }
        // Ensure thử trước trên worker để log fail (ensure là RemoteCall —
        // RemoteCall dùng được từ worker vì mỗi process 1 trojanMem? KHÔNG:
        // RemoteCall IPC serialize qua mach, gọi từ thread nào cũng được miễn
        // không đồng thời 2 threads. Worker là thread duy nhất gọi ensure ở
        // đây; update gọi trên bridge — 2 threads khác nhau! Để an toàn, chỉ
        // LOG ở đây, ensure thật để ds_esp_present lo trên bridge.
        if ((!g_espWindow || !g_espContainer) && now2 - s_lastEnsureFailLog > 10.0) {
            // Chưa có window — present sẽ ensure; log nhắc nếu kéo dài.
            // (Không gọi ensure từ worker để tránh race trojanMem với bridge.)
            s_lastEnsureFailLog = now2;
            ESPLog("box overlay ensure pending orient=%d sb=%.0fx%.0f",
                   orient, (double)CGRectGetWidth(sbBounds),
                   (double)CGRectGetHeight(sbBounds));
        }
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP overlay update failed: %{public}@", exception.reason);
    }
    s_espBusy.store(false);
}

// Present nội suy 12Hz trên worker: lerp từng box từ s_prev tới s_tgt theo
// thời gian rồi async sang bridge. Mắt thấy chuyển động liên tục thay vì nhảy
// nấc theo nhịp refresh (~150ms). Frame cache bên update vẫn dedup IPC khi
// đứng yên. KHÔNG present khi: hết mẫu, khác gen/count/orient (đợi snap),
// hoặc đích đã present xong.
static void ds_esp_present_tick(void) {
    if (!g_hudRequested.load() || !g_hudActive.load() || !g_springBoard) return;
    if (s_tgt.count <= 0 || s_prev.count <= 0) return;
    if (s_tgt.count != s_prev.count || s_tgt.gen != s_prev.gen) return;
    if (s_tgt.orient != s_prev.orient) return;
    if (s_tgt.t <= s_lastPresentedT) return; // đích đã present xong
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double span = s_tgt.t - s_prev.t;
    if (span < 0.01) span = 0.01;
    double a = (now - s_prev.t) / span;
    if (a <= 0) return;
    if (a > 1) a = 1;
    DSESPFrame *frame = (DSESPFrame *)malloc(sizeof(DSESPFrame));
    if (!frame) return;
    for (int i = 0; i < s_tgt.count && i < ESPOverlayMaxBoxes; i++) {
        ESPBox2D p = s_prev.boxes[i], t = s_tgt.boxes[i];
        frame->boxes[i].x = (float)(p.x + (t.x - p.x) * a);
        frame->boxes[i].y = (float)(p.y + (t.y - p.y) * a);
        frame->boxes[i].w = (float)(p.w + (t.w - p.w) * a);
        frame->boxes[i].h = (float)(p.h + (t.h - p.h) * a);
        frame->boxes[i].distance = t.distance;
        frame->boxes[i].health = t.health;
        frame->boxes[i].visible = t.visible;
    }
    frame->count = s_tgt.count;
    frame->bounds = s_tgt.bounds;
    frame->orient = s_tgt.orient;
    if (a >= 1) s_lastPresentedT = s_tgt.t;
    dispatch_async(ds_bridge_queue(), ^{
        ds_esp_present(frame);
    });
}

static void ds_start_esp_timer(void) {
    if (g_espTimer) return;
    // 8Hz cho box mượt (khớp ESP_REFRESH_HZ). Refresh kernel chạy trên worker
    // queue riêng để không nghẽn bridge queue; IPC present vẫn trên bridge.
    const uint64_t interval = NSEC_PER_SEC / 8;
    g_espTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_esp_work_queue());
    dispatch_source_set_timer(g_espTimer,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_espTimer, ^{
        @autoreleasepool {
            ds_esp_tick();
        }
    });
    dispatch_resume(g_espTimer);
    if (!g_espPresentTimer) {
        const uint64_t pinterval = NSEC_PER_SEC / 12;
        g_espPresentTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_esp_work_queue());
        dispatch_source_set_timer(g_espPresentTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, pinterval),
                                  pinterval, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_espPresentTimer, ^{
            @autoreleasepool {
                ds_esp_present_tick();
            }
        });
        dispatch_resume(g_espPresentTimer);
    }
}

static void ds_stop_esp_timer(void) {
    if (g_espPresentTimer) {
        dispatch_source_cancel(g_espPresentTimer);
        g_espPresentTimer = nil;
    }
    if (!g_espTimer) return;
    dispatch_source_cancel(g_espTimer);
    g_espTimer = nil;
}

static void ds_start_rate_timer(void) {
    if (g_rateTimer) return;
    // Bật đo orientation phần cứng cho ESP overlay (ds_esp_game_orientation).
    // Phải gọi trên main thread; async để không block bridge queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    });
    g_previousInput = 0;
    g_previousOutput = 0;
    g_previousSampleTime = 0;
    g_previousDirtyFrameCount = 0;
    g_needsFPSBaselineReset = YES;
    g_rateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_bridge_queue());
    dispatch_source_set_timer(g_rateTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_rateTimer, ^{
        @autoreleasepool {
            ds_update_rate();
        }
    });
    dispatch_resume(g_rateTimer);
    ds_start_esp_timer();
}

static void ds_stop_rate_timer(void) {
    ds_stop_esp_timer();
    if (!g_rateTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIDevice.currentDevice endGeneratingDeviceOrientationNotifications];
    });
    dispatch_source_cancel(g_rateTimer);
    g_rateTimer = nil;
}

static void ds_unregister_hud_notifications(void) {
    if (g_reloadHUDToken >= 0) {
        notify_cancel(g_reloadHUDToken);
        g_reloadHUDToken = -1;
    }
    if (g_lockStateToken >= 0) {
        notify_cancel(g_lockStateToken);
        g_lockStateToken = -1;
    }
}

static void ds_register_hud_notifications(void) {
    ds_unregister_hud_notifications();
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &g_reloadHUDToken,
                             ds_bridge_queue(), ^(int token) {
        (void)token;
        if (!g_hudActive.load()) return;
        NSDictionary *preferences = ds_hud_preferences();
        ds_append_checkpoint([NSString stringWithFormat:
            @"HUD settings refreshed position=%@ size=%@ snapshot=%@",
            preferences[UIInterfaceOrientationIsLandscape(ds_interface_orientation())
                ? HUDUserDefaultsKeySelectedModeLandscape
                : HUDUserDefaultsKeySelectedMode] ?: @"default",
            preferences[HUDUserDefaultsKeyUsesLargeFont] ?: @NO,
            preferences[HUDUserDefaultsKeyHideAtSnapshot] ?: @NO]);
        g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
        g_needsFPSBaselineReset = YES;
        ds_update_rate();
    });

    notify_register_dispatch("com.apple.springboard.lockstate", &g_lockStateToken,
                             ds_bridge_queue(), ^(int token) {
        (void)token;
        mach_port_t port = SBSSpringBoardServerPort();
        if (port == MACH_PORT_NULL) return;
        BOOL locked = NO;
        BOOL passcodeSet = NO;
        SBGetScreenLockStatus(port, &locked, &passcodeSet);
        (void)passcodeSet;
        if (!g_hudActive.load() || !g_springBoard || !g_remoteWindow) return;

        // Keep the SpringBoard-hosted HUD above CoverSheet while locked.
        // Reapply the level during the transition because SpringBoard may
        // reorder its own windows as the lock scene becomes active.
        ds_remote_set_double_on_main(g_springBoard, g_remoteWindow,
                                     "setWindowLevel:", kDSHUDWindowLevel);
        if (!locked) {
            g_previousInput = 0;
            g_previousOutput = 0;
            g_previousSampleTime = 0;
            g_needsFPSBaselineReset = YES;
            g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
        }
        g_lastWindowHidden = YES;
        ds_update_rate();
    });
}

BOOL DSBridgeCompiledIn(void) {
    return YES;
}

BOOL DSBridgeIsReady(void) {
    return g_dsReady.load() && ds_is_ready();
}

BOOL DSBridgeAdoptFromEnvironment(void) {
    int control = ds_env_int("DS_CTRL_FD", ds_env_int("DS_HELPER_CTRL_FD", -1));
    int readWrite = ds_env_int("DS_RW_FD", ds_env_int("DS_HELPER_RW_FD", -1));
    uint64_t kernelBase = ds_env_u64("DS_KBASE");
    if (!kernelBase) kernelBase = ds_env_u64("DS_HELPER_KBASE");
    uint64_t kernelSlide = ds_env_u64("DS_KSLIDE");
    if (!kernelSlide) kernelSlide = ds_env_u64("DS_HELPER_KSLIDE");
    if (control < 0 || readWrite < 0 || !kernelBase) return NO;

    const char *lock = getenv("DS_XPROC_LOCK");
    if (!lock || !lock[0]) lock = getenv("DS_HELPER_DOCS");
    if (lock && lock[0]) {
        NSString *path = @(lock);
        if (![path.pathExtension isEqualToString:@"lock"]) {
            path = [path stringByAppendingPathComponent:@".darksword-krw.lock"];
        }
        ds_set_xproc_lock_path(path.fileSystemRepresentation);
    }

    if (!ds_adopt_krw(control, readWrite, kernelBase, kernelSlide)) {
        ds_set_error(ds_localized(@"Could not adopt the DarkSpeed environment."));
        return NO;
    }

    init_offsets();
    offsets_init();
    install_builtin_kernel_symbol_offsets();
    if (!ds_has_symbol_offsets() && !emergencyfixfunctiontobereplacedlateronquestionmark()) {
        ds_set_error(ds_localized(@"DarkSpeed system data is unavailable."));
        return NO;
    }
    g_dsReady.store(true);
    ds_set_stage(ds_localized(@"DarkSpeed initialization complete"));
    ds_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[DSBridge] adopted DarkSword KRW for SpringBoard HUD");
    return YES;
}

BOOL DSBridgeBootstrap(void) {
    if (DSBridgeIsReady()) return YES;
    if (DSBridgeAdoptFromEnvironment()) return YES;

    ds_set_log_callback(ds_bridge_log);
    ds_set_progress_callback(ds_bridge_progress);
    os_log(OS_LOG_DEFAULT, "[DSBridge] running DarkSword chain off-main-thread");

    // offsets_init() must run BEFORE ds_run() — pe_v1() needs the socket/inpcb
    // offsets to find the corrupted socket. Without this, the search runs with
    // all offsets = 0 and retries forever (stuck at ~50%).
    init_offsets();
    offsets_init();
    // Exact build-scoped symbol offsets must be available before ds_run():
    // its final self-proc lookup already needs kernproc/allproc.
    install_builtin_kernel_symbol_offsets();

    ds_set_stage(ds_localized(@"Initializing DarkSpeed"));
    int result = ds_run();
    if (result != 0 || !ds_is_ready()) {
        ds_set_error([NSString stringWithFormat:ds_localized(@"DarkSpeed initialization failed (%d)"), result]);
        return NO;
    }

    g_dsReady.store(true);
    ds_set_stage(ds_localized(@"DarkSpeed initialization complete"));
    ds_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[DSBridge] DarkSword ready");
    return YES;
}

static void ds_finish_disable(void) {
    ds_set_stage(ds_localized(@"Closing HUD"));
    ds_unregister_hud_notifications();
    ds_stop_rate_timer();
    RemoteCall *process = g_springBoard;
    g_springBoard = nil;
    ESPMemoryFlushPageCache(); // nhả mapping + port của world cũ
    g_hudActive.store(false);
    if (process) {
        @try {
            ds_remove_springboard_hud(process);
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] HUD remove exception: %{public}@", exception.reason);
        }
        @try {
            // Ẩn ESP overlay trước khi huỷ session (views leak có chủ ý như HUD).
            if (g_espWindow) ds_esp_overlay_hide(process);
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP hide exception: %{public}@", exception.reason);
        }
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] destroyRemoteCall exception: %{public}@", exception.reason);
        }
    }
    g_remoteContainer = 0;
    g_remoteBlurView = 0;
    g_remoteBlurEffect = 0;
    g_remoteLabel = 0;
    g_remoteSecureField = 0;
    g_remoteSecureCanvas = 0;
    g_remoteWindow = 0;
    g_remoteWindowScene = 0;
    g_remoteWindowPid = 0;
    g_espWindow = 0;
    g_espContainer = 0;
    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        for (int e = 0; e < 4; e++) g_espBorders[i][e] = 0;
        g_espLabels[i] = 0;
        g_espHiddenCache[i] = YES;
        g_espRectValid[i] = NO;
    }
    g_espWindowHiddenCache = YES;
    g_espLastContainerBounds = CGRectZero;
    g_remoteOrientation.store(UIInterfaceOrientationUnknown);
    g_foregroundOrientation.store(UIInterfaceOrientationUnknown);
    // GIỮ g_espLastLandscape qua disable/enable để orientation không rớt về
    // portrait mỗi lần bật lại HUD giữa trận.
    g_lastPresentationSignature = 0;
    g_lastWindowFrame = CGRectNull;
    g_lastLabelFrame = CGRectNull;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = -1.0;
    g_lastFontSize = -1.0;
    g_lastInverted = NO;
    g_lastHideAtSnapshot = NO;
    ds_reset_remote_symbol_cache();
    ds_stop_keepalive();
    ds_set_stage(ds_localized(@"HUD closed"));
    notify_post(NOTIFY_RELOAD_APP);
    os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard HUD disabled");
}

static void ds_finish_enable(void) {
    if (!g_hudRequested.load()) return;
    g_dsRunning.store(true);
    g_dsProgress.store(0.0);
    ds_set_stage(ds_localized(@"Preparing startup"));
    ds_post_progress();

    if (!ds_start_keepalive()) {
        g_hudRequested.store(false);
        g_dsRunning.store(false);
        ds_post_progress();
        return;
    }

    g_dsProgress.store(0.03);
    ds_set_stage(ds_localized(@"Preparing system data"));
    ds_post_progress();
    if (!ds_wait_for_kernel_prefetch(240.0, YES)) {
        NSString *preparationError = DSBridgeLastError();
        ds_fail_enable(preparationError.length > 0 ? preparationError :
            ds_localized(@"Kernelcache download or parsing failed. Network access may still be pending. Check network access and retry; if it still fails, reinstall over the existing app. Restart the device only as a last resort."));
        return;
    }

    if (!DSBridgeBootstrap() || !g_hudRequested.load()) {
        ds_fail_enable(ds_localized(@"DarkSpeed startup failed. Retry or reinstall over the existing app; restart the device only as a last resort."));
        return;
    }

    g_dsProgress.store(0.96);
    ds_set_stage(ds_localized(@"Locating SpringBoard"));
    ds_post_progress();
    uint64_t sbProc = proc_find_by_name("SpringBoard");
    if (!sbProc) {
        ds_fail_enable(ds_localized(@"SpringBoard is not ready, so the HUD cannot be created. Retry or reinstall over the existing app; restart the device only as a last resort."));
        return;
    }

    @try {
        os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard proc=0x%llx self=0x%llx — starting RemoteCall",
               (unsigned long long)sbProc, (unsigned long long)ds_get_our_proc());
        g_dsProgress.store(0.98);
        ds_set_stage(ds_localized(@"Connecting to SpringBoard"));
        ds_reset_remote_symbol_cache();
        g_springBoard = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
        if (!g_springBoard || !g_springBoard.trojanMem || g_springBoard.pid <= 1) {
            NSString *remoteError = [RemoteCall lastInitError];
            if (remoteError.length == 0 && g_springBoard) remoteError = g_springBoard.lastError;
            if (remoteError.length == 0) remoteError = @"RemoteCall init failed (no detail)";
            ds_append_checkpoint([ds_localized(@"SpringBoard connection failed: ") stringByAppendingString:remoteError]);
            g_springBoard = nil;
            ds_fail_enable([NSString stringWithFormat:
                ds_localized(@"SpringBoard connection failed: %@\nRetry or reinstall over the existing app; restart the device only as a last resort."),
                remoteError]);
            return;
        }

        g_dsProgress.store(0.99);
        ds_set_stage(ds_localized(@"Creating SpringBoard HUD"));
        g_remoteLabel = ds_create_springboard_hud(g_springBoard);
        if (!g_remoteLabel) {
            [g_springBoard destroyRemoteCall];
            g_springBoard = nil;
            ds_fail_enable(ds_localized(@"SpringBoard HUD creation failed. Retry or reinstall over the existing app; restart the device only as a last resort."));
            return;
        }
    } @catch (NSException *exception) {
        g_springBoard = nil;
        ds_fail_enable([NSString stringWithFormat:
            ds_localized(@"SpringBoard HUD exception: %@\nRetry or reinstall over the existing app; restart the device only as a last resort."),
            exception.reason]);
        return;
    }

    g_hudActive.store(true);
    g_dsRunning.store(false);
    g_dsProgress.store(1.0);
    ds_set_stage(ds_localized(@"SpringBoard HUD started"));
    ds_set_error(@"");
    ds_start_rate_timer();
    ds_register_hud_notifications();
    notify_post(NOTIFY_LAUNCHED_HUD);
    ds_post_progress();
    os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard HUD active (SpringBoard pid=%d)", g_springBoard.pid);
}

BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    g_hudRequested.store(enabled);
    dispatch_async(ds_bridge_queue(), ^{
        @autoreleasepool {
            if (enabled) {
                if (!g_hudRequested.load() || g_hudActive.load()) return;
                ds_finish_enable();
            } else {
                ds_finish_disable();
            }
        }
    });
    return YES;
}

BOOL DSBridgeHUDEnabled(void) {
    return g_hudActive.load();
}

double DSBridgeProgress(void) {
    return g_dsProgress.load();
}

BOOL DSBridgeIsRunning(void) {
    return g_dsRunning.load();
}

#else

BOOL DSBridgeCompiledIn(void) { return NO; }
BOOL DSBridgeIsReady(void) { return NO; }
void DSBridgeWarmUpNetworkAndPrefetchKernelCache(void) {}
BOOL DSBridgeAdoptFromEnvironment(void) {
    ds_set_error(ds_localized(@"DarkSpeed is not enabled in this build."));
    return NO;
}
BOOL DSBridgeBootstrap(void) {
    ds_set_error(ds_localized(@"DarkSpeed is not enabled in this build."));
    return NO;
}
BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    (void)enabled;
    return NO;
}
BOOL DSBridgeHUDEnabled(void) { return NO; }
double DSBridgeProgress(void) { return 0.0; }
BOOL DSBridgeIsRunning(void) { return NO; }
uint64_t DSBridgeGameBase(void) { return 0; }
NSString *DSBridgeGameStatus(void) { return @""; }
NSString *DSBridgeGameCachedStatus(void) { return @""; }
NSString *DSBridgeGameProcessName(void) { return @"ShadowTrackerExtra"; }
void DSBridgeRefreshGameBase(void) {}
NSString *DSBridgeESPStatus(void) { return @""; }
NSString *DSBridgeESPCachedStatus(void) { return @""; }
NSString *DSBridgeESPScanInfo(void) { return @"scan sim"; }
uint32_t DSBridgeESPCount(void) { return 0; }

#endif

NSString *DSBridgeLastError(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *error = [g_dsLastError copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    return error;
}

NSString *DSBridgeStage(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *stage = [g_dsStage copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    return [stage isEqualToString:@"Waiting to start"] ? ds_localized(@"Waiting to start") : stage;
}
