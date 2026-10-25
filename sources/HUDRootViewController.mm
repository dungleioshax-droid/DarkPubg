//
//  HUDRootViewController.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <notify.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#import "HUDPresetPosition.h"
#import "HUDRootViewController.h"
#import "HUDBackdropLabel.h"
#import "DSBridge.h"
#import "DarkSpeed-Swift.h"


#pragma mark -

#import "FBSOrientationUpdate.h"
#import "FBSOrientationObserver.h"
#import "UIApplication+Private.h"
#import "LSApplicationProxy.h"
#import "LSApplicationWorkspace.h"
#import "SpringBoardServices.h"

#define NOTIFY_UI_LOCKSTATE    "com.apple.springboard.lockstate"
#define NOTIFY_LS_APP_CHANGED  "com.apple.LaunchServices.ApplicationsChanged"

static void LaunchServicesApplicationStateChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    /* Application installed or uninstalled */

    BOOL isAppInstalled = NO;

    for (LSApplicationProxy *app in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications])
    {
        if ([app.applicationIdentifier isEqualToString:@"ch.xxtou.hudapp"])
        {
            isAppInstalled = YES;
            break;
        }
    }

    if (!isAppInstalled)
    {
        UIApplication *app = [UIApplication sharedApplication];
        [app terminateWithSuccess];
    }
}

static void SpringBoardLockStatusChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if ([lockState isEqualToString:@NOTIFY_UI_LOCKSTATE])
    {
        mach_port_t sbsPort = SBSSpringBoardServerPort();

        if (sbsPort == MACH_PORT_NULL)
            return;

        BOOL isLocked;
        BOOL isPasscodeSet;
        SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);

        if (!isLocked)
        {
            [rootViewController.view setHidden:NO];
            [rootViewController resetLoopTimer];
        }
        else
        {
            [rootViewController stopLoopTimer];
            [rootViewController.view setHidden:YES];
        }
    }
}

#pragma mark - DarkSpeed ESP-only HUD shell (kernrw48)

// kernrw48: toàn bộ HUD speed/FPS (getUpDownBytes/formattedSpeed/FPS/…) đã
// gỡ — app chỉ còn ESP. Cửa sổ shell này giờ chỉ hiển thị 1 dòng trạng thái
// ESP (bật qua toggle ESP Box).

#define UPDATE_INTERVAL 1.0
#define IDLE_INTERVAL 3.0

static const double HUD_FONT_SIZE_DEFAULT = 22.0;
static const double HUD_MIN_CORNER_RADIUS = 0.0;
static double HUD_FONT_SIZE = HUD_FONT_SIZE_DEFAULT;
static CGFloat HUD_INACTIVE_OPACITY = 0.9;
static uint8_t HUD_SHOW_ESP_BOX = 0; // 0=hide, 1=show ESP status

static NSAttributedString *formattedNSAttributedString(BOOL __unused isFocused)
{
    @autoreleasepool
    {
        if (!HUD_SHOW_ESP_BOX) return nil;

        uint32_t count = 0;
        @try {
            count = DSBridgeESPCount();
        } @catch (__unused NSException *e) {
            count = 0;
        }

        NSString *status = nil;
        @try {
            status = DSBridgeESPStatus();
        } @catch (__unused NSException *e) {
            status = nil;
        }

        if (!status || status.length == 0) return nil;

        BOOL isWaiting = ([status containsString:@"wait"] || [status containsString:@"--"]);

        NSString *numStr = nil;
        if (isWaiting && count == 0) {
            numStr = @"--";
        } else {
            numStr = [NSString stringWithFormat:@"%u", (unsigned)count];
        }

        UIFont *font = [UIFont monospacedDigitSystemFontOfSize:HUD_FONT_SIZE weight:UIFontWeightHeavy];
        // Chỉ hiện số địch màu đỏ nổi bật, rõ ràng
        UIColor *redColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0];

        return [[NSAttributedString alloc] initWithString:numStr attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: redColor
        }];
    }
}

#pragma mark - HUDRootViewController

@interface HUDRootViewController (Troll)
- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration;
@end

static const CACornerMask kCornerMaskBottom = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
static const CACornerMask kCornerMaskAll = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;

@implementation HUDRootViewController {
    NSMutableDictionary *_userDefaults;
    NSMutableArray <NSLayoutConstraint *> *_constraints;
    UIBlurEffect *_blurEffect;
    UIVisualEffectView *_blurView;
    ScreenshotInvisibleContainer *_containerView;
    UIView *_contentView;
    HUDBackdropLabel *_speedLabel;
    UIImageView *_lockedView;
    NSTimer *_timer;
    UITapGestureRecognizer *_tapGestureRecognizer;
    UIPanGestureRecognizer *_panGestureRecognizer;
    UIImpactFeedbackGenerator *_impactFeedbackGenerator;
    UINotificationFeedbackGenerator *_notificationFeedbackGenerator;
    BOOL _isFocused;
    NSLayoutConstraint *_topConstraint;
    NSLayoutConstraint *_centerXConstraint;
    NSLayoutConstraint *_leadingConstraint;
    NSLayoutConstraint *_trailingConstraint;
    UIInterfaceOrientation _orientation;
    FBSOrientationObserver *_orientationObserver;
}

- (void)registerNotifications
{
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &token, dispatch_get_main_queue(), ^(int token) {
        [self reloadUserDefaults];
    });

    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        LaunchServicesApplicationStateChanged,
        CFSTR(NOTIFY_LS_APP_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        SpringBoardLockStatusChanged,
        CFSTR(NOTIFY_UI_LOCKSTATE),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    NSUserDefaults *userDefaults = GetStandardUserDefaults();
    [userDefaults addObserver:self forKeyPath:HUDUserDefaultsKeyUsesCustomFontSize options:NSKeyValueObservingOptionNew context:nil];
    [userDefaults addObserver:self forKeyPath:HUDUserDefaultsKeyRealCustomFontSize options:NSKeyValueObservingOptionNew context:nil];
    [userDefaults addObserver:self forKeyPath:HUDUserDefaultsKeyUsesCustomOffset options:NSKeyValueObservingOptionNew context:nil];
    [userDefaults addObserver:self forKeyPath:HUDUserDefaultsKeyRealCustomOffsetX options:NSKeyValueObservingOptionNew context:nil];
    [userDefaults addObserver:self forKeyPath:HUDUserDefaultsKeyRealCustomOffsetY options:NSKeyValueObservingOptionNew context:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:HUDUserDefaultsKeyUsesCustomFontSize] ||
        [keyPath isEqualToString:HUDUserDefaultsKeyRealCustomFontSize] ||
        [keyPath isEqualToString:HUDUserDefaultsKeyUsesCustomOffset] ||
        [keyPath isEqualToString:HUDUserDefaultsKeyRealCustomOffsetX] ||
        [keyPath isEqualToString:HUDUserDefaultsKeyRealCustomOffsetY])
    {
        [self reloadUserDefaults];
    }
}

- (void)loadUserDefaults:(BOOL)forceReload
{
    if (forceReload || !_userDefaults)
        _userDefaults = [[NSDictionary dictionaryWithContentsOfFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH))] mutableCopy] ?: [NSMutableDictionary dictionary];
}

- (void)saveUserDefaults
{
    BOOL wroteSucceed = [_userDefaults writeToFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) atomically:YES];
    if (wroteSucceed) {
        [[NSFileManager defaultManager] setAttributes:@{
            NSFileOwnerAccountID: @501,
            NSFileGroupOwnerAccountID: @501,
        } ofItemAtPath:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) error:nil];
        notify_post(NOTIFY_RELOAD_APP);
    }
}

- (void)reloadUserDefaults
{
    [self loadUserDefaults:YES];

    // Custom font/offset = setting cấu trúc của shell — giữ nguyên.
    BOOL usesCustomFontSize = [self usesCustomFontSize];
    if (usesCustomFontSize) {
        HUD_FONT_SIZE = MIN(MAX([self realCustomFontSize], 14), 40);
    } else {
        HUD_FONT_SIZE = HUD_FONT_SIZE_DEFAULT;
    }
    _blurView.layer.cornerRadius = 0.0;
    _blurView.backgroundColor = [UIColor clearColor];

    BOOL hideAtSnapshot = [self hideAtSnapshot];
    if (hideAtSnapshot) {
        [_containerView setupContainerAsHideContentInScreenshots];
    } else {
        [_containerView setupContainerAsDisplayContentInScreenshots];
    }

    BOOL showESPBox = [self showESPBox];
    HUD_SHOW_ESP_BOX = showESPBox;

    [self removeAllAnimations];
    [self resetGestureRecognizers];
    [self updateViewConstraints];

    if (!_isFocused) {
        [self onFocus:_contentView];
    } else {
        [self keepFocus:_contentView];
    }

    [self performSelector:@selector(onBlur:) withObject:_contentView afterDelay:IDLE_INTERVAL];
}

+ (BOOL)passthroughMode
{
    return [[[NSDictionary dictionaryWithContentsOfFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH))] objectForKey:HUDUserDefaultsKeyPassthroughMode] boolValue];
}

- (BOOL)isLandscapeOrientation
{
    return YES;
}

- (HUDUserDefaultsKey)selectedModeKeyForCurrentOrientation
{
    return HUDUserDefaultsKeySelectedModeLandscape;
}

- (HUDPresetPosition)selectedModeForCurrentOrientation
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeySelectedModeLandscape];
    if (mode == nil) {
        mode = [_userDefaults objectForKey:HUDUserDefaultsKeySelectedMode];
    }
    return mode != nil ? (HUDPresetPosition)[mode integerValue] : HUDPresetPositionTopCenter;
}

- (BOOL)singleLineMode
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeySingleLineMode];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)displayMode
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyDisplayMode];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)showBaseGame
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyShowBaseGame];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)showESPBox
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyShowESPBox];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)usesBitrate
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesBitrate];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)usesArrowPrefixes
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesArrowPrefixes];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)usesLargeFont
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesLargeFont];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)usesRotation
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesRotation];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)usesInvertedColor
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesInvertedColor];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)keepInPlace
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyKeepInPlace];
    return mode != nil ? [mode boolValue] : NO;
}

- (BOOL)hideAtSnapshot
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyHideAtSnapshot];
    return mode != nil ? [mode boolValue] : NO;
}

- (CGFloat)currentPositionY
{
    [self loadUserDefaults:NO];
    NSNumber *positionY = [_userDefaults objectForKey:HUDUserDefaultsKeyCurrentPositionY];
    return positionY != nil ? [positionY doubleValue] : CGFLOAT_MAX;
}

- (void)setCurrentPositionY:(CGFloat)positionY
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:[NSNumber numberWithDouble:positionY] forKey:HUDUserDefaultsKeyCurrentPositionY];
    [self saveUserDefaults];
}

- (CGFloat)currentLandscapePositionY
{
    [self loadUserDefaults:NO];
    NSNumber *positionY = [_userDefaults objectForKey:HUDUserDefaultsKeyCurrentLandscapePositionY];
    return positionY != nil ? [positionY doubleValue] : CGFLOAT_MAX;
}

- (void)setCurrentLandscapePositionY:(CGFloat)positionY
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:[NSNumber numberWithDouble:positionY] forKey:HUDUserDefaultsKeyCurrentLandscapePositionY];
    [self saveUserDefaults];
}

- (BOOL)usesCustomFontSize {
    return [GetStandardUserDefaults() boolForKey:HUDUserDefaultsKeyUsesCustomFontSize];
}

- (CGFloat)realCustomFontSize {
    return [GetStandardUserDefaults() doubleForKey:HUDUserDefaultsKeyRealCustomFontSize];
}

- (BOOL)usesCustomOffset {
    return [GetStandardUserDefaults() boolForKey:HUDUserDefaultsKeyUsesCustomOffset];
}

- (CGFloat)realCustomOffsetX {
    return [GetStandardUserDefaults() doubleForKey:HUDUserDefaultsKeyRealCustomOffsetX];
}

- (CGFloat)realCustomOffsetY {
    return [GetStandardUserDefaults() doubleForKey:HUDUserDefaultsKeyRealCustomOffsetY];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _constraints = [NSMutableArray array];
        _orientation = UIInterfaceOrientationLandscapeRight;
        [self registerNotifications];
        _orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init];
        __weak HUDRootViewController *weakSelf = self;
        [_orientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
            HUDRootViewController *strongSelf = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf updateOrientation:(UIInterfaceOrientation)orientationUpdate.orientation animateWithDuration:orientationUpdate.duration];
            });
        }];
    }
    return self;
}

- (void)dealloc
{
    [_orientationObserver invalidate];
}

- (void)updateSpeedLabel
{
    log_debug(OS_LOG_DEFAULT, "updateSpeedLabel");
    NSAttributedString *attributedText = formattedNSAttributedString(_isFocused);
    if (attributedText) {
        [_speedLabel setAttributedText:attributedText];
        _speedLabel.hidden = NO;
        _blurView.hidden = NO;
    } else {
        [_speedLabel setAttributedText:[[NSAttributedString alloc] initWithString:@""]];
        _speedLabel.hidden = YES;
        _blurView.hidden = YES;
    }
    [_speedLabel sizeToFit];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    /* Just put your HUD view here */

    _contentView = [[UIView alloc] init];
    _contentView.backgroundColor = [UIColor clearColor];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_contentView];

    // Nền hoàn toàn trong suốt không có khung hộp đen
    _blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
    _blurView.layer.cornerRadius = 0.0;
    _blurView.layer.masksToBounds = NO;
    _blurView.layer.borderWidth = 0.0;
    _blurView.layer.borderColor = nil;
    _blurView.backgroundColor = [UIColor clearColor];
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    _containerView = [[ScreenshotInvisibleContainer alloc] initWithContent:_blurView];
    _containerView.hiddenContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentView addSubview:_containerView.hiddenContainer];

    // Chỉ hiển thị số lượng địch màu đỏ trực tiếp trên màn hình có viền đổ bóng rõ nét
    _speedLabel = [[HUDBackdropLabel alloc] initWithFrame:CGRectZero];
    _speedLabel.numberOfLines = 1;
    _speedLabel.textAlignment = NSTextAlignmentCenter;
    _speedLabel.textColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0];
    _speedLabel.font = [UIFont monospacedDigitSystemFontOfSize:HUD_FONT_SIZE weight:UIFontWeightHeavy];
    _speedLabel.layer.shadowColor = [UIColor blackColor].CGColor;
    _speedLabel.layer.shadowOffset = CGSizeMake(1.5, 1.5);
    _speedLabel.layer.shadowRadius = 2.0;
    _speedLabel.layer.shadowOpacity = 0.95;
    _speedLabel.alpha = 1.0;
    _speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_speedLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
    [_blurView.contentView addSubview:_speedLabel];

    _lockedView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
    _lockedView.tintColor = [UIColor whiteColor];
    _lockedView.translatesAutoresizingMaskIntoConstraints = NO;
    _lockedView.contentMode = UIViewContentModeScaleAspectFit;
    _lockedView.alpha = 0.0;
    [_lockedView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [_lockedView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [_blurView.contentView addSubview:_lockedView];

    _tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapGestureRecognized:)];
    _tapGestureRecognizer.numberOfTapsRequired = 1;
    _tapGestureRecognizer.numberOfTouchesRequired = 1;
    [_contentView addGestureRecognizer:_tapGestureRecognizer];

    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panGestureRecognized:)];
    _panGestureRecognizer.minimumNumberOfTouches = 1;
    _panGestureRecognizer.maximumNumberOfTouches = 1;
    [_contentView addGestureRecognizer:_panGestureRecognizer];

    [_contentView setUserInteractionEnabled:YES];

    _orientation = UIInterfaceOrientationLandscapeRight;
    CGRect initialBounds = orientationBounds(_orientation, [UIScreen mainScreen].bounds);
    [self.view setBounds:initialBounds];
    [self.view setTransform:CGAffineTransformMakeRotation(orientationAngle(_orientation))];
    [self.view setHidden:NO];

    [self reloadUserDefaults];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    notify_post(NOTIFY_LAUNCHED_HUD);

    UIInterfaceOrientation currentOrientation = (UIInterfaceOrientation)[_orientationObserver activeInterfaceOrientation];
    if (currentOrientation != UIInterfaceOrientationLandscapeLeft &&
        currentOrientation != UIInterfaceOrientationLandscapeRight)
    {
        currentOrientation = UIInterfaceOrientationLandscapeRight;
    }
    [self updateOrientation:currentOrientation animateWithDuration:0];
    [self.view setHidden:NO];
}

- (void)resetLoopTimer
{
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:UPDATE_INTERVAL target:self selector:@selector(updateSpeedLabel) userInfo:nil repeats:YES];
}

- (void)stopLoopTimer
{
    [_timer invalidate];
    _timer = nil;
}

- (void)viewSafeAreaInsetsDidChange
{
    [super viewSafeAreaInsetsDidChange];
    [self removeAllAnimations];
    [self resetGestureRecognizers];
    [self updateViewConstraints];
}

- (void)updateViewConstraints
{
    [NSLayoutConstraint deactivateConstraints:_constraints];
    [_constraints removeAllObjects];

    BOOL isLandscape = YES;

    HUDPresetPosition selectedMode = [self selectedModeForCurrentOrientation];
    BOOL isCentered = (selectedMode == HUDPresetPositionTopCenter || selectedMode == HUDPresetPositionTopCenterMost);
    BOOL isCenteredMost = (selectedMode == HUDPresetPositionTopCenterMost);
    BOOL isPad = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);

    [_speedLabel setTextAlignment:(isCentered ? NSTextAlignmentCenter : NSTextAlignmentLeft)];
    [_lockedView setImage:[UIImage systemImageNamed:(isCentered ? @"hand.raised.slash.fill" : @"lock.fill")]];
    [_blurView.layer setMaskedCorners:((isCenteredMost && !isLandscape) ? kCornerMaskBottom : kCornerMaskAll)];

    BOOL usesCustomOffset = [self usesCustomOffset];
    CGFloat realCustomOffsetX = 0;
    CGFloat realCustomOffsetY = 0;

    if (usesCustomOffset)
    {
        realCustomOffsetX = [self realCustomOffsetX] * (-1);
        realCustomOffsetY = [self realCustomOffsetY];
    }

    UILayoutGuide *layoutGuide = self.view.safeAreaLayoutGuide;
    if (isLandscape)
    {
        CGFloat notchHeight;
        CGFloat paddingNearNotch;
        CGFloat paddingFarFromNotch;

        notchHeight = CGRectGetMinY(layoutGuide.layoutFrame);
        paddingNearNotch = (notchHeight > 30) ? notchHeight - 16 : 4;
        paddingFarFromNotch = (notchHeight > 30) ? -24 : -4;

        paddingNearNotch += realCustomOffsetX;
        paddingFarFromNotch += realCustomOffsetX;

        [_constraints addObjectsFromArray:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:layoutGuide.leadingAnchor constant:(_orientation == UIInterfaceOrientationLandscapeLeft ? -paddingFarFromNotch : paddingNearNotch)],
            [_contentView.trailingAnchor constraintEqualToAnchor:layoutGuide.trailingAnchor constant:(_orientation == UIInterfaceOrientationLandscapeLeft ? -paddingNearNotch : paddingFarFromNotch)],
        ]];

        CGFloat minimumLandscapeTopConstant = 0;
        CGFloat minimumLandscapeBottomConstant = 0;

        minimumLandscapeTopConstant = (isPad ? 30 : 10);
        minimumLandscapeBottomConstant = (isPad ? -34 : -14);

        minimumLandscapeTopConstant += realCustomOffsetY;
        minimumLandscapeBottomConstant += realCustomOffsetY;

        /* Fixed Constraints */
        [_constraints addObjectsFromArray:@[
            [_contentView.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.topAnchor constant:minimumLandscapeTopConstant],
            [_contentView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:minimumLandscapeBottomConstant],
        ]];

        /* Flexible Constraint */
        _topConstraint = [_contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:minimumLandscapeTopConstant];
        if (!isCentered) {
            CGFloat currentPositionY = [self currentLandscapePositionY];
            if (currentPositionY < CGFLOAT_MAX) {
                _topConstraint.constant = currentPositionY;
            }
        }
        _topConstraint.priority = UILayoutPriorityDefaultLow;

        [_constraints addObject:_topConstraint];
    }
    else
    {
        [_constraints addObjectsFromArray:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:layoutGuide.leadingAnchor constant:realCustomOffsetX],
            [_contentView.trailingAnchor constraintEqualToAnchor:layoutGuide.trailingAnchor constant:realCustomOffsetX],
        ]];

        if (isCenteredMost && !isPad) {
            [_constraints addObject:[_contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0]];
        }
        else
        {
            CGFloat minimumTopConstraintConstant = 0;
            CGFloat minimumBottomConstraintConstant = 0;

            if (CGRectGetMinY(layoutGuide.layoutFrame) >= 51) {
                minimumTopConstraintConstant = -8;
                minimumBottomConstraintConstant = -4;
            }
            else if (CGRectGetMinY(layoutGuide.layoutFrame) > 30) {
                minimumTopConstraintConstant = -12;
                minimumBottomConstraintConstant = -4;
            } else {
                minimumTopConstraintConstant = (isPad ? 30 : 20);
                minimumBottomConstraintConstant = -20;
            }

            minimumTopConstraintConstant += realCustomOffsetY;
            minimumBottomConstraintConstant += realCustomOffsetY;

            /* Fixed Constraints */
            [_constraints addObjectsFromArray:@[
                [_contentView.topAnchor constraintGreaterThanOrEqualToAnchor:layoutGuide.topAnchor constant:minimumTopConstraintConstant],
                [_contentView.bottomAnchor constraintLessThanOrEqualToAnchor:layoutGuide.bottomAnchor constant:minimumBottomConstraintConstant],
            ]];

            /* Flexible Constraint */
            _topConstraint = [_contentView.topAnchor constraintEqualToAnchor:layoutGuide.topAnchor constant:minimumTopConstraintConstant];
            if (!isCentered) {
                CGFloat currentPositionY = [self currentPositionY];
                if (currentPositionY < CGFLOAT_MAX) {
                    _topConstraint.constant = currentPositionY;
                }
            }
            _topConstraint.priority = UILayoutPriorityDefaultLow;

            [_constraints addObject:_topConstraint];
        }
    }

    [_constraints addObjectsFromArray:@[
        [_speedLabel.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
        [_speedLabel.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor],
    ]];

    _centerXConstraint = [_speedLabel.centerXAnchor constraintEqualToAnchor:layoutGuide.centerXAnchor];
    if (isCentered) {
        [_constraints addObject:_centerXConstraint];
    }

    _leadingConstraint = [_speedLabel.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:10];
    if (selectedMode == HUDPresetPositionTopLeft) {
        [_constraints addObject:_leadingConstraint];
    }

    _trailingConstraint = [_speedLabel.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-10];
    if (selectedMode == HUDPresetPositionTopRight) {
        [_constraints addObject:_trailingConstraint];
    }

    [_constraints addObjectsFromArray:@[
        [_blurView.topAnchor constraintEqualToAnchor:_speedLabel.topAnchor],
        [_blurView.leadingAnchor constraintEqualToAnchor:_speedLabel.leadingAnchor],
        [_blurView.trailingAnchor constraintEqualToAnchor:_speedLabel.trailingAnchor],
        [_blurView.bottomAnchor constraintEqualToAnchor:_speedLabel.bottomAnchor],
    ]];

    [_constraints addObjectsFromArray:@[
        [_lockedView.topAnchor constraintGreaterThanOrEqualToAnchor:_blurView.topAnchor constant:2],
        [_lockedView.centerXAnchor constraintEqualToAnchor:_blurView.centerXAnchor],
        [_lockedView.centerYAnchor constraintEqualToAnchor:_blurView.centerYAnchor],
    ]];

    [NSLayoutConstraint activateConstraints:_constraints];
    [super updateViewConstraints];
}

- (void)keepFocus:(UIView *)view
{
    [self onFocus:view duration:0];
}

- (void)onFocus:(UIView *)view
{
    [self onFocus:view duration:0.2];
}

- (void)onFocus:(UIView *)view duration:(NSTimeInterval)duration
{
    [self onFocus:view scaleFactor:0.1 duration:duration beginFromInitialState:YES blurWhenDone:YES];
}

- (void)onFocus:(UIView *)view scaleFactor:(CGFloat)scaleFactor duration:(NSTimeInterval)duration beginFromInitialState:(BOOL)beginFromInitialState blurWhenDone:(BOOL)blurWhenDone
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onBlur:) object:view];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onFocus:) object:view];

    _isFocused = YES;
    [self updateSpeedLabel];
    [self resetLoopTimer];

    HUDPresetPosition selectedMode = [self selectedModeForCurrentOrientation];
    BOOL isCentered = (selectedMode == HUDPresetPositionTopCenter || selectedMode == HUDPresetPositionTopCenterMost);

    CGFloat topTrans = CGRectGetHeight(view.bounds) * (scaleFactor / 2);
    CGFloat leadingTrans = (isCentered ? 0 : (selectedMode == HUDPresetPositionTopLeft ? CGRectGetWidth(view.bounds) * (scaleFactor / 2) : -CGRectGetWidth(view.bounds) * (scaleFactor / 2)));

    if (beginFromInitialState)
        [view setTransform:CGAffineTransformIdentity];

    [UIView animateWithDuration:duration delay:0.0 usingSpringWithDamping:1.0 initialSpringVelocity:1.0 options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState animations:^{
        if (ABS(leadingTrans) > 1e-6 || ABS(topTrans) > 1e-6)
        {
            CGAffineTransform transform = CGAffineTransformMakeTranslation(leadingTrans, topTrans);
            view.transform = CGAffineTransformScale(transform, 1.0 + scaleFactor, 1.0 + scaleFactor);
        }

        view.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (blurWhenDone) {
            [self performSelector:@selector(onBlur:) withObject:view afterDelay:IDLE_INTERVAL];
        }
    }];
}

- (void)onBlur:(UIView *)view
{
    [self onBlur:view duration:0.6];
}

- (void)onBlur:(UIView *)view duration:(NSTimeInterval)duration
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onBlur:) object:view];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onFocus:) object:view];

    _isFocused = NO;
    [self updateSpeedLabel];
    [self resetLoopTimer];

    [UIView animateWithDuration:duration delay:0.0 usingSpringWithDamping:1.0 initialSpringVelocity:1.0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        view.transform = CGAffineTransformIdentity;
        view.alpha = HUD_INACTIVE_OPACITY;
    } completion:nil];
}

- (void)removeAllAnimations
{
    [_contentView.layer removeAllAnimations];
}

- (void)resetGestureRecognizers
{
    for (UIGestureRecognizer *recognizer in _contentView.gestureRecognizers)
    {
        [recognizer setEnabled:NO];
        [recognizer setEnabled:YES];
    }
}

- (void)tapGestureRecognized:(UITapGestureRecognizer *)sender
{
    log_info(OS_LOG_DEFAULT, "TAPPED");
    if (!_isFocused) {
        [self onFocus:sender.view];
    } else {
        [self keepFocus:sender.view];
    }
}

- (void)cancelPreviousPerformRequestsWithTarget:(UIView *)view
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onBlur:) object:view];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onFocus:) object:view];
}

- (void)flashLockedViewWithDuration:(NSTimeInterval)duration
{
    [_lockedView.layer removeAllAnimations];
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    animation.fromValue = [NSNumber numberWithFloat:0.0];
    animation.toValue = [NSNumber numberWithFloat:1.0];
    animation.duration = duration;
    animation.autoreverses = YES;
    animation.repeatCount = 1;
    animation.removedOnCompletion = YES;
    animation.fillMode = kCAFillModeForwards;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_lockedView.layer addAnimation:animation forKey:@"opacity"];

    [_speedLabel.layer removeAllAnimations];
    CABasicAnimation *animationReverse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    animationReverse.fromValue = [NSNumber numberWithFloat:1.0];
    animationReverse.toValue = [NSNumber numberWithFloat:0.0];
    animationReverse.duration = duration;
    animationReverse.autoreverses = YES;
    animationReverse.repeatCount = 1;
    animationReverse.removedOnCompletion = YES;
    animationReverse.fillMode = kCAFillModeForwards;
    animationReverse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_speedLabel.layer addAnimation:animationReverse forKey:@"opacity"];
}

- (void)panGestureRecognized:(UIPanGestureRecognizer *)sender
{
    if (!_isFocused)
        return;

    HUDPresetPosition selectedMode = [self selectedModeForCurrentOrientation];
    BOOL isCentered = (selectedMode == HUDPresetPositionTopCenter || selectedMode == HUDPresetPositionTopCenterMost);

    if (isCentered || [self keepInPlace])
    {
        if (sender.state == UIGestureRecognizerStateBegan)
            [self cancelPreviousPerformRequestsWithTarget:sender.view];
        else if (sender.state == UIGestureRecognizerStateFailed || sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled)
            [self performSelector:@selector(onBlur:) withObject:sender.view afterDelay:IDLE_INTERVAL];

        if (sender.state == UIGestureRecognizerStateBegan)
        {
            if (!_notificationFeedbackGenerator)
                _notificationFeedbackGenerator = [[UINotificationFeedbackGenerator alloc] init];

            [_notificationFeedbackGenerator prepare];
            [_notificationFeedbackGenerator notificationOccurred:UINotificationFeedbackTypeError];

            [self flashLockedViewWithDuration:0.2];
        }

        return;
    }

    static CGFloat beginConstantY = 0.0;
    if (sender.state == UIGestureRecognizerStatePossible || sender.state == UIGestureRecognizerStateBegan)
    {
        beginConstantY = _topConstraint.constant;
        [self onFocus:sender.view scaleFactor:0.2 duration:0.1 beginFromInitialState:NO blurWhenDone:NO];
    }
    else
    {
        if (sender.state == UIGestureRecognizerStateChanged || sender.state == UIGestureRecognizerStateEnded)
        {
            CGFloat currentOffsetY = [sender translationInView:sender.view.superview].y;
            [_topConstraint setConstant:beginConstantY + currentOffsetY];
        }

        if (sender.state == UIGestureRecognizerStateEnded)
        {
            if (UIInterfaceOrientationIsLandscape(_orientation))
                [self setCurrentLandscapePositionY:_topConstraint.constant];
            else
                [self setCurrentPositionY:_topConstraint.constant];
        }

        if (sender.state != UIGestureRecognizerStateChanged)
        {
            [self onFocus:sender.view scaleFactor:0.1 duration:0.1 beginFromInitialState:NO blurWhenDone:NO];
            [self reloadUserDefaults];
        }
    }

    if (!_impactFeedbackGenerator)
    {
        _impactFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }

    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled)
    {
        [_impactFeedbackGenerator prepare];
        [_impactFeedbackGenerator impactOccurred];
    }
}

@end

@implementation HUDRootViewController (Troll)

static inline CGFloat orientationAngle(UIInterfaceOrientation orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
        default:
            return M_PI_2;
    }
}

static inline CGRect orientationBounds(UIInterfaceOrientation orientation, CGRect bounds)
{
    CGFloat w = MAX(bounds.size.width, bounds.size.height);
    CGFloat h = MIN(bounds.size.width, bounds.size.height);
    return CGRectMake(0, 0, w, h);
}

- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration
{
    // HUD DarkPubg luôn luôn là kiểu ngang (Landscape) cho game.
    // Nếu thiết bị xoay sang LandscapeLeft thì xoay LandscapeLeft (-90°).
    // Nếu thiết bị xoay sang LandscapeRight (hoặc Portrait/khác) thì giữ LandscapeRight (+90°).
    UIInterfaceOrientation targetOrientation = orientation;
    if (targetOrientation != UIInterfaceOrientationLandscapeLeft &&
        targetOrientation != UIInterfaceOrientationLandscapeRight)
    {
        targetOrientation = UIInterfaceOrientationLandscapeRight;
    }

    if (targetOrientation == _orientation && !self.view.hidden) {
        return;
    }

    _orientation = targetOrientation;
    [self cancelPreviousPerformRequestsWithTarget:_contentView];

    CGRect bounds = orientationBounds(targetOrientation, [UIScreen mainScreen].bounds);
    [self.view setNeedsUpdateConstraints];
    [self.view setBounds:bounds];

    [self resetGestureRecognizers];
    [self onBlur:_contentView duration:duration];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:(duration > 0 ? duration : 0.2) animations:^{
        [weakSelf.view setTransform:CGAffineTransformMakeRotation(orientationAngle(targetOrientation))];
    } completion:^(BOOL finished) {
        [weakSelf.view setHidden:NO];
    }];
    [self.view setHidden:NO];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}

@end
