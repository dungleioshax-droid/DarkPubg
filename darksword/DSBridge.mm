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
#include <mutex>
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
// Window của session TRƯỚC, giữ lại để enable sau dọn bằng RemoteCall mới khi
// lần disable trước không ẩn được (session đã chết -> trojanMem=0). Chỉ dùng
// khi pid SpringBoard trùng; sau respring pid đổi nên địa chỉ cũ bị bỏ.
static uint64_t g_staleHudWindow = 0;
static pid_t g_staleHudPid = 0;
static uint64_t g_staleEspWindow = 0;
static pid_t g_staleEspPid = 0;
// ESP overlay (box thật): window full-screen + container xoay theo orientation
// + pool ESPOverlayMaxBoxes*(4 viền + 1 label). Intentionally leak như HUD.
static uint64_t g_espWindow = 0;
static uint64_t g_espContainer = 0;
static uint64_t g_espBorders[ESPOverlayMaxBoxes][4] = {{0}};
static uint64_t g_espBorderLayer[ESPOverlayMaxBoxes] = {0}; // layer của view viền (bật/tắt khung)
static BOOL g_espBoxBorderOn[ESPOverlayMaxBoxes];            // borderWidth đang = kDSESPBorder?
static uint64_t g_espLabels[ESPOverlayMaxBoxes] = {0};
// kernrw49: health bar per-box = 2 UIView con (nền đen alpha + fill màu band
// như Kernel: <30%% đỏ, <60%% vàng, còn lại xanh lá).
static uint64_t g_espHpBG[ESPOverlayMaxBoxes] = {0};
static uint64_t g_espHpFill[ESPOverlayMaxBoxes] = {0};
static uint8_t g_espHpBand[ESPOverlayMaxBoxes]; // 0/1/2 = green/yellow/red, 0xFF = chưa track
static uint32_t g_espHpFillH[ESPOverlayMaxBoxes]; // chiều cao fill x10 - dirty khi đổi
static float g_espHpFrameH[ESPOverlayMaxBoxes]; // chiều cao box lúc set frame HP gần nhất (0 = chưa set)
static BOOL g_espLabelShown[ESPOverlayMaxBoxes] = {0}; // kernrw51: label đang hiện? (cờ riêng vì label có hidden=1 riêng)
static uint64_t g_dsRedColor = 0;       // kernrw49: cache 3 UIColor trên SpringBoard
static uint64_t g_dsYellowColor = 0;
static uint64_t g_dsGreenColor = 0;
static CGPoint g_espLastLine[ESPOverlayMaxBoxes][4]; // mirror pre-check snapline
static BOOL g_espHpShown[ESPOverlayMaxBoxes] = {0}; // HP bar đang hiển thị?
static int g_espLastHp[ESPOverlayMaxBoxes]; // mirror pre-check hp
static BOOL g_espHiddenCache[ESPOverlayMaxBoxes] = {0};
static BOOL g_espWindowHiddenCache = YES;
// Cache frame/text từng box cho tick 8Hz (đứng yên thì 0 remote call).
// Reset cùng views ở ds_finish_disable (views mới = địa chỉ mới).
static CGRect g_espLastRect[ESPOverlayMaxBoxes][5]; // 0-3 viền, 4 label
static char g_espLastDist[ESPOverlayMaxBoxes][96]; // kernrw49: "Nick\n123m" UTF-8
static BOOL g_espRectValid[ESPOverlayMaxBoxes] = {NO};
static CGRect g_espLastContainerBounds = CGRectZero;
static int g_espLastMapOrient = UIInterfaceOrientationUnknown;

// Renderer QBL (frame + command list). 0 = quay lại renderer per-box cũ.
// Định nghĩa ở đây (không phải cạnh block QBL) để ds_esp_overlay_ensure_impl
// phía trên dùng được.
#ifndef DS_ESP_RENDER_COMMANDLIST
#define DS_ESP_RENDER_COMMANDLIST 1
#endif

// Batch path layer: 1 CAShapeLayer vẽ MỌI box bằng 1 CGPath dựng trong process
// đích -> ~5 remote call/frame BẤT KỂ số box (thay vì ~2 × N).
static pid_t g_espWindowPid = 0;         // pid SpringBoard sở hữu g_espWindow
static uint64_t g_espPathLayer = 0;      // CAShapeLayer trong process đích
static uint64_t g_espPathObj = 0;        // CGPath đang gắn vào layer (để release)
static uint64_t g_espRectsAddr = 0;      // buffer CGRect[] malloc trong process đích
static int g_espRectsCap = 0;            // số CGRect buffer chứa được
static BOOL g_espPathDisabled = NO;        // kernrw49: snapline layer ON mặc định; fail là YES vĩnh viễn (an toàn như kernrw27)
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
static const NSTimeInterval kDSESPSettleDelay = 1.0;

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
        // kernrw52: ESP sub-features sống ở standardDefaults — merge vào snapshot
        // để bridge đọc cùng nguồn với Settings app (tránh lệch default).
        HUDUserDefaultsKeyESPShowLine,
        HUDUserDefaultsKeyESPShowName,
        HUDUserDefaultsKeyESPShowHealth,
        HUDUserDefaultsKeyESPShowDistance,
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
        // Task port đã xoá hẳn -> dyld luôn fail. Fallback: kernel walk tìm
        // __TEXT (ESPGameBaseViaKernel, cache theo pid, chỉ chạy khi base=0).
        if (!base && proc) base = ESPGameBaseViaKernel(proc);
        ESPLog("ds base refresh pid=%d name=%@ base=0x%llx", pid,
               foundName ?: @"?", (unsigned long long)base);
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
    ESPGameBaseInvalidate(); // ép walk lại thật, không trả cache pid cũ
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

// kernrw51: toggles từng thành phần ESP (Line/Name/Health). Key chưa có -> ON
// (giữ thói quen cũ: bật ESP Box nghĩa là thấy đầy đủ như trước).
static BOOL ds_esp_feature_pref(NSDictionary *prefs, NSString *key) {
    NSNumber *n = prefs ? prefs[key] : nil;
    if (n) return n.boolValue;
    NSNumber *direct = nil;
    @try { direct = [NSUserDefaults.standardUserDefaults objectForKey:key]; } @catch (__unused NSException *e) {}
    if (direct) return direct.boolValue;
    return YES;
}

// qblpack: như trên nhưng default cấu hình được (Bones/Scale mặc định OFF).
static BOOL ds_esp_feature_pref_default(NSDictionary *prefs, NSString *key, BOOL def) {
    NSNumber *n = prefs ? prefs[key] : nil;
    if (n) return n.boolValue;
    NSNumber *direct = nil;
    @try { direct = [NSUserDefaults.standardUserDefaults objectForKey:key]; } @catch (__unused NSException *e) {}
    if (direct) return direct.boolValue;
    return def;
}

// "ESP Box" CHỈ là toggle của khung 2D. Các thành phần khác (Snapline,
// Tên, Máu, Khoảng cách) phải chạy độc lập — trước đây cả overlay bị gate
// theo mỗi ESP Box nên tắt Box là Line/Name/Health/Distance cũng không chạy.
// Overlay chỉ tắt hẳn khi TẤT CẢ đều OFF.
static BOOL ds_esp_any_feature_from_prefs(NSDictionary *prefs) {
    if (ds_show_esp_from_prefs(prefs)) return YES;
    if (ds_esp_feature_pref(prefs, HUDUserDefaultsKeyESPShowLine) ||
        ds_esp_feature_pref(prefs, HUDUserDefaultsKeyESPShowName) ||
        ds_esp_feature_pref(prefs, HUDUserDefaultsKeyESPShowHealth) ||
        ds_esp_feature_pref(prefs, HUDUserDefaultsKeyESPShowDistance)) {
        return YES;
    }
    // qblpack: key mới mặc định ON, nhưng CHỈ giữ module chạy khi user đã set
    // tường minh = YES — để "tắt hết" vẫn tắt được như trước (không tự bật lại
    // chỉ vì key chưa tồn tại trong NSUserDefaults).
    NSArray<NSString *> *extra = @[
        HUDUserDefaultsKeyESPShowTeamID,
        HUDUserDefaultsKeyESPShowHeadDot,
        HUDUserDefaultsKeyESPShowAIMark,
        HUDUserDefaultsKeyESPShowBones,
        HUDUserDefaultsKeyESPESPScale,
    ];
    for (NSString *key in extra) {
        NSNumber *n = prefs ? prefs[key] : nil;
        if (n && n.boolValue) return YES;
    }
    return NO;
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
    if (!ds_is_ready()) return 0;
    NSDictionary *prefs = nil;
    @try { prefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
    ds_ensure_game_base(prefs);
    if (!g_gameBase) return 0;
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
        // qblpack: gắn trạng thái xương vào dòng scan của app (chỉ khi toggle
        // Bones đang bật) để verify trên máy: detect / 0x<off> ok / no-match /
        // auto-off. Tắt bones -> không đổi gì (giữ dòng scan như cũ).
        if (ESPEngineBonesEnabled()) {
            const char *bs = ESPEngineBonesStatus();
            if (bs && bs[0]) {
                NSString *suffix = [NSString stringWithFormat:@" · %s", bs];
                return s.length ? [s stringByAppendingString:suffix] : suffix;
            }
        }
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

static void ds_esp_ensure_orientation_observer(void); // forward decl

static UIInterfaceOrientation ds_interface_orientation(void) {
    // kernrw52j: đảm bảo observer orientation được khởi tạo (cho HUD text window).
    ds_esp_ensure_orientation_observer();
    // Ưu tiên orientation của game (foreground) và thiết bị, không chỉ
    // SpringBoard scene (kẹt portrait). Nếu không, HUD chỉ đúng khi xoay máy
    // trước khi mở HUD — không tự xoay theo game.
    int fg = g_foregroundOrientation.load();
    if (fg == UIInterfaceOrientationLandscapeLeft || fg == UIInterfaceOrientationLandscapeRight ||
        fg == UIInterfaceOrientationPortrait || fg == UIInterfaceOrientationPortraitUpsideDown) {
        return (UIInterfaceOrientation)fg;
    }
    // Thiết bị vật lý
    UIDeviceOrientation dev = UIDevice.currentDevice.orientation;
    UIInterfaceOrientation mapped = UIInterfaceOrientationUnknown;
    switch (dev) {
        case UIDeviceOrientationLandscapeLeft:  mapped = UIInterfaceOrientationLandscapeRight; break;
        case UIDeviceOrientationLandscapeRight: mapped = UIInterfaceOrientationLandscapeLeft; break;
        case UIDeviceOrientationPortrait:       mapped = UIInterfaceOrientationPortrait; break;
        case UIDeviceOrientationPortraitUpsideDown: mapped = UIInterfaceOrientationPortraitUpsideDown; break;
        default: break;
    }
    if (mapped != UIInterfaceOrientationUnknown) return mapped;
    // SpringBoard scene (fallback)
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

static NSString *ds_esp_line_for_prefs(NSDictionary *preferences) {
    if (!ds_esp_any_feature_from_prefs(preferences)) return nil;
    uint32_t count = 0;
    @try {
        count = DSBridgeESPCount();
    } @catch (__unused NSException *e) {
        count = 0;
    }
    if (!ds_is_ready()) return (count > 0) ? [NSString stringWithFormat:@"%u", (unsigned)count] : @"--";
    ds_ensure_game_base(preferences);
    if (!g_gameBase) return (count > 0) ? [NSString stringWithFormat:@"%u", (unsigned)count] : @"--";
    return [NSString stringWithFormat:@"%u", (unsigned)count];
}

static NSString *ds_display_text(NSDictionary *preferences,
                                 BOOL __unused centered,
                                 BOOL __unused focused,
                                 double __unused down,
                                 double __unused up) {
    // Chỉ hiển thị số lượng địch thuần tuý
    NSString *espLine = ds_esp_line_for_prefs(preferences);
    return espLine ?: @"";
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
    presentation.singleLine = YES;
    presentation.bitrate = NO;
    presentation.arrowPrefixes = NO;
    presentation.inverted = NO;
    presentation.followsRotation = YES; // Luôn hiển thị cả ngang lẫn dọc trong game
    presentation.hideAtSnapshot = ds_pref_bool(preferences, HUDUserDefaultsKeyHideAtSnapshot);
    presentation.displayFPS = NO;
    presentation.passthrough = YES;

    BOOL customFont = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomFontSize);
    if (customFont) {
        presentation.fontSize = MIN(MAX(ds_pref_double(
            preferences, HUDUserDefaultsKeyRealCustomFontSize, 24.0), 14.0), 40.0);
    } else {
        presentation.fontSize = 24.0;
    }
    presentation.cornerRadius = 0.0;
    presentation.inactiveOpacity = 1.0;
    presentation.numberOfLines = 1;
    presentation.alignment = presentation.centered ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    presentation.maskedCorners = kDSCornerMaskAll;

    UIFontWeight weight = UIFontWeightHeavy;
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

// Lock + ensure cho cache sel/class/symbol dùng chung bridge/ship (leaf).
// (Định nghĩa ở đây vì ds_remote_sel bên dưới dùng ngay.)
static NSLock *s_remoteCacheLock = nil;
static void ds_remote_cache_ensure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_remoteCacheLock = [NSLock new]; });
}

static uint64_t ds_remote_sel(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    ds_remote_cache_ensure();
    // Cache dùng chung bridge/ship -> khóa (leaf, không gọi gì khác khi giữ).
    [s_remoteCacheLock lock];
    @try {
        if (!g_remoteSelectorCache) g_remoteSelectorCache = [NSMutableDictionary dictionary];
        NSString *key = [NSString stringWithUTF8String:name];
        if (!key) return 0;
        NSNumber *cached = g_remoteSelectorCache[key];
        if (cached) return cached.unsignedLongLongValue;
        uint64_t value = remote_sel(process, name);
        if (value) g_remoteSelectorCache[key] = @(value);
        return value;
    } @finally {
        [s_remoteCacheLock unlock];
    }
}

static uint64_t ds_remote_class(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    ds_remote_cache_ensure();
    [s_remoteCacheLock lock];
    @try {
        if (!g_remoteClassCache) g_remoteClassCache = [NSMutableDictionary dictionary];
        NSString *key = [NSString stringWithUTF8String:name];
        if (!key) return 0;
        NSNumber *cached = g_remoteClassCache[key];
        if (cached) return cached.unsignedLongLongValue;
        uint64_t value = remote_getClass(process, name);
        if (value) g_remoteClassCache[key] = @(value);
        return value;
    } @finally {
        [s_remoteCacheLock unlock];
    }
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

// ---- Pool NSAutoreleasePool dùng chung ----
// Mỗi ds_remote_invoke_on_main_result trước đây TẠO + DRAIN pool REMOTE riêng:
// alloc + init + drain = 3 remote_msg thừa cho MỖI lời gọi. Một lượt present ESP
// = 4 box × (setFrame viền + label) × 60Hz ≈ 2400 vòng/giây -> ~30% remote msg
// chỉ là phí pool, và present chậm hơn 16.7ms là s_latestFrame.exchange ném frame
// đi -> box giật. ds_remote_pool_begin/end giữ MỘT pool cho cả lượt; caller khác
// (HUD, ensure…) không gọi begin nên depth=0 -> chạy y hệt code cũ.
static thread_local int s_dsPoolDepth = 0;
static thread_local uint64_t s_dsPool = 0;

// ---- RemoteCall batch lock (kernrw22) ----
// RemoteCall không thread-safe (1 hijacked thread + scratch dùng chung trong
// SB). Mọi traffic RemoteCall
// (bridge present/rate/fgPoll/enable/disable) phải qua lock
// này theo BATCH (không khóa lẻ từng call vì scratch 0x800/0xC00 và text page
// dùng chung giữa các bước của 1 invocation sequence). Recursive để
// ensure/nested gọi nhau an toàn. Thứ tự lock: batch -> cache/symbol (leaf)
// -> ESPLog (leaf), không đảo nên không deadlock.
static std::recursive_mutex s_rcBatchMutex;
// (s_remoteCacheLock + ds_remote_cache_ensure đã định nghĩa phía trên,
// trước ds_remote_sel.)

static void ds_remote_pool_begin(RemoteCall *process) {
    if (s_dsPoolDepth != 0) return; // đã có pool outer (lồng nhau)
    if (!process || !process.trojanMem) return;
    uint64_t poolClass = ds_remote_class(process, "NSAutoreleasePool");
    if (!poolClass) return;
    uint64_t pool = remote_msg(process,
                               remote_msg(process, poolClass,
                                          ds_remote_sel(process, "alloc"), 0, 0, 0, 0),
                               ds_remote_sel(process, "init"), 0, 0, 0, 0);
    if (!pool) return;
    s_dsPool = pool;
    s_dsPoolDepth = 1;
}

static void ds_remote_pool_end(RemoteCall *process) {
    if (s_dsPoolDepth == 0) return;
    s_dsPoolDepth = 0;
    uint64_t pool = s_dsPool;
    s_dsPool = 0;
    if (pool && process && process.trojanMem) {
        remote_msg(process, pool, ds_remote_sel(process, "drain"), 0, 0, 0, 0);
    }
}

// ---- NSInvocation cache (kernrw18) ----
// Mỗi (target,selector) của void-method (setFrame:/setHidden:/setBounds:/...)
// chỉ dựng NSInvocation 1 lần rồi retain trong SB; các frame sau chỉ còn
// remote_write arg + setArgument: + invoke (3 msg thay vì ~7: bỏ
// methodSignatureForSelector + invocationWithMethodSignature: + setTarget: +
// setSelector:). Cùng entry point SB (setArgument/invoke) nên an toàn hơn
// path layer. Getter có return value KHÔNG cache (đi đường cũ).
// Session/view mới -> địa chỉ cũ vô nghĩa -> xả qua ds_inv_cache_drop()
// (gọi ở ensure rebuild + disable); đổi trojanMem cũng tự xả.
static NSMutableDictionary<NSString *, NSNumber *> *s_invCache = nil;
static NSLock *s_invCacheLock = nil;
static uint64_t s_invCacheTrojan = 0;

static void ds_inv_cache_ensure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_invCache = [NSMutableDictionary dictionary];
        s_invCacheLock = [NSLock new];
    });
}

static inline NSString *ds_inv_cache_key(uint64_t target, uint64_t selector) {
    return [NSString stringWithFormat:@"%llx_%llx",
            (unsigned long long)target, (unsigned long long)selector];
}

// Trả invocation đã retain, hoặc 0. Tự xả khi đổi session.
static uint64_t ds_inv_cache_get(RemoteCall *process, uint64_t target, uint64_t selector) {
    if (!process || !process.trojanMem || !target || !selector) return 0;
    ds_inv_cache_ensure();
    uint64_t inv = 0;
    [s_invCacheLock lock];
    @try {
        if (s_invCacheTrojan != process.trojanMem) {
            [s_invCache removeAllObjects];
            s_invCacheTrojan = process.trojanMem;
        } else {
            NSNumber *hit = s_invCache[ds_inv_cache_key(target, selector)];
            inv = hit ? hit.unsignedLongLongValue : 0;
        }
    } @finally {
        [s_invCacheLock unlock];
    }
    return inv;
}

static void ds_inv_cache_put(RemoteCall *process, uint64_t target, uint64_t selector, uint64_t invocation) {
    if (!process || !process.trojanMem || !target || !selector || !invocation) return;
    ds_inv_cache_ensure();
    [s_invCacheLock lock];
    @try {
        if (s_invCacheTrojan != process.trojanMem) {
            [s_invCache removeAllObjects];
            s_invCacheTrojan = process.trojanMem;
        }
        s_invCache[ds_inv_cache_key(target, selector)] = @(invocation);
    } @finally {
        [s_invCacheLock unlock];
    }
}

// Xả toàn bộ (gọi khi rebuild views / disable — địa chỉ view mới khác cũ,
// dùng lại invocation cũ sẽ bắn nhầm vào view chết đã leak).
static void ds_inv_cache_drop(void) {
    ds_inv_cache_ensure();
    [s_invCacheLock lock];
    @try {
        [s_invCache removeAllObjects];
        s_invCacheTrojan = 0;
    } @finally {
        [s_invCacheLock unlock];
    }
}

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

    // Fast path kernrw18: invocation đã dựng + retain từ frame trước (chỉ cho
    // call không lấy return value: setFrame:/setHidden:/...). Getter đi đường cũ.
    BOOL wantResult = (result && resultSize > 0);
    uint64_t cachedInv = 0;
    if (!wantResult) cachedInv = ds_inv_cache_get(process, target, selector);

    // depth>0 = caller đang giữ pool (ds_remote_pool_begin) -> dùng chung,
    // không tạo và không drain. depth==0 = nguyên bản: 1 pool cho đúng 1 lời gọi.
    BOOL ownPool = (s_dsPoolDepth == 0);
    uint64_t autoreleasePool = 0;
    uint64_t drainSelector = 0;
    if (ownPool) {
        uint64_t poolClass = ds_remote_class(process, "NSAutoreleasePool");
        uint64_t allocSelector = ds_remote_sel(process, "alloc");
        uint64_t initSelector = ds_remote_sel(process, "init");
        drainSelector = ds_remote_sel(process, "drain");
        autoreleasePool = poolClass && allocSelector && initSelector && drainSelector
            ? remote_msg(process,
                         remote_msg(process, poolClass, allocSelector, 0, 0, 0, 0),
                         initSelector, 0, 0, 0, 0)
            : 0;
        if (!autoreleasePool) return NO;
    }

    @try {

    uint64_t invocation = cachedInv;
    if (!invocation) {
        uint64_t signature = remote_msg(process, target,
                                        ds_remote_sel(process, "methodSignatureForSelector:"),
                                        selector, 0, 0, 0);
        if (!process.trojanMem) return NO;
        uint64_t invocationClass = ds_remote_class(process, "NSInvocation");
        invocation = signature && invocationClass
            ? remote_msg(process, invocationClass,
                         ds_remote_sel(process, "invocationWithMethodSignature:"),
                         signature, 0, 0, 0)
            : 0;
        if (!invocation || !process.trojanMem) return NO;

        remote_msg(process, invocation, ds_remote_sel(process, "setTarget:"), target, 0, 0, 0);
        if (!process.trojanMem) return NO;
        remote_msg(process, invocation, ds_remote_sel(process, "setSelector:"), selector, 0, 0, 0);
        if (!process.trojanMem) return NO;
        if (!wantResult) {
            // Giữ invocation cho frame sau: retain trong SB ngay lúc này
            // (bản autorelease gốc sẽ bị pool chung drain cuối lượt present).
            // setArgument: copy bytes vào frame lúc gọi nên scratch tái dùng
            // an toàn; invoke gọi lại nhiều lần hợp lệ.
            remote_msg(process, invocation, ds_remote_sel(process, "retain"), 0, 0, 0, 0);
            if (process.trojanMem) ds_inv_cache_put(process, target, selector, invocation);
        }
    }

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
        if (ownPool && process.trojanMem) {
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

// qblpack: property kiểu `float` (CALayer.speed, shadowOpacity...) — NSInvocation
// copy đúng sizeof(type)=4 byte từ buffer, nên double 8 byte ở đây là SAI
// (little-endian: 4 byte thấp của 1000.0 = 0 -> speed 0, path không cập nhật).
static BOOL ds_remote_set_float_on_main(RemoteCall *process, uint64_t target,
                                        const char *selectorName, float value) {
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
// kernrw49: build label text theo style Kernel — nickname\n dist
// (giống additive hồi esp.mm:1069-1079: name trắng 18, dist vàng 16 dưới).
// kernrw52: Distance là toggle riêng — nếu Name OFF thì không hiện nick, nếu
// Distance OFF thì không hiện mét; cả hai OFF → caller giấu label.
static void ds_esp_build_label_text(ESPBox2D b, BOOL showName, BOOL showDist,
                                    char *out, int outCap) {
    if (!out || outCap <= 0) return;
    out[0] = '\0';
    const char *nick = b.nick;
    BOOL haveNick = nick && nick[0] != '\0' &&
                    strncmp(nick, "Unknown", 7) != 0;
    BOOL showNick = (showName && haveNick);
    BOOL showMeters = showDist;
    if (showNick && showMeters) {
        snprintf(out, outCap, "%s\n%.0fm", nick, b.distance);
    } else if (showNick) {
        snprintf(out, outCap, "%s", nick);
    } else if (showMeters && b.health >= 0 && b.health <= 100) {
        snprintf(out, outCap, "%.0fm %d%%", b.distance, b.health);
    } else if (showMeters) {
        snprintf(out, outCap, "%.0fm", b.distance);
    } else {
        out[0] = '\0';
    }
}

// kernrw49: snapline point p trong hệ game-landscape (b.x, b.y, b.w, b.h đã
// map thành fullBox). Mục đích mirror. pt không dùng — đây chỉ điểm đơn TOP
// (Kernel dùng AddLine chỉ từ center đến đỉnh box); ready if in future open
// bottom/a head, for now returns 1 line.
static inline CGPoint ds_esp_line_for_box(ESPBox2D __unused b, CGRect fullBox,
                                          CGFloat __unused landW,
                                          CGFloat __unused landH,
                                          CGPoint __unused winCenter,
                                          int __unused mapOrient, int __unused pt) {
    // Đã map, được dùng cho mirror dirty — trả về điểm TOP box (center của top edge)
    // để mirror check (Kernel line đi xuống từ đỉnh — chỉ cần điểm đỉnh).
    return CGPointMake(CGRectGetMidX(fullBox), fullBox.origin.y);
}

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

    uint64_t red = ds_remote_get_object_on_main(process, colorClass, "systemRedColor");

    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, secureField,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
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
                                   red ?: white, YES);
    ds_remote_set_u64_on_main(process, label, "setNumberOfLines:",
                              (uint64_t)presentation.numberOfLines);
    ds_remote_set_u64_on_main(process, label, "setHidden:", 0);
    uint64_t font = ds_remote_font(process, presentation.fontSize,
                                   YES);
    if (!font) return 0;
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setFont:"), font, YES);
    ds_remote_set_u64_on_main(process, label, "setAdjustsFontSizeToFitWidth:", 0);
    ds_remote_set_u64_on_main(process, label, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, label, "setTextAlignment:",
                              (uint64_t)presentation.alignment);
    ds_remote_set_double_on_main(process, label, "setAlpha:", 1.0);

    uint64_t labelLayer = ds_remote_get_object_on_main(process, label, "layer");
    if (labelLayer) {
        ds_remote_set_double_on_main(process, labelLayer, "setShadowOpacity:", 1.0);
        ds_remote_set_double_on_main(process, labelLayer, "setShadowRadius:", 2.0);
    }

    uint64_t layer = ds_remote_get_object_on_main(process, blurView, "layer");
    if (layer) {
        ds_remote_set_double_on_main(process, layer, "setCornerRadius:", 0.0);
        ds_remote_set_u64_on_main(process, layer, "setMasksToBounds:", 0);
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
    ds_remote_cache_ensure();
    [s_remoteCacheLock lock];
    @try {
        if (!cache) cache = [NSMutableDictionary dictionary];
        NSString *key = [NSString stringWithUTF8String:name];
        if (!key) return NULL;
        NSNumber *hit = cache[key];
        if (hit) return (void *)(uintptr_t)hit.unsignedLongLongValue;
        void *addr = dlsym(RTLD_DEFAULT, name);
        if (addr) cache[key] = @((uint64_t)(uintptr_t)addr);
        return addr;
    } @finally {
        [s_remoteCacheLock unlock];
    }
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

static BOOL ds_esp_path_update(RemoteCall *process, CGPoint *pts, int count) {
    // kernrw49: snapline - CGPathAddLines voi polyline "center->box1->center->
    // box2->center..." - moi line deu START tai cung diem (center man hinh),
    // quay lai center giua 2 line KHONG tao duong rac (no chinh la duong da vẽ).
    // 1 CGPathAddLines cho TAT CA snapline (~5 remote call/frame).
    if (!process || !process.trojanMem || !g_espPathLayer) return NO;
    static BOOL s_pathEmpty = NO;
    if (!pts || count <= 0) {
        if (!s_pathEmpty) {
            ds_perform_on_springboard_main(process, g_espPathLayer,
                                           ds_remote_sel(process, "setPath:"), 0, YES);
            s_pathEmpty = YES;
            if (g_espPathObj) {
                void *relSym = ds_remote_system_symbol("CGPathRelease");
                if (relSym) DSRemoteArbCallWithTimeout(1, process, relSym, g_espPathObj);
                g_espPathObj = 0;
            }
        }
        return YES;
    }
    s_pathEmpty = NO;
    size_t bytes = (size_t)count * sizeof(CGPoint);
    if (!g_espRectsAddr || g_espRectsCap < bytes) {
        if (g_espRectsAddr) {
            void *freeSym = ds_remote_system_symbol("free");
            if (freeSym) DSRemoteArbCallWithTimeout(1, process, freeSym, g_espRectsAddr);
            g_espRectsAddr = 0;
            g_espRectsCap = 0;
        }
        void *mallocSym = ds_remote_system_symbol("malloc");
        if (!mallocSym) return NO;
        int allocCap = bytes > 4096 ? (int)bytes : 4096;
        uint64_t addr = (uint64_t)DSRemoteArbCallWithTimeout(1, process, mallocSym, (uint64_t)allocCap);
        if (!addr) return NO;
        g_espRectsAddr = addr;
        g_espRectsCap = allocCap;
    }
    if (![process remote_write:g_espRectsAddr from:pts size:(uint64_t)bytes]) return NO;
    void *createSym = ds_remote_system_symbol("CGPathCreateMutable");
    void *addSym = ds_remote_system_symbol("CGPathAddLines");
    void *releaseSym = ds_remote_system_symbol("CGPathRelease");
    if (!createSym || !addSym || !releaseSym) {
        g_espPathFails++;
        return NO;
    }
    uint64_t path = (uint64_t)DSRemoteArbCallWithTimeout(1, process, createSym, (uint64_t)0);
    if (!path) {
        g_espPathFails++;
        return NO;
    }
    DSRemoteArbCallWithTimeout(1, process, addSym, path, 0, g_espRectsAddr, (uint64_t)count);
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
    // được (xả, ensure dựng lại bên dưới nếu batching còn bật).
    // Views mới = địa chỉ mới -> xả invocation cache (kẻo bắn nhầm view cũ).
    g_espPathLayer = 0;
    g_espPathObj = 0;
    g_espRectsAddr = 0;
    g_espRectsCap = 0;
    for (int k = 0; k < ESPOverlayMaxBoxes; k++) {
        g_espHpBG[k] = 0;
        g_espHpFill[k] = 0;
        g_espHpBand[k] = 0xFF;
        g_espHpFillH[k] = 0xFFFFFFFF;
        g_espHpFrameH[k] = 0.0f;
    }
    g_dsRedColor = 0;
    g_dsYellowColor = 0;
    g_dsGreenColor = 0;
    ds_inv_cache_drop();
    if (g_espWindow && g_espContainer) {
#if DS_ESP_RENDER_COMMANDLIST
        // QBL: window+container là đủ. Layer/label do ds_qbl_present dựng lazy
        // theo frame đầu tiên cần tới (xem kQBLShapeBudgetPerTick).
        return YES;
#else
        BOOL ok = YES;
        for (int i = 0; i < ESPOverlayMaxBoxes && ok; i++) {
            ok = (g_espBorders[i][0] != 0) && (g_espLabels[i] != 0);
        }
        if (ok) return YES;
#endif
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
    // kernrw49: mau health bar theo band (Kernel: <30%% do, <60%% vang, con lai xanh la)
    // + den cho nen bar. Fail mau -> bo per-box health bar (ESP van chay, label chi con dist).
    uint64_t black = ds_remote_get_object_on_main(process, colorClass, "blackColor");
    uint64_t green = ds_remote_get_object_on_main(process, colorClass, "greenColor");
    uint64_t yellow = ds_remote_get_object_on_main(process, colorClass, "yellowColor");
    g_dsRedColor = red;
    g_dsYellowColor = yellow;
    g_dsGreenColor = green;
    if (!clear || !red || !white) return NO;
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_remote_set_u64_on_main(process, container, "setTag:", (uint64_t)kDSESPOverlayTag);
    ds_remote_set_u64_on_main(process, container, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, container, "setHidden:", 0);
    ds_remote_set_rect_on_main(process, container, "setFrame:", portraitBounds);

#if !DS_ESP_RENDER_COMMANDLIST
    BOOL hpColorOK = (black && green && yellow);
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
        // kernrw49: viền box màu TRẮNG (giống Kernel Box4Line ai ImColor(255,255,255))
        uint64_t cgColor = ds_remote_get_u64_on_main(process, white, "CGColor");
        if (cgColor) ds_perform_on_springboard_main(process, layer, ds_remote_sel(process, "setBorderColor:"), cgColor, YES);
        // Tắt implicit animation bằng cách đặt speed rất cao (999.0) để animation kết thúc tức thì
        ds_remote_set_double_on_main(process, layer, "setSpeed:", 999.0);
        
        ds_perform_on_springboard_main(process, container, ds_remote_sel(process, "addSubview:"), v, YES);
        
        g_espBorders[i][0] = v; // Dùng 1 view duy nhất cho toàn bộ khung box
        g_espBorderLayer[i] = layer;
        g_espBoxBorderOn[i] = YES;
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
        // kernrw49: 2 dòng "Nickname\n123m" (giống Kernel name 18f trắng +
        // distance 16f vàng, placement dưới box) -> numberOfLines 2.
        ds_remote_set_u64_on_main(process, lb, "setNumberOfLines:", 2);
        ds_remote_set_u64_on_main(process, lb, "setHidden:", 1);
        ds_remote_set_u64_on_main(process, lb, "setUserInteractionEnabled:", 0);
        // kernrw51: label cache cờ — setHidden:1 riêng của label (unhide cha
        // không unhide con) => hội tụ qua g_espLabelShown trong vòng vẽ.
        g_espLabelShown[i] = NO;
        // Bounds 140x28: đủ rộng cho nickname + dòng distance. Transform ±90°
        // khi mapOrient landscape vẫn chỉ di center, giữ bounds.
        ds_remote_set_rect_on_main(process, lb, "setBounds:", CGRectMake(0, 0, 140.0, 28.0));
        ds_remote_set_rect_on_main(process, lb, "setFrame:", CGRectMake(0, 0, 140.0, 28.0));
        
        uint64_t lbLayer = ds_remote_get_object_on_main(process, lb, "layer");
        ds_remote_set_double_on_main(process, lbLayer, "setSpeed:", 999.0);
        
        // kernrw49: health bar 2 view con của border view (giữ cùng pattern
        // "label là subview -> ẩn theo cha": hp bar ẨN chỉ khi border ẩn).
        g_espHpBG[i] = 0;
        g_espHpFill[i] = 0;
        g_espHpBand[i] = 0xFF;
        g_espHpFillH[i] = 0xFFFFFFFF;
        g_espHpFrameH[i] = 0.0f;
        g_espHpShown[i] = NO;
        if (hpColorOK) {
            uint64_t hfill = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
            if (hfill && ds_remote_invoke_noarg_on_main(process, hfill, "init")) {
                ds_perform_on_springboard_main(process, hfill, ds_remote_sel(process, "setBackgroundColor:"), green, YES);
                ds_remote_set_u64_on_main(process, hfill, "setHidden:", 1);
                ds_remote_set_u64_on_main(process, hfill, "setUserInteractionEnabled:", 0);
                ds_remote_set_rect_on_main(process, hfill, "setFrame:", CGRectMake(0, 0, 6.0, 4.0));
                ds_perform_on_springboard_main(process, v, ds_remote_sel(process, "addSubview:"), hfill, YES);
                g_espHpFill[i] = hfill;
            }
        }

        ds_perform_on_springboard_main(process, v, ds_remote_sel(process, "addSubview:"), lb, YES);
        g_espLabels[i] = lb;
        g_espHiddenCache[i] = YES;
        g_espLabelShown[i] = NO;
        // kernrw51: hp cache cũng reset khi rebuild views (ensure mới).
        g_espHpShown[i] = NO;
        g_espHpBand[i] = 0xFF;
        g_espHpFillH[i] = 0xFFFFFFFF;
        g_espHpFrameH[i] = 0.0f;

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
#endif // !DS_ESP_RENDER_COMMANDLIST

    ds_trace("esp ensure: attaching window");
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "addSubview:"), container, YES);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);
    ds_trace("esp ensure: window shown");
    g_espWindow = window;
    g_espContainer = container;
    g_espWindowPid = (pid_t)process.pid;
    g_espWindowHiddenCache = NO;
    g_espLastContainerBounds = CGRectZero;
    g_espLastMapOrient = UIInterfaceOrientationUnknown;
    ESPLog("esp ensure ok pid=%d win=0x%llx cont=0x%llx renderer=%s",
           (int)process.pid, (unsigned long long)window,
           (unsigned long long)container,
           DS_ESP_RENDER_COMMANDLIST ? "qbl" : "per-box");
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

// ===========================================================================
// MARK: - QBL-style renderer: Frame builder + batched presenter
// ---------------------------------------------------------------------------
// Port kiến trúc QBL (QBLDrawList -> DSOverlay::PresentFrame):
//   1. ds_qbl_build_frame() gom TOÀN BỘ primitive của 1 frame vào draw list
//      CPU (ESPOverlay.mm) — đúng bộ hàm QBL dùng: AddRect/AddRectFilled/
//      AddLine/AddCircle/AddTriangleFilled/AddOutlinedText.
//   2. ds_qbl_present() bắn sang SpringBoard theo BATCH:
//        - mỗi style (box/box AI/snapline/xương/head dot/AI mark/HP) là 1
//          CAShapeLayer tái sử dụng;
//        - rect gom 1 lần bằng CGPathAddRects, polyline bằng CGPathAddLines
//          (points/rects nằm trong 1 buffer remote, write 1 lần/frame);
//        - text vào pool UILabel (setText khi đổi, setFrame 30Hz) — thay cho
//          attributed-string stroke của QBL bằng shadow đen set 1 lần.
//   3. Frame trùng hash (không có gì đổi) -> bỏ qua toàn bộ remote call.
// Toàn bộ nằm trong 1 UIView gốc (g_qblRoot) => hide/show 1 call.
// Cờ DS_ESP_RENDER_COMMANDLIST=0 để quay lại renderer per-box cũ.
// (Cờ được định nghĩa ở đầu file để ds_esp_overlay_ensure_impl dùng được.)
// ===========================================================================

enum {
    kQBLBucketBox = 0,   // viền box player (trắng)
    kQBLBucketBoxAI,     // viền box AI (vàng, đậm hơn)
    kQBLBucketLine,      // snapline (trắng)
    kQBLBucketBone,      // xương (xanh lá)
    kQBLBucketDot,       // head dot (trắng, tô)
    kQBLBucketAIMark,    // tam giác AI + dot AI (vàng, tô + viền)
    kQBLBucketHpBg,      // nền thanh máu (đen, tô)
    kQBLBucketHpRed,     // máu < 30% (tô)
    kQBLBucketHpYellow,  // máu 30-59% (tô)
    kQBLBucketHpGreen,   // máu >= 60% (tô)
    kQBLBucketCount
};

// 0xAARRGGBB — cùng quy ước màu với QBL draw list.
static const uint32_t kQBLColorBox = 0xFFFFFFFFu;
static const uint32_t kQBLColorAI  = 0xFFFFD040u;
static const uint32_t kQBLColorLine = 0xFFFFFFFFu;
static const uint32_t kQBLColorBone = 0xFF35E06Au;
static const uint32_t kQBLColorDot = 0xFFFFFFFFu;
static const uint32_t kQBLColorHpBg = 0xFF000000u;
static const uint32_t kQBLColorHpRed = 0xFFFF3B30u;
static const uint32_t kQBLColorHpYellow = 0xFFFFCC00u;
static const uint32_t kQBLColorHpGreen = 0xFF34C759u;

static uint32_t ds_qbl_bucket_color(int bucket) {
    switch (bucket) {
        case kQBLBucketBox: return kQBLColorBox;
        case kQBLBucketBoxAI: return kQBLColorAI;
        case kQBLBucketLine: return kQBLColorLine;
        case kQBLBucketBone: return kQBLColorBone;
        case kQBLBucketDot: return kQBLColorDot;
        case kQBLBucketAIMark: return kQBLColorAI;
        case kQBLBucketHpBg: return kQBLColorHpBg;
        case kQBLBucketHpRed: return kQBLColorHpRed;
        case kQBLBucketHpYellow: return kQBLColorHpYellow;
        case kQBLBucketHpGreen: return kQBLColorHpGreen;
        default: return 0xFFFFFFFFu;
    }
}

static float ds_qbl_bucket_width(int bucket) {
    switch (bucket) {
        case kQBLBucketBox: return 1.5f;
        case kQBLBucketBoxAI: return 2.0f;
        case kQBLBucketLine: return 1.0f;
        case kQBLBucketBone: return 1.2f;
        case kQBLBucketAIMark: return 1.5f;
        default: return 1.0f;
    }
}

static BOOL ds_qbl_bucket_filled(int bucket) {
    return bucket == kQBLBucketDot || bucket == kQBLBucketAIMark ||
           bucket >= kQBLBucketHpBg;
}

static BOOL ds_qbl_bucket_stroked(int bucket) {
    return bucket <= kQBLBucketAIMark; // box/line/bone/dot/AIMark đều có viền
}

#define kQBLLabelCount (ESPOverlayMaxBoxes * 2) // 0..7 = tên/máu, 8..15 = TeamID
#define DS_QBL_MAX_RECTS 32
#define DS_QBL_MAX_POLYS 16

typedef struct {
    BOOL box, line, name, dist, health, teamID, headDot, aiMark, bones;
    float scale;
} DSQBLFeat;

typedef struct {
    int start;
    int count;
} DSQBLPolyRef;

// --- remote object cache (theo pid SpringBoard; pid đổi = dựng lại) ---
static pid_t g_qblPid = 0;
static uint64_t g_qblContainer = 0;
static uint64_t g_qblRoot = 0;
static uint64_t g_qblRootLayer = 0;
static uint64_t g_qblShape[kQBLBucketCount];
static uint64_t g_qblShapePath[kQBLBucketCount];
static uint64_t g_qblShapeHash[kQBLBucketCount]; // hash nội dung path đã set (dirty per-bucket)
static uint64_t g_qblLabel[kQBLLabelCount];
static uint32_t g_qblLabelColor[kQBLLabelCount];
static char g_qblLabelText[kQBLLabelCount][112];
static CGRect g_qblLabelRect[kQBLLabelCount];
static BOOL g_qblLabelRectValid[kQBLLabelCount];
static BOOL g_qblLabelShown[kQBLLabelCount];
static CFAbsoluteTime g_qblLabelAt[kQBLLabelCount];
static BOOL g_qblRootHidden = YES;
static CGRect g_qblRootFrame;
static CGRect g_qblWindowFrame;
static uint64_t g_qblBufAddr = 0;
static int g_qblBufCap = 0;
static uint64_t g_qblFrameHash = 0;
static unsigned long g_qblFrames = 0;
static unsigned long g_qblSkips = 0;
// Style dùng chung cho mọi label/layer.
// QUAN TRỌNG: chỉ dùng màu SINGLETON của UIColor (+clearColor/+whiteColor/
// +blackColor/+redColor/+yellowColor/+greenColor). KHÔNG dùng
// +colorWithRed:green:blue:alpha: qua RemoteCall: object trả về là autoreleased
// trong SpringBoard, pool của SB có thể giải phóng nó trước khi lệnh `retain`
// kế tiếp chạm tới -> objc_msgSend fault -> RemoteCall tự destroyRemoteCall
// (trojanMem=0) -> HUD không hide được nữa. Đây đúng là lỗi trong log
// 12:00:28 (style ok shadow=0 font=0/0 rồi disable session=-1).
static uint64_t g_qblClearColor = 0;
static uint64_t g_qblWhiteColor = 0;
static uint64_t g_qblAIColor = 0;      // +yellowColor
static uint64_t g_qblBlackColor = 0;   // +blackColor (shadow + HP nền)
static uint64_t g_qblRedColor = 0;     // +redColor
static uint64_t g_qblGreenColor = 0;   // +greenColor
static uint64_t g_qblShadowCG = 0;
static uint64_t g_qblFontMain = 0;     // font riêng 13pt (retained)
static uint64_t g_qblFontSmall = 0;
static BOOL g_qblStyleOK = NO;
static uint8_t g_qblStyleFails = 0;    // fail liên tiếp -> tắt QBL, tránh giết session
static BOOL g_qblDead = NO;            // đường vẽ QBL đã bị bỏ trong session này
// Đếm số lần tạo fail để không kẹt vòng "missing -> present mãi".
static uint8_t g_qblShapeFail[kQBLBucketCount];
static uint8_t g_qblLabelFail[kQBLLabelCount];
// Lazy creation: mỗi tick tối đa N object mới (tránh dồn ~180 remote call).
// qblpack: hạ 2 -> 1. Mỗi object là 8-10 RemoteCall (alloc/init/set...); tạo
// 2 shape + 2 label trong 1 tick từng làm present đầu mất 2.8s, dễ watchdog.
#define kQBLShapeBudgetPerTick 1
#define kQBLLabelBudgetPerTick 1
static int s_qblShapeBudget = 0;
static int s_qblLabelBudget = 0;

// --- per-frame accumulators (mapped sang portrait) ---
static CGRect s_qblRects[kQBLBucketCount][DS_QBL_MAX_RECTS];
static int s_qblRectCount[kQBLBucketCount];
static DSQBLPolyRef s_qblPolys[kQBLBucketCount][DS_QBL_MAX_POLYS];
static int s_qblPolyCount[kQBLBucketCount];
static CGPoint s_qblPts[ESP_DRAW_MAX_POINTS];
static int s_qblPtCount = 0;
static CGRect s_qblAllRects[kQBLBucketCount * DS_QBL_MAX_RECTS];
// Text tách khỏi geometry: label đặt theo anchor đã map + quantize 0.5pt.
static ESPDrawCommand s_qblTexts[kQBLLabelCount];
static CGPoint s_qblTextAnchor[kQBLLabelCount];
static uint64_t s_qblTextHash[kQBLLabelCount];
static int s_qblTextCount = 0;

static void ds_qbl_reset_remote(void) {
    g_qblPid = 0;
    g_qblContainer = 0;
    g_qblRoot = 0;
    g_qblRootLayer = 0;
    memset(g_qblShape, 0, sizeof(g_qblShape));
    memset(g_qblShapePath, 0, sizeof(g_qblShapePath));
    memset(g_qblShapeHash, 0, sizeof(g_qblShapeHash));
    memset(g_qblLabel, 0, sizeof(g_qblLabel));
    memset(g_qblLabelRectValid, 0, sizeof(g_qblLabelRectValid));
    memset(g_qblLabelShown, 0, sizeof(g_qblLabelShown));
    memset(g_qblLabelText, 0, sizeof(g_qblLabelText));
    memset(g_qblLabelColor, 0, sizeof(g_qblLabelColor));
    memset(g_qblLabelAt, 0, sizeof(g_qblLabelAt));
    g_qblBufAddr = 0;
    g_qblBufCap = 0;
    g_qblRootHidden = YES;
    g_qblRootFrame = CGRectZero;
    g_qblWindowFrame = CGRectZero;
    g_qblFrameHash = 0;
    g_qblClearColor = 0;
    g_qblWhiteColor = 0;
    g_qblAIColor = 0;
    g_qblBlackColor = 0;
    g_qblRedColor = 0;
    g_qblGreenColor = 0;
    g_qblShadowCG = 0;
    g_qblFontMain = 0;
    g_qblFontSmall = 0;
    g_qblStyleOK = NO;
    g_qblStyleFails = 0;
    g_qblDead = NO;
    memset(g_qblShapeFail, 0, sizeof(g_qblShapeFail));
    memset(g_qblLabelFail, 0, sizeof(g_qblLabelFail));
    s_qblShapeBudget = 0;
    s_qblLabelBudget = 0;
    s_qblTextCount = 0;
}

// Trả UIColor singleton theo bucket — KHÔNG tạo object mới, KHÔNG retain.
// Màu gần đúng với QBL draw list (yellow/green/red của UIKit) nhưng an toàn
// tuyệt đối vì các singleton sống suốt đời SpringBoard.
static uint64_t ds_qbl_color_for_bucket(int bucket) {
    switch (bucket) {
        case kQBLBucketBox:      return g_qblWhiteColor;
        case kQBLBucketBoxAI:    return g_qblAIColor ? g_qblAIColor : g_qblWhiteColor;
        case kQBLBucketLine:     return g_qblWhiteColor;
        case kQBLBucketBone:     return g_qblGreenColor ? g_qblGreenColor : g_qblWhiteColor;
        case kQBLBucketDot:      return g_qblWhiteColor;
        case kQBLBucketAIMark:   return g_qblAIColor ? g_qblAIColor : g_qblWhiteColor;
        case kQBLBucketHpBg:     return g_qblBlackColor ? g_qblBlackColor : g_qblWhiteColor;
        case kQBLBucketHpRed:    return g_qblRedColor ? g_qblRedColor : g_qblWhiteColor;
        case kQBLBucketHpYellow: return g_qblAIColor ? g_qblAIColor : g_qblWhiteColor;
        case kQBLBucketHpGreen:  return g_qblGreenColor ? g_qblGreenColor : g_qblWhiteColor;
        default:                 return g_qblWhiteColor;
    }
}

static BOOL ds_qbl_buf(RemoteCall *process, size_t bytes) {
    if (!process || !process.trojanMem || bytes == 0) return NO;
    if (g_qblBufAddr && (size_t)g_qblBufCap >= bytes) return YES;
    if (g_qblBufAddr) {
        void *freeSym = ds_remote_system_symbol("free");
        if (freeSym) DSRemoteArbCallWithTimeout(1, process, freeSym, g_qblBufAddr);
        g_qblBufAddr = 0;
        g_qblBufCap = 0;
    }
    void *mallocSym = ds_remote_system_symbol("malloc");
    if (!mallocSym) return NO;
    int cap = bytes < 16384 ? 16384 : (int)bytes;
    uint64_t addr = (uint64_t)DSRemoteArbCallWithTimeout(1, process, mallocSym, (uint64_t)cap);
    if (!addr) return NO;
    g_qblBufAddr = addr;
    g_qblBufCap = cap;
    return YES;
}

// setPath: + release path cũ (path mới do layer giữ).
static BOOL ds_qbl_set_path(RemoteCall *process, int bucket, uint64_t path) {
    if (!process || bucket < 0 || bucket >= kQBLBucketCount || !g_qblShape[bucket]) return NO;
    if (!ds_perform_on_springboard_main(process, g_qblShape[bucket],
                                        ds_remote_sel(process, "setPath:"), path, YES)) {
        if (path) {
            void *rel = ds_remote_system_symbol("CGPathRelease");
            if (rel) DSRemoteArbCallWithTimeout(1, process, rel, path);
        }
        return NO;
    }
    if (g_qblShapePath[bucket]) {
        void *rel = ds_remote_system_symbol("CGPathRelease");
        if (rel) DSRemoteArbCallWithTimeout(1, process, rel, g_qblShapePath[bucket]);
    }
    g_qblShapePath[bucket] = path;
    return YES;
}

// --- style dùng chung: tạo 1 lần/session ---
// Chỉ dùng màu SINGLETON (proven path của renderer cũ) — không tạo object
// autoreleased qua RemoteCall. Font mượn từ label HUD để khỏi factory/retain.
static BOOL ds_qbl_style_ready(RemoteCall *process) {
    if (g_qblStyleOK) return YES;
    if (!process || !process.trojanMem) return NO;
    uint64_t colorClass = ds_remote_class(process, "UIColor");
    if (!colorClass) return NO;

    if (!g_qblClearColor) g_qblClearColor = ds_remote_get_object_on_main(process, colorClass, "clearColor");
    if (!g_qblWhiteColor) g_qblWhiteColor = ds_remote_get_object_on_main(process, colorClass, "whiteColor");
    if (!g_qblClearColor || !g_qblWhiteColor) {
        const char *err = process.lastError.UTF8String;
        ESPLog("qbl style fail clear=0x%llx white=0x%llx err=%s",
               (unsigned long long)g_qblClearColor,
               (unsigned long long)g_qblWhiteColor, err ? err : "-");
        if (g_qblStyleFails < 255) g_qblStyleFails++;
        return NO;
    }
    if (!g_qblAIColor)    g_qblAIColor    = ds_remote_get_object_on_main(process, colorClass, "yellowColor");
    if (!g_qblBlackColor) g_qblBlackColor = ds_remote_get_object_on_main(process, colorClass, "blackColor");
    if (!g_qblRedColor)   g_qblRedColor   = ds_remote_get_object_on_main(process, colorClass, "redColor");
    if (!g_qblGreenColor) g_qblGreenColor = ds_remote_get_object_on_main(process, colorClass, "greenColor");
    if (!g_qblAIColor)    g_qblAIColor    = g_qblWhiteColor;
    if (!g_qblBlackColor) g_qblBlackColor = g_qblWhiteColor;
    if (!g_qblRedColor)   g_qblRedColor   = g_qblWhiteColor;
    if (!g_qblGreenColor) g_qblGreenColor = g_qblWhiteColor;

    // qblpack FONT: KHÔNG mượn font HUD. HUD mặc định 24pt (custom 14..40)
    // trong khi rect QBL thiết kế cho 13pt (tên+mét, 180x32) và 11pt
    // (TeamID, 84x15) -> chữ tràn/che box. UIFont là object cache/immortal
    // nên retain-after-sync an toàn (không dính race như UIColor factory).
    if (!g_qblFontMain)  g_qblFontMain  = ds_remote_font(process, 13.0, NO);
    if (!g_qblFontSmall) g_qblFontSmall = ds_remote_font(process, 11.0, NO);
    if (!g_qblFontMain && g_remoteLabel && g_remoteWindowPid == (pid_t)process.pid) {
        // Fallback duy nhất: font HUD (chữ vẫn hiện, chỉ to hơn thiết kế).
        g_qblFontMain = ds_remote_get_object_on_main(process, g_remoteLabel, "font");
    }
    if (!g_qblFontSmall) g_qblFontSmall = g_qblFontMain;

    // Shadow text: CGColor của blackColor (getter, không retain CF object).
    if (!g_qblShadowCG) {
        g_qblShadowCG = ds_remote_get_object_on_main(process, g_qblBlackColor, "CGColor");
    }
    g_qblStyleOK = YES;
    g_qblStyleFails = 0;
    ESPLog("qbl style ok shadow=%d font=%d small=%d ai=%d green=%d red=%d",
           g_qblShadowCG ? 1 : 0, g_qblFontMain ? 1 : 0, g_qblFontSmall ? 1 : 0,
           g_qblAIColor ? 1 : 0, g_qblGreenColor ? 1 : 0, g_qblRedColor ? 1 : 0);
    return YES;
}

// Tạo CAShapeLayer theo nhu cầu, tối đa kQBLShapeBudgetPerTick object/tick.
// Budget là hàng rào chống dồn hàng trăm remote call trong 1 tick (mỗi remote
// call timeout = RemoteCall tự destroy -> HUD đứng, ESP mất).
static uint64_t ds_qbl_shape_for(RemoteCall *process, int bucket) {
    if (bucket < 0 || bucket >= kQBLBucketCount) return 0;
    if (g_qblShape[bucket]) return g_qblShape[bucket];
    if (!process || !process.trojanMem || !g_qblRootLayer) return 0;
    if (s_qblShapeBudget <= 0) return 0;
    uint64_t shapeClass = ds_remote_class(process, "CAShapeLayer");
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t addSublayer = ds_remote_sel(process, "addSublayer:");
    if (!shapeClass || !alloc || !addSublayer) {
        if (g_qblShapeFail[bucket] < 255) g_qblShapeFail[bucket]++;
        ESPLog("qbl shape fail: class=0x%llx alloc=0x%llx addSub=0x%llx",
               (unsigned long long)shapeClass, (unsigned long long)alloc,
               (unsigned long long)addSublayer);
        return 0;
    }
    ESPLog("qbl phase: shape %d", bucket);
    uint64_t layer = remote_msg(process, shapeClass, alloc, 0, 0, 0, 0);
    if (!layer || !ds_remote_invoke_noarg_on_main(process, layer, "init")) {
        if (g_qblShapeFail[bucket] < 255) g_qblShapeFail[bucket]++;
        return 0;
    }
    ds_remote_set_rect_on_main(process, layer, "setFrame:", g_qblRootFrame);
    ds_remote_set_float_on_main(process, layer, "setSpeed:", 1000.0f);
    ds_remote_set_double_on_main(process, layer, "setLineWidth:", (double)ds_qbl_bucket_width(bucket));
    // CAShapeLayer nhận CGColorRef -> lấy từ UIColor singleton (getter, không
    // retain CF; cùng pattern setBorderColor:/setStrokeColor: của renderer cũ).
    uint64_t color = ds_qbl_color_for_bucket(bucket);
    uint64_t cg = color ? ds_remote_get_object_on_main(process, color, "CGColor") : 0;
    if (cg) {
        if (ds_qbl_bucket_stroked(bucket)) {
            ds_perform_on_springboard_main(process, layer, ds_remote_sel(process,
                "setStrokeColor:"), cg, YES);
        }
        if (ds_qbl_bucket_filled(bucket)) {
            ds_perform_on_springboard_main(process, layer, ds_remote_sel(process,
                "setFillColor:"), cg, YES);
        }
    }
    if (!ds_perform_on_springboard_main(process, g_qblRootLayer, addSublayer, layer, YES)) {
        if (g_qblShapeFail[bucket] < 255) g_qblShapeFail[bucket]++;
        return 0;
    }
    s_qblShapeBudget--;
    g_qblShape[bucket] = layer;
    g_qblShapeHash[bucket] = 0;
    ESPLog("qbl shape %d created (budget %d)", bucket, s_qblShapeBudget);
    return layer;
}

// UILabel lazy. Slot chẵn = tên + mét (2 dòng), slot lẻ = TeamID (1 dòng).
static uint64_t ds_qbl_label_for(RemoteCall *process, int slot) {
    if (slot < 0 || slot >= kQBLLabelCount) return 0;
    if (g_qblLabel[slot]) return g_qblLabel[slot];
    if (!process || !process.trojanMem || !g_qblRoot) return 0;
    if (!ds_qbl_style_ready(process)) {
        if (g_qblLabelFail[slot] < 255) g_qblLabelFail[slot]++;
        return 0;
    }
    if (s_qblLabelBudget <= 0) return 0;
    uint64_t labelClass = ds_remote_class(process, "UILabel");
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t addSubview = ds_remote_sel(process, "addSubview:");
    if (!labelClass || !alloc || !addSubview) {
        if (g_qblLabelFail[slot] < 255) g_qblLabelFail[slot]++;
        return 0;
    }
    ESPLog("qbl phase: label %d", slot);
    uint64_t lb = remote_msg(process, labelClass, alloc, 0, 0, 0, 0);
    if (!lb || !ds_remote_invoke_noarg_on_main(process, lb, "init")) {
        if (g_qblLabelFail[slot] < 255) g_qblLabelFail[slot]++;
        return 0;
    }
    ds_remote_set_u64_on_main(process, lb, "setHidden:", 1);
    ds_remote_set_u64_on_main(process, lb, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, lb, "setNumberOfLines:", (slot % 2 == 0) ? 2 : 1);
    ds_remote_set_u64_on_main(process, lb, "setTextAlignment:", 1);
    ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setTextColor:"),
                                   g_qblWhiteColor, YES);
    ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setBackgroundColor:"),
                                   g_qblClearColor, YES);
    uint64_t f = (slot % 2 == 0) ? g_qblFontMain : g_qblFontSmall;
    if (f) ds_perform_on_springboard_main(process, lb, ds_remote_sel(process, "setFont:"), f, YES);
    // QBL AddOutlinedText: UILabel không có stroke -> shadow đen (bán kính 1.2,
    // offset 0) set MỘT lần lúc tạo, 0 chi phí/frame.
    if (g_qblShadowCG) {
        uint64_t lbLayer = ds_remote_get_object_on_main(process, lb, "layer");
        if (lbLayer) {
            ds_perform_on_springboard_main(process, lbLayer, ds_remote_sel(process,
                "setShadowColor:"), g_qblShadowCG, YES);
            ds_remote_set_float_on_main(process, lbLayer, "setShadowOpacity:", 1.0f);
            ds_remote_set_double_on_main(process, lbLayer, "setShadowRadius:", 1.2);
            ds_remote_set_point_on_main(process, lbLayer, "setShadowOffset:", CGPointMake(0, 0));
        }
    }
    if (!ds_perform_on_springboard_main(process, g_qblRoot, addSubview, lb, YES)) {
        if (g_qblLabelFail[slot] < 255) g_qblLabelFail[slot]++;
        return 0;
    }
    s_qblLabelBudget--;
    g_qblLabel[slot] = lb;
    g_qblLabelColor[slot] = 0xFFFFFFFFu;
    g_qblLabelText[slot][0] = '\0';
    g_qblLabelRectValid[slot] = NO;
    g_qblLabelShown[slot] = NO;
    g_qblLabelAt[slot] = 0;
    ESPLog("qbl label %d created (budget %d)", slot, s_qblLabelBudget);
    return lb;
}

static BOOL ds_qbl_ensure(RemoteCall *process, CGRect portraitBounds) {
    if (!process || !process.trojanMem || g_qblDead) return NO;
    // pid/container đổi = mọi địa chỉ cache vô nghĩa (respring hoặc rebuild overlay).
    if (g_qblPid != (pid_t)process.pid || g_qblContainer != g_espContainer) {
        ds_qbl_reset_remote();
    }
    if (g_qblRoot && g_qblRootLayer) {
        if (!CGRectEqualToRect(g_qblRootFrame, portraitBounds)) {
            ds_remote_set_rect_on_main(process, g_qblRoot, "setFrame:", portraitBounds);
            for (int i = 0; i < kQBLBucketCount; i++) {
                if (g_qblShape[i]) {
                    ds_remote_set_rect_on_main(process, g_qblShape[i], "setFrame:", portraitBounds);
                }
            }
            g_qblRootFrame = portraitBounds;
        }
        return YES;
    }
    if (!g_espContainer) {
        ESPLog("qbl ensure fail: no esp container");
        return NO;
    }

    uint64_t viewClass = ds_remote_class(process, "UIView");
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t addSubview = ds_remote_sel(process, "addSubview:");
    if (!viewClass || !alloc || !addSubview) {
        ESPLog("qbl ensure fail: class=0x%llx alloc=0x%llx addSub=0x%llx",
               (unsigned long long)viewClass, (unsigned long long)alloc,
               (unsigned long long)addSubview);
        return NO;
    }
    // qblpack: KHÔNG dựng style (6 màu + 2 font + shadow) trong cùng tick với
    // root nữa. Tick đầu chỉ tạo root (3 call), tick sau mới style -> tránh
    // dồn ~15 RemoteCall liên tiếp làm SpringBoard main thread đứng lâu.
    ESPLog("qbl phase: root create");
    uint64_t root = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    if (!root || !ds_remote_invoke_noarg_on_main(process, root, "init")) {
        const char *err = process.lastError.UTF8String;
        ESPLog("qbl ensure fail: root=0x%llx err=%s",
               (unsigned long long)root, err ? err : "-");
        return NO;
    }
    ds_remote_set_rect_on_main(process, root, "setFrame:", portraitBounds);
    ds_remote_set_u64_on_main(process, root, "setUserInteractionEnabled:", 0);
    // Root UIView mặc định trong suốt (backgroundColor=nil) — không cần gọi
    // setBackgroundColor: clearColor ở đây; tiết kiệm 1 RemoteCall lúc khởi tạo.
    if (!ds_perform_on_springboard_main(process, g_espContainer, addSubview, root, YES)) {
        ESPLog("qbl ensure fail: addSubview");
        return NO;
    }
    uint64_t rootLayer = ds_remote_get_object_on_main(process, root, "layer");
    if (!rootLayer) {
        ESPLog("qbl ensure fail: root layer");
        return NO;
    }

    g_qblPid = (pid_t)process.pid;
    g_qblContainer = g_espContainer;
    g_qblRoot = root;
    g_qblRootLayer = rootLayer;
    g_qblRootFrame = portraitBounds;
    g_qblRootHidden = YES;
    ESPLog("qbl ensure ok pid=%d root=0x%llx (layers/labels lazy)",
           (int)process.pid, (unsigned long long)root);
    return YES;
}

// Một polyline xương/người: DFS có retrace để retraced segment trùng khít
// segment đã vẽ (CGPathAddLines chỉ vẽ 1 subpath/lần -> 1 call cho cả bộ xương).
static void ds_qbl_emit_bones(const ESPBox2D *b, float sx, float sy, float ox, float oy) {
    if (!b || b->boneCount < 2) return;
    CGPoint p[ESPBone_Count];
    BOOL ok[ESPBone_Count];
    for (int i = 0; i < ESPBone_Count; i++) {
        p[i] = CGPointMake((b->bones[i].x - ox) * sx + ox,
                           (b->bones[i].y - oy) * sy + oy);
        ok[i] = b->bones[i].ok != 0;
    }
    CGPoint pts[40];
    int n = 0;
#define QBL_BONE_PUT(idx) do { if (ok[(idx)]) pts[n++] = p[(idx)]; } while (0)
    // Thân: đầu -> cổ -> ngực -> hông -> ngực (retrace).
    QBL_BONE_PUT(ESPBone_Head);
    QBL_BONE_PUT(ESPBone_Neck);
    QBL_BONE_PUT(ESPBone_Chest);
    if (ok[ESPBone_Pelvis]) {
        QBL_BONE_PUT(ESPBone_Pelvis);
        QBL_BONE_PUT(ESPBone_Chest);
    }
    // 2 tay từ ngực: vai -> khuỷu -> bàn tay -> khuỷu -> vai -> ngực.
    for (int side = 0; side < 2; side++) {
        int sh = side ? ESPBone_RShoulder : ESPBone_LShoulder;
        int el = side ? ESPBone_RElbow : ESPBone_LElbow;
        int hd = side ? ESPBone_RHand : ESPBone_LHand;
        if (!ok[ESPBone_Chest] || !ok[sh]) continue;
        pts[n++] = p[sh];
        if (ok[el]) {
            pts[n++] = p[el];
            if (ok[hd]) pts[n++] = p[hd];
            pts[n++] = p[el];
        }
        pts[n++] = p[sh];
        pts[n++] = p[ESPBone_Chest];
    }
    // 2 chân từ hông: hip -> knee -> foot -> knee -> hip -> hông.
    for (int side = 0; side < 2; side++) {
        int hp = side ? ESPBone_RHip : ESPBone_LHip;
        int kn = side ? ESPBone_RKnee : ESPBone_LKnee;
        int ft = side ? ESPBone_RFoot : ESPBone_LFoot;
        if (!ok[ESPBone_Pelvis] || !ok[hp]) continue;
        pts[n++] = p[hp];
        if (ok[kn]) {
            pts[n++] = p[kn];
            if (ok[ft]) pts[n++] = p[ft];
            pts[n++] = p[kn];
        }
        pts[n++] = p[hp];
        pts[n++] = p[ESPBone_Pelvis];
    }
#undef QBL_BONE_PUT
    if (n >= 2) {
        ESPDrawAddPolyline(pts, n, kQBLColorBone, 1.2f, kQBLBucketBone, NO);
    }
}

static void ds_qbl_build_frame(ESPBox2D *boxes, int count, CGRect portraitBounds,
                               int orientation, const DSQBLFeat *f) {
    (void)orientation; // toạ độ build ở hệ game-landscape; presenter mới map
    CGFloat landW = MAX(portraitBounds.size.width, portraitBounds.size.height);
    CGFloat landH = MIN(portraitBounds.size.width, portraitBounds.size.height);
    ESPDrawFrameBegin(CGSizeMake(landW, landH));
    if (!boxes || count <= 0 || !f) return;

    // Snapline của MỌI player gộp 1 polyline: start -> đỉnh box -> start -> ...
    // (start trùng nhau nên đoạn quay lại không tạo đường lạ — như bản cũ).
    CGPoint linePts[2 + ESPOverlayMaxBoxes * 2];
    int lineN = 0;
    CGPoint lineStart = CGPointMake(landW * 0.5f, 25.0f);
    float scale = (f->scale >= 1.0f && f->scale <= 2.0f) ? f->scale : 1.0f;

    for (int i = 0; i < count; i++) {
        const ESPBox2D *b = &boxes[i];
        if (b->visible == 0 || b->w < 1.0f || b->h < 2.0f) continue;
        // ESPScale (QBL player.ESPScale): phóng quanh tâm box.
        CGFloat bw = b->w * scale;
        CGFloat bh = b->h * scale;
        CGFloat bcx = b->x + b->w * 0.5f;
        CGFloat bcy = b->y + b->h * 0.5f;
        CGFloat bx = bcx - bw * 0.5f;
        CGFloat by = bcy - bh * 0.5f;
        if (by + bh < -60.0f || by > landH + 60.0f) continue;
        if (bx + bw < -60.0f || bx > landW + 60.0f) continue;

        BOOL ai = (b->isAI != 0) && f->aiMark;
        uint32_t mainColor = ai ? kQBLColorAI : kQBLColorBox;

        if (f->box) {
            ESPDrawAddRect(CGRectMake(bx, by, bw, bh), mainColor,
                           ai ? 2.0f : 1.5f,
                           ai ? kQBLBucketBoxAI : kQBLBucketBox, NO);
        }

        // Thanh máu trái box, fill mọc từ đáy (giống bản per-box cũ).
        if (f->health && b->health >= 0 && b->health <= 100 && bh >= 8.0f) {
            CGFloat barW = 5.0f, pad = 4.0f;
            CGFloat barX = bx - barW - pad;
            CGFloat fillH = bh * ((float)b->health) / 100.0f;
            ESPDrawAddRect(CGRectMake(barX, by, barW, bh), kQBLColorHpBg, 1.0f, kQBLBucketHpBg, YES);
            if (fillH > 0.5f) {
                int bk = (b->health < 30) ? kQBLBucketHpRed
                       : (b->health < 60) ? kQBLBucketHpYellow : kQBLBucketHpGreen;
                ESPDrawAddRect(CGRectMake(barX, by + bh - fillH, barW, fillH),
                               ds_qbl_bucket_color(bk), 1.0f, bk, YES);
            }
        }

        // Head dot: ưu tiên khớp đầu thật (bones), không có thì 8% từ đỉnh box.
        CGFloat headX = bcx;
        CGFloat headY = by + bh * 0.08f;
        if (f->bones && b->boneCount >= 2 && b->bones[ESPBone_Head].ok) {
            headX = (b->bones[ESPBone_Head].x - bcx) * scale + bcx;
            headY = (b->bones[ESPBone_Head].y - bcy) * scale + bcy;
        }
        if (f->headDot && b->kind == 1) {
            ESPDrawAddCircle(CGPointMake(headX, headY), 3.0f,
                             ai ? kQBLColorAI : kQBLColorDot, 1.0f,
                             ai ? kQBLBucketAIMark : kQBLBucketDot, YES);
        }

        // Skeleton (chỉ player; không vẽ hình nhân).
        if (f->bones && b->kind == 1 && b->boneCount >= 2) {
            ds_qbl_emit_bones(b, scale, scale, bcx, bcy);
        }

        // AI mark: tam giác vàng trên đỉnh box (QBL AIMarkDifferent).
        if (ai) {
            CGFloat tx = bx + bw * 0.5f;
            CGFloat ty = by - 5.0f;
            CGPoint tri[3] = {
                CGPointMake(tx, ty - 9.0f),
                CGPointMake(tx - 7.0f, ty),
                CGPointMake(tx + 7.0f, ty),
            };
            ESPDrawAddPolyline(tri, 3, kQBLColorAI, 1.5f, kQBLBucketAIMark, YES);
        }

        // Snapline chỉ player (dummy không có line như Kernel/QBL).
        if (f->line && b->kind == 1 && lineN + 2 <= (int)(sizeof(linePts) / sizeof(linePts[0]))) {
            linePts[lineN++] = lineStart;
            linePts[lineN++] = CGPointMake(bx + bw * 0.5f, by);
        }

        // Text: LUÔN 2 lệnh/box (kể cả rỗng) để slot label không bị lệch.
        char txt[96];
        ds_esp_build_label_text(*b, f->name, f->dist, txt, (int)sizeof(txt));
        ESPDrawAddText(txt, CGPointMake(bcx, by + bh), 13.0f, mainColor, YES, 1);
        char teamTxt[40];
        teamTxt[0] = '\0';
        if (f->teamID && b->kind == 1 && b->team >= 0 && b->team <= 200000000) {
            snprintf(teamTxt, sizeof(teamTxt), "T%d%s", b->team, ai ? " AI" : "");
        }
        ESPDrawAddText(teamTxt, CGPointMake(bcx, by), 11.0f, mainColor, YES, 1);
    }

    if (lineN >= 2) {
        ESPDrawAddPolyline(linePts, lineN, kQBLColorLine, 1.0f, kQBLBucketLine, NO);
    }
}

// Đặt 1 label theo lệnh text. Text đổi -> setText (rẻ, chỉ khi đổi); vị trí
// cập nhật tối đa 30Hz + ngưỡng 0.5pt như bản per-box cũ.
// ---------------------------------------------------------------------------
// Presenter (frame -> SpringBoard, dirty theo từng bucket)
// ---------------------------------------------------------------------------

// Quantize 0.5pt: triệt tiêu jitter w2s dưới ngưỡng nhìn thấy. Nhờ vậy frame
// đứng yên mới hash giống nhau và skip được (dirty tracking như renderer cũ).
static inline CGFloat ds_qbl_q(CGFloat v) { return round(v * 2.0) / 2.0; }

static inline CGPoint ds_qbl_qpoint(CGPoint p) {
    return CGPointMake(ds_qbl_q(p.x), ds_qbl_q(p.y));
}

static inline CGRect ds_qbl_qrect(CGRect r) {
    CGFloat w = ds_qbl_q(r.size.width);
    CGFloat h = ds_qbl_q(r.size.height);
    if (w < 1.0) w = 1.0;
    if (h < 1.0) h = 1.0;
    return CGRectMake(ds_qbl_q(r.origin.x), ds_qbl_q(r.origin.y), w, h);
}

static inline void ds_qbl_hash_bytes(uint64_t *h, const void *ptr, size_t n) {
    const unsigned char *p = (const unsigned char *)ptr;
    for (size_t i = 0; i < n; i++) {
        *h ^= (uint64_t)p[i];
        *h *= 1099511628211ULL;
    }
}

static uint64_t ds_qbl_hash_bucket(int b) {
    uint64_t h = 1469598103934665603ULL;
    for (int r = 0; r < s_qblRectCount[b]; r++) {
        ds_qbl_hash_bytes(&h, &s_qblRects[b][r], sizeof(CGRect));
    }
    for (int p = 0; p < s_qblPolyCount[b]; p++) {
        int start = s_qblPolys[b][p].start;
        int n = s_qblPolys[b][p].count;
        if (start < 0 || n <= 0 || start + n > s_qblPtCount) continue;
        ds_qbl_hash_bytes(&h, &s_qblPts[start], (size_t)n * sizeof(CGPoint));
    }
    return h;
}

// Rect của label suy TỪ anchor hiện tại (không lưu hàng đợi) -> gate 30Hz
// không bao giờ làm mất update, pass sau luôn đọc vị trí mới nhất.
static inline CGRect ds_qbl_label_rect(int slot, CGPoint anchor) {
    if (slot % 2 == 0) {
        // Tên + mét (2 dòng, font 13) ngay dưới box, rộng 180pt — numberOfLines=2
        // nên cao 32pt để dòng 2 không bị cắt.
        return CGRectMake(anchor.x - 90.0, anchor.y + 3.0, 180.0, 32.0);
    }
    // TeamID ngay trên box.
    return CGRectMake(anchor.x - 42.0, anchor.y - 16.0, 84.0, 15.0);
}

static void ds_qbl_place_label(RemoteCall *process, int slot, const ESPDrawCommand *c,
                               CGPoint anchor) {
    if (!process || !c || slot < 0 || slot >= kQBLLabelCount) return;
    // qblpack: anchor NaN/cực lớn (W2S lỗi) -> ẩn, không tạo label mới và
    // không setFrame với toạ độ điên (SpringBoard có thể respring vì path/rect).
    if (!isfinite((double)anchor.x) || !isfinite((double)anchor.y) ||
        fabs((double)anchor.x) > 20000.0 || fabs((double)anchor.y) > 20000.0) {
        uint64_t hidden = g_qblLabel[slot];
        if (hidden && g_qblLabelShown[slot]) {
            ds_remote_set_u64_on_main(process, hidden, "setHidden:", 1);
            g_qblLabelShown[slot] = NO;
        }
        return;
    }
    if (!c->text[0]) {
        uint64_t hidden = g_qblLabel[slot];
        if (hidden && g_qblLabelShown[slot]) {
            ds_remote_set_u64_on_main(process, hidden, "setHidden:", 1);
            g_qblLabelShown[slot] = NO;
        }
        return;
    }
    uint64_t lb = ds_qbl_label_for(process, slot);
    if (!lb) return;
    if (!g_qblLabelShown[slot]) {
        ds_remote_set_u64_on_main(process, lb, "setHidden:", 0);
        g_qblLabelShown[slot] = YES;
    }
    if (strncmp(g_qblLabelText[slot], c->text, sizeof(g_qblLabelText[slot]) - 1) != 0) {
        NSString *s = [NSString stringWithUTF8String:c->text];
        if (s && ds_remote_set_text_on_main(process, lb, s)) {
            strncpy(g_qblLabelText[slot], c->text, sizeof(g_qblLabelText[slot]) - 1);
            g_qblLabelText[slot][sizeof(g_qblLabelText[slot]) - 1] = '\0';
        }
    }
    if (g_qblLabelColor[slot] != c->color) {
        // Chỉ 2 màu text (trắng player / vàng AI) — dùng singleton, không tạo
        // UIColor mới (tránh factory autoreleased + retain race trong SB).
        uint64_t col = 0;
        if (c->color == 0xFFFFFFFFu) col = g_qblWhiteColor;
        else if (c->color == kQBLColorAI) col = g_qblAIColor;
        if (col && ds_perform_on_springboard_main(process, lb,
                ds_remote_sel(process, "setTextColor:"), col, YES)) {
            g_qblLabelColor[slot] = c->color;
        }
    }
    CGRect r = ds_qbl_label_rect(slot, anchor);
    if (!g_qblLabelRectValid[slot] ||
        fabs(g_qblLabelRect[slot].origin.x - r.origin.x) > 0.5 ||
        fabs(g_qblLabelRect[slot].origin.y - r.origin.y) > 0.5 ||
        fabs(g_qblLabelRect[slot].size.width - r.size.width) > 0.5) {
        ds_remote_set_rect_on_main(process, lb, "setFrame:", r);
        g_qblLabelRect[slot] = r;
        g_qblLabelRectValid[slot] = YES;
    }
}

static void ds_qbl_present(RemoteCall *process, ESPBox2D *boxes, int count,
                           CGRect portraitBounds, int orientation) {
    if (!process || !process.trojanMem) return;
    if (g_qblDead) return;
    std::lock_guard<std::recursive_mutex> _rc(s_rcBatchMutex);
    CFAbsoluteTime nowP = CFAbsoluteTimeGetCurrent();

    // ---- prefs 1Hz (đọc NSUserDefaults như bản cũ) ----
    static CFAbsoluteTime s_prefAt = 0;
    static DSQBLFeat s_feat = {
        YES, YES, YES, YES, YES, YES, YES, YES, NO, 1.0f
    };
    if (nowP - s_prefAt > 1.0) {
        s_prefAt = nowP;
        NSDictionary *p = nil;
        @try { p = ds_hud_preferences(); } @catch (__unused NSException *e) {}
        DSQBLFeat f;
        f.box = ds_show_esp_from_prefs(p);
        f.line = ds_esp_feature_pref(p, HUDUserDefaultsKeyESPShowLine);
        f.name = ds_esp_feature_pref(p, HUDUserDefaultsKeyESPShowName);
        f.dist = ds_esp_feature_pref(p, HUDUserDefaultsKeyESPShowDistance);
        f.health = ds_esp_feature_pref(p, HUDUserDefaultsKeyESPShowHealth);
        f.teamID = ds_esp_feature_pref_default(p, HUDUserDefaultsKeyESPShowTeamID, YES);
        f.headDot = ds_esp_feature_pref_default(p, HUDUserDefaultsKeyESPShowHeadDot, YES);
        f.aiMark = ds_esp_feature_pref_default(p, HUDUserDefaultsKeyESPShowAIMark, YES);
        f.bones = ds_esp_feature_pref_default(p, HUDUserDefaultsKeyESPShowBones, NO);
        BOOL sc = ds_esp_feature_pref_default(p, HUDUserDefaultsKeyESPESPScale, NO);
        f.scale = sc ? 1.15f : 1.0f;
        s_feat = f;
        // Engine chỉ đọc xương khi được bật (mặc định OFF để không thêm chi phí).
        ESPEngineSetBonesEnabled(s_feat.bones);
    }

    // ---- show/hide window (1 call) ----
    BOOL wantHidden = (count <= 0);
    if (wantHidden != g_espWindowHiddenCache) {
        ds_remote_set_u64_on_main(process, g_espWindow, "setHidden:", wantHidden ? 1 : 0);
        g_espWindowHiddenCache = wantHidden;
    }
    if (wantHidden) return;
    BOOL hadRoot = (g_qblRoot != 0);
    if (!ds_qbl_ensure(process, portraitBounds)) return;
    if (!hadRoot && g_qblRoot) {
        // Tick đầu chỉ dựng root; style/shape/label để tick sau (chia burst).
        ESPDrawFrameReset();
        return;
    }
    if (!g_qblStyleOK) {
        ESPLog("qbl phase: style");
        if (!ds_qbl_style_ready(process)) {
            if (g_qblStyleFails >= 3) {
                g_qblDead = YES;
                ESPLog("qbl: style fail 3x -> bo QBL renderer (giu session cho HUD)");
            }
            return;
        }
    }
    if (!CGRectEqualToRect(g_qblWindowFrame, portraitBounds)) {
        ds_remote_set_rect_on_main(process, g_espWindow, "setFrame:", portraitBounds);
        ds_remote_set_rect_on_main(process, g_espContainer, "setFrame:", portraitBounds);
        g_qblWindowFrame = portraitBounds;
    }

    // Budget tạo object mới: tối đa 1 shape + 1 label/tick (xem chú thích ở
    // kQBLShapeBudgetPerTick). Object dư sẽ được tạo ở các tick sau.
    s_qblShapeBudget = kQBLShapeBudgetPerTick;
    s_qblLabelBudget = kQBLLabelBudgetPerTick;

    ds_qbl_build_frame(boxes, count, portraitBounds, orientation, &s_feat);
    ESPDrawFrameEnd();

    CGFloat landW = MAX(portraitBounds.size.width, portraitBounds.size.height);
    CGFloat landH = MIN(portraitBounds.size.width, portraitBounds.size.height);
    CGPoint winCenter = CGPointMake(CGRectGetMidX(portraitBounds), CGRectGetMidY(portraitBounds));
    BOOL scenePortrait = portraitBounds.size.height > portraitBounds.size.width;
    int mapOrient = (scenePortrait &&
                     (orientation == UIInterfaceOrientationLandscapeLeft ||
                      orientation == UIInterfaceOrientationLandscapeRight))
                        ? orientation : UIInterfaceOrientationPortrait;

    for (int b = 0; b < kQBLBucketCount; b++) {
        s_qblRectCount[b] = 0;
        s_qblPolyCount[b] = 0;
    }
    s_qblPtCount = 0;
    s_qblTextCount = 0;

    const ESPDrawCommand *cmds = ESPDrawFrameCommands();
    int ncmds = ESPDrawFrameCount();
    const CGPoint *framePts = ESPDrawFramePoints();
    BOOL missing = NO;

    // ---- gather (map + quantize 0.5pt + cull) ----
    // qblpack: dữ liệu W2S có thể ra NaN/toạ độ cực lớn (actor sau lưng, camera
    // lỗi, box khổng lồ). CGPathAddRects/AddLines với rect vài triệu pt từng
    // làm SpringBoard respring. Cull theo viewport (margin 64pt) + clamp điểm.
    const CGFloat cullX0 = -64.0, cullY0 = -64.0;
    const CGFloat cullX1 = landW + 64.0, cullY1 = landH + 64.0;
    const CGFloat maxRectW = landW * 3.0, maxRectH = landH * 3.0;
    for (int i = 0; i < ncmds; i++) {
        const ESPDrawCommand *c = &cmds[i];
        if (c->prim == ESPDrawPrimText) {
            if (s_qblTextCount >= kQBLLabelCount) continue;
            int slot = s_qblTextCount;
            s_qblTexts[slot] = *c; // copy: command buffer reset sau present
            CGPoint anchor = ds_esp_map_point(CGPointMake(c->tx, c->ty),
                                              landW, landH, winCenter, mapOrient);
            if (!isfinite((double)anchor.x) || !isfinite((double)anchor.y)) {
                anchor = CGPointMake(-10000.0, -10000.0); // label pass sẽ ẩn
            } else {
                anchor.x = MAX(-landW, MIN(anchor.x, landW * 2.0));
                anchor.y = MAX(-landH, MIN(anchor.y, landH * 2.0));
            }
            s_qblTextAnchor[slot] = ds_qbl_qpoint(anchor);
            uint64_t th = 1469598103934665603ULL;
            ds_qbl_hash_bytes(&th, c->text, sizeof(c->text));
            ds_qbl_hash_bytes(&th, &c->color, sizeof(c->color));
            ds_qbl_hash_bytes(&th, &s_qblTextAnchor[slot], sizeof(CGPoint));
            s_qblTextHash[slot] = th;
            if (c->text[0] && !g_qblLabel[slot] && g_qblLabelFail[slot] < 3) missing = YES;
            s_qblTextCount++;
            continue;
        }
        int bk = c->bucket;
        if (bk < 0 || bk >= kQBLBucketCount) continue;
        if (c->prim == ESPDrawPrimRect) {
            if (s_qblRectCount[bk] >= DS_QBL_MAX_RECTS) continue;
            CGRect r = ds_esp_map_rect(c->rect, landW, landH, winCenter, mapOrient);
            if (!isfinite((double)r.origin.x) || !isfinite((double)r.origin.y) ||
                !isfinite((double)r.size.width) || !isfinite((double)r.size.height)) continue;
            r = CGRectStandardize(r);
            if (r.size.width < 0.5 || r.size.height < 0.5) continue;
            if (r.size.width > maxRectW || r.size.height > maxRectH) continue;
            if (CGRectGetMaxX(r) < cullX0 || r.origin.x > cullX1 ||
                CGRectGetMaxY(r) < cullY0 || r.origin.y > cullY1) continue;
            s_qblRects[bk][s_qblRectCount[bk]++] = ds_qbl_qrect(r);
        } else if (c->prim == ESPDrawPrimPolyline) {
            if (s_qblPolyCount[bk] >= DS_QBL_MAX_POLYS) continue;
            if (!framePts) continue;
            const CGPoint *src = framePts + c->pointStart;
            int pc = c->pointCount;
            if (pc < 2 || pc > 128) continue;
            if (s_qblPtCount + pc > ESP_DRAW_MAX_POINTS) continue;
            CGPoint mapped[128];
            CGFloat minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
            BOOL bad = NO;
            for (int k = 0; k < pc; k++) {
                CGPoint p = ds_esp_map_point(src[k], landW, landH, winCenter, mapOrient);
                if (!isfinite((double)p.x) || !isfinite((double)p.y)) { bad = YES; break; }
                // Clamp vào 3x viewport: path khổng lồ = main thread SB quá tải.
                p.x = MAX(-landW, MIN(p.x, landW * 2.0));
                p.y = MAX(-landH, MIN(p.y, landH * 2.0));
                mapped[k] = ds_qbl_qpoint(p);
                if (p.x < minX) minX = p.x;
                if (p.x > maxX) maxX = p.x;
                if (p.y < minY) minY = p.y;
                if (p.y > maxY) maxY = p.y;
            }
            if (bad) continue;
            // Cả polyline ngoài màn hình (kể cả đường cắt ngang) -> bỏ.
            if (maxX < cullX0 || minX > cullX1 || maxY < cullY0 || minY > cullY1) continue;
            int start = s_qblPtCount;
            for (int k = 0; k < pc; k++) s_qblPts[s_qblPtCount++] = mapped[k];
            s_qblPolys[bk][s_qblPolyCount[bk]].start = start;
            s_qblPolys[bk][s_qblPolyCount[bk]].count = pc;
            s_qblPolyCount[bk]++;
        }
    }

    // ---- hash theo bucket + hash tổng ----
    // Hash từng field (không hash cả struct: padding chưa khởi tạo).
    uint64_t bucketHash[kQBLBucketCount];
    uint64_t hash = 1469598103934665603ULL;
    ds_qbl_hash_bytes(&hash, &s_feat.box, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.line, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.name, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.dist, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.health, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.teamID, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.headDot, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.aiMark, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.bones, 1);
    ds_qbl_hash_bytes(&hash, &s_feat.scale, sizeof(float));
    ds_qbl_hash_bytes(&hash, &portraitBounds, sizeof(CGRect));
    int32_t orient32 = orientation;
    ds_qbl_hash_bytes(&hash, &orient32, sizeof(orient32));
    for (int b = 0; b < kQBLBucketCount; b++) {
        BOOL used = (s_qblRectCount[b] > 0 || s_qblPolyCount[b] > 0);
        bucketHash[b] = used ? ds_qbl_hash_bucket(b) : 0;
        ds_qbl_hash_bytes(&hash, &bucketHash[b], sizeof(uint64_t));
        if (used && !g_qblShape[b] && g_qblShapeFail[b] < 3) missing = YES;
    }
    for (int t = 0; t < s_qblTextCount; t++) {
        ds_qbl_hash_bytes(&hash, &s_qblTextHash[t], sizeof(uint64_t));
    }

    // qblpack: geometry tối đa 30Hz. Trước đây hash đổi gần như mỗi frame khi
    // player di chuyển -> mỗi frame tạo 5-10 CGPath + release path cũ +
    // setPath: trong SpringBoard (60Hz). Đây là tải chính gây respring.
    // KHÔNG cập nhật g_qblFrameHash khi bị throttle (nếu không sẽ mất update).
    static CFAbsoluteTime s_lastGeomPass = 0;
    BOOL geomDue = (s_lastGeomPass <= 0 || (nowP - s_lastGeomPass) >= (1.0 / 30.0));
    BOOL skipGeometry = (!missing && hash == g_qblFrameHash);
    BOOL deferGeometry = (!skipGeometry && !geomDue);
    if (skipGeometry || deferGeometry) {
        g_qblSkips++;
    } else {
        s_lastGeomPass = nowP;
        g_qblFrameHash = hash;
        g_qblFrames++;
    }

    // ---- label pass (15Hz, chạy CẢ khi geometry không đổi) ----
    // Geometry hash chỉ đổi khi rect/point đổi > 0.5pt; label còn phụ thuộc
    // anchor + text + màu nên phải có pass riêng. Phần quyết định labelWork là
    // pure CPU (strncmp/so rect) -> frame đứng yên = 0 remote call.
    static CFAbsoluteTime s_lastLabelPass = 0;
    // qblpack: 15Hz thay vì 30Hz. Label di chuyển theo box nên mỗi lần chạy
    // có thể setFrame 16 UILabel; 30Hz x 16 = 480 RemoteCall/s làm main thread
    // SpringBoard nghẽn. 15Hz vẫn mượt với text, giảm một nửa tải.
    if (nowP - s_lastLabelPass >= (1.0 / 15.0)) {
        BOOL labelWork = NO;
        for (int t = 0; t < kQBLLabelCount && !labelWork; t++) {
            if (t >= s_qblTextCount) {
                if (g_qblLabelShown[t]) labelWork = YES;
                continue;
            }
            const ESPDrawCommand *c = &s_qblTexts[t];
            if (!c->text[0]) {
                if (g_qblLabelShown[t]) labelWork = YES;
                continue;
            }
            uint64_t lb = g_qblLabel[t];
            if (!lb) {
                if (g_qblLabelFail[t] < 3) { labelWork = YES; break; }
                continue;
            }
            if (!g_qblLabelShown[t]) { labelWork = YES; break; }
            if (strncmp(g_qblLabelText[t], c->text, sizeof(g_qblLabelText[t]) - 1) != 0 ||
                g_qblLabelColor[t] != c->color) { labelWork = YES; break; }
            CGRect lr = ds_qbl_label_rect(t, s_qblTextAnchor[t]);
            if (!g_qblLabelRectValid[t] ||
                fabs(g_qblLabelRect[t].origin.x - lr.origin.x) > 0.5 ||
                fabs(g_qblLabelRect[t].origin.y - lr.origin.y) > 0.5 ||
                fabs(g_qblLabelRect[t].size.width - lr.size.width) > 0.5) {
                labelWork = YES;
            }
        }
        if (labelWork) {
            s_lastLabelPass = nowP;
            ds_remote_pool_begin(process);
            @try {
                for (int t = 0; t < s_qblTextCount && process.trojanMem; t++) {
                    ds_qbl_place_label(process, t, &s_qblTexts[t], s_qblTextAnchor[t]);
                }
                for (int t = s_qblTextCount; t < kQBLLabelCount; t++) {
                    if (g_qblLabelShown[t] && g_qblLabel[t]) {
                        ds_remote_set_u64_on_main(process, g_qblLabel[t], "setHidden:", 1);
                        g_qblLabelShown[t] = NO;
                    }
                }
            } @finally {
                ds_remote_pool_end(process);
            }
        }
    }

    if (skipGeometry || deferGeometry) {
        ESPDrawFrameReset();
        return;
    }

    static CFAbsoluteTime s_lastStatLog = 0;
    if (nowP - s_lastStatLog > 5.0) {
        s_lastStatLog = nowP;
        ESPLog("qbl present: frames=%lu skips=%lu cmds=%d texts=%d pts=%d missing=%d bones=%s",
               g_qblFrames, g_qblSkips, ncmds, s_qblTextCount, s_qblPtCount,
               missing ? 1 : 0, ESPEngineBonesStatus());
    }

    // ---- gom rect + point vào 1 buffer remote (1 write/frame) ----
    int rectOffset[kQBLBucketCount];
    int rectTotal = 0;
    for (int b = 0; b < kQBLBucketCount; b++) {
        rectOffset[b] = rectTotal;
        for (int r = 0; r < s_qblRectCount[b]; r++) {
            s_qblAllRects[rectTotal++] = s_qblRects[b][r];
        }
    }
    size_t ptsBytes = (size_t)s_qblPtCount * sizeof(CGPoint);
    size_t rectsBytes = (size_t)rectTotal * sizeof(CGRect);

    ds_remote_pool_begin(process);
    @try {
        BOOL ok = YES;
        if (ptsBytes || rectsBytes) {
            if (!ds_qbl_buf(process, ptsBytes + rectsBytes)) {
                ESPLog("qbl buf fail bytes=%zu", ptsBytes + rectsBytes);
                ok = NO;
            }
        }
        uint64_t ptsAddr = g_qblBufAddr;
        uint64_t rectsAddr = g_qblBufAddr + (uint64_t)ptsBytes;
        if (ok && ptsBytes &&
            ![process remote_write:ptsAddr from:s_qblPts size:(uint64_t)ptsBytes]) {
            ESPLog("qbl write pts fail bytes=%zu", ptsBytes);
            ok = NO;
        }
        if (ok && rectsBytes &&
            ![process remote_write:rectsAddr from:s_qblAllRects size:(uint64_t)rectsBytes]) {
            ESPLog("qbl write rects fail bytes=%zu", rectsBytes);
            ok = NO;
        }

        void *createSym = ok ? ds_remote_system_symbol("CGPathCreateMutable") : NULL;
        void *addRectsSym = ok ? ds_remote_system_symbol("CGPathAddRects") : NULL;
        void *addLinesSym = ok ? ds_remote_system_symbol("CGPathAddLines") : NULL;
        if (ok && !createSym) {
            static BOOL s_loggedNoCreate = NO;
            if (!s_loggedNoCreate) {
                s_loggedNoCreate = YES;
                ESPLog("qbl: CGPathCreateMutable unavailable -> no geometry");
            }
        }

        for (int b = 0; ok && b < kQBLBucketCount; b++) {
            int nR = s_qblRectCount[b];
            int nP = s_qblPolyCount[b];
            BOOL used = (nR > 0 || nP > 0);
            if (!used) {
                if (g_qblShapePath[b] && g_qblShape[b]) {
                    ds_qbl_set_path(process, b, 0);
                    g_qblShapeHash[b] = 0;
                }
                continue;
            }
            if (!g_qblShape[b] && g_qblShapeFail[b] >= 3) continue;
            uint64_t shape = ds_qbl_shape_for(process, b);
            if (!shape) continue; // budget hết / tạo fail -> tick sau
            // Nội dung bucket không đổi -> giữ nguyên path (0 remote call).
            if (g_qblShapePath[b] && g_qblShapeHash[b] == bucketHash[b]) continue;
            if (!createSym) break;
            uint64_t path = (uint64_t)DSRemoteArbCallWithTimeout(1, process, createSym, (uint64_t)0);
            if (!path) break;
            if (nR && addRectsSym) {
                DSRemoteArbCallWithTimeout(1, process, addRectsSym, path, 0,
                                           rectsAddr + (uint64_t)rectOffset[b] * sizeof(CGRect),
                                           (uint64_t)nR);
            }
            if (addLinesSym) {
                for (int p = 0; p < nP; p++) {
                    DSRemoteArbCallWithTimeout(1, process, addLinesSym, path, 0,
                                               ptsAddr + (uint64_t)s_qblPolys[b][p].start * sizeof(CGPoint),
                                               (uint64_t)s_qblPolys[b][p].count);
                }
            }
            if (!ds_qbl_set_path(process, b, path)) break;
            g_qblShapeHash[b] = bucketHash[b];
            if (!process.trojanMem) { ok = NO; break; }
        }
    } @finally {
        ds_remote_pool_end(process);
    }
    if (!process.trojanMem) {
        static CFAbsoluteTime s_lastDeadLog = 0;
        if (nowP - s_lastDeadLog > 1.0) {
            s_lastDeadLog = nowP;
            const char *err = process.lastError.UTF8String;
            ESPLog("qbl: RemoteCall session died during present err=%s (bo QBL, giu HUD)",
                   err ? err : "-");
        }
        g_qblDead = YES;
    }
    if (g_qblRoot && g_qblRootHidden) g_qblRootHidden = NO;
    ESPDrawFrameReset();
}

static void __attribute__((unused))
ds_esp_overlay_update(RemoteCall *process, ESPBox2D *boxes, int count,
                                  CGRect portraitBounds, int orientation) {
    if (!process || !process.trojanMem) return;
    // Vẽ per-box trực tiếp trên bridge dưới batch lock (kernrw43: bitmap đã
    // bị xoá hẳn — xem ghi chú ds_finish_disable).
    std::lock_guard<std::recursive_mutex> _rc(s_rcBatchMutex);
    CFAbsoluteTime nowP = CFAbsoluteTimeGetCurrent();
    // Hoist lên đầu hàm để pre-check idle (trước pool) dùng chung với vòng vẽ
    // chính bên dưới — 1 nguồn sự thật cho gate text/diag.
    static BOOL s_espBoundsLogged = NO;
    static CFAbsoluteTime s_lastTextAt[ESPOverlayMaxBoxes] = {0};
    // kernrw51: cache toggle ESP Line/Name/Health 1s — đọc từ NSUserDefaults
    // (Source: Setting app). "ESP Box" là công tắc chính (như cũ, gate ở tick);
    // ba toggle này dàng riêng từng thành phần trên overlay. Đổi toggle => buộc
    // frame sau chạy vòng vẽ (s_featDirty) để label/hp hội tụ trạng thái mới.
    static CFAbsoluteTime s_featPrefAt = 0;
    static BOOL s_featLine = YES, s_featName = YES, s_featHealth = YES, s_featDist = YES;
    static BOOL s_featBox = YES; // khung 2D — tách khỏi các thành phần khác
    static BOOL s_featDirty = NO;
    if (nowP - s_featPrefAt > 1.0) {
        s_featPrefAt = nowP;
        NSDictionary *featPrefs = nil;
        @try { featPrefs = ds_hud_preferences(); } @catch (__unused NSException *e) {}
        BOOL nb = ds_show_esp_from_prefs(featPrefs);
        BOOL nl = ds_esp_feature_pref(featPrefs, HUDUserDefaultsKeyESPShowLine);
        BOOL nn = ds_esp_feature_pref(featPrefs, HUDUserDefaultsKeyESPShowName);
        BOOL nh = ds_esp_feature_pref(featPrefs, HUDUserDefaultsKeyESPShowHealth);
        BOOL nd = ds_esp_feature_pref(featPrefs, HUDUserDefaultsKeyESPShowDistance);
        if (nb != s_featBox || nl != s_featLine || nn != s_featName ||
            nh != s_featHealth || nd != s_featDist) s_featDirty = YES;
        s_featBox = nb; s_featLine = nl; s_featName = nn; s_featHealth = nh; s_featDist = nd;
    }
    if (!g_espWindow || !g_espContainer) {
        if (!ds_esp_overlay_ensure(process, portraitBounds)) return;
    }
    // Game PUBG luôn render landscape: W = cạnh dài, H = cạnh ngắn — KHÔNG suy
    // từ orientation (SpringBoard scene kẹt portrait). Phải khớp EXACT với
    // landW/H dùng trong W2S ở ds_esp_tick, không thì box lệch/hụt.
    // (Tính ở đây — thuần CPU — để cả pre-check idle lẫn vòng vẽ dùng chung.)
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
    // kernrw43: bitmap overlay đã bị XOÁ HOÀN TOÀN (nó là nguồn gây đơ máy).
    // ESP giờ chỉ vẽ per-box ở vòng lặp bên dưới.
    // Pre-check idle thuần CPU (0 remote call): frame nào không có gì đổi —
    // không box dịch/vẽ lại, không label/text đến hạn, không đổi container/
    // orient, không diag 1 lần — thì return luôn, khỏi mở pool (tiết kiệm
    // alloc+init+drain). Điều kiện mirror Y HỆT vòng vẽ bên dưới; nghi ngờ
    // trường hợp nào thì dirty (chạy như cũ), nên không bao giờ bỏ sót vẽ.
    {
        BOOL dirty = NO;
        BOOL wantHiddenPre = (count <= 0);
        if (wantHiddenPre != g_espWindowHiddenCache) dirty = YES;
        else if (wantHiddenPre) {
            for (int i = 0; i < ESPOverlayMaxBoxes && !dirty; i++) {
                if (!g_espHiddenCache[i]) dirty = YES;
            }
        }
        if (!dirty && !s_espBoundsLogged) dirty = YES;
        // kernrw51: BỎ always-dirty-when-path-layer — nó ép MỌI frame chạy full
        // vòng vẽ (setFrame HP mỗi tick ~960 IPC/s) kể cả khi không đổi gì, lâ
        // bão NSInvocation -> respring. Line giờ đã dirty riêng qua s_pathDirty /
        // s_lastLineCount != count (như vòng vẽ bên dưới), không cần always.
        if (!dirty && s_featDirty) dirty = YES;
        if (!dirty && (!CGRectEqualToRect(g_espLastContainerBounds, portraitBounds) ||
                       mapOrient != g_espLastMapOrient)) dirty = YES;
        for (int i = 0; i < ESPOverlayMaxBoxes && !dirty; i++) {
            ESPBox2D b = boxes[i];
            BOOL hide = (b.visible == 0 || b.w < 1.0f || b.h < 2.0f);
            if (hide != g_espHiddenCache[i] || !g_espRectValid[i]) { dirty = YES; break; }
            if (hide) continue;
            char distTxt[96]; // "Nick\n123m" hoặc "123m 100%%" (giống cũ khi Unknown)
            ds_esp_build_label_text(b, s_featName, s_featDist, distTxt, (int)sizeof(distTxt));
            CGRect fullBox = ds_esp_map_rect(CGRectMake(b.x, b.y, b.w, b.h),
                                             landW, landH, winCenter, mapOrient);
            CGFloat labelGameY = b.y + b.h + 16.0f; // kernrw49: NICK/DIST dưới box (Kernel)
            CGPoint labelCenter = ds_esp_map_point(CGPointMake(b.x + b.w * 0.5f, labelGameY),
                                                   landW, landH, winCenter, mapOrient);
            CGRect prevBox = g_espLastRect[i][0];
            // kernrw49: box vẽ per-box ALWAYS (g_espPathLayer giờ chỉ là snapline)
            BOOL boxMoved = (fabs(prevBox.origin.x - fullBox.origin.x) >= 0.5 ||
                             fabs(prevBox.origin.y - fullBox.origin.y) >= 0.5 ||
                             fabs(prevBox.size.width - fullBox.size.width) >= 0.5 ||
                             fabs(prevBox.size.height - fullBox.size.height) >= 0.5);
            if (boxMoved) { dirty = YES; break; }
            if ((s_featName || s_featDist) && strcmp(g_espLastDist[i], distTxt) != 0 &&
                nowP - s_lastTextAt[i] >= 0.5) {
                dirty = YES; break;
            }
            // kernrw49: hp bar/line geometry đổi theo health/kind + line theo box.
            if (b.health != g_espLastHp[i]) { dirty = YES; break; }
            // kernrw51: mirror line chỉ cần khi toggle Line đang ON.
            if (s_featLine) for (int pt = 0; pt < 4 && !dirty; pt++) {
                CGPoint prevPt = g_espLastLine[i][pt];
                CGPoint curPt = ds_esp_line_for_box(b, fullBox, landW, landH, winCenter, mapOrient, pt);
                if (prevPt.x > 1e9 && curPt.x > 1e9) continue; // cả 2 vô hiệu
                if (prevPt.x != curPt.x || prevPt.y != curPt.y) { dirty = YES; break; }
            }
            // kernrw38 mirror: label local (subview của viền), ngưỡng 4pt.
            // kernrw52: chỉ dirty khi Name/Distance đang bật.
            if (s_featName || s_featDist) {
                CGPoint labelLocalPre = CGPointMake(labelCenter.x - fullBox.origin.x,
                                                    labelCenter.y - fullBox.origin.y);
                if ((fabs(g_espLastLabelCenter[i].x - labelLocalPre.x) > 4.0 ||
                     fabs(g_espLastLabelCenter[i].y - labelLocalPre.y) > 4.0) &&
                    nowP - g_espLastLabelAt[i] >= (1.0 / ESP_OVERLAY_LABEL_HZ)) {
                    dirty = YES; break;
                }
            }
        }
        if (!dirty) return;
        s_featDirty = NO; // đã tiêu: vòng vẽ dưới hội tụ label/hp theo toggle mới
    }
    // 1 pool cho TOÀN BỘ lượt present: mỗi setFrame/setText trước đây tự tạo
    // + drain pool (3 remote_msg thừa). Bọc @try/@finally để pool LUÔN được
    // drain kể cả khi return sớm hay ném exception (không rò autoreleased
    // object vào SpringBoard).
    ds_remote_pool_begin(process);
    @try {
    // Diag 1 lần/process: bounds THỰC của container + window trên SpringBoard
    // (biết SpringBoard có tự xoay window overlay theo máy không — quyết định
    // boxes phải map local hay vẽ trực tiếp).
    {
        // s_espBoundsLogged hoist ở đầu hàm (dùng chung với pre-check idle).
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
                if (g_espBorders[i][0]) ds_remote_set_u64_on_main(process, g_espBorders[i][0], "setHidden:", 1);
                ds_remote_set_u64_on_main(process, g_espLabels[i], "setHidden:", 1);
                g_espHiddenCache[i] = YES;
            }
        }
        return;
    }
    // landW/landH/winCenter/mapOrient đã tính ở pre-check idle phía trên —
    // dùng chung ở đây để khớp EXACT (không tính lại 2 lần lệch nhau).
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

    // kernrw49: s_pathRects NO LONGER uses path layer (per-box). Snapline path
    // stack: (start, top) mỗi box — pool line qua 1 CGPathAddLines.
    CGRect s_pathRects[ESPOverlayMaxBoxes];
    int s_pathCount = 0;
    BOOL s_pathDirty = NO;
    static int s_pathFailStreak = 0;
    static CGPoint s_linePts[2 * ESPOverlayMaxBoxes + 2];
    int s_linePtsCount = 0;
    static const int kESPLinePointsMax = 2 * ESPOverlayMaxBoxes;

    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        ESPBox2D b = boxes[i];
        BOOL hide = (b.visible == 0 || b.w < 1.0f || b.h < 2.0f);
        if (hide != g_espHiddenCache[i]) {
            if (g_espBorders[i][0]) ds_remote_set_u64_on_main(process, g_espBorders[i][0], "setHidden:", hide ? 1 : 0);
            // label/hp là subview của viền — cache cờ về NO để vòng sau hội tụ
            // lại đúng theo toggle (kernrw51: converge qua g_espLabelShown).
            g_espHiddenCache[i] = hide;
            if (hide) {
                g_espRectValid[i] = NO;
                g_espLabelShown[i] = NO;
                g_espHpShown[i] = NO;
                g_espHpFrameH[i] = 0.0f; // hiện lại -> setFrame lại từ đầu
            }
        }
        if (hide) continue;

        char distTxt[96] = {0}; // kernrw49: 96B cho "Nickname\n123m" (UTF-8 nick)
        ds_esp_build_label_text(b, s_featName, s_featDist, distTxt, (int)sizeof(distTxt));

        // 1 border view ôm toàn bộ diện tích box — map từ hệ game-landscape
        // sang hệ container (chỉ xoay khi scene portrait).
        CGRect fullBox = ds_esp_map_rect(CGRectMake(b.x, b.y, b.w, b.h),
                                         landW, landH, winCenter, mapOrient);
        // Label 2 dòng NICK\nDIST ở DƯỚI box (Kernel: name trắng + dist vàng,
        // y = BottomBox + 5px). Center label = bottom-center của box + 16pt
        // (28/2 + 2px lùi). Bounds 140x28.
        CGFloat labelGameY = b.y + b.h + 16.0f;
        CGPoint labelCenter = ds_esp_map_point(CGPointMake(b.x + b.w * 0.5f, labelGameY),
                                               landW, landH, winCenter, mapOrient);
        CGFloat labelHalfW = 70.0f; // bounds 140x28
        CGRect lf = CGRectMake(labelCenter.x - labelHalfW, labelCenter.y - 14.0f,
                               labelHalfW * 2.0f, 28.0f);

        // Box có dịch chuyển?
        // Khi dùng path layer: ngưỡng 0.25pt cực nhạy và mượt (chỉ 1 remote call/frame).
        // Khi fallback per-box: ngưỡng 2.0pt để chống bão NSInvocation gây respring.
        BOOL boxMoved = YES;
        CGRect prevBox = g_espRectValid[i] ? g_espLastRect[i][0] : CGRectZero;
        if (g_espRectValid[i]) {
            // kernrw49: viền box vẽ per-box ALWAYS — ngưỡng 2pt (giữ nguyên
            // cơ chế per-box proven kể từ kernrw27, không qua path layer).
            boxMoved = (fabs(prevBox.origin.x - fullBox.origin.x) >= 0.5 ||
                        fabs(prevBox.origin.y - fullBox.origin.y) >= 0.5 ||
                        fabs(prevBox.size.width - fullBox.size.width) >= 0.5 ||
                        fabs(prevBox.size.height - fullBox.size.height) >= 0.5);
        }
        if (boxMoved) s_pathDirty = YES;

        if (fullBox.size.width >= 1.0f && fullBox.size.height >= 1.0f) {
            s_pathRects[s_pathCount++] = fullBox;
        }

        if (boxMoved && g_espBorders[i][0]) {
            // kernrw49: viền box — SET FRAME là CHIÊU chính (per-box như trước)
            ds_remote_set_rect_on_main(process, g_espBorders[i][0], "setFrame:", fullBox);
        }

        // "ESP Box" chỉ điều khiển KHUNG. View viền vẫn phải tồn tại vì nó là
        // cha của label + thanh máu, nên khi Box OFF chỉ set borderWidth = 0 —
        // Snapline / Tên / Máu / Khoảng cách vẫn chạy độc lập (trước đây tắt
        // Box là cả overlay tắt theo nên các toggle kia vô dụng).
        if (g_espBorderLayer[i] && g_espBoxBorderOn[i] != s_featBox) {
            ds_remote_set_double_on_main(process, g_espBorderLayer[i], "setBorderWidth:",
                                         s_featBox ? (double)kDSESPBorder : 0.0);
            g_espBoxBorderOn[i] = s_featBox;
        }

        // ---- kernrw49/51: HEALTH BAR (giống Kernel) ----
        // Đá thanh máu TRÁI box: d tại fullBox (local), cao như box, thầu "chân"
        // = bottom. kernrw51: 1) gate theo toggle(s) ESP Health; 2) setFrame chỉ
        // khi box FLÚC/rect chưa hợp lệ (trước đây setFrame chạy mỗi frame
        // bất kể => ~960 IPC/s, bão NSInvocation + CA transaction -> respring).
        if (g_espHpFill[i] && b.health >= 0 && b.health <= 100) {
            uint8_t band = (b.health < 30) ? 2 : (b.health < 60) ? 1 : 0;
            if (s_featHealth && fullBox.size.height >= 8.0f && fullBox.size.width >= 2.0f) {
                CGFloat barW = 6.0f; CGFloat barPad = 4.0f;
                // HP fill là SUBVIEW của viền: viền chạy thì bar chạy theo MIỄN
                // PHÍ. Frame local của bar chỉ phụ thuộc chiều cao box + % máu,
                // nên chỉ cần setFrame khi 2 thứ đó đổi. Trước đây gate theo
                // boxMoved -> mỗi frame địch chạy là thêm 1 IPC/box (8 box =
                // 8 call main-thread/frame) chỉ để đặt lại đúng frame cũ, đẩy
                // present vượt 16.7ms -> frame bị bỏ -> box trễ/giật.
                BOOL hpFrameDirty = !g_espRectValid[i] || b.health != g_espLastHp[i];
                if (!hpFrameDirty) {
                    // So với chiều cao LÚC SET gần nhất (không phải frame trước):
                    // box to/nhỏ dần từng 0.1pt/frame vẫn phải cập nhật, không
                    // thì bar lệch dần khỏi đáy box.
                    hpFrameDirty = (g_espHpFrameH[i] <= 0.0f) ||
                                   (fabs(g_espHpFrameH[i] - fullBox.size.height) >= 0.5);
                }
                if (hpFrameDirty) {
                    g_espHpFrameH[i] = (float)fullBox.size.height;
                    // Bar nằm bên TRÁI box (hệ game), fill mọc từ ĐÁY box lên:
                    // gameRect = (b.x - barW - barPad, b.y + b.h - fillH,
                    //             barW, fillH), fillH = b.h * pct/100.
                    // fillLocal = fill đã map về hệ container TRỪ gốc fullBox,
                    // vì fill là subview của viền (toạ độ local của viền).
                    CGFloat fillHGame = b.h * ((float)b.health) / 100.0f;
                    CGRect fillGame = CGRectMake(b.x - barW - barPad, b.y + b.h - fillHGame,
                                                 barW, fillHGame);
                    CGRect fillMap = ds_esp_map_rect(fillGame, landW, landH, winCenter, mapOrient);
                    CGRect fillLocal = CGRectMake(fillMap.origin.x - fullBox.origin.x,
                                                  fillMap.origin.y - fullBox.origin.y,
                                                  fillMap.size.width, fillMap.size.height);
                    ds_remote_set_rect_on_main(process, g_espHpFill[i], "setFrame:", fillLocal);
                }
                uint8_t lastBand = g_espHpBand[i];
                if (lastBand == 0xFF) lastBand = 0; // lần đầu coi như green
                if (band != lastBand || g_espHpFillH[i] == 0xFFFFFFFF) {
                    uint64_t color = (band == 2) ? g_dsRedColor
                                   : (band == 1) ? g_dsYellowColor : g_dsGreenColor;
                    ds_perform_on_springboard_main(process, g_espHpFill[i],
                                                   ds_remote_sel(process, "setBackgroundColor:"), color, YES);
                    g_espHpBand[i] = band;
                    g_espHpFillH[i] = 0;
                }
                if (!g_espHpShown[i]) {
                    ds_remote_set_u64_on_main(process, g_espHpFill[i], "setHidden:", 0);
                    g_espHpShown[i] = YES;
                }
            } else if (g_espHpShown[i]) {
                // box quá nhỏ / toggle Health OFF / tọa độ lệch — ẩn bar
                ds_remote_set_u64_on_main(process, g_espHpFill[i], "setHidden:", 1);
                g_espHpShown[i] = NO;
                g_espHpFrameH[i] = 0.0f;
            }
        } else if (g_espHpFill[i] && g_espHpShown[i]) {
            // health chưa đọc được (dưới -1) — ẩn bar
            ds_remote_set_u64_on_main(process, g_espHpFill[i], "setHidden:", 1);
            g_espHpShown[i] = NO;
            g_espHpFrameH[i] = 0.0f;
        }

        // kernrw51: label hội tụ theo toggle ESP Name — cờ g_espLabelShown riêng
        // (label có hidden=1 riêng từ ensure; unhide CHA không unhide CON).
        BOOL wantLabel = (s_featName || s_featDist);
        if (wantLabel != g_espLabelShown[i]) {
            if (g_espLabels[i]) ds_remote_set_u64_on_main(process, g_espLabels[i],
                                                          "setHidden:", wantLabel ? 0 : 1);
            g_espLabelShown[i] = wantLabel;
        }
        // Chỉ cập nhật setText khi text mét thực sự đổi để giảm tải IPC mach
        // Rate-limit setText: tối đa 2Hz (500ms, kernrw38 từ 5Hz) — mét/HP đọc
        // bằng mắt không cần nhanh hơn, mỗi setText là alloc+set+release IPC.
        // (s_lastTextAt hoist ở đầu hàm, dùng chung với pre-check idle).
        BOOL textChanged = (!g_espRectValid[i] || strcmp(g_espLastDist[i], distTxt) != 0);
        if (wantLabel && textChanged && (!g_espRectValid[i] || nowP - s_lastTextAt[i] >= 0.5)) {
            s_lastTextAt[i] = nowP;
            NSString *dist = [NSString stringWithUTF8String:distTxt];
            ds_remote_set_text_on_main(process, g_espLabels[i], dist);
            snprintf(g_espLastDist[i], sizeof(g_espLastDist[i]), "%s", distTxt);
        }
        // kernrw38: label là SUBVIEW của viền -> tọa độ LOCAL (trừ gốc fullBox),
        // bắn bằng setCenter (1 call, không cần size). Ngưỡng 4pt + gate 10Hz:
        // w box đổi mượt theo khoảng cách nên center local gần như đứng yên —
        // lia máy/box chạy thì viền setFrame kéo label theo miễn phí.
        CGPoint labelLocal = CGPointMake(labelCenter.x - fullBox.origin.x,
                                         labelCenter.y - fullBox.origin.y);
        BOOL labelMoved = !g_espRectValid[i] ||
            fabs(g_espLastLabelCenter[i].x - labelLocal.x) > 1.0 ||
            fabs(g_espLastLabelCenter[i].y - labelLocal.y) > 1.0;
        if (wantLabel && labelMoved &&
            (!g_espRectValid[i] || nowP - g_espLastLabelAt[i] >= (1.0 / ESP_OVERLAY_LABEL_HZ))) {
            ds_remote_set_point_on_main(process, g_espLabels[i], "setCenter:", labelLocal);
            g_espLastLabelCenter[i] = labelLocal;
            g_espLastLabelAt[i] = nowP;
        } else if (!wantLabel) {
            // Name OFF: giữ mirror với giá trị hiện hành để pre-check không
            // không dirty hoài khi toggle lại ON.
            g_espLastLabelCenter[i] = labelLocal;
        }

        // kernrw49: snapline (Kernel esp.mm:1069): từ (screenW/2, 25) -> đỉnh
        // box. CHỈ với player (kind 1) — dummy không có line như Kernel.
        // Slot line point cache cho mirror pre-check.
        for (int pt = 0; pt < 4; pt++) {
            g_espLastLine[i][pt] = ds_esp_line_for_box(b, fullBox, landW, landH,
                                                       winCenter, mapOrient, pt);
        }
        g_espLastHp[i] = b.health;
        // kernrw51: snapline chỉ với toggle Line ON (Kernel chỉ vẽ line cho
        // player kind 1 — dummy không có line).
        if (s_featLine && b.kind == 1 && g_espPathLayer && fullBox.size.width > 1.0f &&
            fullBox.size.height > 1.0f && s_linePtsCount + 2 <= kESPLinePointsMax) {
            CGPoint start = CGPointMake(landW * 0.5f, 25.0f);
            CGPoint startM = ds_esp_map_point(start, landW, landH, winCenter, mapOrient);
            CGPoint topM = ds_esp_map_point(
                CGPointMake(b.x + b.w * 0.5f, b.y), landW, landH, winCenter, mapOrient);
            s_linePts[s_linePtsCount++] = startM;
            s_linePts[s_linePtsCount++] = topM;
        }

        g_espLastRect[i][0] = fullBox;
        for (int e = 1; e < 4; e++) g_espLastRect[i][e] = CGRectZero;
        g_espLastRect[i][4] = lf;
        g_espRectValid[i] = YES;
    }

    // kernrw49: path layer chỉ vẽ SNAPSHOT DỊT / snapline — box_rects s_pathRects
    // giờ KHÔNG qua path layer (viền qui cho per-box view ở vòng trên). s_pathRects
    // vãn còn được push (chỉ để diag kẻ sau đo ở s_lastPathCount) — không dùng.
    static int s_lastLineCount = -1;
    static CFAbsoluteTime s_lastPathUpdate = 0;
    // kernrw52: throttle snapline update 10Hz — trước đây path update mỗi
    // frame khi box di chuyển (>2pt) → CGPath alloc/release + malloc/write
    // mỗi tick → SpringBoard nghẽn -> lag. 10Hz đủ mượt cho đường kẻ.
    if (g_espPathLayer && (s_pathDirty || s_lastLineCount != s_linePtsCount) &&
        nowP - s_lastPathUpdate >= (1.0 / 10.0)) {
        s_lastPathUpdate = nowP;
        s_lastLineCount = s_linePtsCount;
        if (!ds_esp_path_update(process, s_linePts, s_linePtsCount) && s_linePtsCount > 0) {
            g_espPathFails++;
            if (++s_pathFailStreak >= 3) {
                // Keszt — line tắt vĩnh viễn, box không bị ảnh hưởng gì (viền
                // per-box đã chạy từ đầu).
                s_pathFailStreak = 0;
                g_espPathDisabled = YES;
                ds_esp_path_clear(process);
                g_espPathLayer = 0;
                ESPLog("esp snapline OFF (fails=%lu)", g_espPathFails);
            }
        } else {
            s_pathFailStreak = 0;
        }
    }
    } @finally {
        ds_remote_pool_end(process);
    }
}

static void ds_remove_springboard_hud(RemoteCall *process) {
    if (!g_remoteWindow || !process || g_remoteWindowPid != process.pid) {
        ESPLog("hud hide skipped win=0x%llx pid=%d/%d",
               (unsigned long long)g_remoteWindow,
               (int)g_remoteWindowPid, process ? (int)process.pid : -1);
        return;
    }
    if (!process.trojanMem) {
        // Session đã chết (RemoteCall tự destroy sau 1 remote call fault) nhưng
        // HUD vẫn nằm trong SpringBoard. Mở session MỚI chỉ để hide rồi destroy;
        // không có bước này thì HUD đè màn hình đến khi respring.
        ESPLog("hud hide: session dead -> thu session moi");
        RemoteCall *tmp = nil;
        @try {
            tmp = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
        } @catch (NSException *e) {
            const char *msg = e.reason.UTF8String;
            ESPLog("hud hide retry init exception: %s", msg ? msg : "-");
        }
        if (tmp && tmp.trojanMem && tmp.pid == g_remoteWindowPid) {
            if (g_remoteContainer) {
                ds_perform_on_springboard_main(tmp, g_remoteContainer,
                                               ds_remote_sel(tmp, "removeFromSuperview"), 0, YES);
            }
            ds_remote_set_u64_on_main(tmp, g_remoteWindow, "setHidden:", 1);
            if (g_espWindow) ds_remote_set_u64_on_main(tmp, g_espWindow, "setHidden:", 1);
            ESPLog("hud hide RETRY ok win=0x%llx", (unsigned long long)g_remoteWindow);
        } else {
            ESPLog("hud hide RETRY failed (session init)");
        }
        if (tmp) {
            @try { [tmp destroyRemoteCall]; } @catch (__unused NSException *e) {}
        }
        return;
    }
    if (g_remoteContainer) {
        ds_perform_on_springboard_main(process, g_remoteContainer,
                                       ds_remote_sel(process, "removeFromSuperview"), 0, YES);
    }
    ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", 1);
    ESPLog("hud hide done win=0x%llx", (unsigned long long)g_remoteWindow);
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

    BOOL shouldHide = NO; // Luôn hiển thị trong game cả landscape lẫn portrait
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
        uint64_t red = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "systemRedColor") : 0;
        uint64_t clear = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "clearColor") : 0;
        if (red && clear) {
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setTextColor:"), red, YES);
            ds_perform_on_springboard_main(process, g_remoteBlurView,
                                           ds_remote_sel(process, "setBackgroundColor:"),
                                           clear, YES);
        }

        if (fabs(g_lastFontSize - presentation->fontSize) > 0.001 ||
            g_lastInverted != presentation->inverted) {
            uint64_t font = ds_remote_font(process, presentation->fontSize,
                                           YES);
            if (!font) return NO;
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setFont:"), font, YES);
            g_lastFontSize = presentation->fontSize;
            g_lastInverted = presentation->inverted;
        }

        uint64_t layer = ds_remote_get_object_on_main(process, g_remoteBlurView, "layer");
        if (layer) {
            ds_remote_set_double_on_main(process, layer, "setCornerRadius:", 0.0);
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
    // Rate 1Hz chạy bridge -> lấy batch lock.
    std::lock_guard<std::recursive_mutex> _rc(s_rcBatchMutex);

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
#define DS_ESP_BUILD_TAG "kernrw60-hudfix"

// ESP Box thật trên SpringBoard (RemoteCall) 60Hz: chỉ chạy khi toggle ESP Box
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

// Chi phí PRESENT (toàn bộ IPC remote vào SpringBoard cho 1 frame box). Trước
// đây chỉ đo refresh (box perf proc/cam/act) nên không bao giờ biết box giật do
// đọc kernel hay do IPC. Trung bình > ~20ms nghĩa là present vượt ngân sách
// 16.7ms của timer 60Hz -> frame bị s_latestFrame.exchange ném đi -> giật.
static std::atomic<uint64_t> s_presentUsTotal{0};
static std::atomic<uint32_t> s_presentN{0};
static std::atomic<uint32_t> s_presentMaxUs{0};
static void ds_esp_present_heartbeat(void);

// kernrw44: đo TOÀN BỘ ds_esp_tick (refresh + slot + log + geometry + mọi lần
// chờ lock TRƯỚC tBox0). box perf proc/cam/act chỉ đo bên trong
// ESPEngineRefreshBoxes -> không thấy phần chờ lock tracked (trước tBox0) và
// các khâu khác của tick. So tick(N/10s, avg, max) với ngân sách 16.7ms (60Hz)
// là biết ngay work queue có bị chặn không.
static std::atomic<uint64_t> s_tickUsTotal{0};
static std::atomic<uint32_t> s_tickN{0};
static std::atomic<uint32_t> s_tickMaxUs{0};
static void ds_esp_tick_note(double ms) {
    if (ms < 0) ms = 0;
    uint64_t us = (uint64_t)(ms * 1000.0);
    s_tickN.fetch_add(1, std::memory_order_relaxed);
    s_tickUsTotal.fetch_add(us, std::memory_order_relaxed);
    uint32_t prev = s_tickMaxUs.load(std::memory_order_relaxed);
    while ((double)us > (double)prev &&
           !s_tickMaxUs.compare_exchange_weak(prev, (uint32_t)us,
                                              std::memory_order_relaxed)) {
    }
}

// Present lên SpringBoard — CHẠY TRÊN BRIDGE QUEUE.
static void ds_esp_present_single(DSESPFrame *frame) {
    if (!frame) return;
    ds_esp_present_heartbeat();
    ds_trace("esp present count=%d", frame->count);
    // kernrw43: single-thread. Vẽ per-box chạy tại chỗ dưới batch lock.
    // kernrw41: backpressure — present trước chậm (>40ms, SB nghẽn) thì bỏ 1
    // tick cho SB thở (frame rớt đã có s_latestFrame.exchange lo). Chỉ skip,
    // không bao giờ thêm việc nên không thể gây kẹt.
    static double s_lastPresentMs = 0;
    if (s_lastPresentMs > 40.0) {
        s_lastPresentMs = 0.0;
        free(frame);
        return;
    }
    std::lock_guard<std::recursive_mutex> _rc(s_rcBatchMutex);
    @try {
        if (g_espWindow && g_springBoard && g_espWindowPid != (pid_t)g_springBoard.pid) {
            // SpringBoard respring: window/container cũ trỏ vào process đã chết.
            // Gọi tiếp = gửi selector vào địa chỉ rác -> SB chết tiếp/HUD đứng.
            ESPLog("esp: SpringBoard pid changed (%d -> %d) -> rebuild overlay",
                   (int)g_espWindowPid, (int)g_springBoard.pid);
            g_espWindow = 0;
            g_espContainer = 0;
            g_espWindowHiddenCache = YES;
            g_espLastContainerBounds = CGRectZero;
            g_espLastMapOrient = UIInterfaceOrientationUnknown;
            g_espPathLayer = 0;
            g_espPathObj = 0;
            g_espWindowPid = 0;
            ds_qbl_reset_remote();
        }
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
                CFAbsoluteTime tPres = CFAbsoluteTimeGetCurrent();
#if DS_ESP_RENDER_COMMANDLIST
                // QBL-style: build draw list -> present batch (xem ds_qbl_present).
                ds_qbl_present(g_springBoard, frame->boxes, frame->count,
                               frame->bounds, frame->orient);
#else
                ds_esp_overlay_update(g_springBoard, frame->boxes, frame->count,
                                      frame->bounds, frame->orient);
#endif
                double usP = (CFAbsoluteTimeGetCurrent() - tPres) * 1000000.0;
                if (usP < 0) usP = 0;
                s_lastPresentMs = usP / 1000.0; // backpressure tick sau
                s_presentN.fetch_add(1, std::memory_order_relaxed);
                s_presentUsTotal.fetch_add((uint64_t)usP, std::memory_order_relaxed);
                uint32_t prevMax = s_presentMaxUs.load(std::memory_order_relaxed);
                while (usP > (double)prevMax &&
                       !s_presentMaxUs.compare_exchange_weak(prevMax, (uint32_t)usP,
                                                             std::memory_order_relaxed)) {
                }
            }
        }
    } @catch (NSException *exception) {
        // Vào ESP.log (không chỉ os_log): nếu SB chết ngay sau dòng này thì
        // breadcrumb chỉ đúng exception làm respring.
        ESPLog("ESP present failed: %@", exception.reason);
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP present failed: %{public}@", exception.reason);
    }
    free(frame);
}

// Heartbeat từ BRIDGE QUEUE: nếu SB chết thì log vẫn viết được (queue này chỉ
// treo khi app chết). Dòng cuối mất dấu = bridge queue/app dừng — so với
// BOX-SUM (work queue) và scan (scan queue) để xác định queue nào chết trước.
static void ds_esp_present_heartbeat(void) {
    static CFAbsoluteTime s_lastHb = 0;
    CFAbsoluteTime nowHb = CFAbsoluteTimeGetCurrent();
    if (nowHb - s_lastHb < 5.0) return;
    s_lastHb = nowHb;
    uint32_t n = s_presentN.load(std::memory_order_relaxed);
    uint64_t tot = s_presentUsTotal.load(std::memory_order_relaxed);
    double avg = n ? (double)tot / (double)n / 1000.0 : 0.0;
    ESPLog("present hb: n=%u pAvg=%.1f pMax=%.1fms",
           n, avg, (double)s_presentMaxUs.load(std::memory_order_relaxed) / 1000.0);
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
    if (!ds_esp_any_feature_from_prefs(preferences) || !g_gameBase) {
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
        // Refresh MỖI tick. ESPEngineRefreshBoxes đọc vị trí TƯƠI của mọi
        // tracked mỗi tick + camera POV tươi (đều qua region-map memcpy).
        // kernrw17..kernrw23 đọc xoay vòng 1/2 tracked -> địch đang chạy chỉ
        // cập nhật 20Hz trong khi frame ship 60Hz = box nhảy từng bước + trễ
        // pha ("giật giật, không bám theo địch"); đã bỏ ở kernrw24.
        // Present mọi tick khi còn box.
        double minInterval = 0.5 / (double)ESP_REFRESH_HZ;

        uint64_t gen = 0;
        int count = 0;
        BOOL didRefresh = NO;
        if (now2 - s_lastRefresh >= minInterval) {
            s_lastRefresh = now2;
            didRefresh = YES;
            // kernrw52d: ADAPTIVE DISCOVER — skip discover khi tất cả slot đều
            // active và recently seen (< 1.0s). Discover chỉ cần khi có slot trống
            // hoặc slot stale (> 1.0s) — tức là có khả năng xuất hiện địch mới.
            // Giảm tải CPU đáng kể trong trận ổn định (không spawn địch mới).
            {
                BOOL allStable = YES;
                int activeCount = 0;
                for (int s = 0; s < ESPOverlayMaxBoxes; s++) {
                    if (!s_slots[s].active || s_slots[s].actor == 0) { allStable = NO; break; }
                    activeCount++;
                    if (now2 - s_slots[s].lastSeen > 1.0) { allStable = NO; break; }
                }
                if (!allStable || activeCount < ESPOverlayMaxBoxes) {
                    ESPEngineRequestDiscover(g_gameBase);
                }
            }
            ESPEngineRequestScan(g_gameBase);
            // Task port game: thử mỗi 10s (trước đây mỗi tick -> Route A/B chậm).
            static CFAbsoluteTime s_lastTaskEnsure = 0;
            if (now2 - s_lastTaskEnsure >= 10.0) {
                s_lastTaskEnsure = now2;
                ESPGameTaskEnsure();
            }
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
                            // kernrw52g: bỏ log BOX-JUMP (I/O blocking trên tick)
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
                    // kernrw52g: bỏ log BOX-ASSIGN (I/O blocking)
                    s_slots[bestSlot].actor = rawBoxes[r].actor;
                    s_slots[bestSlot].box = rawBoxes[r];
                    s_slots[bestSlot].lastSeen = now2;
                    s_slots[bestSlot].active = YES;
                    rawMatched[r] = true;
                }
            }

            // Phase 3: Thu thập box active. 2 ngưỡng (kernrw39: nới hide 0.5->1.2s):
            //  - lastSeen <= 1.2s: project OK -> hiện box. Kể cả w2s hụt vài
            //    frame (lia máy, rách camera lẻ) box vẫn đứng yên vị trí cũ
            //    thay vì tắt/bật = hết "reset" khi xoay camera.
            //  - 1.2s < lastSeen <= 2.5s: chắc chắn out-of-view -> ẨN box
            //    (visible=0) nhưng GIỮ slot (không clear actor) để khi
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
                // Địch CHẾT/ẩn: engine đã bỏ actor khỏi danh sách box ngay tick
                // đó. Không chờ grace 1.2s (box đứng yên ở chỗ chết) — bỏ slot
                // luôn để box tắt ngay. age>0.10 chỉ để không đụng slot vừa
                // được refresh cập nhật trong chính tick này.
                if (age > 0.10 && ESPEngineActorGone(s_slots[s].actor, 5.0)) {
                    char msg[128];
                    snprintf(msg, sizeof(msg),
                             "BOX-DROP: slot[%d] -DEAD act=0x%llx",
                             s, (unsigned long long)s_slots[s].actor);
                    boxEventLog(msg);
                    s_slots[s].active = NO;
                    s_slots[s].actor = 0;
                    s_boxes[s] = (ESPBox2D){0, 0, 0, 0, 0, -1, 0, 0};
                    continue;
                }
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
                if (age > 1.2) {
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
            if (now2 - s_lastBoxSummaryLog >= 30.0) {
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
                uint32_t presN = s_presentN.exchange(0, std::memory_order_relaxed);
                uint64_t presUs = s_presentUsTotal.exchange(0, std::memory_order_relaxed);
                uint32_t presMaxUs = s_presentMaxUs.exchange(0, std::memory_order_relaxed);
                double presAvgMs = presN ? (double)presUs / (double)presN / 1000.0 : 0.0;
                uint32_t tickN = s_tickN.exchange(0, std::memory_order_relaxed);
                uint64_t tickUs = s_tickUsTotal.exchange(0, std::memory_order_relaxed);
                uint32_t tickMaxUs = s_tickMaxUs.exchange(0, std::memory_order_relaxed);
                double tickAvgMs = tickN ? (double)tickUs / (double)tickN / 1000.0 : 0.0;
                ESPLog("box perf: %s count=%d pres=%u pAvg=%.1f pMax=%.1fms tick(n=%u avg=%.1f max=%.1fms) path(on=%d c=%lu b=%lu f=%lu) prov=%d fails=%llu scans=%llu hp=%.0f/%.0f=%d hpf=%d rss=%llumb dead=%llu",
                       ESPEngineBoxPerfText(), count, presN, presAvgMs,
                       (double)presMaxUs / 1000.0, tickN, tickAvgMs,
                       (double)tickMaxUs / 1000.0, g_espPathLayer ? 1 : 0,
                       g_espPathCalls, g_espPathBoxes, g_espPathFails,
                       ESPProviderIsDegraded() ? 1 : 0,
                       (unsigned long long)ESPProviderFailureCount(),
                       (unsigned long long)ESPProviderFullScanCount(),
                       hpCur, hpMax, hpPct, hpFails, (unsigned long long)rssMB,
                       (unsigned long long)ESPMemoryDeadRegionDrops());
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
        ESPLog("ESP overlay update failed: %@", exception.reason);
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
            CFAbsoluteTime tTick = CFAbsoluteTimeGetCurrent();
            ds_esp_tick();
            ds_esp_tick_note((CFAbsoluteTimeGetCurrent() - tTick) * 1000.0);
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
            @"HUD settings refreshed position=%@ esp=%@ snapshot=%@",
            preferences[UIInterfaceOrientationIsLandscape(ds_interface_orientation())
                ? HUDUserDefaultsKeySelectedModeLandscape
                : HUDUserDefaultsKeySelectedMode] ?: @"default",
            preferences[HUDUserDefaultsKeyShowESPBox] ?: @NO,
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
    // kernrw43: bitmap overlay đã bị xoá hẳn (nguồn gây đơ máy 19-42), nên
    // không còn ship queue/buffer trong SB phải chờ trước khi destroy session.
    std::lock_guard<std::recursive_mutex> _rc(s_rcBatchMutex);
    ds_set_stage(ds_localized(@"Closing HUD"));
    ds_unregister_hud_notifications();
    ds_stop_rate_timer();
    RemoteCall *process = g_springBoard;
    ESPLog("disable: session=%d hudWin=0x%llx hudPid=%d espWin=0x%llx espPid=%d",
           process ? (process.trojanMem ? 1 : -1) : -2,
           (unsigned long long)g_remoteWindow, (int)g_remoteWindowPid,
           (unsigned long long)g_espWindow, (int)g_espWindowPid);
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
            ESPLog("ESP hide exception: %@", exception.reason);
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] ESP hide exception: %{public}@", exception.reason);
        }
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
            ESPLog("destroyRemoteCall exception: %@", exception.reason);
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] destroyRemoteCall exception: %{public}@", exception.reason);
        }
    }
    // Nhớ window cũ: nếu ẩn thất bại (session chết) thì enable sau sẽ ẩn bằng
    // session mới — tránh "bật lại đè lên HUD/ESP cũ".
    if (g_remoteWindow && g_remoteWindowPid > 1) {
        g_staleHudWindow = g_remoteWindow;
        g_staleHudPid = g_remoteWindowPid;
    }
    if (g_espWindow && g_espWindowPid > 1) {
        g_staleEspWindow = g_espWindow;
        g_staleEspPid = g_espWindowPid;
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
    g_espWindowPid = 0;
    ds_qbl_reset_remote(); // cache layer/label/buffer của session cũ
    for (int i = 0; i < ESPOverlayMaxBoxes; i++) {
        for (int e = 0; e < 4; e++)        g_espBorders[i][e] = 0;
        g_espBorderLayer[i] = 0;
        g_espBoxBorderOn[i] = YES;
        g_espLabels[i] = 0;
        g_espHiddenCache[i] = YES;
        g_espRectValid[i] = NO;
        // kernrw51: reset cache toggle-convergence để session mới hội tụ lại.
        g_espLabelShown[i] = NO;
        g_espHpShown[i] = NO;
        g_espHpBand[i] = 0xFF;
        g_espHpFillH[i] = 0xFFFFFFFF;
        g_espHpFrameH[i] = 0.0f;
    }
    s_espStaleCleaned = NO; // enable sau quét dọn lại từ đầu
    g_hudEnabledAt = 0; // tắt TRACE + settle delay của phiên cũ
    ds_inv_cache_drop(); // views chết theo session -> invocation cũ vô nghĩa
    g_espPathDisabled = NO; // kernrw49: snapline layer cho phép khi bật lại HUD (rút từ enable)
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
    // Enable chạy bridge, ship/warmer có thể còn sót batch cũ -> chung lock.
    std::lock_guard<std::recursive_mutex> _rc(s_rcBatchMutex);
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
        // Log mới cho mỗi lần bật HUD: xoá log cũ, file sau đây là của
        // session này (dòng đầu sẽ là "enable self ...").
        ESPLogReset();
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
        // Dọn window của session trước nếu lần disable không ẩn được (vd session
        // đã chết -> mọi remote call fail). Guard pid: respring thì địa chỉ cũ
        // là rác, bỏ qua. Đây là chốt chặn cuối cho lỗi "bật lại đè HUD cũ".
        if (g_staleHudWindow || g_staleEspWindow) {
            @try {
                if (g_staleHudWindow && g_staleHudPid == (pid_t)g_springBoard.pid) {
                    ds_remote_set_u64_on_main(g_springBoard, g_staleHudWindow, "setHidden:", 1);
                    ESPLog("enable: hid stale HUD win=0x%llx",
                           (unsigned long long)g_staleHudWindow);
                }
                if (g_staleEspWindow && g_staleEspPid == (pid_t)g_springBoard.pid) {
                    ds_remote_set_u64_on_main(g_springBoard, g_staleEspWindow, "setHidden:", 1);
                    ESPLog("enable: hid stale ESP win=0x%llx",
                           (unsigned long long)g_staleEspWindow);
                }
            } @catch (NSException *exception) {
                ESPLog("stale window cleanup exception: %@", exception.reason);
            }
            g_staleHudWindow = 0; g_staleHudPid = 0;
            g_staleEspWindow = 0; g_staleEspPid = 0;
        }
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
