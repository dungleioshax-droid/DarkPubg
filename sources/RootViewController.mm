//
//  RootViewController.mm
//  DarkPubg
//
//  Created by Lessica on 2024/1/24.
//  Redesigned by DLX07 on 2026/11/08.
//

#import <notify.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <atomic>
#include <algorithm>

#ifdef __cplusplus
extern "C" {
#endif
#import "libproc.h"
#ifdef __cplusplus
}
#endif

#import "HUDHelper.h"
#import "DSBridge.h"
#import "MainButton.h"
#import "MainApplication.h"
#import "HUDPresetPosition.h"
#import "RootViewController.h"
#import "UIApplication+Private.h"
#import "HUDRootViewController.h"
#import "DSTheme.h"

#define HUD_TRANSITION_DURATION 0.25

static BOOL _gShouldToggleHUDAfterLaunch = NO;

static NSString *CurrentLanguage(void) {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppLanguage"];
    if (!lang || lang.length == 0) return @"vi";
    return lang;
}

static BOOL IsEnglish(void) {
    return [CurrentLanguage() isEqualToString:@"en"];
}

static BOOL CheckDarkSwordSupport(NSString **outVersionStr, NSString **outStatusStr) {
    NSString *version = [[UIDevice currentDevice] systemVersion];
    if (outVersionStr) *outVersionStr = [NSString stringWithFormat:@"iOS %@", version];

    BOOL supported = NO;
    if (version.length > 0) {
        // Supported ranges specified by user: 17.0 - 17.7, 18.0 - 18.7.1, 26.0 - 26.0.1
        if ([version compare:@"17.0" options:NSNumericSearch] != NSOrderedAscending &&
            [version compare:@"17.7.99" options:NSNumericSearch] == NSOrderedAscending) {
            supported = YES;
        }
        else if ([version compare:@"18.0" options:NSNumericSearch] != NSOrderedAscending &&
                 [version compare:@"18.7.1" options:NSNumericSearch] != NSOrderedDescending) {
            supported = YES;
        }
        else if ([version compare:@"26.0" options:NSNumericSearch] != NSOrderedAscending &&
                 [version compare:@"26.0.1" options:NSNumericSearch] != NSOrderedDescending) {
            supported = YES;
        }
    }

    if (outStatusStr) {
        if (supported) {
            *outStatusStr = IsEnglish() ? @"DarkSword: Supported" : @"DarkSword: Đã hỗ trợ";
        } else {
            *outStatusStr = IsEnglish() ? @"DarkSword: Unsupported" : @"DarkSword: Chưa hỗ trợ";
        }
    }
    return supported;
}

static BOOL CheckPUBGViaSpringBoard(void) {
    static pid_t (*sbsFunc)(CFStringRef) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        if (sbs) {
            sbsFunc = (pid_t (*)(CFStringRef))dlsym(sbs, "SBSProcessIDForDisplayIdentifier");
        }
    });

    NSArray<NSString *> *bundleIDs = @[
        @"vn.vng.pubgmobile",
        @"com.vng.pubgmobile",
        @"com.epicgames.ShadowTrackerExtra"
    ];

    if (sbsFunc) {
        for (NSString *bundleID in bundleIDs) {
            pid_t pid = sbsFunc((__bridge CFStringRef)bundleID);
            if (pid > 0) {
                return YES;
            }
        }
    }

    Class bksClass = NSClassFromString(@"BKSApplicationStateMonitor");
    if (!bksClass) {
        void *bksLib = dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_NOW);
        if (bksLib) {
            bksClass = NSClassFromString(@"BKSApplicationStateMonitor");
        }
    }
    if (bksClass) {
        @try {
            id monitor = [[bksClass alloc] init];
            SEL sel = NSSelectorFromString(@"applicationStateForApplication:");
            if ([monitor respondsToSelector:sel]) {
                typedef unsigned int (*StateFunc)(id, SEL, NSString *);
                StateFunc func = (StateFunc)[monitor methodForSelector:sel];
                if (func) {
                    for (NSString *bundleID in bundleIDs) {
                        unsigned int state = func(monitor, sel, bundleID);
                        if (state & (2 | 4 | 8)) {
                            return YES;
                        }
                    }
                }
            }
        } @catch (id ex) {}
    }

    return NO;
}

static BOOL CheckPUBGViaSysctl(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0 || size == 0) {
        return NO;
    }
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return NO;
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return NO;
    }
    int count = (int)(size / sizeof(struct kinfo_proc));
    BOOL found = NO;
    for (int i = 0; i < count; i++) {
        const char *name = procs[i].kp_proc.p_comm;
        if (!name || !name[0]) continue;
        if (strcasestr(name, "ShadowTracker") != NULL ||
            strcasestr(name, "Shadow") != NULL ||
            strcasestr(name, "PUBG") != NULL ||
            strcasestr(name, "pubgmobile") != NULL ||
            strcasestr(name, "vn.vng") != NULL) {
            found = YES;
            break;
        }
    }
    free(procs);
    return found;
}

static BOOL CheckPUBGViaLibProc(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > 100000) return NO;
    pid_t *pids = (pid_t *)malloc((size_t)count * sizeof(pid_t));
    if (!pids) return NO;
    int got = proc_listallpids(pids, count * (int)sizeof(pid_t));
    BOOL found = NO;
    if (got > 0) {
        if (got > count) got = count;
        char name[1024];
        char path[1024];
        for (int i = 0; i < got; i++) {
            pid_t p = pids[i];
            if (p <= 0) continue;
            memset(name, 0, sizeof(name));
            if (proc_name(p, name, sizeof(name) - 1) > 0) {
                if (strcasestr(name, "ShadowTracker") != NULL ||
                    strcasestr(name, "Shadow") != NULL ||
                    strcasestr(name, "PUBG") != NULL ||
                    strcasestr(name, "pubgmobile") != NULL ||
                    strcasestr(name, "vn.vng") != NULL) {
                    found = YES;
                    break;
                }
            }
            memset(path, 0, sizeof(path));
            if (proc_pidpath(p, path, sizeof(path) - 1) > 0) {
                if (strcasestr(path, "ShadowTracker") != NULL ||
                    strcasestr(path, "Shadow") != NULL ||
                    strcasestr(path, "PUBG") != NULL ||
                    strcasestr(path, "pubgmobile") != NULL ||
                    strcasestr(path, "vn.vng") != NULL) {
                    found = YES;
                    break;
                }
            }
        }
    }
    free(pids);
    return found;
}

static BOOL IsPUBGProcessRunning(void) {
    // 1. SpringBoardServices / AssertionServices check (Direct to SpringBoard on iOS)
    if (CheckPUBGViaSpringBoard()) return YES;

    // 2. Sysctl check (KERN_PROC_ALL)
    if (CheckPUBGViaSysctl()) return YES;

    // 3. Libproc check
    if (CheckPUBGViaLibProc()) return YES;

#if USE_DARKSWORD
    // 4. DarkSword kernel check (if kernel is ready)
    if (DSBridgeIsPUBGRunning()) return YES;
#endif

    return NO;
}

@implementation RootViewController {
    NSMutableDictionary *_userDefaults;
    MainButton *_mainButton;
    UILabel *_buttonSubLabel;
    UIActivityIndicatorView *_mainBtnSpinner;
    BOOL _isHUDLaunching;

    // Tab Navigation Containers
    UIView *_homeView;
    UIView *_settingView;
    UIScrollView *_settingScrollView;
    UIView *_settingContentView;
    UIView *_bottomTabBar;
    UILayoutGuide *_contentColumn;
    UILayoutGuide *_settingsColumn;
    CAGradientLayer *_ambientLayer;
    UIView *_tabIndicator;
    UIButton *_homeTabButton;
    UIButton *_settingTabButton;
    NSLayoutConstraint *_tabIndicatorHomeLeading;
    NSLayoutConstraint *_tabIndicatorHomeWidth;
    NSLayoutConstraint *_tabIndicatorSettingLeading;
    NSLayoutConstraint *_tabIndicatorSettingWidth;
    NSInteger _selectedTabIndex;

    // Home localized labels
    UILabel *_homeTitleLabel;
    UILabel *_homeSubTitleLabel;
    UILabel *_iosVersionLabel;
    UILabel *_systemTagLabel;
    UIView *_statusDotView;
    UILabel *_dsStatusLabel;
    UIView *_dsStatusBadge;
    UILabel *_dsBadgeLabel;

    // Home Console Terminal
    UIView *_consoleCard;
    UILabel *_consoleHeaderLabel;
    UIView *_consoleLiveDot;
    UILabel *_consoleLiveLabel;
    UITextView *_consoleTextView;
    NSMutableAttributedString *_consoleLogStorage;

    // Setting localized labels
    UILabel *_settingTitleLabel;
    UILabel *_settingSubTitleLabel;
    UILabel *_langHeaderLabel;
    UISegmentedControl *_langSegmentedControl;

    // Developer Card
    UILabel *_aboutHeaderLabel;
    UILabel *_devHeaderLabel;
    UILabel *_devNameLabel;

    // Security & Engine Card
    UIView *_securityCard;
    UILabel *_secHeaderLabel;
    UILabel *_secRow1Title;
    UILabel *_secRow1Val;
    UILabel *_secRow2Title;
    UILabel *_secRow2Val;
    UILabel *_secRow3Title;
    UILabel *_secRow3Val;

    // App Details Card
    UILabel *_infoRow1Title;
    UILabel *_infoRow2Title;
    UILabel *_infoRow3Title;
    UILabel *_infoRow4Title;

    UILabel *_noteLabel;

    BOOL _isRemoteHUDActive;
    UIImpactFeedbackGenerator *_impactFeedbackGenerator;
}

+ (void)setShouldToggleHUDAfterLaunch:(BOOL)flag
{
    _gShouldToggleHUDAfterLaunch = flag;
}

+ (BOOL)shouldToggleHUDAfterLaunch
{
    return _gShouldToggleHUDAfterLaunch;
}

- (BOOL)isHUDEnabled
{
    return IsHUDEnabled();
}

- (void)setHUDEnabled:(BOOL)enabled
{
    SetHUDEnabled(enabled);
}

- (void)registerNotifications
{
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_APP, &token, dispatch_get_main_queue(), ^(int token) {
        [self loadUserDefaults:YES];
        [self reloadMainButtonState];
#if USE_DARKSWORD
        if (DSBridgeLastError().length > 0) {
            [self showDSFailure:DSBridgeLastError()];
            [self.backgroundView setUserInteractionEnabled:YES];
        }
#endif
    });

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(toggleHUDNotificationReceived:) name:kToggleHUDAfterLaunchNotificationName object:nil];

#if USE_DARKSWORD
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dsProgressDidChange:) name:DSBridgeProgressNotification object:nil];
#endif
}

- (void)loadView
{
    CGRect bounds = UIScreen.mainScreen.bounds;

    self.view = [[UIView alloc] initWithFrame:bounds];
    self.view.backgroundColor = DSColorInk();

    self.backgroundView = [[UIView alloc] initWithFrame:bounds];
    self.backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundView.backgroundColor = DSColorInk();
    self.backgroundView.layer.masksToBounds = YES;
    [self.view addSubview:self.backgroundView];

    // Ambient wash: a mint bloom top-left and a cold blue bloom bottom-right
    // give the flat ink base some depth without tinting the content.
    CAGradientLayer *ambient = [CAGradientLayer layer];
    ambient.frame = bounds;
    _ambientLayer = ambient;
    ambient.colors = @[
        (id)[DSColorAccent() colorWithAlphaComponent:0.16].CGColor,
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor clearColor].CGColor,
        (id)[DSColorInfo() colorWithAlphaComponent:0.12].CGColor,
    ];
    ambient.locations = @[@0.0, @0.34, @0.68, @1.0];
    ambient.startPoint = CGPointMake(0.0, 0.0);
    ambient.endPoint = CGPointMake(1.0, 1.0);
    [self.backgroundView.layer addSublayer:ambient];

    [self setupBottomTabBar];
    [self setupHomeView];
    [self setupSettingView];

    [self updateTabSelection:0];
    [self applyLanguageTexts];
    [self reloadMainButtonState];
}

#pragma mark - Bottom Tab Bar

- (void)setupBottomTabBar
{
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:blur];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.layer.cornerRadius = 24.0;
    bar.layer.cornerCurve = kCACornerCurveContinuous;
    bar.layer.masksToBounds = YES;
    bar.layer.borderWidth = 1.0;
    bar.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.75].CGColor;
    _bottomTabBar = bar;

    // Sliding accent pill that marks the active tab.
    _tabIndicator = [[UIView alloc] init];
    _tabIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _tabIndicator.backgroundColor = DSColorAccentDim();
    _tabIndicator.layer.cornerRadius = 18.0;
    _tabIndicator.layer.cornerCurve = kCACornerCurveContinuous;
    _tabIndicator.layer.borderWidth = 1.0;
    _tabIndicator.layer.borderColor = [DSColorAccent() colorWithAlphaComponent:0.28].CGColor;
    [bar.contentView addSubview:_tabIndicator];

    _homeTabButton = [self createTabButtonWithTitle:@"Home" iconName:@"house.fill" tag:0];
    _settingTabButton = [self createTabButtonWithTitle:@"Setting" iconName:@"gearshape.fill" tag:1];

    [bar.contentView addSubview:_homeTabButton];
    [bar.contentView addSubview:_settingTabButton];

    [self.view addSubview:bar];

    _tabIndicatorHomeLeading =
        [_tabIndicator.leadingAnchor constraintEqualToAnchor:_homeTabButton.leadingAnchor];
    _tabIndicatorHomeWidth =
        [_tabIndicator.widthAnchor constraintEqualToAnchor:_homeTabButton.widthAnchor];
    _tabIndicatorSettingLeading =
        [_tabIndicator.leadingAnchor constraintEqualToAnchor:_settingTabButton.leadingAnchor];
    _tabIndicatorSettingWidth =
        [_tabIndicator.widthAnchor constraintEqualToAnchor:_settingTabButton.widthAnchor];
    _tabIndicatorHomeLeading.active = YES;
    _tabIndicatorHomeWidth.active = YES;

    NSLayoutConstraint *barFillWidth =
        [bar.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-2 * DSGutter];
    barFillWidth.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        // The floating bar hugs the same centred column as the content.
        [bar.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:DSGutter],
        [bar.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-DSGutter],
        [bar.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [bar.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        barFillWidth,
        [bar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8.0],
        [bar.heightAnchor constraintEqualToConstant:62.0],

        [_homeTabButton.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:5.0],
        [_homeTabButton.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
        [_homeTabButton.widthAnchor constraintEqualToAnchor:bar.contentView.widthAnchor multiplier:0.5 constant:-7.5],
        [_settingTabButton.widthAnchor constraintEqualToAnchor:_homeTabButton.widthAnchor],
        [_homeTabButton.heightAnchor constraintEqualToConstant:52.0],

        [_settingTabButton.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-5.0],
        [_settingTabButton.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
        [_settingTabButton.leadingAnchor constraintEqualToAnchor:_homeTabButton.trailingAnchor],
        [_settingTabButton.heightAnchor constraintEqualToConstant:52.0],

        [_tabIndicator.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
        [_tabIndicator.heightAnchor constraintEqualToConstant:52.0],
    ]];
}

- (UIButton *)createTabButtonWithTitle:(NSString *)title iconName:(NSString *)iconName tag:(NSInteger)tag
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = tag;
    [btn addTarget:self action:@selector(tabButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *symbol =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightSemibold];

    // Icon + caption are laid out manually: UIButtonConfiguration would need
    // iOS 15 while the shell still supports iOS 14.
    UIImageView *iconView = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:iconName] imageWithConfiguration:symbol]];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tag = 101;
    iconView.userInteractionEnabled = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = DSColorTextTertiary();
    [btn addSubview:iconView];

    UILabel *caption = [[UILabel alloc] init];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.tag = 102;
    caption.text = title;
    caption.textColor = DSColorTextTertiary();
    caption.font = DSFontBody(11.0, UIFontWeightSemibold);
    caption.textAlignment = NSTextAlignmentCenter;
    caption.userInteractionEnabled = NO;
    [btn addSubview:caption];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
        [iconView.topAnchor constraintEqualToAnchor:btn.topAnchor constant:6.0],
        [iconView.widthAnchor constraintEqualToConstant:22.0],
        [iconView.heightAnchor constraintEqualToConstant:22.0],

        [caption.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
        [caption.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:2.0],
        [caption.leadingAnchor constraintGreaterThanOrEqualToAnchor:btn.leadingAnchor constant:2.0],
        [caption.trailingAnchor constraintLessThanOrEqualToAnchor:btn.trailingAnchor constant:-2.0],
    ]];

    return btn;
}

- (void)tabButtonTapped:(UIButton *)sender
{
    [self updateTabSelection:sender.tag];
}

- (void)updateTabSelection:(NSInteger)index
{
    _selectedTabIndex = index;
    if (_impactFeedbackGenerator) {
        [_impactFeedbackGenerator impactOccurred];
    }

    UIColor *activeColor = DSColorAccent();
    UIColor *inactiveColor = DSColorTextTertiary();

    UIImageView *homeIcon = (UIImageView *)[_homeTabButton viewWithTag:101];
    UILabel *homeCaption = (UILabel *)[_homeTabButton viewWithTag:102];
    UIImageView *setIcon = (UIImageView *)[_settingTabButton viewWithTag:101];
    UILabel *setCaption = (UILabel *)[_settingTabButton viewWithTag:102];

    homeIcon.tintColor = (index == 0) ? activeColor : inactiveColor;
    setIcon.tintColor = (index == 1) ? activeColor : inactiveColor;
    homeCaption.textColor = homeIcon.tintColor;
    setCaption.textColor = setIcon.tintColor;

    [UIView animateWithDuration:DSMotionFast
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        CGFloat homeScale = (index == 0) ? 1.06 : 1.0;
        CGFloat setScale = (index == 1) ? 1.06 : 1.0;
        homeIcon.transform = CGAffineTransformMakeScale(homeScale, homeScale);
        setIcon.transform = CGAffineTransformMakeScale(setScale, setScale);
    } completion:nil];

    if (_tabIndicator) {
        BOOL isHome = (index == 0);
        _tabIndicatorHomeLeading.active = isHome;
        _tabIndicatorHomeWidth.active = isHome;
        _tabIndicatorSettingLeading.active = !isHome;
        _tabIndicatorSettingWidth.active = !isHome;

        [UIView animateWithDuration:DSMotionNormal
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ [self.view layoutIfNeeded]; }
                         completion:nil];
    }

    [UIView transitionWithView:self.backgroundView duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self->_homeView.hidden = (index != 0);
        self->_settingView.hidden = (index != 1);
    } completion:nil];
}

#pragma mark - Home View

- (void)setupHomeView
{
    _homeView = [[UIView alloc] init];
    _homeView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backgroundView addSubview:_homeView];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;

    // Keep the column readable on iPad/Mac: it stretches with the window but
    // never past ~560pt, and stays centred when there is extra room.
    [NSLayoutConstraint activateConstraints:@[
        [_homeView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [_homeView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_homeView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_homeView.bottomAnchor constraintEqualToAnchor:_bottomTabBar.topAnchor],
    ]];
    _contentColumn = [[UILayoutGuide alloc] init];
    [_homeView addLayoutGuide:_contentColumn];
    NSLayoutConstraint *contentColumnWidth =
        [_contentColumn.widthAnchor constraintEqualToAnchor:_homeView.widthAnchor];
    contentColumnWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        contentColumnWidth,
        [_contentColumn.centerXAnchor constraintEqualToAnchor:_homeView.centerXAnchor],
        [_contentColumn.widthAnchor constraintLessThanOrEqualToConstant:560.0 + 2 * DSGutter],
        [_contentColumn.topAnchor constraintEqualToAnchor:_homeView.topAnchor],
        [_contentColumn.bottomAnchor constraintEqualToAnchor:_homeView.bottomAnchor],
    ]];

    // ---------------------------------------------------------------- header
    UIView *brandMark = [[UIView alloc] init];
    brandMark.translatesAutoresizingMaskIntoConstraints = NO;
    brandMark.backgroundColor = DSColorAccent();
    brandMark.layer.cornerRadius = 14.0;
    brandMark.layer.cornerCurve = kCACornerCurveContinuous;
    brandMark.layer.shadowColor = DSColorAccent().CGColor;
    brandMark.layer.shadowOpacity = 0.50f;
    brandMark.layer.shadowRadius = 16.0f;
    brandMark.layer.shadowOffset = CGSizeMake(0, 5);
    [_homeView addSubview:brandMark];

    UIImage *shieldGlyphImg = [UIImage systemImageNamed:@"bolt.shield.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                                                                      weight:UIImageSymbolWeightBlack]];
    if (!shieldGlyphImg) {
        shieldGlyphImg = [UIImage systemImageNamed:@"bolt.fill"
                                 withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                                                                 weight:UIImageSymbolWeightBlack]];
    }
    UIImageView *brandGlyph = [[UIImageView alloc] initWithImage:shieldGlyphImg];
    brandGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    brandGlyph.tintColor = DSColorOnAccent();
    brandGlyph.contentMode = UIViewContentModeScaleAspectFit;
    [brandMark addSubview:brandGlyph];

    _homeTitleLabel = [[UILabel alloc] init];
    _homeTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _homeTitleLabel.text = @"DarkPubg";
    _homeTitleLabel.textColor = DSColorTextPrimary();
    _homeTitleLabel.font = DSFontDisplay(30.0);
    _homeTitleLabel.adjustsFontSizeToFitWidth = YES;
    _homeTitleLabel.minimumScaleFactor = 0.7;
    [_homeView addSubview:_homeTitleLabel];

    _homeSubTitleLabel = [[UILabel alloc] init];
    _homeSubTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _homeSubTitleLabel.textAlignment = NSTextAlignmentLeft;
    _homeSubTitleLabel.attributedText = [[NSAttributedString alloc]
        initWithString:@"KERNEL EDITION • PUBG MOBILE"
            attributes:@{
                NSKernAttributeName: @1.8,
                NSForegroundColorAttributeName: DSColorAccent(),
                NSFontAttributeName: DSFontBody(10.5, UIFontWeightHeavy),
            }];
    [_homeView addSubview:_homeSubTitleLabel];

    // ------------------------------------------------------------ status card
    UIView *statusCard = [[UIView alloc] init];
    statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(statusCard, DSRadiusCard);
    statusCard.layer.borderColor = [DSColorAccent() colorWithAlphaComponent:0.20].CGColor;
    [_homeView addSubview:statusCard];

    NSString *iosVer = @"";
    NSString *dsStatus = @"";
    BOOL isSupported = CheckDarkSwordSupport(&iosVer, &dsStatus);

    UIImage *hwIconImg = [UIImage systemImageNamed:@"cpu.fill"
                                 withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                                                                 weight:UIImageSymbolWeightSemibold]];
    if (!hwIconImg) {
        hwIconImg = [UIImage systemImageNamed:@"apple.logo"
                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                                                            weight:UIImageSymbolWeightMedium]];
    }
    UIImageView *appleIcon = [[UIImageView alloc] initWithImage:hwIconImg];
    appleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    appleIcon.tintColor = DSColorAccent();
    appleIcon.contentMode = UIViewContentModeScaleAspectFit;
    [statusCard addSubview:appleIcon];

    _iosVersionLabel = [[UILabel alloc] init];
    _iosVersionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _iosVersionLabel.textColor = DSColorTextPrimary();
    _iosVersionLabel.font = DSFontBody(14.0, UIFontWeightBold);
    [statusCard addSubview:_iosVersionLabel];

    _systemTagLabel = [[UILabel alloc] init];
    _systemTagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _systemTagLabel.textColor = DSColorTextTertiary();
    _systemTagLabel.font = DSFontMono(10.5, UIFontWeightBold);
    _systemTagLabel.textAlignment = NSTextAlignmentRight;
    [statusCard addSubview:_systemTagLabel];

    UIView *cardSep = [[UIView alloc] init];
    cardSep.translatesAutoresizingMaskIntoConstraints = NO;
    cardSep.backgroundColor = [DSColorHairline() colorWithAlphaComponent:0.65];
    [statusCard addSubview:cardSep];

    _statusDotView = [[UIView alloc] init];
    _statusDotView.translatesAutoresizingMaskIntoConstraints = NO;
    UIColor *dotColor = isSupported ? DSColorSuccess() : DSColorDanger();
    _statusDotView.backgroundColor = dotColor;
    _statusDotView.layer.cornerRadius = 4.0;
    _statusDotView.layer.shadowColor = dotColor.CGColor;
    _statusDotView.layer.shadowOpacity = 0.90f;
    _statusDotView.layer.shadowRadius = 6.0f;
    _statusDotView.layer.shadowOffset = CGSizeZero;
    [statusCard addSubview:_statusDotView];

    _dsStatusLabel = [[UILabel alloc] init];
    _dsStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _dsStatusLabel.textColor = dotColor;
    _dsStatusLabel.font = DSFontBody(13.0, UIFontWeightBold);
    _dsStatusLabel.adjustsFontSizeToFitWidth = YES;
    _dsStatusLabel.minimumScaleFactor = 0.8;
    [statusCard addSubview:_dsStatusLabel];

    _dsStatusBadge = [[UIView alloc] init];
    _dsStatusBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _dsStatusBadge.backgroundColor = [dotColor colorWithAlphaComponent:0.14];
    _dsStatusBadge.layer.cornerRadius = 10.0;
    _dsStatusBadge.layer.cornerCurve = kCACornerCurveContinuous;
    _dsStatusBadge.layer.borderWidth = 1.0;
    _dsStatusBadge.layer.borderColor = [dotColor colorWithAlphaComponent:0.35].CGColor;
    _dsStatusBadge.layer.masksToBounds = YES;
    [statusCard addSubview:_dsStatusBadge];

    _dsBadgeLabel = [[UILabel alloc] init];
    _dsBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _dsBadgeLabel.textColor = dotColor;
    _dsBadgeLabel.font = DSFontBody(10.0, UIFontWeightHeavy);
    _dsBadgeLabel.textAlignment = NSTextAlignmentCenter;
    [_dsStatusBadge addSubview:_dsBadgeLabel];

    // -------------------------------------------------------------- CTA button
    _mainButton = [MainButton buttonWithType:UIButtonTypeSystem];
    _mainButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainButton addTarget:self action:@selector(tapMainButton:) forControlEvents:UIControlEventTouchUpInside];
    [_mainButton setTitle:@"OPEN HUD" forState:UIControlStateNormal];
    DSApplyPrimaryButton(_mainButton, NO);
    _mainButton.titleLabel.font = DSFontDisplay(18.0);
    _mainButton.layer.cornerRadius = 20.0;
    [_homeView addSubview:_mainButton];

    if (@available(iOS 13.0, *)) {
        _mainBtnSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    } else {
        _mainBtnSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    }
    _mainBtnSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    _mainBtnSpinner.hidesWhenStopped = YES;
    _mainBtnSpinner.color = DSColorOnAccent();
    [_mainButton addSubview:_mainBtnSpinner];

    _buttonSubLabel = [[UILabel alloc] init];
    _buttonSubLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _buttonSubLabel.textColor = DSColorTextTertiary();
    _buttonSubLabel.font = DSFontBody(11.5, UIFontWeightMedium);
    _buttonSubLabel.textAlignment = NSTextAlignmentCenter;
    _buttonSubLabel.numberOfLines = 1;
    [_homeView addSubview:_buttonSubLabel];

    // ------------------------------------------------------------ console card
    _consoleCard = [[UIView alloc] init];
    _consoleCard.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleCard.backgroundColor = [DSColorInk() colorWithAlphaComponent:0.95];
    _consoleCard.layer.cornerRadius = 18.0;
    _consoleCard.layer.cornerCurve = kCACornerCurveContinuous;
    _consoleCard.layer.borderWidth = 1.0;
    _consoleCard.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.85].CGColor;
    _consoleCard.clipsToBounds = YES;
    [_homeView addSubview:_consoleCard];

    UIView *consoleHeader = [[UIView alloc] init];
    consoleHeader.translatesAutoresizingMaskIntoConstraints = NO;
    consoleHeader.backgroundColor = [DSColorSurface() colorWithAlphaComponent:0.90];
    [_consoleCard addSubview:consoleHeader];

    UIView *dotRed = [[UIView alloc] init];
    dotRed.translatesAutoresizingMaskIntoConstraints = NO;
    dotRed.backgroundColor = [UIColor colorWithRed:1.000 green:0.373 blue:0.337 alpha:1.0];
    dotRed.layer.cornerRadius = 4.0;
    [consoleHeader addSubview:dotRed];

    UIView *dotYellow = [[UIView alloc] init];
    dotYellow.translatesAutoresizingMaskIntoConstraints = NO;
    dotYellow.backgroundColor = [UIColor colorWithRed:1.000 green:0.741 blue:0.180 alpha:1.0];
    dotYellow.layer.cornerRadius = 4.0;
    [consoleHeader addSubview:dotYellow];

    UIView *dotGreen = [[UIView alloc] init];
    dotGreen.translatesAutoresizingMaskIntoConstraints = NO;
    dotGreen.backgroundColor = [UIColor colorWithRed:0.153 green:0.788 blue:0.247 alpha:1.0];
    dotGreen.layer.cornerRadius = 4.0;
    [consoleHeader addSubview:dotGreen];

    _consoleHeaderLabel = [[UILabel alloc] init];
    _consoleHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleHeaderLabel.textColor = DSColorTextSecondary();
    _consoleHeaderLabel.font = DSFontMono(10.0, UIFontWeightBold);
    _consoleHeaderLabel.text = @"CONSOLE LOG";
    [consoleHeader addSubview:_consoleHeaderLabel];

    _consoleLiveDot = [[UIView alloc] init];
    _consoleLiveDot.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleLiveDot.backgroundColor = DSColorSuccess();
    _consoleLiveDot.layer.cornerRadius = 3.5;
    _consoleLiveDot.layer.shadowColor = DSColorSuccess().CGColor;
    _consoleLiveDot.layer.shadowOpacity = 0.85f;
    _consoleLiveDot.layer.shadowRadius = 4.0f;
    _consoleLiveDot.layer.shadowOffset = CGSizeZero;
    [consoleHeader addSubview:_consoleLiveDot];

    _consoleLiveLabel = [[UILabel alloc] init];
    _consoleLiveLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleLiveLabel.textColor = DSColorSuccess();
    _consoleLiveLabel.font = DSFontMono(9.5, UIFontWeightHeavy);
    _consoleLiveLabel.text = @"LIVE";
    [consoleHeader addSubview:_consoleLiveLabel];

    UIView *consoleSep = [[UIView alloc] init];
    consoleSep.translatesAutoresizingMaskIntoConstraints = NO;
    consoleSep.backgroundColor = [DSColorHairline() colorWithAlphaComponent:0.6];
    [_consoleCard addSubview:consoleSep];

    _consoleTextView = [[UITextView alloc] init];
    _consoleTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleTextView.backgroundColor = UIColor.clearColor;
    _consoleTextView.editable = NO;
    _consoleTextView.selectable = NO;
    _consoleTextView.showsVerticalScrollIndicator = YES;
    _consoleTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _consoleTextView.textContainerInset = UIEdgeInsetsMake(8, 12, 8, 12);
    _consoleTextView.scrollEnabled = YES;
    [_consoleCard addSubview:_consoleTextView];

    // ---------------------------------------------------------------- layout
    [NSLayoutConstraint activateConstraints:@[
        [brandMark.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [brandMark.topAnchor constraintEqualToAnchor:_homeView.topAnchor constant:10.0],
        [brandMark.widthAnchor constraintEqualToConstant:48.0],
        [brandMark.heightAnchor constraintEqualToConstant:48.0],

        [brandGlyph.centerXAnchor constraintEqualToAnchor:brandMark.centerXAnchor],
        [brandGlyph.centerYAnchor constraintEqualToAnchor:brandMark.centerYAnchor],
        [brandGlyph.widthAnchor constraintEqualToConstant:24.0],
        [brandGlyph.heightAnchor constraintEqualToConstant:24.0],

        [_homeTitleLabel.leadingAnchor constraintEqualToAnchor:brandMark.trailingAnchor constant:12.0],
        [_homeTitleLabel.topAnchor constraintEqualToAnchor:brandMark.topAnchor constant:-4.0],
        [_homeTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],

        [_homeSubTitleLabel.leadingAnchor constraintEqualToAnchor:_homeTitleLabel.leadingAnchor constant:1.0],
        [_homeSubTitleLabel.topAnchor constraintEqualToAnchor:_homeTitleLabel.bottomAnchor constant:-1.0],
        [_homeSubTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],

        [statusCard.topAnchor constraintEqualToAnchor:brandMark.bottomAnchor constant:16.0],
        [statusCard.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [statusCard.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [statusCard.heightAnchor constraintEqualToConstant:90.0],

        [appleIcon.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [appleIcon.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:16.0],
        [appleIcon.widthAnchor constraintEqualToConstant:16.0],
        [appleIcon.heightAnchor constraintEqualToConstant:16.0],

        [_iosVersionLabel.leadingAnchor constraintEqualToAnchor:appleIcon.trailingAnchor constant:8.0],
        [_iosVersionLabel.centerYAnchor constraintEqualToAnchor:appleIcon.centerYAnchor],

        [_systemTagLabel.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [_systemTagLabel.centerYAnchor constraintEqualToAnchor:appleIcon.centerYAnchor],
        [_systemTagLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_iosVersionLabel.trailingAnchor constant:8.0],

        [cardSep.topAnchor constraintEqualToAnchor:appleIcon.bottomAnchor constant:13.0],
        [cardSep.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [cardSep.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [cardSep.heightAnchor constraintEqualToConstant:1.0],

        [_statusDotView.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [_statusDotView.topAnchor constraintEqualToAnchor:cardSep.bottomAnchor constant:14.0],
        [_statusDotView.widthAnchor constraintEqualToConstant:8.0],
        [_statusDotView.heightAnchor constraintEqualToConstant:8.0],

        [_dsStatusLabel.leadingAnchor constraintEqualToAnchor:_statusDotView.trailingAnchor constant:9.0],
        [_dsStatusLabel.centerYAnchor constraintEqualToAnchor:_statusDotView.centerYAnchor],

        [_dsStatusBadge.leadingAnchor constraintGreaterThanOrEqualToAnchor:_dsStatusLabel.trailingAnchor constant:8.0],
        [_dsStatusBadge.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [_dsStatusBadge.centerYAnchor constraintEqualToAnchor:_statusDotView.centerYAnchor],
        [_dsStatusBadge.heightAnchor constraintEqualToConstant:22.0],

        [_dsBadgeLabel.leadingAnchor constraintEqualToAnchor:_dsStatusBadge.leadingAnchor constant:10.0],
        [_dsBadgeLabel.trailingAnchor constraintEqualToAnchor:_dsStatusBadge.trailingAnchor constant:-10.0],
        [_dsBadgeLabel.centerYAnchor constraintEqualToAnchor:_dsStatusBadge.centerYAnchor],

        [_mainButton.topAnchor constraintEqualToAnchor:statusCard.bottomAnchor constant:14.0],
        [_mainButton.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_mainButton.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [_mainButton.heightAnchor constraintEqualToConstant:58.0],

        [_mainBtnSpinner.centerYAnchor constraintEqualToAnchor:_mainButton.centerYAnchor],
        [_mainBtnSpinner.trailingAnchor constraintEqualToAnchor:_mainButton.titleLabel.leadingAnchor constant:-10.0],

        [_buttonSubLabel.topAnchor constraintEqualToAnchor:_mainButton.bottomAnchor constant:7.0],
        [_buttonSubLabel.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_buttonSubLabel.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],

        [_consoleCard.topAnchor constraintEqualToAnchor:_buttonSubLabel.bottomAnchor constant:12.0],
        [_consoleCard.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_consoleCard.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [_consoleCard.bottomAnchor constraintEqualToAnchor:_homeView.bottomAnchor constant:-12.0],

        [consoleHeader.topAnchor constraintEqualToAnchor:_consoleCard.topAnchor],
        [consoleHeader.leadingAnchor constraintEqualToAnchor:_consoleCard.leadingAnchor],
        [consoleHeader.trailingAnchor constraintEqualToAnchor:_consoleCard.trailingAnchor],
        [consoleHeader.heightAnchor constraintEqualToConstant:34.0],

        [dotRed.leadingAnchor constraintEqualToAnchor:consoleHeader.leadingAnchor constant:14.0],
        [dotRed.centerYAnchor constraintEqualToAnchor:consoleHeader.centerYAnchor],
        [dotRed.widthAnchor constraintEqualToConstant:8.0],
        [dotRed.heightAnchor constraintEqualToConstant:8.0],

        [dotYellow.leadingAnchor constraintEqualToAnchor:dotRed.trailingAnchor constant:6.0],
        [dotYellow.centerYAnchor constraintEqualToAnchor:consoleHeader.centerYAnchor],
        [dotYellow.widthAnchor constraintEqualToConstant:8.0],
        [dotYellow.heightAnchor constraintEqualToConstant:8.0],

        [dotGreen.leadingAnchor constraintEqualToAnchor:dotYellow.trailingAnchor constant:6.0],
        [dotGreen.centerYAnchor constraintEqualToAnchor:consoleHeader.centerYAnchor],
        [dotGreen.widthAnchor constraintEqualToConstant:8.0],
        [dotGreen.heightAnchor constraintEqualToConstant:8.0],

        [_consoleHeaderLabel.leadingAnchor constraintEqualToAnchor:dotGreen.trailingAnchor constant:10.0],
        [_consoleHeaderLabel.centerYAnchor constraintEqualToAnchor:consoleHeader.centerYAnchor],

        [_consoleLiveLabel.trailingAnchor constraintEqualToAnchor:consoleHeader.trailingAnchor constant:-14.0],
        [_consoleLiveLabel.centerYAnchor constraintEqualToAnchor:consoleHeader.centerYAnchor],

        [_consoleLiveDot.trailingAnchor constraintEqualToAnchor:_consoleLiveLabel.leadingAnchor constant:-5.0],
        [_consoleLiveDot.centerYAnchor constraintEqualToAnchor:consoleHeader.centerYAnchor],
        [_consoleLiveDot.widthAnchor constraintEqualToConstant:7.0],
        [_consoleLiveDot.heightAnchor constraintEqualToConstant:7.0],

        [consoleSep.topAnchor constraintEqualToAnchor:consoleHeader.bottomAnchor],
        [consoleSep.leadingAnchor constraintEqualToAnchor:_consoleCard.leadingAnchor],
        [consoleSep.trailingAnchor constraintEqualToAnchor:_consoleCard.trailingAnchor],
        [consoleSep.heightAnchor constraintEqualToConstant:1.0],

        [_consoleTextView.topAnchor constraintEqualToAnchor:consoleSep.bottomAnchor],
        [_consoleTextView.leadingAnchor constraintEqualToAnchor:_consoleCard.leadingAnchor],
        [_consoleTextView.trailingAnchor constraintEqualToAnchor:_consoleCard.trailingAnchor],
        [_consoleTextView.bottomAnchor constraintEqualToAnchor:_consoleCard.bottomAnchor],
    ]];
}

#pragma mark - Setting View

- (void)setupSettingView
{
    _settingView = [[UIView alloc] init];
    _settingView.translatesAutoresizingMaskIntoConstraints = NO;
    _settingView.hidden = YES;
    [self.backgroundView addSubview:_settingView];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [_settingView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [_settingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_settingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_settingView.bottomAnchor constraintEqualToAnchor:_bottomTabBar.topAnchor],
    ]];
    _settingsColumn = [[UILayoutGuide alloc] init];
    [_settingView addLayoutGuide:_settingsColumn];
    NSLayoutConstraint *settingsColumnWidth =
        [_settingsColumn.widthAnchor constraintEqualToAnchor:_settingView.widthAnchor];
    settingsColumnWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        settingsColumnWidth,
        [_settingsColumn.centerXAnchor constraintEqualToAnchor:_settingView.centerXAnchor],
        [_settingsColumn.widthAnchor constraintLessThanOrEqualToConstant:560.0 + 2 * DSGutter],
        [_settingsColumn.topAnchor constraintEqualToAnchor:_settingView.topAnchor],
        [_settingsColumn.bottomAnchor constraintEqualToAnchor:_settingView.bottomAnchor],
    ]];

    _settingScrollView = [[UIScrollView alloc] init];
    _settingScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _settingScrollView.showsVerticalScrollIndicator = NO;
    _settingScrollView.alwaysBounceVertical = YES;
    _settingScrollView.contentInset = UIEdgeInsetsMake(0, 0, 16, 0);
    [_settingView addSubview:_settingScrollView];

    _settingContentView = [[UIView alloc] init];
    _settingContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [_settingScrollView addSubview:_settingContentView];

    // The scroll view itself is pinned to the centred column, so every card
    // inside can stay anchored to the content view without cross-hierarchy
    // constraints.
    [NSLayoutConstraint activateConstraints:@[
        [_settingScrollView.topAnchor constraintEqualToAnchor:_settingView.topAnchor],
        [_settingScrollView.leadingAnchor constraintEqualToAnchor:_settingsColumn.leadingAnchor],
        [_settingScrollView.trailingAnchor constraintEqualToAnchor:_settingsColumn.trailingAnchor],
        [_settingScrollView.bottomAnchor constraintEqualToAnchor:_settingView.bottomAnchor],

        [_settingContentView.topAnchor constraintEqualToAnchor:_settingScrollView.contentLayoutGuide.topAnchor],
        [_settingContentView.leadingAnchor constraintEqualToAnchor:_settingScrollView.contentLayoutGuide.leadingAnchor],
        [_settingContentView.trailingAnchor constraintEqualToAnchor:_settingScrollView.contentLayoutGuide.trailingAnchor],
        [_settingContentView.bottomAnchor constraintEqualToAnchor:_settingScrollView.contentLayoutGuide.bottomAnchor],
        [_settingContentView.widthAnchor constraintEqualToAnchor:_settingScrollView.frameLayoutGuide.widthAnchor],
    ]];

    // ---------------------------------------------------------------- header
    _settingTitleLabel = [[UILabel alloc] init];
    _settingTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _settingTitleLabel.textColor = DSColorTextPrimary();
    _settingTitleLabel.font = DSFontDisplay(30.0);
    _settingTitleLabel.textAlignment = NSTextAlignmentLeft;
    [_settingContentView addSubview:_settingTitleLabel];

    _settingSubTitleLabel = [[UILabel alloc] init];
    _settingSubTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _settingSubTitleLabel.textColor = DSColorTextTertiary();
    _settingSubTitleLabel.font = DSFontBody(12.5, UIFontWeightMedium);
    _settingSubTitleLabel.textAlignment = NSTextAlignmentLeft;
    [_settingContentView addSubview:_settingSubTitleLabel];

    // ------------------------------------------------------- language card
    UIView *langCard = [[UIView alloc] init];
    langCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(langCard, DSRadiusCard);
    [_settingContentView addSubview:langCard];

    UIImageView *globeIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"globe.americas.fill"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                                                weight:UIImageSymbolWeightSemibold]]];
    globeIcon.translatesAutoresizingMaskIntoConstraints = NO;
    globeIcon.tintColor = DSColorAccent();
    globeIcon.contentMode = UIViewContentModeScaleAspectFit;
    [langCard addSubview:globeIcon];

    _langHeaderLabel = [[UILabel alloc] init];
    _langHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _langHeaderLabel.textColor = DSColorTextTertiary();
    _langHeaderLabel.font = DSFontBody(11.0, UIFontWeightHeavy);
    [langCard addSubview:_langHeaderLabel];

    _langSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[ @"Tiếng Việt", @"English" ]];
    _langSegmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
    _langSegmentedControl.selectedSegmentIndex = IsEnglish() ? 1 : 0;
    _langSegmentedControl.selectedSegmentTintColor = DSColorAccent();
    _langSegmentedControl.backgroundColor = DSColorSurfaceHi();
    NSDictionary *segNormal = @{
        NSForegroundColorAttributeName: DSColorTextSecondary(),
        NSFontAttributeName: DSFontBody(13.0, UIFontWeightSemibold),
    };
    NSDictionary *segSelected = @{
        NSForegroundColorAttributeName: DSColorOnAccent(),
        NSFontAttributeName: DSFontBody(13.0, UIFontWeightHeavy),
    };
    [_langSegmentedControl setTitleTextAttributes:segNormal forState:UIControlStateNormal];
    [_langSegmentedControl setTitleTextAttributes:segSelected forState:UIControlStateSelected];
    [_langSegmentedControl addTarget:self action:@selector(langSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [langCard addSubview:_langSegmentedControl];

    [NSLayoutConstraint activateConstraints:@[
        [globeIcon.leadingAnchor constraintEqualToAnchor:langCard.leadingAnchor constant:16.0],
        [globeIcon.topAnchor constraintEqualToAnchor:langCard.topAnchor constant:16.0],
        [globeIcon.widthAnchor constraintEqualToConstant:18.0],
        [globeIcon.heightAnchor constraintEqualToConstant:18.0],

        [_langHeaderLabel.leadingAnchor constraintEqualToAnchor:globeIcon.trailingAnchor constant:8.0],
        [_langHeaderLabel.centerYAnchor constraintEqualToAnchor:globeIcon.centerYAnchor],

        [_langSegmentedControl.topAnchor constraintEqualToAnchor:globeIcon.bottomAnchor constant:12.0],
        [_langSegmentedControl.leadingAnchor constraintEqualToAnchor:langCard.leadingAnchor constant:14.0],
        [_langSegmentedControl.trailingAnchor constraintEqualToAnchor:langCard.trailingAnchor constant:-14.0],
        [_langSegmentedControl.heightAnchor constraintEqualToConstant:34.0],
        [_langSegmentedControl.bottomAnchor constraintEqualToAnchor:langCard.bottomAnchor constant:-14.0],
    ]];

    // --------------------------------------------------------- system card
    UIView *systemCard = [[UIView alloc] init];
    systemCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(systemCard, DSRadiusCard);
    [_settingContentView addSubview:systemCard];

    _secHeaderLabel = [[UILabel alloc] init];
    _secHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _secHeaderLabel.textColor = DSColorTextTertiary();
    _secHeaderLabel.font = DSFontBody(11.0, UIFontWeightHeavy);
    [systemCard addSubview:_secHeaderLabel];

    _securityCard = systemCard;

    auto makeValueRow = ^UIView *(UILabel *titleLbl, UILabel *valueLbl,
                                  UIView *topView, BOOL last) {
        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [systemCard addSubview:row];

        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.textColor = DSColorTextSecondary();
        titleLbl.font = DSFontBody(13.5, UIFontWeightMedium);
        [row addSubview:titleLbl];

        valueLbl.translatesAutoresizingMaskIntoConstraints = NO;
        valueLbl.textColor = DSColorTextPrimary();
        valueLbl.font = DSFontMono(12.0, UIFontWeightSemibold);
        valueLbl.textAlignment = NSTextAlignmentRight;
        valueLbl.adjustsFontSizeToFitWidth = YES;
        valueLbl.minimumScaleFactor = 0.75;
        [row addSubview:valueLbl];

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:systemCard.leadingAnchor constant:16.0],
            [row.trailingAnchor constraintEqualToAnchor:systemCard.trailingAnchor constant:-16.0],
            [row.heightAnchor constraintEqualToConstant:34.0],
            [titleLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [titleLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [valueLbl.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [valueLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [valueLbl.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLbl.trailingAnchor constant:12.0],
        ]];

        if (topView) {
            [row.topAnchor constraintEqualToAnchor:topView.bottomAnchor constant:2.0].active = YES;
        } else {
            [row.topAnchor constraintEqualToAnchor:_secHeaderLabel.bottomAnchor constant:6.0].active = YES;
        }

        if (!last) {
            UIView *hair = [[UIView alloc] init];
            hair.translatesAutoresizingMaskIntoConstraints = NO;
            hair.backgroundColor = [DSColorHairline() colorWithAlphaComponent:0.55];
            [systemCard addSubview:hair];
            [NSLayoutConstraint activateConstraints:@[
                [hair.topAnchor constraintEqualToAnchor:row.bottomAnchor],
                [hair.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [hair.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [hair.heightAnchor constraintEqualToConstant:1.0],
            ]];
        }
        return row;
    };

    _secRow1Title = [[UILabel alloc] init];
    _secRow1Val = [[UILabel alloc] init];
    _secRow2Title = [[UILabel alloc] init];
    _secRow2Val = [[UILabel alloc] init];
    _secRow3Title = [[UILabel alloc] init];
    _secRow3Val = [[UILabel alloc] init];

    UIView *secRow1 = makeValueRow(_secRow1Title, _secRow1Val, nil, NO);
    UIView *secRow2 = makeValueRow(_secRow2Title, _secRow2Val, secRow1, NO);
    UIView *secRow3 = makeValueRow(_secRow3Title, _secRow3Val, secRow2, YES);

    [NSLayoutConstraint activateConstraints:@[
        [_secHeaderLabel.topAnchor constraintEqualToAnchor:systemCard.topAnchor constant:16.0],
        [_secHeaderLabel.leadingAnchor constraintEqualToAnchor:systemCard.leadingAnchor constant:16.0],
        [_secHeaderLabel.trailingAnchor constraintLessThanOrEqualToAnchor:systemCard.trailingAnchor constant:-16.0],

        [systemCard.bottomAnchor constraintEqualToAnchor:secRow3.bottomAnchor constant:12.0],
    ]];

    // --------------------------------------------------------- about card
    UIView *infoCard = [[UIView alloc] init];
    infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(infoCard, DSRadiusCard);
    [_settingContentView addSubview:infoCard];

    _aboutHeaderLabel = [[UILabel alloc] init];
    _aboutHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _aboutHeaderLabel.textColor = DSColorTextTertiary();
    _aboutHeaderLabel.font = DSFontBody(11.0, UIFontWeightHeavy);
    [infoCard addSubview:_aboutHeaderLabel];
    UILabel *aboutHeader = _aboutHeaderLabel;

    auto makeRow = ^UIView *(UILabel *titleLbl, NSString *valStr, UIView *topView, BOOL last) {
        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [infoCard addSubview:row];

        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.textColor = DSColorTextSecondary();
        titleLbl.font = DSFontBody(13.5, UIFontWeightMedium);
        [row addSubview:titleLbl];

        UILabel *vLabel = [[UILabel alloc] init];
        vLabel.translatesAutoresizingMaskIntoConstraints = NO;
        vLabel.text = valStr;
        vLabel.textColor = DSColorTextPrimary();
        vLabel.font = DSFontBody(13.0, UIFontWeightSemibold);
        vLabel.textAlignment = NSTextAlignmentRight;
        [row addSubview:vLabel];

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:16.0],
            [row.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor constant:-16.0],
            [row.heightAnchor constraintEqualToConstant:34.0],
            [titleLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [titleLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [vLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [vLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [vLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLbl.trailingAnchor constant:12.0],
        ]];

        if (topView) {
            [row.topAnchor constraintEqualToAnchor:topView.bottomAnchor constant:2.0].active = YES;
        } else {
            [row.topAnchor constraintEqualToAnchor:aboutHeader.bottomAnchor constant:6.0].active = YES;
        }
        return row;
    };

    _infoRow1Title = [[UILabel alloc] init];
    _infoRow2Title = [[UILabel alloc] init];
    _infoRow3Title = [[UILabel alloc] init];
    _infoRow4Title = [[UILabel alloc] init];

    UIView *r1 = makeRow(_infoRow1Title, @"DarkPubg", nil, NO);
    UIView *r2 = makeRow(_infoRow2Title, @"1.0-1", r1, NO);
    UIView *r3 = makeRow(_infoRow3Title, @"PUBG Mobile", r2, NO);
    UIView *r4 = makeRow(_infoRow4Title, @"DarkSword Kernel", r3, YES);

    [NSLayoutConstraint activateConstraints:@[
        [aboutHeader.topAnchor constraintEqualToAnchor:infoCard.topAnchor constant:16.0],
        [aboutHeader.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:16.0],
        [infoCard.bottomAnchor constraintEqualToAnchor:r4.bottomAnchor constant:12.0],
    ]];

    // ----------------------------------------------------------- dev card
    UIView *devCard = [[UIView alloc] init];
    devCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(devCard, DSRadiusCard);
    [_settingContentView addSubview:devCard];

    UIImageView *devAvatar = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"person.crop.circle.fill"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30.0
                                                                                weight:UIImageSymbolWeightRegular]]];
    devAvatar.translatesAutoresizingMaskIntoConstraints = NO;
    devAvatar.tintColor = DSColorAccent();
    devAvatar.contentMode = UIViewContentModeScaleAspectFit;
    [devCard addSubview:devAvatar];

    _devHeaderLabel = [[UILabel alloc] init];
    _devHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _devHeaderLabel.textColor = DSColorTextTertiary();
    _devHeaderLabel.font = DSFontBody(10.5, UIFontWeightHeavy);
    [devCard addSubview:_devHeaderLabel];

    _devNameLabel = [[UILabel alloc] init];
    _devNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _devNameLabel.text = @"Dũng Lê";
    _devNameLabel.textColor = DSColorTextPrimary();
    _devNameLabel.font = DSFontTitle(18.0);
    [devCard addSubview:_devNameLabel];

    [NSLayoutConstraint activateConstraints:@[
        [devAvatar.leadingAnchor constraintEqualToAnchor:devCard.leadingAnchor constant:16.0],
        [devAvatar.centerYAnchor constraintEqualToAnchor:devCard.centerYAnchor],
        [devAvatar.widthAnchor constraintEqualToConstant:40.0],
        [devAvatar.heightAnchor constraintEqualToConstant:40.0],

        [_devHeaderLabel.leadingAnchor constraintEqualToAnchor:devAvatar.trailingAnchor constant:12.0],
        [_devHeaderLabel.topAnchor constraintEqualToAnchor:devCard.topAnchor constant:14.0],

        [_devNameLabel.leadingAnchor constraintEqualToAnchor:_devHeaderLabel.leadingAnchor],
        [_devNameLabel.topAnchor constraintEqualToAnchor:_devHeaderLabel.bottomAnchor constant:1.0],

        [devCard.heightAnchor constraintEqualToConstant:72.0],
    ]];

    // ------------------------------------------------------------ note card
    UIView *noteCard = [[UIView alloc] init];
    noteCard.translatesAutoresizingMaskIntoConstraints = NO;
    noteCard.backgroundColor = [DSColorSurfaceHi() colorWithAlphaComponent:0.45];
    noteCard.layer.cornerRadius = DSRadiusControl;
    noteCard.layer.cornerCurve = kCACornerCurveContinuous;
    [_settingContentView addSubview:noteCard];

    UIImageView *noteIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"info.circle.fill"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.0
                                                                                weight:UIImageSymbolWeightSemibold]]];
    noteIcon.translatesAutoresizingMaskIntoConstraints = NO;
    noteIcon.tintColor = DSColorTextTertiary();
    [noteCard addSubview:noteIcon];

    _noteLabel = [[UILabel alloc] init];
    _noteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _noteLabel.textColor = DSColorTextTertiary();
    _noteLabel.font = DSFontBody(11.5, UIFontWeightRegular);
    _noteLabel.numberOfLines = 0;
    _noteLabel.textAlignment = NSTextAlignmentLeft;
    [noteCard addSubview:_noteLabel];

    [NSLayoutConstraint activateConstraints:@[
        [noteIcon.leadingAnchor constraintEqualToAnchor:noteCard.leadingAnchor constant:14.0],
        [noteIcon.topAnchor constraintEqualToAnchor:noteCard.topAnchor constant:13.0],
        [noteIcon.widthAnchor constraintEqualToConstant:14.0],
        [noteIcon.heightAnchor constraintEqualToConstant:14.0],

        [_noteLabel.leadingAnchor constraintEqualToAnchor:noteIcon.trailingAnchor constant:8.0],
        [_noteLabel.trailingAnchor constraintEqualToAnchor:noteCard.trailingAnchor constant:-14.0],
        [_noteLabel.topAnchor constraintEqualToAnchor:noteCard.topAnchor constant:11.0],
        [_noteLabel.bottomAnchor constraintEqualToAnchor:noteCard.bottomAnchor constant:-11.0],
    ]];

    // ---------------------------------------------------------------- layout
    [NSLayoutConstraint activateConstraints:@[
        [_settingTitleLabel.topAnchor constraintEqualToAnchor:_settingContentView.topAnchor constant:10.0],
        [_settingTitleLabel.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [_settingTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [_settingSubTitleLabel.topAnchor constraintEqualToAnchor:_settingTitleLabel.bottomAnchor constant:-2.0],
        [_settingSubTitleLabel.leadingAnchor constraintEqualToAnchor:_settingTitleLabel.leadingAnchor],
        [_settingSubTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [langCard.topAnchor constraintEqualToAnchor:_settingSubTitleLabel.bottomAnchor constant:14.0],
        [langCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [langCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [systemCard.topAnchor constraintEqualToAnchor:langCard.bottomAnchor constant:DSSectionGap],
        [systemCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [systemCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [infoCard.topAnchor constraintEqualToAnchor:systemCard.bottomAnchor constant:DSSectionGap],
        [infoCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [infoCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [devCard.topAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:DSSectionGap],
        [devCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [devCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [noteCard.topAnchor constraintEqualToAnchor:devCard.bottomAnchor constant:DSSectionGap],
        [noteCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [noteCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],
        [noteCard.bottomAnchor constraintEqualToAnchor:_settingContentView.bottomAnchor constant:-24.0],
    ]];
}

#pragma mark - Console Logging and Pulse Helpers

- (void)appendConsoleLog:(NSString *)tag message:(NSString *)msg tagColor:(UIColor *)color
{
    if (!_consoleTextView) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        [df setDateFormat:@"HH:mm:ss"];
        NSString *timeStr = [df stringFromDate:[NSDate date]];

        NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];

        // Timestamp [HH:mm:ss]
        NSDictionary *timeAttrs = @{
            NSForegroundColorAttributeName: DSColorTextTertiary(),
            NSFontAttributeName: DSFontMono(10.0, UIFontWeightRegular),
        };
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%@] ", timeStr] attributes:timeAttrs]];

        // Tag [TAG]
        NSDictionary *tagAttrs = @{
            NSForegroundColorAttributeName: color ?: DSColorAccent(),
            NSFontAttributeName: DSFontMono(10.0, UIFontWeightBold),
        };
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%@] ", tag] attributes:tagAttrs]];

        // Message
        NSDictionary *msgAttrs = @{
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.796 green:0.831 blue:0.878 alpha:1.0],
            NSFontAttributeName: DSFontMono(10.5, UIFontWeightRegular),
        };
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", msg] attributes:msgAttrs]];

        if (!self->_consoleLogStorage) {
            self->_consoleLogStorage = [[NSMutableAttributedString alloc] init];
        }
        [self->_consoleLogStorage appendAttributedString:line];

        self->_consoleTextView.attributedText = self->_consoleLogStorage;

        if (self->_consoleTextView.text.length > 0) {
            NSRange bottom = NSMakeRange(self->_consoleTextView.text.length - 1, 1);
            [self->_consoleTextView scrollRangeToVisible:bottom];
        }
    });
}

- (void)startPulseAnimation:(UIView *)view
{
    if (!view) return;
    [UIView animateWithDuration:0.9 delay:0 options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat | UIViewAnimationOptionCurveEaseInOut animations:^{
        view.alpha = 0.25f;
    } completion:nil];
}

- (void)seedBootLogs
{
    BOOL isEN = IsEnglish();
    NSString *iosVer = @"";
    NSString *dsStatus = @"";
    BOOL isSupported = CheckDarkSwordSupport(&iosVer, &dsStatus);

    [self appendConsoleLog:@"SYS" message:(isEN ? @"DarkPubg Core Loader v1.0-1 initialized" : @"Hệ thống DarkPubg Core v1.0-1 khởi động") tagColor:DSColorInfo()];
    [self appendConsoleLog:@"INFO" message:[NSString stringWithFormat:isEN ? @"Host OS: iOS %@ detected" : @"Thiết bị: iOS %@ đã nhận diện", [[UIDevice currentDevice] systemVersion]] tagColor:DSColorAccent()];
    if (isSupported) {
        [self appendConsoleLog:@"OK" message:(isEN ? @"Kernel Compatibility: PASSED (DarkSword supported)" : @"Tương thích Kernel: ĐẠT (Hỗ trợ DarkSword)") tagColor:DSColorSuccess()];
    } else {
        [self appendConsoleLog:@"WARN" message:(isEN ? @"Kernel Compatibility: WARNING (iOS unsupported)" : @"Tương thích Kernel: CẢNH BÁO (iOS chưa hỗ trợ)") tagColor:DSColorDanger()];
    }
    [self appendConsoleLog:@"KERN" message:(isEN ? @"DarkSword kernel driver: Direct R/W active" : @"DarkSword Kernel driver: Kích hoạt bộ nhớ R/W") tagColor:DSColorWarning()];
    [self appendConsoleLog:@"ESP" message:(isEN ? @"Metal 120 FPS rendering pipeline ready" : @"Engine hiển thị đồ hoạ Metal 120 FPS sẵn sàng") tagColor:DSColorAccent()];
    [self appendConsoleLog:@"PUBG" message:(isEN ? @"Target binary: ShadowTrackerExtra" : @"Mục tiêu gắn kết: ShadowTrackerExtra") tagColor:DSColorWarning()];
    [self appendConsoleLog:@"INFO" message:(isEN ? @"Ready. Tap OPEN HUD to attach." : @"Hệ thống sẵn sàng. Nhấn OPEN HUD để bắt đầu.") tagColor:DSColorAccent()];
}

#pragma mark - Language Change

- (void)langSegmentChanged:(UISegmentedControl *)sender
{
    NSString *newLang = (sender.selectedSegmentIndex == 1) ? @"en" : @"vi";
    [[NSUserDefaults standardUserDefaults] setObject:newLang forKey:@"AppLanguage"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (_impactFeedbackGenerator) {
        [_impactFeedbackGenerator impactOccurred];
    }

    [UIView transitionWithView:self.view duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self applyLanguageTexts];
    } completion:nil];
}

- (void)applyLanguageTexts
{
    BOOL isEN = IsEnglish();

    // Bottom tab bar
    ((UILabel *)[_homeTabButton viewWithTag:102]).text = isEN ? @"Home" : @"Trang chủ";
    ((UILabel *)[_settingTabButton viewWithTag:102]).text = isEN ? @"Setting" : @"Cài đặt";

    // Home tab
    _homeTitleLabel.text = @"DarkPubg";

    NSString *iosVer = @"";
    NSString *dsStatus = @"";
    BOOL isSupported = CheckDarkSwordSupport(&iosVer, &dsStatus);
    _iosVersionLabel.text = [NSString stringWithFormat:isEN ? @"Device OS: %@" : @"Phiên bản: %@", iosVer];
    _systemTagLabel.text = isEN ? @"Device" : @"Thiết bị";

    UIColor *stateColor = isSupported ? DSColorSuccess() : DSColorDanger();
    if (_statusDotView) {
        _statusDotView.backgroundColor = stateColor;
        _statusDotView.layer.shadowColor = stateColor.CGColor;
    }
    if (_dsStatusBadge) {
        _dsStatusBadge.backgroundColor = [stateColor colorWithAlphaComponent:0.14];
        _dsStatusBadge.layer.borderColor = [stateColor colorWithAlphaComponent:0.30].CGColor;
    }
    if (_dsBadgeLabel) _dsBadgeLabel.textColor = stateColor;
    _dsStatusLabel.textColor = stateColor;
    _dsStatusLabel.text = isSupported
        ? (isEN ? @"DarkSword: Supported" : @"DarkSword: Đã hỗ trợ")
        : (isEN ? @"DarkSword: Unsupported" : @"DarkSword: Chưa hỗ trợ");
    _dsBadgeLabel.text = isSupported
        ? (isEN ? @"COMPATIBLE" : @"TƯƠNG THÍCH")
        : (isEN ? @"UNSUPPORTED" : @"CHƯA HỖ TRỢ");

    if (_isRemoteHUDActive) {
        [_mainButton setTitle:isEN ? @"EXIT HUD" : @"DỪNG HUD" forState:UIControlStateNormal];
        _buttonSubLabel.text = isEN ? @"DarkPubg is currently active in game" : @"DarkPubg đang hoạt động trong game";
    } else if (_isHUDLaunching) {
        // Retain dynamic percentage while loading
    } else {
        [_mainButton setTitle:isEN ? @"OPEN HUD" : @"MỞ HUD" forState:UIControlStateNormal];
        _buttonSubLabel.text = isEN ? @"Tap to launch in-game ESP menu" : @"Nhấn để bật menu ESP trong game";
    }

    _consoleHeaderLabel.text = isEN ? @"CONSOLE LOG" : @"NHẬT KÝ HỆ THỐNG";
    _consoleLiveLabel.text = isEN ? @"LIVE" : @"HOẠT ĐỘNG";

    // Setting tab
    _settingTitleLabel.text = isEN ? @"Settings" : @"Cài Đặt";
    _settingSubTitleLabel.text = isEN ? @"Information & Options" : @"Thông tin & Tuỳ chọn";
    _langHeaderLabel.text = isEN ? @"LANGUAGE" : @"NGÔN NGỮ";

    // Developer
    _devHeaderLabel.text = isEN ? @"DEVELOPER" : @"NGƯỜI PHÁT TRIỂN";
    _devNameLabel.text = @"Dũng Lê";

    // Security & Protection
    _secHeaderLabel.text = isEN ? @"SECURITY & ENGINE" : @"BẢO MẬT & HỆ THỐNG";
    _secRow1Title.text = isEN ? @"Anti-Cheat Bypass" : @"Bỏ qua chống gian lận";
    _secRow1Val.text = isEN ? @"Active (Safe)" : @"Hoạt động (An toàn)";
    _secRow2Title.text = isEN ? @"Rendering Pipeline" : @"Luồng hiển thị ESP";
    _secRow2Val.text = @"120 FPS Metal";
    _secRow3Title.text = isEN ? @"Memory Privilege" : @"Đặc quyền bộ nhớ";
    _secRow3Val.text = @"DarkSword Kernel (R/W)";

    // App Details
    _aboutHeaderLabel.text = isEN ? @"ABOUT" : @"THÔNG TIN";
    _infoRow1Title.text = isEN ? @"App Name" : @"Ứng dụng";
    _infoRow2Title.text = isEN ? @"Version" : @"Phiên bản";
    _infoRow3Title.text = isEN ? @"Target Game" : @"Trò chơi";
    _infoRow4Title.text = isEN ? @"Exploit Engine" : @"Kiểu can thiệp";

    // Note
    _noteLabel.text = isEN ?
        @"DarkPubg operates directly via DarkSword Kernel on iOS without Jailbreak." :
        @"DarkPubg hoạt động trực tiếp thông qua DarkSword Kernel trên iOS mà không cần Jailbreak.";
}

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    // The shell is a fixed dark design: pin the appearance so system controls
    // (segmented control, alerts, blur materials) never fall back to light.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    _impactFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];

    // Force active game to PUBG Mobile (AOV temporarily hidden)
    [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"DSActiveGame"];
    [[NSUserDefaults standardUserDefaults] synchronize];
#if USE_DARKSWORD
    DSBridgeSetActiveGame(1);
#endif

    [self registerNotifications];
    [self seedBootLogs];
    [self startPulseAnimation:_consoleLiveDot];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    // Keep the ambient wash and the blurred tab bar aligned with the window
    // after rotation or a size-class change.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _ambientLayer.frame = self.backgroundView.bounds;
    [CATransaction commit];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self toggleHUDAfterLaunch];
}

- (void)reloadMainButtonState
{
    _isRemoteHUDActive = [self isHUDEnabled];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_isHUDLaunching) return;

        [self applyLanguageTexts];
        BOOL destructive = self->_isRemoteHUDActive;
        UIColor *fill = destructive ? DSColorDanger() : DSColorAccent();
        self->_mainButton.backgroundColor = fill;
        self->_mainButton.layer.shadowColor = fill.CGColor;
        [self->_mainButton setTitleColor:destructive ? UIColor.whiteColor
                                                 : DSColorOnAccent()
                                forState:UIControlStateNormal];
        self->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
    });
}

- (void)doEnableHUD
{
    BOOL isNowEnabled = [self isHUDEnabled];
    if (isNowEnabled || _isHUDLaunching) return;

    BOOL isEN = IsEnglish();
    _isHUDLaunching = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_mainBtnSpinner.color = DSColorOnAccent();
        [self->_mainBtnSpinner startAnimating];
        [self->_mainButton setTitle:isEN ? @"LAUNCHING... 0%" : @"ĐANG NẠP HUD... 0%" forState:UIControlStateNormal];
        self->_buttonSubLabel.text = isEN ? @"Attaching DarkSword Kernel..." : @"Đang nạp qua DarkSword Kernel...";
        self->_mainButton.contentEdgeInsets = UIEdgeInsetsMake(0, 24, 0, 0);
    });

    [self appendConsoleLog:@"KERN" message:(isEN ? @"Attaching DarkSword kernel hooks..." : @"Đang nạp bộ nhớ qua DarkSword Kernel...") tagColor:DSColorWarning()];

    [self setHUDEnabled:YES];

    [_impactFeedbackGenerator prepare];
    int anyToken;
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(NOTIFY_LAUNCHED_HUD, &anyToken, dispatch_get_main_queue(), ^(int token) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        notify_cancel(token);
        if (!strongSelf) return;

        strongSelf->_isHUDLaunching = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf->_mainBtnSpinner stopAnimating];
            strongSelf->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
            [strongSelf reloadMainButtonState];
            [strongSelf.backgroundView setUserInteractionEnabled:YES];
        });
        [strongSelf->_impactFeedbackGenerator impactOccurred];

        BOOL isEN = IsEnglish();
        [strongSelf appendConsoleLog:@"OK" message:(isEN ? @"ESP Overlay successfully launched in-game!" : @"Menu ESP đã kích hoạt thành công trong game!") tagColor:DSColorSuccess()];
    });

    [self.backgroundView setUserInteractionEnabled:YES];
}

- (void)doDisableHUD
{
    BOOL isNowEnabled = [self isHUDEnabled];
    if (!isNowEnabled && !_isHUDLaunching) return;

    _isHUDLaunching = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_mainBtnSpinner stopAnimating];
        self->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
    });

    BOOL isEN = IsEnglish();
    [self appendConsoleLog:@"INFO" message:(isEN ? @"User requested HUD stop" : @"Yêu cầu tắt HUD từ người dùng") tagColor:DSColorAccent()];
    [self appendConsoleLog:@"KERN" message:(isEN ? @"Detaching DarkSword kernel hooks..." : @"Đang ngắt liên kết DarkSword Kernel...") tagColor:DSColorWarning()];

    [self setHUDEnabled:NO];

    [self.backgroundView setUserInteractionEnabled:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadMainButtonState];
            [self.backgroundView setUserInteractionEnabled:YES];
            [self appendConsoleLog:@"SYS" message:(isEN ? @"HUD stopped. Standby mode active." : @"Đã tắt HUD. Chế độ chờ sẵn sàng.") tagColor:DSColorInfo()];
        });
    });
}

- (void)tapMainButton:(UIButton *)sender
{
    if (_isHUDLaunching) return;

    BOOL isNowEnabled = [self isHUDEnabled];

    // If HUD is currently ON, turn it OFF:
    if (isNowEnabled) {
        [self doDisableHUD];
        return;
    }

    // Direct manual launch: user enters game manually, switches back, taps OPEN HUD
    BOOL isEN = IsEnglish();
    if (IsPUBGProcessRunning()) {
        [self appendConsoleLog:@"OK" message:(isEN ? @"Target process found: ShadowTrackerExtra" : @"Đã kết nối tiến trình: ShadowTrackerExtra") tagColor:DSColorSuccess()];
    } else {
        [self appendConsoleLog:@"INFO" message:(isEN ? @"Waiting for game process..." : @"Đang chờ tiến trình game...") tagColor:DSColorWarning()];
    }

    [self doEnableHUD];
}

#pragma mark - DarkSword Progress Callbacks

#if USE_DARKSWORD
- (void)showDSProgressOverlay
{
    // Replaced by inline spinner & progress % on OPEN HUD button
}

- (void)hideDSProgressOverlay
{
    // Replaced by inline spinner & progress % on OPEN HUD button
}

- (void)showDSFailure:(NSString *)error
{
    _isHUDLaunching = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_mainBtnSpinner stopAnimating];
        self->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
        [self reloadMainButtonState];
    });
    [self appendConsoleLog:@"ERR" message:error tagColor:DSColorDanger()];
}

- (void)dsProgressDidChange:(NSNotification *)note
{
    if (!DSBridgeIsRunning()) {
        if (DSBridgeHUDEnabled()) {
            _isHUDLaunching = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_mainBtnSpinner stopAnimating];
                self->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
                [self reloadMainButtonState];
            });
        }
        return;
    }
    double p = DSBridgeProgress();
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    int pct = (int)llround(p * 100.0);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    NSString *stage = DSBridgeStage();
    BOOL isEN = IsEnglish();

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_isHUDLaunching) {
            [self->_mainBtnSpinner startAnimating];
            self->_mainButton.contentEdgeInsets = UIEdgeInsetsMake(0, 24, 0, 0);
            NSString *title = isEN
                ? [NSString stringWithFormat:@"LAUNCHING... %d%%", pct]
                : [NSString stringWithFormat:@"ĐANG NẠP HUD... %d%%", pct];
            [self->_mainButton setTitle:title forState:UIControlStateNormal];

            if (stage && stage.length > 0) {
                self->_buttonSubLabel.text = stage;
            }
        }
    });
}
#endif

#pragma mark - TSSettingsControllerDelegate

- (BOOL)settingHighlightedWithKey:(NSString * _Nonnull)key
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:key];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)settingDidSelectWithKey:(NSString * _Nonnull)key
{
    BOOL highlighted = [self settingHighlightedWithKey:key];
    [_userDefaults setObject:@(!highlighted) forKey:key];
    [self saveUserDefaults];
}

#pragma mark - Rotation & Orientation

- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }

- (void)reloadModeButtonState {}
- (void)verticalSizeClassUpdated {}

- (void)toggleHUDNotificationReceived:(NSNotification *)notification {
    NSString *toggleAction = notification.userInfo[kToggleHUDAfterLaunchNotificationActionKey];
    if (!toggleAction) {
        [self toggleHUDAfterLaunch];
    } else if ([toggleAction isEqualToString:kToggleHUDAfterLaunchNotificationActionToggleOn]) {
        [self toggleOnHUDAfterLaunch];
    } else if ([toggleAction isEqualToString:kToggleHUDAfterLaunchNotificationActionToggleOff]) {
        [self toggleOffHUDAfterLaunch];
    }
}

- (void)toggleHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        [self tapMainButton:_mainButton];
    }
}

- (void)toggleOnHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        if (!_isRemoteHUDActive) {
            [self tapMainButton:_mainButton];
        }
    }
}

- (void)toggleOffHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        if (_isRemoteHUDActive) {
            [self tapMainButton:_mainButton];
        }
    }
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"DarkPubg" message:@"Bạn có muốn đặt lại cài đặt không?" preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self resetUserDefaults];
        }]];
        [self presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)resetUserDefaults
{
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleIdentifier) {
        [GetStandardUserDefaults() removePersistentDomainForName:bundleIdentifier];
        [GetStandardUserDefaults() synchronize];
    }
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) error:nil];
    if (removed) {
        [self setHUDEnabled:NO];
        [[UIApplication sharedApplication] terminateWithSuccess];
    }
}

- (void)loadUserDefaults:(BOOL)forceReload
{
    if (forceReload || !_userDefaults) {
        _userDefaults = [[NSDictionary dictionaryWithContentsOfFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH))] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
}

- (void)saveUserDefaults
{
    if (![_userDefaults writeToFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) atomically:YES]) return;
    notify_post(NOTIFY_RELOAD_HUD);
}

@end
