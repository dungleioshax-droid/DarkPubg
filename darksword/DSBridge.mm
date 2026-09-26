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
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <algorithm>
#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
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
#import <dlfcn.h>
#import "FBSOrientationObserver.h"
#import "FBSOrientationUpdate.h"
#import "ESPEngine.h"
#import "ESPConfig.h"
#import "ESPOverlay.h"
#import "ESPMemory.h"
#import "ESPProvider.h"
#import "ESPTask.h"
#import "ESPLog.h"

// These vendored headers are plain C/Objective-C. Keep C linkage from this .mm.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// (Forward declarations vmmap*/vmshmem/mach_vm_deallocate đã xoá cùng Kernel Read.)

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
static char g_espLastDist[ESPOverlayMaxBoxes][24];
static BOOL g_espRectValid[ESPOverlayMaxBoxes] = {NO};
static CGRect g_espLastContainerBounds = CGRectZero;
static int g_espLastMapOrient = UIInterfaceOrientationUnknown;

// Batch path layer: 1 CAShapeLayer vẽ MỌI box bằng 1 CGPath dựng trong process
// đích -> ~5 remote call/frame BẤT KỂ số box (thay vì ~2 × N).
static uint64_t g_espPathLayer = 0;      // CAShapeLayer trong process đích
static uint64_t g_espPathObj = 0;        // CGPath đang gắn vào layer (để release)
static uint64_t g_espRectsAddr = 0;      // buffer CGRect[] malloc trong process đích
static int g_espRectsCap = 0;            // số CGRect buffer chứa được
static BOOL g_espPathDisabled = YES;      // TẮT CAShapeLayer batching để bisect respring: per-box views ổn định đã chạy 21s ở bản orientfix1
static unsigned long g_espPathCalls = 0;
static unsigned long g_espPathBoxes = 0;
static unsigned long g_espPathFails = 0;
// Label mét: vị trí chỉ cập nhật ở ESP_OVERLAY_LABEL_HZ (chữ lệch vài chục ms
// không thấy được, còn 1 setCenter/box/frame là phần lớn IPC còn lại).
static CGPoint g_espLastLabelCenter[ESPOverlayMaxBoxes];
static CFAbsoluteTime g_espLastLabelAt[ESPOverlayMaxBoxes] = {0};
static dispatch_source_t g_rateTimer = nil;
// Timer riêng cho ESP overlay 20Hz (box mượt) — tách khỏi timer HUD text 1Hz.
static dispatch_source_t g_espTimer = nil;
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

// --- Breadcrumb chẩn đoán respring -----------------------------------------
// Triệu chứng: bấm OPEN HUD, progress đạt 100% rồi máy respring NGAY, HUD chưa
// kịp hiện => exploit + tạo HUD đã xong, máy chết trong ~1-2s sau đó (lúc HUD
// attach/render và overlay ESP bắt đầu dựng trong SpringBoard). ds_trace ghi
// từng bước kèm mốc thời gian so với lúc bật HUD, chỉ trong 10s đầu — lần sau
// respring thì dòng cuối ESP.log sẽ chỉ đúng bước giết máy, và không spam log
// khi HUD chạy bình thường.
static CFAbsoluteTime g_hudEnabledAt = 0;
// Hoãn phần ESP sau khi bật HUD để không dồn hàng trăm remote call dựng overlay
// vào đúng lúc SpringBoard vừa attach cửa sổ HUD.
static const NSTimeInterval kDSESPSettleDelay = 2.5;

static void ds_trace(const char *fmt, ...) {
    if (g_hudEnabledAt <= 0) return;
    double ms = (CFAbsoluteTimeGetCurrent() - g_hudEnabledAt) * 1000.0;
    if (ms < 0 || ms > 10000.0) return;
    char body[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);
    ESPLog("TRACE +%.0fms %s", ms, body);
}

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

// ds_scan_process_base (kernel-walk map từng entry) đã XOÁ — tìm base duy
// nhất qua TASK_DYLD_INFO (ds_game_base_via_dyld, syscall thuần kiểu aovcheat).
static uint64_t ds_dyld_read(mach_port_t task, uint64_t remote, void *buf, uint64_t len) {
    if (task == MACH_PORT_NULL || !remote || !buf || !len || len > 0x1000) return 0;
    vm_size_t out = 0;
    if (vm_read_overwrite(task, (vm_address_t)remote, (vm_size_t)len,
                           (vm_address_t)buf, &out) != KERN_SUCCESS) return 0;
    return (uint64_t)out;
}

// Tìm game base kiểu aovcheat: task_info(TASK_DYLD_INFO) -> all_image_info_addr
// -> duyệt infoArray (mỗi entry 0x18 bytes) -> đọc path -> strstr tên game.
// Toàn syscall, KHÔNG kernel walk/map từng entry như ds_scan_process_base.
static uint64_t ds_game_base_via_dyld(mach_port_t task, const char *wantSub) {
    if (task == MACH_PORT_NULL || !wantSub || !wantSub[0]) return 0;
    struct task_dyld_info di;
    mach_msg_type_number_t n = TASK_DYLD_INFO_COUNT;
    memset(&di, 0, sizeof(di));
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &n) != KERN_SUCCESS) return 0;
    uint64_t infoAddr = (uint64_t)di.all_image_info_addr;
    if (infoAddr < 0x100000000ULL) return 0;
    uint32_t hdr[2] = {0, 0}; // version + infoArrayCount
    if (ds_dyld_read(task, infoAddr, hdr, sizeof(hdr)) != sizeof(hdr)) return 0;
    uint32_t imgCount = hdr[1];
    if (imgCount == 0 || imgCount > 0x400) return 0; // cap như aovcheat
    uint64_t array = 0;
    if (ds_dyld_read(task, infoAddr + 8, &array, 8) != 8) return 0;
    if (array < 0x100000000ULL) return 0;
    char path[256];
    for (uint32_t i = 0; i < imgCount; i++) {
        uint64_t ent[3] = {0, 0, 0}; // loadAddress, filePath, modDate
        if (ds_dyld_read(task, array + (uint64_t)i * 24, ent, sizeof(ent)) != sizeof(ent)) continue;
        if (ent[0] < 0x100000000ULL || !ent[1]) continue;
        memset(path, 0, sizeof(path));
        if (ds_dyld_read(task, ent[1], path, sizeof(path) - 1) == 0) continue;
        path[sizeof(path) - 1] = '\0';
        if (strstr(path, wantSub)) return ent[0];
    }
    return 0;
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
        (void)vmMap; // chỉ còn để validate proc/task, không walk/map gì nữa
        // DUY NHẤT đường này (kiểu aovcheat): base qua TASK_DYLD_INFO.
        // Không port -> base=0 (mù tới khi có port), không kernel-walk nữa.
        uint64_t base = 0;
        ESPGameTaskEnsure();
        mach_port_t pt = ESPGameTaskPort();
        if (pt != MACH_PORT_NULL) {
            base = ds_game_base_via_dyld(pt, cname);
            if (!base) base = ds_game_base_via_dyld(pt, "Shadow");
        }
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
    // CGRect NaN/Inf từ w2s/map -> SpringBoard setFrame: -> CoreAnimation assert
    // -> respring. Bỏ remote call, giữ frame cũ.
    if (!isfinite(value.origin.x) || !isfinite(value.origin.y) ||
        !isfinite(value.size.width) || !isfinite(value.size.height) ||
        value.size.width < 0 || value.size.height < 0 ||
        value.size.width > 100000 || value.size.height > 100000) {
        return NO;
    }
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static BOOL ds_remote_set_point_on_main(RemoteCall *process, uint64_t target,
                                        const char *selectorName, CGPoint value) {
    // Như set_rect: CGPoint NaN/Inf (w2s chia 0 lúc khởi động) vào setCenter:
    // -> CoreAnimation assert trong SpringBoard -> respring. Bỏ remote call.
    // (Hở từ bản meter1: trước đó label đi setFrame đã sanitize.)
    if (!isfinite(value.x) || !isfinite(value.y)) {
        return NO;
    }
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

// Map 1 điểm từ hệ game-landscape sang hệ portrait-window, quay quanh tâm
// màn hình. LandscapeLeft = R(-90°), LandscapeRight = R(+90°) — đã verify
// bằng vector: game top-left (0,0) ra đúng physical top edge cả 2 chiều.
// Không landscape: identity.
static inline CGPoint ds_esp_map_point(CGPoint p, CGFloat landW, CGFloat landH,
                                       CGPoint winCenter, int orientation) {
    BOOL left = (orientation == UIInterfaceOrientationLandscapeLeft);
    BOOL right = (orientation == UIInterfaceOrientationLandscapeRight);
    if (!left && !right) return p;
    CGFloat dx = p.x - landW * 0.5, dy = p.y - landH * 0.5;
    if (left) return CGPointMake(winCenter.x + dy, winCenter.y - dx);
    return CGPointMake(winCenter.x - dy, winCenter.y + dx);
}

// Bbox của 4 góc đã map — đúng cho hình học xoay ±90° (viền box).
// KHÔNG dùng cho label text (phải giữ ngang — xem chỗ gọi).
static inline CGRect ds_esp_map_rect(CGRect r, CGFloat landW, CGFloat landH,
                                     CGPoint winCenter, int orientation) {
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

static inline int ds_bks_orientation(void) {
    static int (*pfn_bkshid)(void) = NULL;
    static int (*pfn_bkhid)(void) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (!h) h = RTLD_DEFAULT;
        pfn_bkshid = (int (*)(void))dlsym(h, "_BKSHIDGetCurrentDeviceOrientation");
        pfn_bkhid = (int (*)(void))dlsym(h, "BKHIDServicesGetCurrentDeviceOrientation");
    });
    int o = 0;
    if (pfn_bkshid) {
        o = pfn_bkshid();
    } else if (pfn_bkhid) {
        o = pfn_bkhid();
    }
    // 3 = BKHIDDeviceOrientationLandscapeRight, 4 = BKHIDDeviceOrientationLandscapeLeft
    if (o == 3) return (int)UIInterfaceOrientationLandscapeRight;
    if (o == 4) return (int)UIInterfaceOrientationLandscapeLeft;
    return 0;
}

static FBSOrientationObserver *g_espOrientationObserver = nil;
static void ds_esp_ensure_orientation_observer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        Class cls = NSClassFromString(@"FBSOrientationObserver");
        if (cls) {
            g_espOrientationObserver = [[cls alloc] init];
            [g_espOrientationObserver setHandler:^(FBSOrientationUpdate *update) {
                long long o = update.orientation;
                if (o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight) {
                    g_foregroundOrientation.store((int)o);
                }
            }];
            long long cur = [g_espOrientationObserver activeInterfaceOrientation];
            if (cur == UIInterfaceOrientationLandscapeLeft || cur == UIInterfaceOrientationLandscapeRight) {
                g_foregroundOrientation.store((int)cur);
            }
        }
    });
}

// Orientation THẬT của game cho ESP overlay, theo thứ tự tin cậy:
// 1) FrontBoardServices activeInterfaceOrientation
// 2) BackBoardServices hardware orientation
// 3) SpringBoard foreground poll
// 4) UIDevice accelerometer
// 5) Landscape đã thấy lần cuối
// PUBG Mobile luôn là game màn hình ngang (Landscape), không bao giờ là Portrait.
// Mặc định luôn là LandscapeRight (hướng phổ biến nhất khi cầm máy chơi game).
static int g_espLastLandscape = UIInterfaceOrientationLandscapeRight; // chỉ chạm từ bridge queue
static int ds_esp_game_orientation_uncached(void) {
    ds_esp_ensure_orientation_observer();

    // Ưu tiên UIDevice (vật lý: cầm máy sao thì ra vậy). User xoay ngang chơi
    // là landscape ngay, không cần ritual "quay ngang trước khi mở HUD".
    // FBS/BKS/poll phía SpringBoard có thể trả portrait (scene kẹt) -> map sai
    // (ESP dọc, không theo địch, bars/lines văng off-screen).
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

    if (g_espOrientationObserver) {
        long long cur = [g_espOrientationObserver activeInterfaceOrientation];
        if (cur == UIInterfaceOrientationLandscapeLeft || cur == UIInterfaceOrientationLandscapeRight) {
            g_espLastLandscape = (int)cur;
            return (int)cur;
        }
    }

    int bks = ds_bks_orientation();
    if (bks == UIInterfaceOrientationLandscapeLeft || bks == UIInterfaceOrientationLandscapeRight) {
        g_espLastLandscape = bks;
        return bks;
    }

    int fg = g_foregroundOrientation.load();
    if (fg == UIInterfaceOrientationLandscapeLeft || fg == UIInterfaceOrientationLandscapeRight) {
        g_espLastLandscape = fg;
        return fg;
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

    return UIInterfaceOrientationLandscapeRight;
}

// Cache 1s: hàm này trước đây chạy MỖI tick 60Hz, mà nhánh đầu của nó là
// -[FBSOrientationObserver activeInterfaceOrientation] (XPC sang FrontBoard)
// và nhánh sau là BKSGetCurrentDeviceOrientation (BackBoard) — gọi 60 lần/giây
// là tự bóp nhịp vẽ (mỗi lần vài trăm µs - ms trên main thread SpringBoard).
// Hướng máy chỉ đổi khi user xoay, và handler của FBSOrientationObserver đã
// cập nhật g_foregroundOrientation ngay khi có thay đổi -> 1s là quá đủ.
static int ds_esp_game_orientation(void) {
    static CFAbsoluteTime s_orientAt = 0;
    static int s_orientVal = UIInterfaceOrientationUnknown;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (s_orientVal != UIInterfaceOrientationUnknown && now - s_orientAt < 1.0) {
        return s_orientVal;
    }
    int o = ds_esp_game_orientation_uncached();
    s_orientAt = now;
    s_orientVal = o;
    return o;
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
    ds_trace("hud: scene=0x%llx frame=%.0fx%.0f", (unsigned long long)scene,
             presentation.windowFrame.size.width, presentation.windowFrame.size.height);

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
    ds_trace("hud: views init ok win=0x%llx", (unsigned long long)window);

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

    ds_trace("hud: views attached, resolving snapshot container");
    g_remoteWindow = window;
    g_remoteContainer = container;
    g_remoteSecureField = secureField;
    g_remoteSecureCanvas = ds_remote_secure_canvas(process, secureField);
    ds_apply_snapshot_container(process, presentation.hideAtSnapshot);
    ds_trace("hud: snapshot canvas=0x%llx hide=%d",
             (unsigned long long)g_remoteSecureCanvas, presentation.hideAtSnapshot ? 1 : 0);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);
    ds_trace("hud: window shown level=%.0f hiddenCache=%d", kDSHUDWindowLevel,
             g_lastWindowHidden ? 1 : 0);

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

// ---------------------------------------------------------------------------
// Batch path: vẽ mọi box bằng MỘT CAShapeLayer + MỘT CGPath.
// Chi phí mỗi frame = 5 remote call bất kể số box:
//   remote_write (mảng CGRect) -> CGPathCreateMutable -> CGPathAddRects
//   -> setPath: -> CGPathRelease (path cũ)
// CoreGraphics/libSystem nằm trong dyld shared cache nên được map ở CÙNG địa
// chỉ trên mọi process -> địa chỉ local dùng được cho process đích (đúng cách
// RemoteCall gọi thread_set_exception_ports / pthread_exit).
// ---------------------------------------------------------------------------
static void *ds_remote_system_symbol(const char *name) {
    static NSMutableDictionary<NSString *, NSNumber *> *cache = nil;
    if (!name) return NULL;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return NULL;
    NSNumber *hit = cache[key];
    if (hit) return (void *)(uintptr_t)hit.unsignedLongLongValue;
    void *addr = dlsym(RTLD_DEFAULT, name);
    if (addr) cache[key] = @((uint64_t)(uintptr_t)addr);
    return addr;
}

static void ds_esp_path_clear(RemoteCall *process) {
    if (g_espPathObj) {
        void *releaseSym = ds_remote_system_symbol("CGPathRelease");
        if (process && process.trojanMem && releaseSym) {
            DSRemoteArbCallWithTimeout(1, process, releaseSym, g_espPathObj);
        }
        g_espPathObj = 0;
    }
    if (g_espPathLayer && process && process.trojanMem) {
        ds_perform_on_springboard_main(process, g_espPathLayer, ds_remote_sel(process, "setPath:"), 0, YES);
    }
}

static BOOL ds_esp_path_update(RemoteCall *process, CGRect *rects, int count) {
    if (!process || !process.trojanMem || !g_espPathLayer) return NO;
    if (!rects || count <= 0) {
        ds_esp_path_clear(process);
        return YES;
    }
    size_t bytes = (size_t)count * sizeof(CGRect);
    if (!g_espRectsAddr || g_espRectsCap < count) {
        if (g_espRectsAddr) {
            void *freeSym = ds_remote_system_symbol("free");
            if (freeSym) DSRemoteArbCallWithTimeout(1, process, freeSym, g_espRectsAddr);
            g_espRectsAddr = 0;
            g_espRectsCap = 0;
        }
        void *mallocSym = ds_remote_system_symbol("malloc");
        if (!mallocSym) return NO;
        int allocCap = count > 32 ? count : 32;
        uint64_t addr = (uint64_t)DSRemoteArbCallWithTimeout(1, process, mallocSym, (uint64_t)(allocCap * sizeof(CGRect)));
        if (!addr) return NO;
        g_espRectsAddr = addr;
        g_espRectsCap = allocCap;
    }
    if (![process remote_write:g_espRectsAddr from:rects size:(uint64_t)bytes]) return NO;
    void *createSym = ds_remote_system_symbol("CGPathCreateMutable");
    void *addRectsSym = ds_remote_system_symbol("CGPathAddRects");
    void *releaseSym = ds_remote_system_symbol("CGPathRelease");
    if (!createSym || !addRectsSym) return NO;
    // CGPathCreateMutable(void): tham số thừa trong x0 bị bỏ qua (không thể gọi
    // remote call với 0 arg vì macro remote tạo mảng args rỗng).
    uint64_t path = (uint64_t)DSRemoteArbCallWithTimeout(1, process, createSym, (uint64_t)0);
    if (!path) return NO;
    DSRemoteArbCallWithTimeout(1, process, addRectsSym, path, 0, g_espRectsAddr, (uint64_t)count);
    ds_perform_on_springboard_main(process, g_espPathLayer, ds_remote_sel(process, "setPath:"), path, YES);
    if (g_espPathObj && releaseSym) {
        DSRemoteArbCallWithTimeout(1, process, releaseSym, g_espPathObj);
    }
    g_espPathObj = path;
    g_espPathCalls += 5;
    g_espPathBoxes += (unsigned long)count;
    return YES;
}

static void ds_esp_overlay_hide(RemoteCall *process) {
    if (!process || !g_espWindow) return;
    ds_esp_path_clear(process);
    if (!g_espWindowHiddenCache) {
        ds_remote_set_u64_on_main(process, g_espWindow, "setHidden:", 1);
        g_espWindowHiddenCache = YES;
    }
}

// Dọn ESP container MA của session/process cũ còn sót trong SpringBoard.
// Views leak có chủ ý + kill app khi chưa disable (cài đè IPA, crash) =>
// window cũ vẫn HIỆN, boxes/labels ĐÔNG CỨNG — kể cả container từng bị xoay
// ở bản transform-remote (chữ mét dựng đứng ma). Chạy 1 lần trước khi tạo
// overlay mới của session này (sau disable/enable lại cho quét tiếp).
static BOOL s_espStaleCleaned = NO;
// Tạm KHÔNG gọi trong đường ensure (xem comment bên dưới). Giữ lại để bật khi
// đã xác nhận nó không làm chết phiên RemoteCall.
__attribute__((unused))
static void ds_esp_cleanup_stale(RemoteCall *process) {
    if (!process || !process.trojanMem) return;
    if (s_espStaleCleaned) return;
    s_espStaleCleaned = YES;
    @try {
        uint64_t appClass = ds_remote_class(process, "UIApplication");
        if (!appClass) return;
        uint64_t app = ds_remote_get_object_on_main(process, appClass, "sharedApplication");
        if (!app) return;
        uint64_t windows = ds_remote_get_retained_object_on_main(process, app, "windows", NULL, 0);
        if (!windows) return;
        uint64_t count = ds_remote_get_u64_on_main(process, windows, "count");
        count = MIN(count, 64);
        uint64_t tagSel = ds_remote_sel(process, "viewWithTag:");
        uint64_t idxSel = ds_remote_sel(process, "objectAtIndex:");
        uint64_t rmSel = ds_remote_sel(process, "removeFromSuperview");
        for (uint64_t i = 0; i < count; i++) {
            DSRemoteArgument arg = { &i, sizeof(i) };
            uint64_t window = 0;
            if (!ds_remote_invoke_on_main_result(
                    process, windows, idxSel, &arg, 1, &window, sizeof(window)) || !window) {
                continue;
            }
            uint64_t tag = (uint64_t)kDSESPOverlayTag;
            DSRemoteArgument targ = { &tag, sizeof(tag) };
            uint64_t found = 0;
            if (!ds_remote_invoke_on_main_result(
                    process, window, tagSel, &targ, 1, &found, sizeof(found)) || !found) {
                continue;
            }
            if (found == g_espContainer) continue; // của session này, giữ lại
            ds_remote_set_u64_on_main(process, found, "setHidden:", 1);
            ds_remote_invoke_on_main(process, found, rmSel, NULL, 0);
            ESPLog("esp stale container removed");
        }
    } @catch (__unused NSException *e) {
    }
}

static BOOL ds_esp_overlay_ensure_impl(RemoteCall *process, CGRect portraitBounds) {
    if (!process || !process.trojanMem) return NO;
    ds_trace("esp ensure: start bounds=%.0fx%.0f", portraitBounds.size.width,
             portraitBounds.size.height);
    // Session/process mới: địa chỉ path layer + buffer CGRect cũ không còn dùng
    // được. GIỮ batching TẮT (bisect respring) — per-box views đã ổn định.
    g_espPathLayer = 0;
    g_espPathObj = 0;
    g_espRectsAddr = 0;
    g_espRectsCap = 0;
    if (g_espWindow && g_espContainer) {
        BOOL ok = YES;
        for (int i = 0; i < ESPOverlayMaxBoxes && ok; i++) {
            ok = (g_espBorders[i][0] != 0) && (g_espLabels[i] != 0);
        }
        if (ok) return YES;
    }
    // KHÔNG dọn stale trong đường ensure nữa: cleanup quét toàn bộ window của
    // SpringBoard bằng remote call, chỉ cần 1 call fail là RemoteCall tự
    // destroyRemoteCall (trojanMem=0) -> HUD chết đứng. Dọn stale giờ chạy
    // một lần lúc bật HUD (ds_finish_enable), không nằm trong present path.
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t windowClass = ds_remote_class(process, "UIWindow");
    uint64_t viewClass = ds_remote_class(process, "UIView");
    uint64_t labelClass = ds_remote_class(process, "UILabel");
    uint64_t colorClass = ds_remote_class(process, "UIColor");
    if (!windowClass || !viewClass || !labelClass || !colorClass) {
        ESPLog("esp ensure fail: class win=%llx view=%llx lbl=%llx col=%llx",
               (unsigned long long)windowClass, (unsigned long long)viewClass,
               (unsigned long long)labelClass, (unsigned long long)colorClass);
        return NO;
    }
    // Dùng scene của HUD đã tạo thành công — KHÔNG dò SBMainWorkspace bằng
    // thêm remote call nữa (mỗi call thừa là một cơ hội fail -> RemoteCall tự
    // destroy, trojanMem=0, HUD chết).
    uint64_t scene = g_remoteWindowScene;
    if (!scene) { ESPLog("esp ensure fail: no scene"); return NO; }
    // Window/container phủ kín scene THEO HỆ PORTRAIT (SpringBoard scene kẹt
    // portrait). setFrame PHẢI chạy SAU setWindowScene: nếu đặt landscape
    // (812x375) trước khi attach, UIKit ép lại theo scene portrait (375x812)
    // -> dải dọc. Boxes game landscape sẽ được map local sang portrait ở
    // ds_esp_overlay_update (ds_esp_map_rect).
    uint64_t window = remote_msg(process, windowClass, alloc, 0, 0, 0, 0);
    uint64_t container = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    if (!window || !container) {
        ESPLog("esp ensure fail: alloc win=%llx cont=%llx",
               (unsigned long long)window, (unsigned long long)container);
        return NO;
    }
    if (!ds_remote_invoke_noarg_on_main(process, window, "init") ||
        !ds_remote_invoke_noarg_on_main(process, container, "init")) {
        ESPLog("esp ensure fail: init win=%llx cont=%llx",
               (unsigned long long)window, (unsigned long long)container);
        return NO;
    }

    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setWindowScene:"), scene, YES);
    ds_remote_set_rect_on_main(process, window, "setFrame:", portraitBounds);
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

    uint64_t font = ds_remote_font(process, 10.0, YES);
    if (!font) { ESPLog("esp ensure fail: font"); return NO; }

    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        uint64_t v = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
        if (!v || !ds_remote_invoke_noarg_on_main(process, v, "init")) {
            ESPLog("esp ensure fail: border i=%d", i);
            return NO;
        }
        ds_perform_on_springboard_main(process, v, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
        ds_remote_set_u64_on_main(process, v, "setHidden:", 1);
        ds_remote_set_u64_on_main(process, v, "setUserInteractionEnabled:", 0);
        
        uint64_t layer = ds_remote_get_object_on_main(process, v, "layer");
        ds_remote_set_double_on_main(process, layer, "setBorderWidth:", kDSESPBorder);
        uint64_t cgColor = ds_remote_get_u64_on_main(process, red, "CGColor");
        if (cgColor) ds_perform_on_springboard_main(process, layer, ds_remote_sel(process, "setBorderColor:"), cgColor, YES);
        // Tắt implicit animation bằng cách đặt speed rất cao (999.0) để animation kết thúc tức thì
        ds_remote_set_double_on_main(process, layer, "setSpeed:", 999.0);
        
        ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "addSubview:"), v, YES);
        
        g_espBorders[i][0] = v; // Dùng 1 view duy nhất cho toàn bộ khung box
        for (int e = 1; e < 4; e++) g_espBorders[i][e] = 0;

        uint64_t lb = remote_msg(process, labelClass, alloc, 0, 0, 0, 0);
        if (!lb || !ds_remote_invoke_noarg_on_main(process, lb, "init")) {
            ESPLog("esp ensure fail: label i=%d lb=%llx", i, (unsigned long long)lb);
            return NO;
        }
        ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setTextColor:"), white, YES);
        ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
        ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setFont:"), font, YES);
        ds_remote_set_u64_on_main(process, lb, "setTextAlignment:", 1);
        ds_remote_set_u64_on_main(process, lb, "setNumberOfLines:", 1);
        ds_remote_set_u64_on_main(process, lb, "setHidden:", 1);
        ds_remote_set_u64_on_main(process, lb, "setUserInteractionEnabled:", 0);
        // Bounds ngang 80x14: chữ đọc dọc local X. Transform ±90° sẽ set
        // ở ds_esp_overlay_update khi mapOrient landscape (setBounds+setCenter).
        ds_remote_set_rect_on_main(process, lb, "setBounds:", CGRectMake(0, 0, 80.0, 14.0));
        ds_remote_set_rect_on_main(process, lb, "setFrame:", CGRectMake(0, 0, 80.0, 14.0));
        
        uint64_t lbLayer = ds_remote_get_object_on_main(process, lb, "layer");
        ds_remote_set_double_on_main(process, lbLayer, "setSpeed:", 999.0);
        
        ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "addSubview:"), lb, YES);
        g_espLabels[i] = lb;
        g_espHiddenCache[i] = YES;

    }
    ds_trace("esp ensure: %d box views built", ESPOverlayMaxBoxes);

    // Batch path layer: 1 CAShapeLayer chứa TẤT CẢ box. Khi layer này sống,
    // các view viền từng box chỉ để fallback (giữ hidden) -> present path
    // không còn setFrame cho từng box.
    if (!g_espPathDisabled) {
        uint64_t shapeClass = ds_remote_class(process, "CAShapeLayer");
        uint64_t pl = shapeClass ? remote_msg(process, shapeClass, alloc, 0, 0, 0, 0) : 0;
        if (pl && ds_remote_invoke_noarg_on_main(process, pl, "init")) {
            uint64_t clearLayer = ds_remote_get_u64_on_main(process, clear, "CGColor");
            uint64_t redLayer = ds_remote_get_u64_on_main(process, red, "CGColor");
            if (redLayer) ds_perform_on_springboard_main(process, pl, ds_remote_sel(process, "setStrokeColor:"), redLayer, YES);
            if (clearLayer) ds_perform_on_springboard_main(process, pl, ds_remote_sel(process, "setFillColor:"), clearLayer, YES);
            ds_remote_set_double_on_main(process, pl, "setLineWidth:", kDSESPBorder);
            ds_remote_set_double_on_main(process, pl, "setSpeed:", 999.0);
            ds_remote_set_rect_on_main(process, pl, "setFrame:", portraitBounds);
            uint64_t containerLayer = ds_remote_get_object_on_main(process, container, "layer");
            if (containerLayer) ds_perform_on_springboard_main(process, containerLayer, ds_remote_sel(process, "addSublayer:"), pl, YES);
            g_espPathLayer = pl;
            ESPLog("esp path layer ON (pid=%d layer=0x%llx)", (int)process.pid, (unsigned long long)pl);
        } else {
            g_espPathDisabled = YES;
            ESPLog("esp path layer FAIL (shape=0x%llx) -> per-box", (unsigned long long)shapeClass);
        }
    }

    ds_trace("esp ensure: attaching window");
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "addSubview:"), container, YES);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);
    ds_trace("esp ensure: window shown");
    g_espWindow = window;
    g_espContainer = container;
    g_espWindowHiddenCache = NO;
    g_espLastContainerBounds = CGRectZero;
    g_espLastMapOrient = UIInterfaceOrientationUnknown;
    return YES;
}

// Bọc ensure bằng COOLDOWN. Trước đây mỗi present tick (20-30 lần/giây) gọi
// thẳng ensure; khi ensure fail giữa chừng (chưa có scene / class) nó tạo
// UIWindow/UIView rác trong SpringBoard rồi fail, lặp mãi -> SpringBoard và
// RemoteCall kiệt sức, HUD text “remote presentation update failed” rồi đứng
// hình. Giờ fail thì nghỉ 1s mới thử lại, và log lý do.
static BOOL ds_esp_overlay_ensure(RemoteCall *process, CGRect portraitBounds) {
    if (!process || !process.trojanMem) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    static CFAbsoluteTime s_ensureCooldownUntil = 0;
    static CFAbsoluteTime s_lastEnsureFailLog = 0;
    if (!(g_espWindow && g_espContainer) && now < s_ensureCooldownUntil) {
        return NO; // đang cooldown sau lần fail trước
    }
    BOOL ok = ds_esp_overlay_ensure_impl(process, portraitBounds);
    if (!ok) {
        s_ensureCooldownUntil = now + 1.0;
        if (now - s_lastEnsureFailLog > 5.0) {
            s_lastEnsureFailLog = now;
            ESPLog("esp ensure FAIL (cooldown 1s) pid=%d win=%llx cont=%llx",
                   (int)process.pid,
                   (unsigned long long)g_espWindow,
                   (unsigned long long)g_espContainer);
        }
    }
    return ok;
}

static void ds_esp_overlay_update(RemoteCall *process, ESPBox2D *boxes, int count,
                                  CGRect portraitBounds, int orientation) {
    if (!process || !process.trojanMem) return;
    CFAbsoluteTime nowP = CFAbsoluteTimeGetCurrent();
    if (!g_espWindow || !g_espContainer) {
        if (!ds_esp_overlay_ensure(process, portraitBounds)) return;
    }
    // Diag 1 lần/process: bounds THỰC của container + window trên SpringBoard
    // (biết SpringBoard có tự xoay window overlay theo máy không — quyết định
    // boxes phải map local hay vẽ trực tiếp).
    {
        static BOOL s_espBoundsLogged = NO;
        if (!s_espBoundsLogged) {
            s_espBoundsLogged = YES;
            CGRect cb = CGRectZero, wb = CGRectZero;
            ds_remote_invoke_on_main_result(process, g_espContainer,
                ds_remote_sel(process, "bounds"), NULL, 0, &cb, sizeof(cb));
            ds_remote_invoke_on_main_result(process, g_espWindow,
                ds_remote_sel(process, "bounds"), NULL, 0, &wb, sizeof(wb));
            ESPLog("espwin: container=%@ window=%@ sb=%@ ori=%d",
                   NSStringFromCGRect(cb), NSStringFromCGRect(wb),
                   NSStringFromCGRect(portraitBounds), orientation);
        }
    }
    // Show/hide window
    BOOL wantHidden = (count <= 0);
    if (wantHidden != g_espWindowHiddenCache) {
        ds_remote_set_u64_on_main(process, g_espWindow, "setHidden:", wantHidden ? 1 : 0);
        g_espWindowHiddenCache = wantHidden;
    }
    if (wantHidden) {
        ds_esp_path_clear(process);
        // Hide stale boxes once
        for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
            if (!g_espHiddenCache[i]) {
                if (!g_espPathLayer && g_espBorders[i][0]) ds_remote_set_u64_on_main(process, g_espBorders[i][0], "setHidden:", 1);
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
    // Chỉ map ±90° khi scene THẬT đang portrait (h>w) và game landscape.
    // Nếu scene đã landscape (w>=h) thì container khớp game — vẽ trực tiếp
    // (map thêm 90° sẽ quay ngược, box ra rìa màn hình).
    BOOL scenePortrait = portraitBounds.size.height > portraitBounds.size.width;
    int mapOrient = (scenePortrait &&
                     (orientation == UIInterfaceOrientationLandscapeLeft ||
                      orientation == UIInterfaceOrientationLandscapeRight))
                        ? orientation
                        : UIInterfaceOrientationPortrait;
    // Container: full theo scene, KHÔNG xoay remote (setTransform: không có
    // tác dụng trên SpringBoard). Map tọa độ từng box local khi cần.
    if (!CGRectEqualToRect(g_espLastContainerBounds, portraitBounds)) {
        ds_remote_set_rect_on_main(process, g_espWindow, "setFrame:", portraitBounds);
        ds_remote_set_rect_on_main(process, g_espContainer, "setFrame:", portraitBounds);
        if (g_espPathLayer) {
            ds_remote_set_rect_on_main(process, g_espPathLayer, "setFrame:", portraitBounds);
        }
        g_espLastContainerBounds = portraitBounds;
        for (int i = 0; i < ESPOverlayMaxBoxes; i++) g_espRectValid[i] = NO;
    }
    if (mapOrient != g_espLastMapOrient) {
        g_espLastMapOrient = mapOrient;
        // setTransform: vô tác dụng trên SpringBoard (label/line xoay vẫn
        // dựng đứng, nghi là thủ phạm respring) -> bỏ xoay hẳn, vẽ frames
        // thuần như bản respring1 ổn định. Đổi orient thì vẽ lại hết.
        for (int i = 0; i < ESPOverlayMaxBoxes; i++) g_espRectValid[i] = NO;
    }

    // Rect đã map cho path layer (chỉ chứa các box visible).
    CGRect s_pathRects[ESPOverlayMaxBoxes];
    int s_pathCount = 0;
    BOOL s_pathDirty = NO;
    static int s_pathFailStreak = 0;

    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        ESPBox2D b = boxes[i];
        BOOL hide = (b.visible == 0 || b.w < 1.0f || b.h < 2.0f);
        if (hide != g_espHiddenCache[i]) {
            if (!g_espPathLayer && g_espBorders[i][0]) ds_remote_set_u64_on_main(process, g_espBorders[i][0], "setHidden:", hide ? 1 : 0);
            ds_remote_set_u64_on_main(process, g_espLabels[i], "setHidden:", hide ? 1 : 0);
            g_espHiddenCache[i] = hide;
            if (hide) {
                g_espRectValid[i] = NO;
            }
        }
        if (hide) continue;

        char distTxt[24] = {0};
        if (b.health >= 0 && b.health <= 100) {
            snprintf(distTxt, sizeof(distTxt), "%.0fm %d%%", b.distance, b.health);
        } else {
            snprintf(distTxt, sizeof(distTxt), "%.0fm", b.distance);
        }

        // 1 border view ôm toàn bộ diện tích box — map từ hệ game-landscape
        // sang hệ container (chỉ xoay khi scene portrait).
        CGRect fullBox = ds_esp_map_rect(CGRectMake(b.x, b.y, b.w, b.h),
                                         landW, landH, winCenter, mapOrient);
        // Label mét: center = top-center của box đã map. Bounds ngang 80x14
        // (text đọc dọc local X). Transform ±90° khi map landscape đã set ở
        // block mapOrient — local X thành trục ngang vật lý -> chữ nằm ngang
        // theo game. KHÔNG dùng setFrame khi có transform (frame chưa map).
        CGFloat labelGameY = (b.y >= 14.0f) ? (b.y - 9.0f) : (b.y + 12.0f);
        CGPoint labelCenter = ds_esp_map_point(CGPointMake(b.x + b.w * 0.5f, labelGameY),
                                               landW, landH, winCenter, mapOrient);
        CGFloat labelHalfW = 40.0f; // bounds 80x14
        CGRect lf = CGRectMake(labelCenter.x - labelHalfW, labelCenter.y - 7.0f,
                               labelHalfW * 2.0f, 14.0f);

        // Box có dịch chuyển?
        // Khi dùng path layer: ngưỡng 0.25pt cực nhạy và mượt (chỉ 1 remote call/frame).
        // Khi fallback per-box: ngưỡng 2.0pt để chống bão NSInvocation gây respring.
        BOOL boxMoved = YES;
        CGRect prevBox = g_espRectValid[i] ? g_espLastRect[i][0] : CGRectZero;
        if (g_espRectValid[i]) {
            if (g_espPathLayer) {
                boxMoved = (fabs(prevBox.origin.x - fullBox.origin.x) >= 0.25 ||
                            fabs(prevBox.origin.y - fullBox.origin.y) >= 0.25 ||
                            fabs(prevBox.size.width - fullBox.size.width) >= 0.35 ||
                            fabs(prevBox.size.height - fullBox.size.height) >= 0.35);
            } else {
                boxMoved = (fabs(prevBox.origin.x - fullBox.origin.x) >= 2.0 ||
                            fabs(prevBox.origin.y - fullBox.origin.y) >= 2.0 ||
                            fabs(prevBox.size.width - fullBox.size.width) >= 2.0 ||
                            fabs(prevBox.size.height - fullBox.size.height) >= 2.0);
            }
        }
        if (boxMoved) s_pathDirty = YES;

        if (fullBox.size.width >= 1.0f && fullBox.size.height >= 1.0f) {
            s_pathRects[s_pathCount++] = fullBox;
        }

        if (!g_espPathLayer && boxMoved && g_espBorders[i][0]) {
            // Fallback: 1 setFrame cho view viền của box này.
            ds_remote_set_rect_on_main(process, g_espBorders[i][0], "setFrame:", fullBox);
        }

        // Chỉ cập nhật setText khi text mét thực sự đổi để giảm tải IPC mach
        // Rate-limit setText: tối đa 5Hz (200ms) để không dồn IPC alloc/setText/release vào SpringBoard
        static CFAbsoluteTime s_lastTextAt[ESPOverlayMaxBoxes] = {0};
        BOOL textChanged = (!g_espRectValid[i] || strcmp(g_espLastDist[i], distTxt) != 0);
        if (textChanged && (!g_espRectValid[i] || nowP - s_lastTextAt[i] >= 0.2)) {
            s_lastTextAt[i] = nowP;
            NSString *dist = [NSString stringWithUTF8String:distTxt];
            ds_remote_set_text_on_main(process, g_espLabels[i], dist);
            snprintf(g_espLastDist[i], sizeof(g_espLastDist[i]), "%s", distTxt);
        }
        // Vị trí label chỉ bắn ở ESP_OVERLAY_LABEL_HZ (không dồn mỗi frame theo textChanged)
        BOOL labelMoved = !g_espRectValid[i] ||
            fabs(g_espLastLabelCenter[i].x - labelCenter.x) > 2.0 ||
            fabs(g_espLastLabelCenter[i].y - labelCenter.y) > 2.0;
        if (labelMoved && (!g_espRectValid[i] || nowP - g_espLastLabelAt[i] >= (1.0 / ESP_OVERLAY_LABEL_HZ))) {
            ds_remote_set_rect_on_main(process, g_espLabels[i], "setFrame:", lf);
            g_espLastLabelCenter[i] = labelCenter;
            g_espLastLabelAt[i] = nowP;
        }

        g_espLastRect[i][0] = fullBox;
        for (int e = 1; e < 4; e++) g_espLastRect[i][e] = CGRectZero;
        g_espLastRect[i][4] = lf;
        g_espRectValid[i] = YES;
    }

    // Batch: dựng lại toàn bộ path một lần cho MỌI box (chỉ 1 remote call setPath, ~2ms).
    static int s_lastPathCount = -1;
    if (g_espPathLayer && (s_pathDirty || s_lastPathCount != s_pathCount)) {
        s_lastPathCount = s_pathCount;
        if (!ds_esp_path_update(process, s_pathRects, s_pathCount)) {
            g_espPathFails++;
            if (++s_pathFailStreak >= 3) {
                // Hỏng liên tục -> trả về đường vẽ từng box (an toàn, không để
                // box biến mất khi path lỗi).
                s_pathFailStreak = 0;
                g_espPathDisabled = YES;
                ds_esp_path_clear(process);
                g_espPathLayer = 0;
                for (int i = 0; i < ESPOverlayMaxBoxes; i++) g_espRectValid[i] = NO;
                ESPLog("esp path layer OFF -> per-box (fails=%lu)", g_espPathFails);
            }
        } else {
            s_pathFailStreak = 0;
        }
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

    static int s_presentSeq = 0;
    int presentSeq = ++s_presentSeq;
    ds_trace("hud present #%d start applyStyle=%d text=%d chars", presentSeq,
             applyStyle ? 1 : 0, (int)text.length);

    @try {
        if (!ds_apply_remote_presentation(
                g_springBoard, &presentation, text, focused, applyStyle)) {
            @throw [NSException exceptionWithName:@"DSRemoteHUDUpdate"
                                           reason:@"remote presentation update failed"
                                         userInfo:nil];
        }
        g_lastPresentationSignature = presentationSignature;
        ds_trace("hud present #%d ok", presentSeq);
    } @catch (NSException *exception) {
        ESPLog("HUD present FAIL: %s trojan=%d pid=%d label=%llx window=%llx",
               exception.reason.UTF8String ?: "?",
               g_springBoard.trojanMem ? 1 : 0, (int)g_springBoard.pid,
               (unsigned long long)g_remoteLabel, (unsigned long long)g_remoteWindow);
        // CHỈ báo chết khi phiên RemoteCall mất hẳn (trojanMem=0). Lỗi tạm
        // thời (1 call fail) trước đây tắt HUD luôn -> HUD đứng hình vĩnh viễn
        // dù chỉ hụt một nhịp. Giờ giữ HUD sống để tick sau tự thử lại.
        if (!g_springBoard || !g_springBoard.trojanMem) {
            ds_set_error([NSString stringWithFormat:@"SpringBoard HUD update failed: %@", exception.reason]);
            g_hudActive.store(false);
        }
    }

    // ESP overlay chạy timer RIÊNG 8Hz (ds_esp_tick) để box mượt — timer HUD
    // này giữ 1Hz cho text. Xem ds_esp_tick bên dưới.
}

// Tag build cho ESP overlay — ĐỔI mỗi lần sửa đường vẽ để log cho biết user
// đang chạy bản nào (box tick in kèm tag).
#define DS_ESP_BUILD_TAG "kptrfix1"

// ESP Box thật trên SpringBoard (RemoteCall) 20Hz: chỉ chạy khi toggle ESP Box
// ON. Vị trí refresh ESP_REFRESH_HZ lần/giây bằng ESPEngineRefreshBoxes (rẻ ~2ms),
// đọc memory trên worker queue riêng để không nghẽn bridge queue, rồi async sang
// bridge queue để IPC present lên SpringBoard.
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

static std::atomic<DSESPFrame *> s_latestFrame{nullptr};
static std::atomic_bool s_espPresenting{false};
static BOOL s_espHideSent = NO; // đã gửi hide lên bridge (tránh spam async), chỉ chạm từ worker

// Present lên SpringBoard — CHẠY TRÊN BRIDGE QUEUE (RemoteCall không thread-safe).
static void ds_esp_present_single(DSESPFrame *frame) {
    if (!frame) return;
    ds_trace("esp present count=%d", frame->count);
    @try {
        if (frame->count < 0) {
            // Lệnh hide từ worker.
            if (g_espWindow) ds_esp_overlay_hide(g_springBoard);
        } else if ((!g_espWindow || !g_espContainer) &&
                   !ds_esp_overlay_ensure(g_springBoard, frame->bounds)) {
            // Ensure fail đã log bên worker, bỏ tick này.
        } else {
            // Presentation pacing: dùng margin 4ms chống sai số microsecond của timer
            // Khi ESP_PRESENT_HZ = 60, truyền đủ 60 FPS mượt mà không rớt frame.
            // Nếu đặt 30Hz, đảm bảo chính xác 30.0 FPS đều đặn không bị trễ thành 20 FPS.
            const double kTargetPresentHz = (double)ESP_PRESENT_HZ;
            const double kPresentMinInterval = (kTargetPresentHz > 0) ? (1.0 / kTargetPresentHz - 0.004) : 0.0;
            static CFAbsoluteTime s_lastPresentUpdate = 0;
            CFAbsoluteTime nowPu = CFAbsoluteTimeGetCurrent();
            if (kPresentMinInterval <= 0 || (nowPu - s_lastPresentUpdate >= kPresentMinInterval)) {
                s_lastPresentUpdate = nowPu;
                ds_esp_overlay_update(g_springBoard, frame->boxes, frame->count,
                                      frame->bounds, frame->orient);
            }
        }
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP present failed: %{public}@", exception.reason);
    }
    free(frame);
}

static void ds_esp_presentation_loop(void) {
    while (true) {
        DSESPFrame *frame = s_latestFrame.exchange(nullptr);
        if (!frame) {
            s_espPresenting.store(false);
            // Double-check: phòng ngừa trường hợp frame mới đến ngay trước khi store false
            frame = s_latestFrame.exchange(nullptr);
            if (!frame) {
                break;
            }
            s_espPresenting.store(true);
        }
        ds_esp_present_single(frame);
    }
}

static void ds_esp_schedule_present(DSESPFrame *frame) {
    if (!frame) return;
    DSESPFrame *old = s_latestFrame.exchange(frame);
    if (old) {
        free(old);
    }
    bool expected = false;
    if (s_espPresenting.compare_exchange_strong(expected, true)) {
        dispatch_async(ds_bridge_queue(), ^{
            ds_esp_presentation_loop();
        });
    }
}

static void ds_esp_tick(void) {
    if (!g_hudRequested.load() || !g_hudActive.load() || !g_springBoard) return;
    CFAbsoluteTime nowP = CFAbsoluteTimeGetCurrent();
    // Vừa bật HUD: hoãn TOÀN BỘ đường ESP trong kDSESPSettleDelay giây. Trước
    // đây tick đầu chạy ngay, dồn hàng trăm remote call (dựng window + 12 viền
    // + 12 label + addSubLayer) cùng lúc SpringBoard vừa attach cửa sổ HUD ->
    // máy respring trước khi HUD kịp hiện. Trong lúc hoãn coi như ESP tắt.
    if (g_hudEnabledAt > 0 && nowP - g_hudEnabledAt < kDSESPSettleDelay) return;
    // Cache prefs 1s + geometry 0.5s. Chỉ chạm từ worker queue.
    static NSDictionary *s_prefsCache = nil;
    static CFAbsoluteTime s_prefsAt = 0;
    static CGRect s_geoCache = CGRectNull;
    static CFAbsoluteTime s_geoAt = 0;
    if (!s_prefsCache || nowP - s_prefsAt > 1.0) {
        @try { s_prefsCache = ds_hud_preferences(); } @catch (__unused NSException *e) {}
        s_prefsAt = nowP;
    }
    NSDictionary *preferences = s_prefsCache ?: @{};
    if (!ds_show_esp_from_prefs(preferences) || !g_gameBase) {
        if (!s_espHideSent) {
            s_espHideSent = YES;
            DSESPFrame *frame = (DSESPFrame *)malloc(sizeof(DSESPFrame));
            if (frame) {
                frame->count = -1;
                frame->bounds = CGRectZero;
                frame->orient = 0;
                ds_esp_schedule_present(frame);
            }
        }
        return;
    }
    s_espHideSent = NO;

    @try {
        CGRect sbBounds = CGRectZero;
        if (CGRectIsNull(s_geoCache) || nowP - s_geoAt > 0.5) {
            ds_screen_geometry(&sbBounds, NULL);
            s_geoCache = sbBounds;
            s_geoAt = nowP;
        } else {
            sbBounds = s_geoCache;
        }
        if (CGRectIsNull(sbBounds) || sbBounds.size.width <= 0) {
            return;
        }
        static ESPBox2D s_boxes[ESPOverlayMaxBoxes];
        static CFAbsoluteTime s_lastRefresh = 0;
        static CFAbsoluteTime s_lastRescueScan = 0;
        static BOOL s_zeroHidden = NO;
        static CFAbsoluteTime s_lastEnsureFailLog = 0;
        static CFAbsoluteTime s_lastPerfLog = 0;
        // Port sống => không cần mapping page nào nữa (mọi read đi
        // vm_read_overwrite) -> trả hết mapping + memory-entry port một lần.
        static BOOL s_pageCacheShed = NO;

        // Persistent slot tracking state
        typedef struct {
            uint64_t actor;
            ESPBox2D box;
            CFAbsoluteTime lastSeen;
            BOOL active;
        } DSESPSlot;
        static DSESPSlot s_slots[ESPOverlayMaxBoxes] = {{0}};

        CFAbsoluteTime now2 = CFAbsoluteTimeGetCurrent();
        int orient = ds_esp_game_orientation();
        // Refresh MỖI tick 60Hz. Kernel position reads vẫn bị throttle 15Hz
        // bên trong ESPEngineRefreshBoxes (kPosReadInterval + ngoại suy vận
        // tốc) — van chống quá tải exploit path. Camera POV đi page-cache
        // (memcpy sau lần đầu). Present trước đây bị kẹp theo didRefresh
        // (=15Hz khi không task port) -> box update 15fps = giật; giờ present
        // mọi tick khi còn box.
        double minInterval = 0.5 / (double)ESP_REFRESH_HZ;

        uint64_t gen = 0;
        int count = 0;
        BOOL didRefresh = NO;
        if (now2 - s_lastRefresh >= minInterval) {
            s_lastRefresh = now2;
            didRefresh = YES;
            // Đặt lịch quét nền và discover TRÊN QUEUE NỀN (không chặn tick render 60Hz).
            ESPEngineRequestDiscover(g_gameBase);
            ESPEngineRequestScan(g_gameBase);
            // Task port game (như aovcheat): có thì mọi read bên dưới đi đường
            // nhanh mach_vm_read_overwrite; chưa có thì ensure (throttle trong).
            ESPGameTaskEnsure();
            if (!s_pageCacheShed && ESPGameTaskPort() != MACH_PORT_NULL) {
                // Non-blocking: scan nền đang đọc kernel thì để lần refresh sau.
                s_pageCacheShed = ESPMemoryFlushPageCacheIfIdle();
            }
            float landW = (float)MAX(CGRectGetWidth(sbBounds), CGRectGetHeight(sbBounds));
            float landH = (float)MIN(CGRectGetWidth(sbBounds), CGRectGetHeight(sbBounds));
            gen = 0;
            static ESPBox2D rawBoxes[32];
            ESPProviderBeginRead();
            int rawCount = ESPEngineRefreshBoxes(g_gameBase, landW, landH,
                                                 rawBoxes, 32, &gen);
            ESPProviderEndRead();
            if (rawCount == 0) {
                // KHÔNG quét đồng bộ ở đây nữa (trước đây: khi rawCount==0 thì
                // 1 giây/lần gọi ESPEngineBoxes() ngay trên tick 60Hz — mỗi
                // lần phân loại cả trăm actor, chặn tick hàng chục tới hàng
                // trăm ms -> box đứng hình đúng nhịp 1 giây, đúng kiểu "giật
                // giật"). Giờ chỉ ĐẶT LỊCH quét trên queue nền (không block,
                // TTL gộp lịch); frame sau RefreshBoxes tự ăn tracked mới.
                ESPEngineRequestDiscover(g_gameBase);
                ESPEngineRequestScan(g_gameBase);
                // Cứu cánh hiếm: CHƯA TỪNG có tracked (scan nền chưa xong hoặc
                // kẹt) thì cho phép 1 lượt quét đồng bộ, tối đa 10s/lần — để
                // không bao giờ rơi vào cảnh không box nào mà cũng không quét.
                if (ESPEngineTrackedGen() == 0 && now2 - s_lastRescueScan >= 10.0) {
                    s_lastRescueScan = now2;
                    ESPProviderBeginRead();
                    rawCount = ESPEngineBoxes(g_gameBase, landW, landH, rawBoxes, 32);
                    ESPProviderEndRead();
                    if (rawCount > 0) gen = ESPEngineTrackedGen();
                }
            }

            if (rawCount > 1) {
                std::sort(rawBoxes, rawBoxes + rawCount, [](const ESPBox2D &a, const ESPBox2D &b) {
                    return a.distance < b.distance;
                });
            }

            bool rawMatched[32] = {false};

            // Rate-limit log sự kiện box (BOX-JUMP/ASSIGN/DROP): ghi mỗi frame
            // gây I/O blocking trên tick 60Hz -> thấy lag. Chỉ log mẫu ~2Hz.
            static CFAbsoluteTime s_lastBoxEventLog = 0;
            auto boxEventLog = [&](const char *msg) {
                if (now2 - s_lastBoxEventLog < 0.5) return;
                s_lastBoxEventLog = now2;
                ESPLog("%s", msg);
            };

            // Phase 1: Giữ nguyên slot cho các actor đã được gán trước đó (chống nhảy slot)
            for (int s = 0; s < ESPOverlayMaxBoxes; s++) {
                if (!s_slots[s].active || s_slots[s].actor == 0) continue;
                for (int r = 0; r < rawCount; r++) {
                    if (rawMatched[r]) continue;
                    if (rawBoxes[r].actor == s_slots[s].actor) {
                        rawMatched[r] = true;
                        ESPBox2D prev = s_slots[s].box;
                        ESPBox2D cur = rawBoxes[r];
                        float dx = fabsf(cur.x - prev.x);
                        float dy = fabsf(cur.y - prev.y);
                        // Ngưỡng rộng: xoay camera nhanh cũng làm box nhảy vài
                        // chục px một cách hợp lệ, log ở ngưỡng 40 chỉ tạo nhiễu.
                        // Chỉ log cú nhảy LỚN (teleport/đổi actor) để soi lỗi thật.
                        if (dx > 120.0f || dy > 120.0f) {
                            char msg[192];
                            snprintf(msg, sizeof(msg),
                                     "BOX-JUMP: slot[%d] act=0x%llx dx=%.1f dy=%.1f prev=[%.1f,%.1f] cur=[%.1f,%.1f]",
                                     s, (unsigned long long)cur.actor, dx, dy, prev.x, prev.y, cur.x, cur.y);
                            boxEventLog(msg);
                        }
                        // Vị trí 3D và phép chiếu W2S đã được xử lý mượt và ngoại suy ở ESPEngineRefreshBoxes.
                        // Gán cur trực tiếp để box bám dính 1:1 theo camera rotation, không bị trôi/chậm pha.
                        s_slots[s].box = cur;
                        s_slots[s].lastSeen = now2;
                        break;
                    }
                }
            }

            // Phase 2: Gán actor mới vào slot trống
            for (int r = 0; r < rawCount; r++) {
                if (rawMatched[r]) continue;
                int bestSlot = -1;
                // Ưu tiên 1: Tìm slot chưa active hoặc actor == 0
                for (int s = 0; s < ESPOverlayMaxBoxes; s++) {
                    if (!s_slots[s].active || s_slots[s].actor == 0) {
                        bestSlot = s;
                        break;
                    }
                }
                // Ưu tiên 2: Nếu đầy slot, chiếm slot NHÌN LÂU NHẤT (kể cả
                // còn hạn) — 8 địch trên màn hình + 1 mới thì phải thay cái
                // cũ nhất. Khớp Phase 3: slot age > 2.5s sẽ bị drop anyway.
                if (bestSlot < 0) {
                    CFAbsoluteTime oldest = now2;
                    for (int s = 0; s < ESPOverlayMaxBoxes; s++) {
                        if (s_slots[s].lastSeen < oldest) {
                            oldest = s_slots[s].lastSeen;
                            bestSlot = s;
                        }
                    }
                }
                if (bestSlot >= 0) {
                    char msg[160];
                    snprintf(msg, sizeof(msg),
                             "BOX-ASSIGN: slot[%d] +NEW act=0x%llx dist=%.1fm box=[%.1f,%.1f,%.1f,%.1f]",
                             bestSlot, (unsigned long long)rawBoxes[r].actor, rawBoxes[r].distance,
                             rawBoxes[r].x, rawBoxes[r].y, rawBoxes[r].w, rawBoxes[r].h);
                    boxEventLog(msg);
                    s_slots[bestSlot].actor = rawBoxes[r].actor;
                    s_slots[bestSlot].box = rawBoxes[r];
                    s_slots[bestSlot].lastSeen = now2;
                    s_slots[bestSlot].active = YES;
                    rawMatched[r] = true;
                }
            }

            // Phase 3: Thu thập box active. 2 ngưỡng:
            //  - lastSeen <= 0.5s: project OK -> hiện box.
            //  - 0.5s < lastSeen <= 2.5s: w2s fail / địch ra mép màn hình ->
            //    ẨN box (visible=0) nhưng GIỮ slot (không clear actor) để khi
            //    project lại được thì Phase 1 rematch tức thì — không rơi vào
            //    BOX-DROP + BOX-ASSIGN +NEW = nhấp nháy / giật như map60.
            //  - > 2.5s: actor chắc chắn mất / out-of-tracked -> drop slot.
            // Clamp rect vào [0,landW]x[0,landH]; center ngoài màn hình -> hide.
            count = 0;
            for (int s = 0; s < ESPOverlayMaxBoxes; s++) {
                if (!s_slots[s].active) {
                    s_boxes[s] = (ESPBox2D){0, 0, 0, 0, 0, -1, 0, 0};
                    continue;
                }
                double age = now2 - s_slots[s].lastSeen;
                if (age > 2.5) {
                    char msg[128];
                    snprintf(msg, sizeof(msg),
                             "BOX-DROP: slot[%d] -TIMEOUT act=0x%llx lastSeen=%.2fs ago",
                             s, (unsigned long long)s_slots[s].actor, age);
                    boxEventLog(msg);
                    s_slots[s].active = NO;
                    s_slots[s].actor = 0;
                    s_boxes[s] = (ESPBox2D){0, 0, 0, 0, 0, -1, 0, 0};
                    continue;
                }
                if (age > 0.5) {
                    // Slot giữ lại, box ẩn (chưa project được).
                    s_boxes[s] = s_slots[s].box;
                    s_boxes[s].visible = 0;
                    continue;
                }
                ESPBox2D b = s_slots[s].box;
                float cx = b.x + b.w * 0.5f, cy = b.y + b.h * 0.5f;
                if (cx < -20 || cx > landW + 20 || cy < -20 || cy > landH + 20) {
                    // Center ngoài màn hình (hệ landscape) -> ẩn, giữ slot.
                    b.visible = 0;
                } else {
                    float x0 = MAX(0.0f, b.x);
                    float y0 = MAX(0.0f, b.y);
                    float x1 = MIN(landW, b.x + b.w);
                    float y1 = MIN(landH, b.y + b.h);
                    if (x1 - x0 < 2.0f || y1 - y0 < 4.0f) {
                        b.visible = 0;
                    } else {
                        b.x = x0;
                        b.y = y0;
                        b.w = x1 - x0;
                        b.h = y1 - y0;
                        b.visible = 1;
                    }
                }
                s_boxes[s] = b;
                if (b.visible) count++;
            }

            ESPBoxCounterSet(count);

            static CFAbsoluteTime s_lastBoxSummaryLog = 0;
            if (now2 - s_lastBoxSummaryLog >= 1.0) {
                s_lastBoxSummaryLog = now2;
                ESPLog("BOX-SUM: %s raw=%d act=%d ori=%d land=%.0fx%.0f %s",
                       DS_ESP_BUILD_TAG, rawCount, count, orient,
                       (double)landW, (double)landH, ESPEngineLastBoxDiag());
                for (int s = 0; s < ESPOverlayMaxBoxes; s++) {
                    if (s_slots[s].active) {
                        ESPLog("  slot[%d]: act=0x%llx d=%.0fm box=[%.0f,%.0f,%.0f,%.0f] hp=%d age=%.2fs",
                               s, (unsigned long long)s_slots[s].actor, s_slots[s].box.distance,
                               s_slots[s].box.x, s_slots[s].box.y, s_slots[s].box.w, s_slots[s].box.h,
                               s_slots[s].box.health,
                               now2 - s_slots[s].lastSeen);
                    }
                }
            }
            if (now2 - s_lastPerfLog > 10.0) {
                s_lastPerfLog = now2;
                float hpCur = 0, hpMax = 0; int hpPct = -1, hpFails = 0;
                ESPEngineHPSample(&hpCur, &hpMax, &hpPct, &hpFails);
                uint64_t rssMB = 0;
                {
                    task_basic_info_data_t binfo;
                    mach_msg_type_number_t bc = TASK_BASIC_INFO_COUNT;
                    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&binfo, &bc) == KERN_SUCCESS) {
                        rssMB = binfo.resident_size / (1024 * 1024);
                    }
                }
                ESPLog("box perf: %s count=%d path(on=%d c=%lu b=%lu f=%lu) prov=%d fails=%llu scans=%llu hp=%.0f/%.0f=%d hpf=%d rss=%llumb",
                       ESPEngineBoxPerfText(), count, g_espPathLayer ? 1 : 0,
                       g_espPathCalls, g_espPathBoxes, g_espPathFails,
                       ESPProviderIsDegraded() ? 1 : 0,
                       (unsigned long long)ESPProviderFailureCount(),
                       (unsigned long long)ESPProviderFullScanCount(),
                       hpCur, hpMax, hpPct, hpFails, (unsigned long long)rssMB);
            }
        }

        static int s_zeroCountFrames = 0;
        static int s_lastPresentCount = 0;
        // Present MỖI tick khi còn box (không đợi didRefresh): timer 60Hz,
        // refresh cũng 60Hz; nếu 1 tick bị skip (jitter) vẫn gửi frame cuối.
        int presentCount = count;
        if (!didRefresh && s_lastPresentCount > 0) presentCount = s_lastPresentCount;
        if (presentCount > 0) {
            s_lastPresentCount = presentCount;
            s_zeroCountFrames = 0;
            s_zeroHidden = NO;
            DSESPFrame *frame = (DSESPFrame *)malloc(sizeof(DSESPFrame));
            if (frame) {
                memcpy(frame->boxes, s_boxes, sizeof(s_boxes));
                frame->count = presentCount;
                frame->bounds = sbBounds;
                frame->orient = orient;
                ds_esp_schedule_present(frame);
            }
        } else if (didRefresh && !s_zeroHidden && count == 0) {
            s_lastPresentCount = 0;
            // Hết box: chỉ hide sau ít nhất 20 frames liên tiếp không có box (~0.7s)
            // để tránh chớp tắt khi 1 frame bị hụt camera hoặc lag đọc bộ nhớ.
            s_zeroCountFrames++;
            if (s_zeroCountFrames >= 20) {
                s_zeroHidden = YES;
                DSESPFrame *frame = (DSESPFrame *)malloc(sizeof(DSESPFrame));
                if (frame) {
                    frame->count = 0;
                    frame->bounds = sbBounds;
                    frame->orient = orient;
                    ds_esp_schedule_present(frame);
                }
            }
        }

        if ((!g_espWindow || !g_espContainer) && now2 - s_lastEnsureFailLog > 10.0) {
            s_lastEnsureFailLog = now2;
            ESPLog("box overlay ensure pending orient=%d sb=%.0fx%.0f",
                   orient, (double)CGRectGetWidth(sbBounds),
                   (double)CGRectGetHeight(sbBounds));
        }
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP overlay update failed: %{public}@", exception.reason);
    }
}

static void ds_start_esp_timer(void) {
    if (g_espTimer) return;
    const uint64_t interval = NSEC_PER_SEC / ESP_REFRESH_HZ;
    g_espTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_esp_work_queue());
    dispatch_source_set_timer(g_espTimer,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_espTimer, ^{
        @autoreleasepool {
            ds_esp_tick();
        }
    });
    dispatch_resume(g_espTimer);
}

static void ds_stop_esp_timer(void) {
    if (!g_espTimer) return;
    dispatch_source_cancel(g_espTimer);
    g_espTimer = nil;
    DSESPFrame *old = s_latestFrame.exchange(nullptr);
    if (old) free(old);
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
    ESPProviderShutdown(); // reset degraded/counters của provider
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
    s_espStaleCleaned = NO; // enable sau quét dọn lại từ đầu
    g_hudEnabledAt = 0; // tắt TRACE + settle delay của phiên cũ
    g_espWindowHiddenCache = YES;
    g_espLastContainerBounds = CGRectZero;
    g_espLastMapOrient = UIInterfaceOrientationUnknown;
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
        // Mốc 0 của TRACE: từ đây tới lúc HUD hiện là cửa sổ hay respring.
        g_hudEnabledAt = CFAbsoluteTimeGetCurrent();
        ds_trace("enable: rc init start");
        // Chẩn đoán respring: pid app mình + RSS (xem app có phình RAM không),
        // so với `rc ok pid=` (SpringBoard) ở session sau để biết ai chết.
        {
            task_basic_info_data_t binfo;
            mach_msg_type_number_t bc = TASK_BASIC_INFO_COUNT;
            uint64_t rssMB = 0;
            if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&binfo, &bc) == KERN_SUCCESS) {
                rssMB = binfo.resident_size / (1024 * 1024);
            }
            ESPLog("enable self pid=%d rss=%llumb", getpid(), (unsigned long long)rssMB);
        }
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

        ds_trace("enable: rc ok pid=%d trojan=0x%llx", (int)g_springBoard.pid,
                 (unsigned long long)g_springBoard.trojanMem);
        g_dsProgress.store(0.99);
        ds_set_stage(ds_localized(@"Creating SpringBoard HUD"));
        g_remoteLabel = ds_create_springboard_hud(g_springBoard);
        if (!g_remoteLabel) {
            [g_springBoard destroyRemoteCall];
            g_springBoard = nil;
            ds_fail_enable(ds_localized(@"SpringBoard HUD creation failed. Retry or reinstall over the existing app; restart the device only as a last resort."));
            return;
        }
        ds_trace("enable: hud created label=0x%llx", (unsigned long long)g_remoteLabel);
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
    ds_trace("enable: DONE (hud active, ESP settle %.1fs)", kDSESPSettleDelay);
    ESPLog("build tag=%s", DS_ESP_BUILD_TAG); // biết chắc user đang chạy bản nào
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
