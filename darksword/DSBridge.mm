//
//  DSBridge.mm
//  DarkPubg
//

#import "DSBridge.h"
#import "HUDHelper.h"
#import "HUDPresetPosition.h"
#import "SpringBoardServices.h"
#import "FBSOrientationObserver.h"
#import "FBSOrientationUpdate.h"
#import "BackboardServices.h"
#import "JetsamHelper.h"

#import <objc/runtime.h>
#import <objc/message.h>

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#import <array>
#import <unordered_map>
#import <vector>

#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const DSBridgeProgressNotification = @"com.huami.darkpubg.dsbridge.progress";

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
    notify_post("com.huami.darkpubg.dsbridge.progress");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSBridgeProgressNotification object:nil];
    });
}

#if USE_DARKSWORD
static void ds_set_stage(NSString *stage) {
    NSString *next = [stage copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsStage = next;
    os_unfair_lock_unlock(&g_errorLock);
    ds_post_progress();
}
#endif

static void ds_set_error(NSString *message) {
    NSString *next = [message copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsLastError = next;
    os_unfair_lock_unlock(&g_errorLock);
    if (next.length > 0) {
        notify_post(NOTIFY_RELOAD_APP);
    }
    ds_post_progress();
}

#if USE_DARKSWORD

#import "DSRemoteCall.h"

// These vendored headers are plain C/Objective-C. Keep C linkage from this .mm.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

struct vmshmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool used;
};

extern "C" struct vmshmem vmmapremotepage(uint64_t vmMap, uint64_t address);
extern "C" struct vmshmem vmmapremotepagefromentry(uint64_t entryAddress,
                                                    uint64_t address);
extern "C" kern_return_t mach_vm_deallocate(task_t task,
                                            mach_vm_address_t address,
                                            mach_vm_size_t size);

static const NSInteger kDSSpringBoardHUDTag = 0x54534844; // "TSHD"
static const CGFloat kDSHUDMinFontSize = 9.0;
static const CGFloat kDSHUDMaxFontSize = 10.0;
static const CGFloat kDSHUDMinCornerRadius = 4.5;
static const CGFloat kDSHUDMaxCornerRadius = 5.0;
static const CGFloat kDSHUDInactiveOpacity = 0.667;
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
// The remote scene's own coordinate-space bounds — the only layout geometry
// that follows rotation. The local app's bounds stay frozen while backgrounded.
static CGRect g_remoteSceneBounds = CGRectNull;
static double g_windowRotation = 0.0;
static CGRect g_windowContentBounds = CGRectNull;
// Active interface orientation, tracked via FBSOrientationObserver (the same
// mechanism cccc/TrollSpeed use): it follows the foreground app even while
// this process is backgrounded.
static id g_orientationObserver = nil;
static id g_deviceOrientationObserver = nil;
static std::atomic<int> g_activeOrientation(UIInterfaceOrientationUnknown);
static dispatch_source_t g_rateTimer = nil;
static AVAudioPlayer *g_keepAlivePlayer = nil;
static std::atomic<int> g_remoteOrientation(UIInterfaceOrientationUnknown);
static int g_reloadHUDToken = -1;
static int g_lockStateToken = -1;
static NSUInteger g_lastPresentationSignature = 0;
static CGRect g_lastWindowFrame = CGRectNull;
static CGRect g_lastHUDContentFrame = CGRectNull;
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

// Stability knobs (respring hardening). Each remote_msg into SpringBoard is a
// hijacked-thread exception round trip; the fewer per tick and the less they
// block, the smaller the chance of wedging SpringBoard's main thread.
static const NSUInteger kDSRemoteTextRingSize = 6;      // delayed-release slots for remote NSStrings
static const NSUInteger kDSRemoteFailureLimit = 3;      // consecutive failures before updates stop
static uint64_t g_remoteTextRing[kDSRemoteTextRingSize] = {0};
static NSUInteger g_remoteTextRingIndex = 0;
static NSUInteger g_remoteFailureCount = 0;
static BOOL g_pendingWindowLevelReapply = NO;
static NSString *g_lastAppliedText = nil;
static BOOL g_fastTickActive = NO;

// ═══ Hosted overlay window (AssistiveTouch mechanism) ═══
// A real UIWindow in OUR process rendered locally at full frame rate; the
// registration is performed INSIDE SpringBoard over the existing RemoteCall
// channel, so the entitlement check sees SpringBoard itself as the caller.
static UIWindow *g_hostedWindow = nil;
static UIView   *g_hostedESPView = nil;
static CALayer  *g_hostedLayer = nil;
static uint64_t  g_hostedRemoteController = 0;  // SBSAccessibilityWindowHostingController inside SpringBoard
static pid_t     g_hostedSBPid = 0;             // SpringBoard generation that owns the registration
static dispatch_source_t g_hostedTimer = nil;
static CGRect   g_hostedContentBounds = CGRectNull;
static int      g_hostedLastOrientation = 0;
static CFAbsoluteTime g_hostedLastSetupTryAt = 0;
static unsigned g_hostedContextId = 0;
static int      g_hostedSetupAttempts = 0;
static int      g_hostedPushedFrames = 0;

static const uint64_t kDSRemoteTextScratchOffset = 0x1000;
static const size_t kDSRemoteTextScratchCapacity = 0x800;
static void ds_update_rate(void);
static void ds_stop_keepalive(void);
static CGRect ds_scene_bounds(void);
static CGRect ds_content_bounds(void);
static CGRect ds_hud_screen_bounds(void);
static void ds_hosted_overlay_stop(void);
static void ds_hosted_overlay_start(void);

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
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        queue = dispatch_queue_create("com.huami.darkpubg.darksword", attr);
    });
    return queue;
}

#include "DSBridgeExploit.inc.mm"

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

static BOOL ds_pref_bool(NSDictionary *preferences, HUDUserDefaultsKey key) {
    return [preferences[key] boolValue];
}

static CGFloat ds_pref_double(NSDictionary *preferences, HUDUserDefaultsKey key,
                              CGFloat fallback) {
    NSNumber *number = preferences[key];
    return number ? number.doubleValue : fallback;
}

static void ds_dispatch_main_sync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static UIInterfaceOrientation ds_interface_orientation(void) {
    // Aspect of the content space is the most reliable signal —
    // SBMainWorkspace's interfaceOrientation may lag or stay portrait.
    CGRect content = ds_content_bounds();
    if (CGRectGetWidth(content) > 0.0) {
        return CGRectGetWidth(content) > CGRectGetHeight(content)
            ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
    }
    UIInterfaceOrientation remoteOrientation =
        (UIInterfaceOrientation)g_remoteOrientation.load();
    if (remoteOrientation != UIInterfaceOrientationUnknown) {
        return remoteOrientation;
    }
    __block UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    ds_dispatch_main_sync(^{
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
    ds_dispatch_main_sync(^{
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

static NSString *ds_full_display_text(NSDictionary *preferences,
                                      BOOL centered,
                                      BOOL focused,
                                      double down,
                                      double up) {
    (void)preferences;
    (void)centered;
    (void)focused;
    (void)down;
    (void)up;
    return @"";
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
    presentation.numberOfLines = 0;
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

    CGRect screenBounds = ds_hud_screen_bounds();
    UIEdgeInsets safeInsets;
    ds_screen_geometry(NULL, &safeInsets);
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

// setText: is posted asynchronously (waitUntilDone:NO) and the replaced
// string is released only after kDSRemoteTextRingSize more ticks, once
// SpringBoard's main runloop has certainly consumed it. This removes both the
// per-second blocking wait on SpringBoard's main thread and the alloc/release
// heap churn inside SpringBoard every second — the two main respring sources
// of the previous implementation.
static BOOL ds_remote_set_text_on_main(RemoteCall *process, uint64_t label,
                                       NSString *text) {
    if (!process || !process.trojanMem || !label || !text) return NO;

    NSUInteger slot = g_remoteTextRingIndex % kDSRemoteTextRingSize;
    uint64_t retired = g_remoteTextRing[slot];

    uint64_t remoteText = ds_remote_create_string(process, text);
    if (!remoteText) return NO;

    g_remoteTextRing[slot] = remoteText;
    g_remoteTextRingIndex++;

    BOOL sent = ds_perform_on_springboard_main(
        process, label, ds_remote_sel(process, "setText:"), remoteText, NO);
    uint64_t release = ds_remote_sel(process, "release");
    if (!sent) {
        // Never queued: safe to release the new string immediately, keep the
        // previous occupant for a later release attempt.
        if (release && process.trojanMem) {
            remote_msg(process, remoteText, release, 0, 0, 0, 0);
        }
        g_remoteTextRing[slot] = retired;
        return NO;
    }
    if (retired && release && process.trojanMem) {
        remote_msg(process, retired, release, 0, 0, 0, 0);
    }
    return YES;
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
                                            NSUInteger resultSize,
                                            BOOL waitUntilDone) {
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
                                   ds_remote_sel(process, "invoke"), 0, waitUntilDone);
    if (!process.trojanMem) return NO;
    if (waitUntilDone && result && resultSize > 0) {
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
                                           arguments, argumentCount, NULL, 0, YES);
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
        &result, sizeof(result), YES);
    return invoked ? result : 0;
}

static uint64_t ds_remote_get_retained_object_on_main(
    RemoteCall *process, uint64_t target, const char *selectorName,
    const DSRemoteArgument *arguments, NSUInteger argumentCount) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName),
        arguments, argumentCount, &result, sizeof(result), YES);
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
        &result, sizeof(result), YES);
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

static BOOL ds_remote_set_transform_on_main(RemoteCall *process, uint64_t target,
                                            CGAffineTransform value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, "setTransform:"),
                                    &argument, 1);
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
                &argument, 1, &view, sizeof(view), YES) || !view) {
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
    return !hideAtSnapshot || canHide;
}

static CGRect ds_scene_bounds(void) {
    if (!CGRectIsNull(g_remoteSceneBounds) &&
        CGRectGetWidth(g_remoteSceneBounds) > 0.0 &&
        CGRectGetHeight(g_remoteSceneBounds) > 0.0) {
        return g_remoteSceneBounds;
    }
    CGRect bounds;
    ds_screen_geometry(&bounds, NULL);
    return bounds;
}

static bool ds_pubg_has_render_source(void);

// The orientation actually shown on screen: FBSOrientationObserver first
// (follows the foreground app), physical device orientation as fallback.
static UIInterfaceOrientation ds_active_orientation(void) {
    int fbs = g_activeOrientation.load();
    if (fbs != UIInterfaceOrientationUnknown) return (UIInterfaceOrientation)fbs;
    switch (UIDevice.currentDevice.orientation) {
        case UIDeviceOrientationLandscapeLeft:  return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight: return UIInterfaceOrientationLandscapeLeft;
        case UIDeviceOrientationPortraitUpsideDown: return UIInterfaceOrientationPortraitUpsideDown;
        default: break;
    }
    if (ds_pubg_has_render_source()) {
        return UIInterfaceOrientationLandscapeRight;
    }
    return UIInterfaceOrientationPortrait;
}

// Space the window's subviews lay out in: the scene space, swapped to
// landscape when the active orientation is landscape but the scene did not
// follow (SpringBoard's scene ignores the foreground app's orientation).
static CGRect ds_content_bounds(void) {
    CGRect scene = ds_scene_bounds();
    BOOL scenePortrait = CGRectGetHeight(scene) >= CGRectGetWidth(scene);
    if (!scenePortrait) return scene;
    if (UIInterfaceOrientationIsLandscape(ds_active_orientation())) {
        return CGRectMake(0, 0, CGRectGetHeight(scene), CGRectGetWidth(scene));
    }
    return scene;
}

static CGRect ds_hud_screen_bounds(void) {
    return ds_content_bounds();
}

static CGRect ds_remote_window_frame(void) {
    return ds_scene_bounds();
}

// Rotates the HUD window by hand whenever the scene space mismatches the
// physical device orientation. Cheap: remote calls fire only on change.
static void ds_update_window_rotation(RemoteCall *process) {
    if (!process || !process.trojanMem || !g_remoteWindow) return;

    CGRect scene = ds_scene_bounds();
    UIInterfaceOrientation active = ds_active_orientation();
    BOOL scenePortrait = CGRectGetHeight(scene) >= CGRectGetWidth(scene);

    // cccc orientationAngle(): landscape-left = -90°, landscape-right = +90°,
    // upside-down = 180°. Only compensate when the scene itself didn't rotate.
    double angle = 0.0;
    CGRect content = scene;
    if (scenePortrait && active == UIInterfaceOrientationLandscapeLeft) {
        angle = -M_PI_2;
        content = CGRectMake(0, 0, CGRectGetHeight(scene), CGRectGetWidth(scene));
    } else if (scenePortrait && active == UIInterfaceOrientationLandscapeRight) {
        angle = M_PI_2;
        content = CGRectMake(0, 0, CGRectGetHeight(scene), CGRectGetWidth(scene));
    } else if (scenePortrait && active == UIInterfaceOrientationPortraitUpsideDown) {
        angle = M_PI;
    }
    if (angle == g_windowRotation && CGRectEqualToRect(content, g_windowContentBounds)) return;

    g_windowRotation = angle;
    g_windowContentBounds = content;
    CGPoint center = CGPointMake(CGRectGetMidX(scene), CGRectGetMidY(scene));
    ds_remote_set_rect_on_main(process, g_remoteWindow, "setBounds:", content);
    ds_remote_set_point_on_main(process, g_remoteWindow, "setCenter:", center);
    ds_remote_set_transform_on_main(process, g_remoteWindow,
                                    CGAffineTransformMakeRotation(angle));
}

static CGRect ds_remote_window_bounds(CGRect windowFrame) {
    return CGRectMake(0, 0, CGRectGetWidth(windowFrame), CGRectGetHeight(windowFrame));
}

static CGRect ds_hud_content_frame(const DSHUDPresentation *presentation,
                                   CGRect windowFrame) {
    if (!presentation) return CGRectZero;
    return CGRectMake(round(CGRectGetMinX(presentation->windowFrame) - CGRectGetMinX(windowFrame)),
                      round(CGRectGetMinY(presentation->windowFrame) - CGRectGetMinY(windowFrame)),
                      CGRectGetWidth(presentation->windowFrame),
                      CGRectGetHeight(presentation->windowFrame));
}

typedef struct {
    float x;
    float y;
    bool valid;
} DSPUBGJoint;

typedef struct {
    float screenX;
    float screenY;
    float headX;
    float headY;
    float boxWidth;
    float boxHeight;
    float distanceMeters;
    float health;
    float healthMax;
    int32_t teamId;
    bool isAI;
    bool isDead;
    bool isVisible;
    bool isOccluded;
    bool isVehicle;
    float fuel;
    uint64_t actorPtr;
    uint32_t playerKey;
    char name[32];
    char nation[16];
    char weaponName[32];
    bool isKnocked;
    bool hasSkeleton;
    DSPUBGJoint skeleton[16];
    float camRelX;
    float camRelY;
    float camRelZ;
    bool has3DBox;
    CGPoint boxCorners[8];
} DSPUBGProjectedPlayer;

typedef enum {
    DSPUBGItemCategoryNone = 0,
    DSPUBGItemCategoryVehicle = 1,
    DSPUBGItemCategoryWeapon = 2,
    DSPUBGItemCategoryScope = 3,
    DSPUBGItemCategoryArmor = 4,
    DSPUBGItemCategoryBag = 5,
    DSPUBGItemCategoryCrate = 6
} DSPUBGItemCategory;

typedef struct {
    float screenX;
    float screenY;
    float distanceMeters;
    char name[36];
    DSPUBGItemCategory category;
    bool isVisible;
    float hp;
    float hpMax;
    float fuel;
    float fuelMax;
    uint32_t colorRGBA;
    bool isPriority;
} DSPUBGProjectedItem;

typedef enum {
    DSPUBGGrenadeTypeFrag = 0,    // Lựu đạn nổ
    DSPUBGGrenadeTypeSmoke = 1,   // Bom khói
    DSPUBGGrenadeTypeBurn = 2,    // Molotov (bom lửa)
    DSPUBGGrenadeTypeStun = 3,    // Bom choáng
} DSPUBGGrenadeType;

static const int kDSPUBGMaxGrenades = 8;
static const int kDSPUBGCirclePoints = 32;
static const int kDSPUBGMaxTrajPoints = 32;

typedef struct {
    float screenX;
    float screenY;
    float distanceMeters;
    bool isVisible;
    DSPUBGGrenadeType type;
    char name[32];
    float damageRadiusMeters;
    bool isLocalInDanger;

    int trajCount;
    CGPoint trajPoints[kDSPUBGMaxTrajPoints];

    int circlePointCount;
    CGPoint circlePoints[kDSPUBGCirclePoints];
    bool circlePointsValid[kDSPUBGCirclePoints];

    CGPoint circlePointsMid[kDSPUBGCirclePoints];
    bool circlePointsMidValid[kDSPUBGCirclePoints];

    CGPoint circlePointsInner[kDSPUBGCirclePoints];
    bool circlePointsInnerValid[kDSPUBGCirclePoints];

    bool hasBox;
    CGPoint boxCorners[8];
    bool boxCornersValid[8];

    float cookSeconds;
    float totalFuseSeconds;
    bool hasDropLine;
    CGPoint groundPoint;
} DSPUBGProjectedGrenade;

static const int kDSPUBGMaxPlayers = 96;
static const int kDSPUBGMaxItems = 64;
static float g_dspubgMaxDistance = 400.0f;
static float g_pubgItemMaxDistance = 150.0f;
static int g_pubgLanguage = 0; // 0 = Tiếng Việt, 1 = English
static float g_pubgEspThickness = 1.5f; // Độ dày chung cho toàn bộ nét vẽ hiện địch
static BOOL g_pubgEspBox = YES;
static BOOL g_pubgEspSkeleton = YES;
static BOOL g_pubgEspLine = YES;
static BOOL g_pubgEspArrow = YES;
static BOOL g_pubgEspHealth = YES;
static BOOL g_pubgEspName = YES;
static BOOL g_pubgEspDist = YES;
static BOOL g_pubgEspBot = YES;
static BOOL g_pubgEspEnemyNumber = YES;
static BOOL g_pubgEspRadar = YES;
static BOOL g_pubgEspTeam = YES;
static BOOL g_pubgEspFlag = YES;
static BOOL g_pubgEspGrenade = YES;
static BOOL g_pubgEspVehicle = YES;
static BOOL g_pubgEspVehicleHp = YES;
static BOOL g_pubgEspVehicleFuel = YES;
static BOOL g_pubgEspWeapon = YES;
static BOOL g_pubgEspArmor = YES;
static BOOL g_pubgEspBag = YES;
static BOOL g_pubgEspScope = YES;
static BOOL g_pubgEspCrate = YES;
static BOOL g_pubgEspFlareGun = YES;
static BOOL g_pubgEspDrug = YES;
static BOOL g_pubgEspWeaponAR = YES;
static BOOL g_pubgEspWeaponSMG = YES;
static BOOL g_pubgEspWeaponShotgun = YES;
static BOOL g_pubgEspWeaponSniper = YES;
static BOOL g_pubgEspArmorLv1 = YES;
static BOOL g_pubgEspArmorLv2 = YES;
static BOOL g_pubgEspArmorLv3 = YES;
static BOOL g_pubgEspAmmo = YES;
static BOOL g_pubgEspVal = YES;
static BOOL g_pubgEspAkm = YES;
static BOOL g_pubgEspM416 = YES;
static BOOL g_pubgEspScarl = YES;

static inline bool ds_pubg_is_item_type_enabled(DSPUBGItemCategory cat, const char *name) {
    if (!name || name[0] == '\0') return true;

    // 1. Vehicle
    if (cat == DSPUBGItemCategoryVehicle) {
        return g_pubgEspVehicle;
    }

    // 2. AirDrop / DeathBox / Ammo
    if (cat == DSPUBGItemCategoryCrate) {
        if (strstr(name, "Đạn") || strstr(name, "Ammo") || strstr(name, "9mm") ||
            strstr(name, "7.62") || strstr(name, "5.56") || strstr(name, "12G") ||
            strstr(name, "12Guage") || strstr(name, ".300") || strstr(name, ".45") ||
            strstr(name, "45ACP") || strstr(name, "5.7")) {
            return g_pubgEspAmmo;
        }
        return g_pubgEspCrate;
    }

    // 3. Flare Gun / Flare Ammo
    if (strstr(name, "Flare")) {
        return g_pubgEspFlareGun;
    }

    // 4. Drugs / Medicine
    if (strstr(name, "Nước") || strstr(name, "Thuốc") || strstr(name, "Máu") ||
        strstr(name, "Adrenaline") || strstr(name, "FirstAid") || strstr(name, "MedKit") ||
        strstr(name, "Bandage") || strstr(name, "Painkiller") || strstr(name, "EnergyDrink")) {
        return g_pubgEspDrug;
    }

    // 5. Scopes / Accessories
    if (cat == DSPUBGItemCategoryScope || strstr(name, "Scope") || strstr(name, "Holo") ||
        strstr(name, "RedDot") || strstr(name, "Nòng") || strstr(name, "Băng") ||
        strstr(name, "Tay Cầm") || strstr(name, "Compensator") || strstr(name, "Suppressor") ||
        strstr(name, "Stock") || strstr(name, "Choke")) {
        return g_pubgEspScope;
    }

    // 6. Grenades / Thrown items
    if (strstr(name, "Lựu") || strstr(name, "Khói") || strstr(name, "Xăng") ||
        strstr(name, "Choáng") || strstr(name, "Grenade") || strstr(name, "Smoke") ||
        strstr(name, "Molotof") || strstr(name, "Flash")) {
        return g_pubgEspGrenade;
    }

    // 7. Armor, Helmets, Backpacks by Level (LV1, LV2, LV3)
    if (cat == DSPUBGItemCategoryArmor || cat == DSPUBGItemCategoryBag ||
        strstr(name, "Giáp") || strstr(name, "Mũ") || strstr(name, "Balo") ||
        strstr(name, "Armor") || strstr(name, "Helmet") || strstr(name, "Bag") ||
        strstr(name, "Head")) {
        if (strstr(name, "3")) return g_pubgEspArmorLv3;
        if (strstr(name, "2")) return g_pubgEspArmorLv2;
        if (strstr(name, "1")) return g_pubgEspArmorLv1;
        return (g_pubgEspArmorLv1 || g_pubgEspArmorLv2 || g_pubgEspArmorLv3);
    }

    // 8. Weapons grouped by AR, SMG, Shotgun, Sniper
    if (cat == DSPUBGItemCategoryWeapon) {
        // AR: AKM, M16A4, SCAR-L, M416, Groza, AUG, QBZ, M762, Mk47, G36C, HoneyBadger, ACE32, FAMAS, Abakan, F2000, Súng AR
        if (strstr(name, "AKM") || strstr(name, "M16") || strstr(name, "SCAR") ||
            strstr(name, "M416") || strstr(name, "Groza") || strstr(name, "AUG") ||
            strstr(name, "QBZ") || strstr(name, "M762") || strstr(name, "Mk47") ||
            strstr(name, "G36") || strstr(name, "Honey") || strstr(name, "ACE32") ||
            strstr(name, "FAMAS") || strstr(name, "Abakan") || strstr(name, "F2000") ||
            strstr(name, "Súng AR") || strstr(name, "AR Rifle")) {
            return g_pubgEspWeaponAR;
        }
        // SMG: UZI, UMP45, Vector, Tommy Gun, Bizon, MP5K, P90, JS9, Súng SMG
        if (strstr(name, "UZI") || strstr(name, "UMP") || strstr(name, "Vector") ||
            strstr(name, "Tommy") || strstr(name, "Bizon") || strstr(name, "MP5") ||
            strstr(name, "P90") || strstr(name, "JS9") || strstr(name, "Súng SMG") ||
            strstr(name, "SMG")) {
            return g_pubgEspWeaponSMG;
        }
        // Shotgun: S686, S1897, S12K, DBS, M1014, NS2000, SPAS, Sawed-Off, Shotgun
        if (strstr(name, "S686") || strstr(name, "S1897") || strstr(name, "S12K") ||
            strstr(name, "DBS") || strstr(name, "M1014") || strstr(name, "NS2000") ||
            strstr(name, "SPAS") || strstr(name, "Sawed") || strstr(name, "Shotgun")) {
            return g_pubgEspWeaponShotgun;
        }
        // Sniper & DMR: Kar98k, M24, AWM, SKS, VSS, Mini14, Mk14, Win94, SLR, QBU, Mosin, AMR, Lynx, Mk12, Dragunov, Súng Sniper
        if (strstr(name, "Kar98") || strstr(name, "M24") || strstr(name, "AWM") ||
            strstr(name, "SKS") || strstr(name, "VSS") || strstr(name, "Mini14") ||
            strstr(name, "Mk14") || strstr(name, "Win94") || strstr(name, "SLR") ||
            strstr(name, "QBU") || strstr(name, "Mosin") || strstr(name, "AMR") ||
            strstr(name, "Lynx") || strstr(name, "VAL") || strstr(name, "Mk12") ||
            strstr(name, "Dragunov") || strstr(name, "Súng Sniper") || strstr(name, "Sniper")) {
            return g_pubgEspWeaponSniper;
        }
        // Other weapons (LMG, Pistols, Melee, Pan, Crossbow): M249, DP-28, MG3, P92, Deagle, Pan...
        return (g_pubgEspWeaponAR || g_pubgEspWeaponSMG || g_pubgEspWeaponShotgun || g_pubgEspWeaponSniper);
    }

    return true;
}
static void ds_pubg_tick(void);
static bool ds_pubg_has_render_source(void);
static const char* ds_pubg_get_debug_status(void);
static int ds_pubg_copy_projected_players(DSPUBGProjectedPlayer out[kDSPUBGMaxPlayers],
                                          uint64_t *epochOut);
static int ds_pubg_copy_projected_items(DSPUBGProjectedItem out[kDSPUBGMaxItems],
                                        uint64_t *epochOut);
static int ds_pubg_copy_projected_grenades(DSPUBGProjectedGrenade out[kDSPUBGMaxGrenades],
                                           uint64_t *epochOut);
static void ds_pubg_get_total_counts(int *outEnemies, int *outBots);
static void ds_pubg_overlay_reset(void);

#include "DSBridgeESP.inc.mm"
#include "DSBridgePUBG.inc.mm"

// The HUD lives in its own UIWindow anchored to SBMainWorkspace.mainWindowScene
// Adding to whatever keyWindow we can find is
// unreliable — that window may be hidden, tiny, or off-screen.
static uint64_t ds_create_springboard_hud(RemoteCall *process) {
    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    NSString *text = ds_full_display_text(preferences, probe.centered, YES, 0, 0);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);

    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t workspaceClass = ds_remote_class(process, "SBMainWorkspace");
    // _UIDebugIdentifierWindow is a stock UIWindow subclass whose
    // -_ignoresHitTest returns YES (verified in UIKitCore disassembly), so the
    // window server excludes it from hit regions and touches fall through to
    // any app — not just SpringBoard. Plain -[UIWindow init] skips its
    // initWithWindowScene:, so the debug identifier label is never created.
    uint64_t windowClass = ds_remote_class(process, "_UIDebugIdentifierWindow");
    if (!windowClass) windowClass = ds_remote_class(process, "UIWindow");
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

    // Adopt the remote scene's geometry immediately so the first layout is
    // already correct for the current rotation.
    uint64_t coordSpace = ds_remote_get_object_on_main(process, scene, "coordinateSpace");
    if (coordSpace) {
        CGRect sceneBounds = remote_getCGRect(process, coordSpace,
                                              ds_remote_sel(process, "bounds"));
        if (!CGRectIsNull(sceneBounds) && CGRectGetWidth(sceneBounds) > 0.0 &&
            CGRectGetHeight(sceneBounds) > 0.0) {
            g_remoteSceneBounds = sceneBounds;
        }
    }

    CGRect windowFrame = ds_remote_window_frame();
    CGRect windowBounds = ds_remote_window_bounds(windowFrame);
    CGRect contentFrame = ds_hud_content_frame(&presentation, windowFrame);

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

    ds_remote_set_rect_on_main(process, window, "setFrame:", windowFrame);
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setWindowScene:"), scene, YES);
    // Match the original hosted HUD. Status-bar level is below SpringBoard's
    // CoverSheet, so it disappears as soon as the device enters the lock UI.
    ds_remote_set_double_on_main(process, window, "setWindowLevel:", kDSHUDWindowLevel);
    ds_remote_set_u64_on_main(process, window, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, window, "setOpaque:", 0);

    ds_remote_set_rect_on_main(process, container, "setFrame:", contentFrame);
    ds_remote_set_rect_on_main(process, blurView, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, label, "setFrame:", presentation.labelFrame);
    ds_remote_set_rect_on_main(process, secureField, "setFrame:", windowBounds);

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
                                   clear, YES);
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
    ds_remote_set_u64_on_main(process, label, "setHidden:", 1);
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
    g_remoteBlurView = blurView;
    g_remoteSecureField = secureField;
    g_remoteSecureCanvas = ds_remote_secure_canvas(process, secureField);
    g_remoteWindowScene = scene;
    g_remoteWindowPid = process.pid;
    ds_apply_snapshot_container(process, presentation.hideAtSnapshot);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);

    g_remoteBlurEffect = 0;
    g_lastPresentationSignature = preferences.description.hash ^
                                  (NSUInteger)ds_interface_orientation();
    g_lastWindowFrame = windowFrame;
    g_lastHUDContentFrame = contentFrame;
    g_lastLabelFrame = presentation.labelFrame;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = 1.0;
    g_lastFontSize = presentation.fontSize;
    g_lastInverted = presentation.inverted;
    return label;
}

// Never release remote UIViews: dealloc on a hijacked thread crashes
// SpringBoard (same CA main-thread assert). The hierarchy stays alive inside
// SpringBoard across toggles — disable only hides the window, and the next
// enable unhides it instead of paying for remote window/label creation again
// (that burst of remote_msg round trips was the visible ~1s progress crawl).
static void ds_remove_springboard_hud(RemoteCall *process) {
    if (!g_remoteWindow || g_remoteWindowPid != process.pid) return;
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

    // Window geometry is owned by ds_update_window_rotation() (bounds/center/
    // transform); here only the content space matters for subviews.
    CGRect contentBounds = ds_content_bounds();
    CGRect contentFrame = ds_hud_content_frame(presentation, contentBounds);
    if (!CGRectEqualToRect(g_lastWindowFrame, contentBounds)) {
        if (g_remoteSecureField) {
            ds_remote_set_rect_on_main(process, g_remoteSecureField, "setFrame:",
                                       contentBounds);
        }
        g_lastWindowFrame = contentBounds;
    }
    if (!CGRectEqualToRect(g_lastHUDContentFrame, contentFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteContainer, "setFrame:",
                                   contentFrame);
        ds_remote_set_rect_on_main(process, g_remoteBlurView, "setFrame:",
                                   presentation->blurFrame);
        g_lastHUDContentFrame = contentFrame;
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
        uint64_t clearColor = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "clearColor") : 0;
        uint64_t textColor = presentation->inverted ? black : white;
        if (textColor && clearColor) {
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setTextColor:"), textColor, YES);
            // Bubble stays transparent: floating text, no pill background.
            ds_perform_on_springboard_main(process, g_remoteBlurView,
                                           ds_remote_sel(process, "setBackgroundColor:"),
                                           clearColor, YES);
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

    // Circuit breaker: once the trojan region is gone, the hijacked thread
    // state is unreliable. Never keep calling into a possibly-wedged
    // SpringBoard — each further call is a respring lottery.
    if (!g_springBoard.trojanMem) {
        ds_set_error(ds_localized(@"Lost the SpringBoard connection; HUD updates stopped. Toggle the HUD off and on to rebuild it."));
        g_hudActive.store(false);
        return;
    }

    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    BOOL focused = NO;
    NSString *text = ds_full_display_text(
        preferences, probe.centered, focused, 0.0, 0.0);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);
    NSUInteger presentationSignature = preferences.description.hash ^
                                       (NSUInteger)ds_interface_orientation();
    BOOL applyStyle = presentationSignature != g_lastPresentationSignature;

    // The hosted CAShapeLayer overlay owns all ESP rendering.
    ds_update_window_rotation(g_springBoard);

    // The text is permanently empty, so regular ticks avoid SpringBoard work
    // unless layout/style or lock-state handling actually changed.
    if (!applyStyle && !focused && !g_pendingWindowLevelReapply &&
        g_lastAppliedText && [g_lastAppliedText isEqualToString:text]) {
        return;
    }

    // Deferred from the lock-state handler; never do this mid-transition.
    if (g_pendingWindowLevelReapply) {
        g_pendingWindowLevelReapply = NO;
        if (g_remoteWindow) {
            ds_remote_set_double_on_main(g_springBoard, g_remoteWindow,
                                         "setWindowLevel:", kDSHUDWindowLevel);
        }
    }

    BOOL applied = NO;
    @try {
        applied = ds_apply_remote_presentation(
            g_springBoard, &presentation, text, focused, applyStyle);
    } @catch (NSException *exception) {
        applied = NO;
        (void)exception;
    }

    if (applied) {
        g_remoteFailureCount = 0;
        g_lastAppliedText = [text copy];
        g_lastPresentationSignature = presentationSignature;
    } else {
        g_remoteFailureCount++;
        if (g_remoteFailureCount >= kDSRemoteFailureLimit || !g_springBoard.trojanMem) {
            // Stop hammering SpringBoard. The frozen HUD view stays in place
            // until the user explicitly rebuilds it by toggling the HUD.
            ds_set_error(ds_localized(@"SpringBoard HUD update failed repeatedly; updates stopped. Toggle the HUD off and on to rebuild it."));
            g_hudActive.store(false);
        }
    }
}

static void ds_start_rate_timer(void) {
    if (g_rateTimer) return;
    g_rateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_bridge_queue());
    // This timer only applies preference/lock-state changes. Orientation comes
    // from FBSOrientationObserver; the hosted ESP has its own display timer.
    g_fastTickActive = NO;
    dispatch_source_set_timer(g_rateTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                              NSEC_PER_SEC / 4, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_rateTimer, ^{
        @autoreleasepool {
            ds_update_rate();
        }
    });
    dispatch_resume(g_rateTimer);
}

static void ds_stop_rate_timer(void) {
    if (!g_rateTimer) return;
    dispatch_source_cancel(g_rateTimer);
    g_rateTimer = nil;
    g_fastTickActive = NO;
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

        // Keep the SpringBoard-hosted HUD above CoverSheet while locked, but
        // never hijack a thread during the lock transition itself — that is
        // exactly when SpringBoard's main thread is busiest and a remote call
        // is most likely to wedge it (respring). Defer everything to the next
        // regular rate tick, which runs within ~1s anyway.
        g_pendingWindowLevelReapply = YES;
        if (!locked) {
        }
        g_lastWindowHidden = YES;
        g_lastAppliedText = nil;  // force a full reapply on the next tick
    });
}

static void ds_finish_disable(void) {
    ds_set_stage(ds_localized(@"Closing HUD"));
    ds_unregister_hud_notifications();
    ds_stop_rate_timer();
    // Pause (not stop): keep the local window + CAContext + the SpringBoard
    // registration alive so the next enable needs no channel at all.
    ds_hosted_overlay_pause();
    g_hudActive.store(false);
    // Keep the SpringBoard RemoteCall channel alive across toggles (DarkPlay
    // pattern). RemoteCall init/destroy and every remote_msg are
    // hijacked-thread round trips inside SpringBoard; repeating them per
    // toggle corrupts thread state (threads-zone UAF -> delayed kernel panic)
    // and is what made every re-enable crawl through the progress bar. The
    // channel is rebuilt only when SpringBoard's pid changes (respring), in
    // ds_finish_enable().
    if (g_springBoard) {
        @try {
            ds_remove_springboard_hud(g_springBoard);
        } @catch (__unused NSException *exception) {
        }
        @try {
            // Release the text ring now that nothing references the strings.
            uint64_t releaseSel = ds_remote_sel(g_springBoard, "release");
            for (NSUInteger i = 0; i < kDSRemoteTextRingSize; i++) {
                if (g_remoteTextRing[i] && releaseSel && g_springBoard.trojanMem) {
                    remote_msg(g_springBoard, g_remoteTextRing[i], releaseSel, 0, 0, 0, 0);
                }
                g_remoteTextRing[i] = 0;
            }
            g_remoteTextRingIndex = 0;
        } @catch (__unused NSException *exception) {
        }
    }
    // Keep the remote window/label pointers: the hierarchy is still alive
    // inside SpringBoard (disable only hid it) and the next enable reuses it.
    g_activeOrientation.store(UIInterfaceOrientationUnknown);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_deviceOrientationObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:g_deviceOrientationObserver];
            g_deviceOrientationObserver = nil;
        }
        [g_orientationObserver invalidate];
        g_orientationObserver = nil;
    });
    g_remoteOrientation.store(UIInterfaceOrientationUnknown);
    g_lastPresentationSignature = 0;
    g_lastWindowFrame = CGRectNull;
    g_lastHUDContentFrame = CGRectNull;
    g_lastLabelFrame = CGRectNull;
    // Game còn sống thì giải phóng hẳn các page đã map (an toàn); game chết
    // rồi thì leak như cũ để tránh panic trong teardown.
    ds_debug_shmem_flush_ex(ds_debug_target_alive());
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = -1.0;
    g_lastFontSize = -1.0;
    g_lastInverted = NO;
    g_lastHideAtSnapshot = NO;
    g_lastAppliedText = nil;
    g_remoteFailureCount = 0;
    g_pendingWindowLevelReapply = NO;
    // Keep the selector/class cache too: it belongs to the live channel and
    // makes the next enable skip every remote symbol lookup.
    // Keep the keepalive running while the SpringBoard channel exists: only a
    // background-RUNNING (not suspended) process gets applicationWillTerminate:,
    // which is where the channel is torn down. Suspending here would lose that
    // callback and leave the hijacked thread behind -> respring on swipe-kill.
    if (!g_springBoard) ds_stop_keepalive();
    ds_set_stage(ds_localized(@"HUD closed"));
    notify_post(NOTIFY_RELOAD_APP);
}

static void ds_finish_enable(void) {
    if (!g_hudRequested.load()) return;
    g_dsRunning.store(true);
    g_dsProgress.store(0.0);
    ds_set_stage(ds_localized(@"Preparing startup"));
    ds_post_progress();

    // Active-interface-orientation tracking (the same FBSOrientationObserver
    // mechanism cccc/TrollSpeed run in their HUD process): it follows the
    // foreground app even while this process is backgrounded.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        if (!g_orientationObserver) {
            Class observerClass = objc_getClass("FBSOrientationObserver");
            if (observerClass) {
                g_orientationObserver = [[observerClass alloc] init];
                [g_orientationObserver setHandler:^(FBSOrientationUpdate *update) {
                    if (!update) return;
                    UIInterfaceOrientation ori = (UIInterfaceOrientation)update.orientation;
                    if (ori == UIInterfaceOrientationUnknown) return;
                    g_activeOrientation.store((int)ori);
                    double duration = update.duration;
                    if ([NSThread isMainThread]) {
                        ds_hosted_apply_orientation(ori, duration);
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ds_hosted_apply_orientation(ori, duration);
                        });
                    }
                }];
                long long current = [g_orientationObserver activeInterfaceOrientation];
                if (current != UIInterfaceOrientationUnknown) {
                    g_activeOrientation.store((int)current);
                    ds_hosted_apply_orientation((UIInterfaceOrientation)current, 0.0);
                }
            }
        }
        if (!g_deviceOrientationObserver) {
            g_deviceOrientationObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIDeviceOrientationDidChangeNotification
                object:nil
                queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
                    (void)note;
                    UIDeviceOrientation devOri = UIDevice.currentDevice.orientation;
                    if (UIDeviceOrientationIsLandscape(devOri)) {
                        UIInterfaceOrientation ori = (devOri == UIDeviceOrientationLandscapeLeft)
                            ? UIInterfaceOrientationLandscapeRight
                            : UIInterfaceOrientationLandscapeLeft;
                        g_activeOrientation.store((int)ori);
                        ds_hosted_apply_orientation(ori, 0.3);
                    } else if (devOri == UIDeviceOrientationPortrait) {
                        g_activeOrientation.store((int)UIInterfaceOrientationPortrait);
                        ds_hosted_apply_orientation(UIInterfaceOrientationPortrait, 0.3);
                    }
                }];
        }
    });

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
        ds_fail_enable(ds_localized(@"DarkPubg startup failed. Retry or reinstall over the existing app; restart the device only as a last resort."));
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
    uint32_t sbPidEarly = off_proc_p_pid ? ds_kread32(sbProc + off_proc_p_pid) : 0;

    // One-shot channel design: after the first successful enable the overlay
    // registration lives inside SpringBoard but the hijacked thread/exception
    // ports are already torn down. Same SpringBoard generation => re-enable
    // is fully local: resume rendering into our own CAContext, zero hijack.
    if (sbPidEarly && g_hostedRemoteController &&
        g_hostedMenuRemoteController &&
        g_hostedSBPid == (pid_t)sbPidEarly && g_hostedLayer &&
        g_hostedMenuWindow) {
        g_hudActive.store(true);
        g_dsRunning.store(false);
        g_dsProgress.store(1.0);
        ds_set_stage(ds_localized(@"SpringBoard HUD started"));
        ds_set_error(@"");
        notify_post(NOTIFY_LAUNCHED_HUD);
        ds_post_progress();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_hostedMenuWindow) {
                g_hostedMenuWindow.hidden = NO;
            }
            if (g_hostedMenuViewController) {
                [g_hostedMenuViewController dsApplyOrientation];
            }
        });
        ds_hosted_overlay_start();
        return;
    }

    BOOL createdChannel = NO;
    @try {
        g_dsProgress.store(0.98);
        ds_set_stage(ds_localized(@"Connecting to SpringBoard"));
        uint32_t sbPid = off_proc_p_pid ? ds_kread32(sbProc + off_proc_p_pid) : 0;
        if (g_springBoard && g_springBoard.trojanMem && sbPid &&
            g_springBoard.pid == (int)sbPid) {
            // Same SpringBoard as last enable: reuse the channel as-is — zero
            // new thread injections, near-instant re-enable (DarkPlay pattern).
        } else {
            // First enable, or SpringBoard resprung while the HUD was off.
            // Drop the stale channel WITHOUT destroyRemoteCall: its restore
            // writes would target a dead process's kernel structures. The old
            // hosting controller died with the old SpringBoard anyway.
            g_springBoard = nil;
            g_hostedRemoteController = 0;
            g_hostedMenuRemoteController = 0;
            ds_reset_remote_symbol_cache();
            g_springBoard = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
            if (!g_springBoard || !g_springBoard.trojanMem || g_springBoard.pid <= 1) {
                NSString *remoteError = [RemoteCall lastInitError];
                if (remoteError.length == 0 && g_springBoard) remoteError = g_springBoard.lastError;
                if (remoteError.length == 0) remoteError = @"RemoteCall init failed (no detail)";
                g_springBoard = nil;
                ds_fail_enable([NSString stringWithFormat:
                    ds_localized(@"SpringBoard connection failed: %@\nRetry or reinstall over the existing app; restart the device only as a last resort."),
                    remoteError]);
                return;
            }
            createdChannel = YES;
        }

        g_dsProgress.store(0.99);
        ds_set_stage(ds_localized(@"Creating SpringBoard HUD"));
        if (g_remoteWindow && g_remoteLabel && g_remoteWindowPid == (pid_t)sbPid) {
            // The HUD hierarchy from the previous enable is still alive inside
            // SpringBoard: unhide it and force one full presentation re-apply
            // instead of recreating every remote view.
            ds_remote_set_u64_on_main(g_springBoard, g_remoteWindow, "setHidden:", 0);
            g_lastWindowHidden = NO;
            g_lastPresentationSignature = 0;
            g_pendingWindowLevelReapply = YES;
        } else {
            g_remoteLabel = ds_create_springboard_hud(g_springBoard);
        }
        if (!g_remoteLabel) {
            // Only tear down a channel THIS enable created; a reused channel
            // stays alive for the next toggle.
            if (createdChannel) {
                RemoteCall *process = g_springBoard;
                g_springBoard = nil;
                @try {
                    [process destroyRemoteCall];
                } @catch (__unused NSException *exception) {
                }
            }
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
    ds_register_hud_notifications();

    // One-shot: register both hosted windows while the channel exists, then
    // tear the channel down — no hijacked thread or exception ports are left
    // inside SpringBoard while the ESP runs (the long-run panic source).
    __block unsigned hostedContextId = 0;
    __block unsigned menuContextId = 0;
    ds_dispatch_main_sync(^{
        hostedContextId = ds_hosted_overlay_setup_on_main();
        menuContextId = ds_hosted_menu_setup_on_main();
    });
    if (hostedContextId) {
        ds_hosted_overlay_register(hostedContextId);
    }
    if (menuContextId) {
        ds_hosted_menu_register(menuContextId);
    }
    if (g_hostedRemoteController && g_hostedMenuRemoteController) {
        RemoteCall *process = g_springBoard;
        g_springBoard = nil;
        @try {
            [process destroyRemoteCall];
        } @catch (__unused NSException *exception) {
        }
        // Nothing remote left to update; the 4 Hz rate timer only exists for
        // channel-driven presentation work.
        ds_stop_rate_timer();
    } else {
        // A registration failed: keep the channel so the overlay/menu retry
        // loop can try again, and keep the rate timer as before.
        ds_start_rate_timer();
    }
    notify_post(NOTIFY_LAUNCHED_HUD);
    ds_post_progress();
    ds_hosted_overlay_start();
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

void DSBridgeTeardownForTermination(void) {
    // applicationWillTerminate runs on main. Hide both local CAContexts before
    // any queued teardown so SpringBoard cannot retain their last frame/icon.
    g_hostedMenuExpanded = NO;
    g_hostedMenuWindow.hidden = YES;
    g_hostedWindow.hidden = YES;
    [CATransaction flush];
    // Called from applicationWillTerminate: on the main thread. The keepalive
    // keeps us background-RUNNING (not suspended), so this really fires on a
    // swipe-kill. Serialize with the bridge queue, but never call helpers that
    // dispatch_sync to the main thread from here (it is blocked in this call).
    dispatch_sync(ds_bridge_queue(), ^{
        @autoreleasepool {
            ds_stop_rate_timer();
            if (g_hostedTimer) {
                dispatch_source_cancel(g_hostedTimer);
                g_hostedTimer = nil;
            }
            RemoteCall *process = g_springBoard;
            g_springBoard = nil;
            g_hostedRemoteController = 0;
            g_hostedMenuRemoteController = 0;
            g_hostedContextId = 0;
            g_hostedMenuContextId = 0;
            g_hudRequested.store(false);
            g_hudActive.store(false);
            if (process) {
                @try {
                    // Restores/exits the hijacked SpringBoard thread.
                    [process destroyRemoteCall];
                } @catch (__unused NSException *exception) {
                }
            }
        }
    });
}

double DSBridgeProgress(void) {
    return g_dsProgress.load();
}

BOOL DSBridgeIsRunning(void) {
    return g_dsRunning.load();
}

BOOL DSBridgeStartKeepalive(void) {
    return ds_start_keepalive();
}

#else

BOOL DSBridgeCompiledIn(void) { return NO; }
BOOL DSBridgeIsReady(void) { return NO; }
void DSBridgeWarmUpNetworkAndPrefetchKernelCache(void) {}
BOOL DSBridgeAdoptFromEnvironment(void) {
    ds_set_error(ds_localized(@"DarkPubg is not enabled in this build."));
    return NO;
}
BOOL DSBridgeBootstrap(void) {
    ds_set_error(ds_localized(@"DarkPubg is not enabled in this build."));
    return NO;
}
BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    (void)enabled;
    return NO;
}
BOOL DSBridgeStartKeepalive(void) {
    return NO;
}
void DSBridgeTeardownForTermination(void) {}
BOOL DSBridgeHUDEnabled(void) { return NO; }
double DSBridgeProgress(void) { return 0.0; }
BOOL DSBridgeIsRunning(void) { return NO; }

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

int DSBridgeActiveGame(void) {
    return 1; // Always PUBG Mobile
}

void DSBridgeSetActiveGame(int game) {
    (void)game;
    ds_pubg_overlay_reset();
}

BOOL DSBridgeIsPUBGRunning(void) {
#if USE_DARKSWORD
    if (DSBridgeIsReady()) {
        pid_t pid = 0;
        uint64_t proc = ds_pubg_find_proc(&pid);
        return (proc != 0 && pid > 0);
    }
#endif
    return NO;
}
