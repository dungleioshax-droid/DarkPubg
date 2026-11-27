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
    UIButton *_homeTabButton;
    UIButton *_settingTabButton;
    NSInteger _selectedTabIndex;

    // Home localized labels
    UILabel *_homeTitleLabel;
    UILabel *_homeSubTitleLabel;
    UIButton *_quickLangButton;
    UILabel *_homeSysSectionLabel;
    UILabel *_iosRowTitleLabel;
    UILabel *_iosVersionLabel;
    UILabel *_kernelRowTitleLabel;
    UIView *_statusIconBox;
    UIImageView *_statusIconView;
    UILabel *_dsStatusLabel;
    UILabel *_espRowTitleLabel;
    UILabel *_espRowValLabel;

    // Home Console Terminal
    UIView *_consoleCard;
    UILabel *_consoleHeaderLabel;
    UIButton *_consoleClearButton;
    UITextView *_consoleTextView;
    NSMutableAttributedString *_consoleLogStorage;

    // Setting localized labels
    UILabel *_settingTitleLabel;
    UILabel *_langHeaderLabel;
    UISegmentedControl *_langSegmentedControl;

    // Developer Card
    UILabel *_aboutHeaderLabel;
    UILabel *_devNameLabel;
    UILabel *_devRoleLabel;
    UIButton *_resetSettingsButton;

    // Security & Engine Card
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
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:blur];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bottomTabBar = bar;

    UIView *topBorder = [[UIView alloc] init];
    topBorder.translatesAutoresizingMaskIntoConstraints = NO;
    topBorder.backgroundColor = [DSColorHairline() colorWithAlphaComponent:0.85];
    [bar.contentView addSubview:topBorder];

    _homeTabButton = [self createTabButtonWithTitle:@"Home" iconName:@"house.fill" tag:0];
    _settingTabButton = [self createTabButtonWithTitle:@"Setting" iconName:@"gearshape.fill" tag:1];

    [bar.contentView addSubview:_homeTabButton];
    [bar.contentView addSubview:_settingTabButton];

    [self.view addSubview:bar];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-49.0],

        [topBorder.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor],
        [topBorder.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor],
        [topBorder.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor],
        [topBorder.heightAnchor constraintEqualToConstant:0.5],

        [_homeTabButton.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor],
        [_homeTabButton.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor],
        [_homeTabButton.widthAnchor constraintEqualToAnchor:bar.contentView.widthAnchor multiplier:0.5],
        [_homeTabButton.heightAnchor constraintEqualToConstant:49.0],

        [_settingTabButton.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor],
        [_settingTabButton.topAnchor constraintEqualToAnchor:bar.contentView.topAnchor],
        [_settingTabButton.leadingAnchor constraintEqualToAnchor:_homeTabButton.trailingAnchor],
        [_settingTabButton.heightAnchor constraintEqualToConstant:49.0],
    ]];
}

- (UIButton *)createTabButtonWithTitle:(NSString *)title iconName:(NSString *)iconName tag:(NSInteger)tag
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = tag;
    [btn addTarget:self action:@selector(tabButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *symbol =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:iconName] imageWithConfiguration:symbol]];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tag = 101;
    iconView.userInteractionEnabled = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor systemGrayColor];
    [btn addSubview:iconView];

    UILabel *caption = [[UILabel alloc] init];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.tag = 102;
    caption.text = title;
    caption.textColor = [UIColor systemGrayColor];
    caption.font = DSFontBody(10.0, UIFontWeightMedium);
    caption.textAlignment = NSTextAlignmentCenter;
    caption.userInteractionEnabled = NO;
    [btn addSubview:caption];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
        [iconView.topAnchor constraintEqualToAnchor:btn.topAnchor constant:5.0],
        [iconView.widthAnchor constraintEqualToConstant:24.0],
        [iconView.heightAnchor constraintEqualToConstant:24.0],

        [caption.centerXAnchor constraintEqualToAnchor:btn.centerXAnchor],
        [caption.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:1.0],
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
    UIColor *inactiveColor = [UIColor systemGrayColor];

    UIImageView *homeIcon = (UIImageView *)[_homeTabButton viewWithTag:101];
    UILabel *homeCaption = (UILabel *)[_homeTabButton viewWithTag:102];
    UIImageView *setIcon = (UIImageView *)[_settingTabButton viewWithTag:101];
    UILabel *setCaption = (UILabel *)[_settingTabButton viewWithTag:102];

    homeIcon.tintColor = (index == 0) ? activeColor : inactiveColor;
    setIcon.tintColor = (index == 1) ? activeColor : inactiveColor;
    homeCaption.textColor = homeIcon.tintColor;
    setCaption.textColor = setIcon.tintColor;

    [UIView transitionWithView:self.backgroundView duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
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

    // ---------------------------------------------------------------- header (iOS Large Title)
    _homeTitleLabel = [[UILabel alloc] init];
    _homeTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _homeTitleLabel.text = @"DarkPubg";
    _homeTitleLabel.textColor = DSColorTextPrimary();
    _homeTitleLabel.font = DSFontDisplay(34.0);
    _homeTitleLabel.adjustsFontSizeToFitWidth = YES;
    _homeTitleLabel.minimumScaleFactor = 0.75;
    [_homeView addSubview:_homeTitleLabel];

    _homeSubTitleLabel = [[UILabel alloc] init];
    _homeSubTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _homeSubTitleLabel.text = @"DarkSword Kernel • PUBG Mobile";
    _homeSubTitleLabel.textColor = DSColorTextSecondary();
    _homeSubTitleLabel.font = DSFontBody(13.0, UIFontWeightRegular);
    [_homeView addSubview:_homeSubTitleLabel];

    _quickLangButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _quickLangButton.translatesAutoresizingMaskIntoConstraints = NO;
    _quickLangButton.backgroundColor = DSColorSurfaceHi();
    _quickLangButton.layer.cornerRadius = 14.0;
    _quickLangButton.layer.cornerCurve = kCACornerCurveContinuous;
    _quickLangButton.titleLabel.font = DSFontBody(12.5, UIFontWeightSemibold);
    [_quickLangButton setTitleColor:DSColorAccent() forState:UIControlStateNormal];
    [_quickLangButton addTarget:self action:@selector(quickLangTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_homeView addSubview:_quickLangButton];

    // --------------------------------------------------- section 1 header
    _homeSysSectionLabel = [[UILabel alloc] init];
    _homeSysSectionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _homeSysSectionLabel.textColor = DSColorTextSecondary();
    _homeSysSectionLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    [_homeView addSubview:_homeSysSectionLabel];

    // ----------------------------------- InsetGrouped system status card
    UIView *statusCard = [[UIView alloc] init];
    statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(statusCard, DSRadiusCard);
    [_homeView addSubview:statusCard];

    auto makeSettingsIcon = ^UIView *(NSString *symbolName, UIColor *bgColor, UIImageView * __strong *outImg) {
        UIView *box = [[UIView alloc] init];
        box.translatesAutoresizingMaskIntoConstraints = NO;
        box.backgroundColor = bgColor;
        box.layer.cornerRadius = 7.0;
        box.layer.cornerCurve = kCACornerCurveContinuous;
        UIImage *img = [UIImage systemImageNamed:symbolName
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                                                               weight:UIImageSymbolWeightMedium]];
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.tintColor = UIColor.whiteColor;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [box addSubview:iv];
        if (outImg) *outImg = iv;
        [NSLayoutConstraint activateConstraints:@[
            [box.widthAnchor constraintEqualToConstant:29.0],
            [box.heightAnchor constraintEqualToConstant:29.0],
            [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
            [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        ]];
        return box;
    };

    NSString *iosVer = @"";
    NSString *dsStatus = @"";
    BOOL isSupported = CheckDarkSwordSupport(&iosVer, &dsStatus);
    UIColor *dotColor = isSupported ? DSColorSuccess() : DSColorDanger();

    UIView *iosIconBox = makeSettingsIcon(@"iphone", DSColorAccent(), nil);
    [statusCard addSubview:iosIconBox];

    _iosRowTitleLabel = [[UILabel alloc] init];
    _iosRowTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _iosRowTitleLabel.textColor = DSColorTextPrimary();
    _iosRowTitleLabel.font = DSFontBody(16.0, UIFontWeightRegular);
    [statusCard addSubview:_iosRowTitleLabel];

    _iosVersionLabel = [[UILabel alloc] init];
    _iosVersionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _iosVersionLabel.textColor = DSColorTextSecondary();
    _iosVersionLabel.font = DSFontBody(15.0, UIFontWeightRegular);
    _iosVersionLabel.textAlignment = NSTextAlignmentRight;
    [statusCard addSubview:_iosVersionLabel];

    UIView *cardSep1 = [[UIView alloc] init];
    cardSep1.translatesAutoresizingMaskIntoConstraints = NO;
    cardSep1.backgroundColor = DSColorHairline();
    [statusCard addSubview:cardSep1];

    _statusIconBox = makeSettingsIcon(isSupported ? @"checkmark.shield.fill" : @"xmark.shield.fill", dotColor, &_statusIconView);
    [statusCard addSubview:_statusIconBox];

    _kernelRowTitleLabel = [[UILabel alloc] init];
    _kernelRowTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _kernelRowTitleLabel.textColor = DSColorTextPrimary();
    _kernelRowTitleLabel.font = DSFontBody(16.0, UIFontWeightRegular);
    [statusCard addSubview:_kernelRowTitleLabel];

    _dsStatusLabel = [[UILabel alloc] init];
    _dsStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _dsStatusLabel.textColor = dotColor;
    _dsStatusLabel.font = DSFontBody(15.0, UIFontWeightMedium);
    _dsStatusLabel.textAlignment = NSTextAlignmentRight;
    [statusCard addSubview:_dsStatusLabel];

    UIView *cardSep2 = [[UIView alloc] init];
    cardSep2.translatesAutoresizingMaskIntoConstraints = NO;
    cardSep2.backgroundColor = DSColorHairline();
    [statusCard addSubview:cardSep2];

    UIView *espIconBox = makeSettingsIcon(@"bolt.fill", DSColorViolet(), nil);
    [statusCard addSubview:espIconBox];

    _espRowTitleLabel = [[UILabel alloc] init];
    _espRowTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _espRowTitleLabel.textColor = DSColorTextPrimary();
    _espRowTitleLabel.font = DSFontBody(16.0, UIFontWeightRegular);
    [statusCard addSubview:_espRowTitleLabel];

    _espRowValLabel = [[UILabel alloc] init];
    _espRowValLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _espRowValLabel.text = @"120 FPS Metal";
    _espRowValLabel.textColor = DSColorTextSecondary();
    _espRowValLabel.font = DSFontBody(15.0, UIFontWeightRegular);
    _espRowValLabel.textAlignment = NSTextAlignmentRight;
    [statusCard addSubview:_espRowValLabel];

    // -------------------------------------------------------------- CTA button
    _mainButton = [MainButton buttonWithType:UIButtonTypeSystem];
    _mainButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainButton addTarget:self action:@selector(tapMainButton:) forControlEvents:UIControlEventTouchUpInside];
    [_mainButton setTitle:@"OPEN HUD" forState:UIControlStateNormal];
    DSApplyPrimaryButton(_mainButton, NO);
    _mainButton.backgroundColor = DSColorAccent();
    _mainButton.titleLabel.font = DSFontTitle(17.0);
    _mainButton.layer.cornerRadius = 12.0;
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
    _buttonSubLabel.textColor = DSColorTextSecondary();
    _buttonSubLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    _buttonSubLabel.textAlignment = NSTextAlignmentCenter;
    _buttonSubLabel.numberOfLines = 1;
    [_homeView addSubview:_buttonSubLabel];

    // --------------------------------------------------- section 2 header
    _consoleHeaderLabel = [[UILabel alloc] init];
    _consoleHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleHeaderLabel.textColor = DSColorTextSecondary();
    _consoleHeaderLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    _consoleHeaderLabel.text = @"ACTIVITY LOG";
    [_homeView addSubview:_consoleHeaderLabel];

    _consoleClearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _consoleClearButton.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleClearButton.titleLabel.font = DSFontBody(13.0, UIFontWeightRegular);
    [_consoleClearButton setTitleColor:DSColorAccent() forState:UIControlStateNormal];
    [_consoleClearButton addTarget:self action:@selector(clearConsoleTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_homeView addSubview:_consoleClearButton];

    // ------------------------------------------------------------ console card
    _consoleCard = [[UIView alloc] init];
    _consoleCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(_consoleCard, DSRadiusCard);
    [_homeView addSubview:_consoleCard];

    _consoleTextView = [[UITextView alloc] init];
    _consoleTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _consoleTextView.backgroundColor = UIColor.clearColor;
    _consoleTextView.editable = NO;
    _consoleTextView.selectable = NO;
    _consoleTextView.showsVerticalScrollIndicator = YES;
    _consoleTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _consoleTextView.textContainerInset = UIEdgeInsetsMake(10, 12, 10, 12);
    _consoleTextView.scrollEnabled = YES;
    [_consoleCard addSubview:_consoleTextView];

    // ---------------------------------------------------------------- layout
    [NSLayoutConstraint activateConstraints:@[
        [_homeTitleLabel.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_homeTitleLabel.topAnchor constraintEqualToAnchor:_homeView.topAnchor constant:8.0],

        [_quickLangButton.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [_quickLangButton.centerYAnchor constraintEqualToAnchor:_homeTitleLabel.centerYAnchor],
        [_quickLangButton.widthAnchor constraintEqualToConstant:50.0],
        [_quickLangButton.heightAnchor constraintEqualToConstant:28.0],
        [_homeTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_quickLangButton.leadingAnchor constant:-10.0],

        [_homeSubTitleLabel.leadingAnchor constraintEqualToAnchor:_homeTitleLabel.leadingAnchor],
        [_homeSubTitleLabel.topAnchor constraintEqualToAnchor:_homeTitleLabel.bottomAnchor constant:2.0],
        [_homeSubTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],

        [_homeSysSectionLabel.topAnchor constraintEqualToAnchor:_homeSubTitleLabel.bottomAnchor constant:16.0],
        [_homeSysSectionLabel.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter + 14.0],
        [_homeSysSectionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],

        [statusCard.topAnchor constraintEqualToAnchor:_homeSysSectionLabel.bottomAnchor constant:6.0],
        [statusCard.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [statusCard.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [statusCard.heightAnchor constraintEqualToConstant:134.0],

        [iosIconBox.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [iosIconBox.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:7.5],
        [_iosRowTitleLabel.leadingAnchor constraintEqualToAnchor:iosIconBox.trailingAnchor constant:14.0],
        [_iosRowTitleLabel.centerYAnchor constraintEqualToAnchor:iosIconBox.centerYAnchor],
        [_iosVersionLabel.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [_iosVersionLabel.centerYAnchor constraintEqualToAnchor:iosIconBox.centerYAnchor],
        [_iosVersionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_iosRowTitleLabel.trailingAnchor constant:8.0],

        [cardSep1.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:44.5],
        [cardSep1.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:59.0],
        [cardSep1.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor],
        [cardSep1.heightAnchor constraintEqualToConstant:0.5],

        [_statusIconBox.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [_statusIconBox.topAnchor constraintEqualToAnchor:cardSep1.bottomAnchor constant:7.5],
        [_kernelRowTitleLabel.leadingAnchor constraintEqualToAnchor:_statusIconBox.trailingAnchor constant:14.0],
        [_kernelRowTitleLabel.centerYAnchor constraintEqualToAnchor:_statusIconBox.centerYAnchor],
        [_dsStatusLabel.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [_dsStatusLabel.centerYAnchor constraintEqualToAnchor:_statusIconBox.centerYAnchor],
        [_dsStatusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_kernelRowTitleLabel.trailingAnchor constant:8.0],

        [cardSep2.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:89.5],
        [cardSep2.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:59.0],
        [cardSep2.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor],
        [cardSep2.heightAnchor constraintEqualToConstant:0.5],

        [espIconBox.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [espIconBox.topAnchor constraintEqualToAnchor:cardSep2.bottomAnchor constant:7.5],
        [_espRowTitleLabel.leadingAnchor constraintEqualToAnchor:espIconBox.trailingAnchor constant:14.0],
        [_espRowTitleLabel.centerYAnchor constraintEqualToAnchor:espIconBox.centerYAnchor],
        [_espRowValLabel.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [_espRowValLabel.centerYAnchor constraintEqualToAnchor:espIconBox.centerYAnchor],
        [_espRowValLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_espRowTitleLabel.trailingAnchor constant:8.0],

        [_mainButton.topAnchor constraintEqualToAnchor:statusCard.bottomAnchor constant:16.0],
        [_mainButton.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_mainButton.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [_mainButton.heightAnchor constraintEqualToConstant:50.0],

        [_mainBtnSpinner.centerYAnchor constraintEqualToAnchor:_mainButton.centerYAnchor],
        [_mainBtnSpinner.trailingAnchor constraintEqualToAnchor:_mainButton.titleLabel.leadingAnchor constant:-10.0],

        [_buttonSubLabel.topAnchor constraintEqualToAnchor:_mainButton.bottomAnchor constant:6.0],
        [_buttonSubLabel.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_buttonSubLabel.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],

        [_consoleHeaderLabel.topAnchor constraintEqualToAnchor:_buttonSubLabel.bottomAnchor constant:16.0],
        [_consoleHeaderLabel.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter + 14.0],

        [_consoleClearButton.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter - 6.0],
        [_consoleClearButton.centerYAnchor constraintEqualToAnchor:_consoleHeaderLabel.centerYAnchor],

        [_consoleCard.topAnchor constraintEqualToAnchor:_consoleHeaderLabel.bottomAnchor constant:6.0],
        [_consoleCard.leadingAnchor constraintEqualToAnchor:_contentColumn.leadingAnchor constant:DSGutter],
        [_consoleCard.trailingAnchor constraintEqualToAnchor:_contentColumn.trailingAnchor constant:-DSGutter],
        [_consoleCard.bottomAnchor constraintEqualToAnchor:_homeView.bottomAnchor constant:-12.0],

        [_consoleTextView.topAnchor constraintEqualToAnchor:_consoleCard.topAnchor],
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

    // ---------------------------------------------------------------- header (iOS Large Title)
    _settingTitleLabel = [[UILabel alloc] init];
    _settingTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _settingTitleLabel.textColor = DSColorTextPrimary();
    _settingTitleLabel.font = DSFontDisplay(34.0);
    _settingTitleLabel.textAlignment = NSTextAlignmentLeft;
    [_settingContentView addSubview:_settingTitleLabel];

    // ----------------------------------- Apple ID style Developer Card
    UIView *devCard = [[UIView alloc] init];
    devCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(devCard, DSRadiusCard);
    [_settingContentView addSubview:devCard];

    UIImageView *devAvatar = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"person.crop.circle.fill"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:48.0
                                                                                weight:UIImageSymbolWeightRegular]]];
    devAvatar.translatesAutoresizingMaskIntoConstraints = NO;
    devAvatar.tintColor = [UIColor systemGrayColor];
    devAvatar.contentMode = UIViewContentModeScaleAspectFit;
    [devCard addSubview:devAvatar];

    _devNameLabel = [[UILabel alloc] init];
    _devNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _devNameLabel.text = @"Dũng Lê";
    _devNameLabel.textColor = DSColorTextPrimary();
    _devNameLabel.font = DSFontTitle(20.0);
    [devCard addSubview:_devNameLabel];

    _devRoleLabel = [[UILabel alloc] init];
    _devRoleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _devRoleLabel.textColor = DSColorTextSecondary();
    _devRoleLabel.font = DSFontBody(13.0, UIFontWeightRegular);
    [devCard addSubview:_devRoleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [devAvatar.leadingAnchor constraintEqualToAnchor:devCard.leadingAnchor constant:16.0],
        [devAvatar.centerYAnchor constraintEqualToAnchor:devCard.centerYAnchor],
        [devAvatar.widthAnchor constraintEqualToConstant:52.0],
        [devAvatar.heightAnchor constraintEqualToConstant:52.0],

        [_devNameLabel.leadingAnchor constraintEqualToAnchor:devAvatar.trailingAnchor constant:14.0],
        [_devNameLabel.topAnchor constraintEqualToAnchor:devCard.topAnchor constant:16.0],
        [_devNameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:devCard.trailingAnchor constant:-16.0],

        [_devRoleLabel.leadingAnchor constraintEqualToAnchor:_devNameLabel.leadingAnchor],
        [_devRoleLabel.topAnchor constraintEqualToAnchor:_devNameLabel.bottomAnchor constant:2.0],
        [_devRoleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:devCard.trailingAnchor constant:-16.0],

        [devCard.heightAnchor constraintEqualToConstant:76.0],
    ]];

    // ------------------------------------------------------- language section
    _langHeaderLabel = [[UILabel alloc] init];
    _langHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _langHeaderLabel.textColor = DSColorTextSecondary();
    _langHeaderLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    [_settingContentView addSubview:_langHeaderLabel];

    UIView *langCard = [[UIView alloc] init];
    langCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(langCard, DSRadiusCard);
    [_settingContentView addSubview:langCard];

    _langSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[ @"Tiếng Việt", @"English" ]];
    _langSegmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
    _langSegmentedControl.selectedSegmentIndex = IsEnglish() ? 1 : 0;
    _langSegmentedControl.selectedSegmentTintColor = [UIColor colorWithWhite:0.38 alpha:1.0];
    _langSegmentedControl.backgroundColor = DSColorSurfaceHi();
    NSDictionary *segNormal = @{
        NSForegroundColorAttributeName: DSColorTextSecondary(),
        NSFontAttributeName: DSFontBody(13.0, UIFontWeightMedium),
    };
    NSDictionary *segSelected = @{
        NSForegroundColorAttributeName: DSColorTextPrimary(),
        NSFontAttributeName: DSFontBody(13.0, UIFontWeightSemibold),
    };
    [_langSegmentedControl setTitleTextAttributes:segNormal forState:UIControlStateNormal];
    [_langSegmentedControl setTitleTextAttributes:segSelected forState:UIControlStateSelected];
    [_langSegmentedControl addTarget:self action:@selector(langSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [langCard addSubview:_langSegmentedControl];

    [NSLayoutConstraint activateConstraints:@[
        [_langSegmentedControl.topAnchor constraintEqualToAnchor:langCard.topAnchor constant:10.0],
        [_langSegmentedControl.leadingAnchor constraintEqualToAnchor:langCard.leadingAnchor constant:12.0],
        [_langSegmentedControl.trailingAnchor constraintEqualToAnchor:langCard.trailingAnchor constant:-12.0],
        [_langSegmentedControl.heightAnchor constraintEqualToConstant:34.0],
        [_langSegmentedControl.bottomAnchor constraintEqualToAnchor:langCard.bottomAnchor constant:-10.0],
    ]];

    // --------------------------------------------------------- system section
    _secHeaderLabel = [[UILabel alloc] init];
    _secHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _secHeaderLabel.textColor = DSColorTextSecondary();
    _secHeaderLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    [_settingContentView addSubview:_secHeaderLabel];

    UIView *systemCard = [[UIView alloc] init];
    systemCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(systemCard, DSRadiusCard);
    [_settingContentView addSubview:systemCard];

    auto makeSecRow = ^UIView *(NSString *iconName, UIColor *iconBg, UILabel *titleLbl, UILabel *valueLbl,
                                UIView *topView, BOOL last) {
        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [systemCard addSubview:row];

        UIView *iconBox = [[UIView alloc] init];
        iconBox.translatesAutoresizingMaskIntoConstraints = NO;
        iconBox.backgroundColor = iconBg;
        iconBox.layer.cornerRadius = 7.0;
        iconBox.layer.cornerCurve = kCACornerCurveContinuous;
        [row addSubview:iconBox];

        UIImageView *iv = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:iconName
                    withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                                                    weight:UIImageSymbolWeightMedium]]];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.tintColor = UIColor.whiteColor;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [iconBox addSubview:iv];

        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.textColor = DSColorTextPrimary();
        titleLbl.font = DSFontBody(16.0, UIFontWeightRegular);
        [row addSubview:titleLbl];

        valueLbl.translatesAutoresizingMaskIntoConstraints = NO;
        valueLbl.textColor = DSColorTextSecondary();
        valueLbl.font = DSFontBody(15.0, UIFontWeightRegular);
        valueLbl.textAlignment = NSTextAlignmentRight;
        valueLbl.adjustsFontSizeToFitWidth = YES;
        valueLbl.minimumScaleFactor = 0.75;
        [row addSubview:valueLbl];

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:systemCard.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:systemCard.trailingAnchor],
            [row.heightAnchor constraintEqualToConstant:44.0],

            [iconBox.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
            [iconBox.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [iconBox.widthAnchor constraintEqualToConstant:29.0],
            [iconBox.heightAnchor constraintEqualToConstant:29.0],
            [iv.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
            [iv.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],

            [titleLbl.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:14.0],
            [titleLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [valueLbl.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
            [valueLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [valueLbl.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLbl.trailingAnchor constant:10.0],
        ]];

        if (topView) {
            [row.topAnchor constraintEqualToAnchor:topView.bottomAnchor].active = YES;
        } else {
            [row.topAnchor constraintEqualToAnchor:systemCard.topAnchor].active = YES;
        }

        if (!last) {
            UIView *hair = [[UIView alloc] init];
            hair.translatesAutoresizingMaskIntoConstraints = NO;
            hair.backgroundColor = DSColorHairline();
            [systemCard addSubview:hair];
            [NSLayoutConstraint activateConstraints:@[
                [hair.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
                [hair.leadingAnchor constraintEqualToAnchor:systemCard.leadingAnchor constant:59.0],
                [hair.trailingAnchor constraintEqualToAnchor:systemCard.trailingAnchor],
                [hair.heightAnchor constraintEqualToConstant:0.5],
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

    UIView *secRow1 = makeSecRow(@"lock.shield.fill", DSColorSuccess(), _secRow1Title, _secRow1Val, nil, NO);
    UIView *secRow2 = makeSecRow(@"speedometer", DSColorAccent(), _secRow2Title, _secRow2Val, secRow1, NO);
    UIView *secRow3 = makeSecRow(@"cpu.fill", DSColorWarning(), _secRow3Title, _secRow3Val, secRow2, YES);

    [systemCard.bottomAnchor constraintEqualToAnchor:secRow3.bottomAnchor].active = YES;

    // --------------------------------------------------------- about section
    _aboutHeaderLabel = [[UILabel alloc] init];
    _aboutHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _aboutHeaderLabel.textColor = DSColorTextSecondary();
    _aboutHeaderLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    [_settingContentView addSubview:_aboutHeaderLabel];

    UIView *infoCard = [[UIView alloc] init];
    infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    DSApplyCard(infoCard, DSRadiusCard);
    [_settingContentView addSubview:infoCard];

    auto makeRow = ^UIView *(UILabel *titleLbl, NSString *valStr, UIView *topView, BOOL last) {
        UIView *row = [[UIView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [infoCard addSubview:row];

        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.textColor = DSColorTextPrimary();
        titleLbl.font = DSFontBody(16.0, UIFontWeightRegular);
        [row addSubview:titleLbl];

        UILabel *vLabel = [[UILabel alloc] init];
        vLabel.translatesAutoresizingMaskIntoConstraints = NO;
        vLabel.text = valStr;
        vLabel.textColor = DSColorTextSecondary();
        vLabel.font = DSFontBody(15.0, UIFontWeightRegular);
        vLabel.textAlignment = NSTextAlignmentRight;
        [row addSubview:vLabel];

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor],
            [row.heightAnchor constraintEqualToConstant:44.0],
            [titleLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
            [titleLbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [vLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
            [vLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [vLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLbl.trailingAnchor constant:12.0],
        ]];

        if (topView) {
            [row.topAnchor constraintEqualToAnchor:topView.bottomAnchor].active = YES;
        } else {
            [row.topAnchor constraintEqualToAnchor:infoCard.topAnchor].active = YES;
        }

        if (!last) {
            UIView *hair = [[UIView alloc] init];
            hair.translatesAutoresizingMaskIntoConstraints = NO;
            hair.backgroundColor = DSColorHairline();
            [infoCard addSubview:hair];
            [NSLayoutConstraint activateConstraints:@[
                [hair.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
                [hair.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:16.0],
                [hair.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor],
                [hair.heightAnchor constraintEqualToConstant:0.5],
            ]];
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

    [infoCard.bottomAnchor constraintEqualToAnchor:r4.bottomAnchor].active = YES;

    // ---------------------------------- standalone iOS destructive action row
    _resetSettingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _resetSettingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _resetSettingsButton.backgroundColor = DSColorSurface();
    _resetSettingsButton.layer.cornerRadius = DSRadiusCard;
    _resetSettingsButton.layer.cornerCurve = kCACornerCurveContinuous;
    _resetSettingsButton.titleLabel.font = DSFontBody(16.0, UIFontWeightRegular);
    [_resetSettingsButton setTitleColor:DSColorDanger() forState:UIControlStateNormal];
    [_resetSettingsButton addTarget:self action:@selector(resetSettingsButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_settingContentView addSubview:_resetSettingsButton];

    // ------------------------------------------------------------ table footer
    _noteLabel = [[UILabel alloc] init];
    _noteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _noteLabel.textColor = DSColorTextSecondary();
    _noteLabel.font = DSFontBody(12.5, UIFontWeightRegular);
    _noteLabel.numberOfLines = 0;
    _noteLabel.textAlignment = NSTextAlignmentLeft;
    [_settingContentView addSubview:_noteLabel];

    // ---------------------------------------------------------------- layout
    [NSLayoutConstraint activateConstraints:@[
        [_settingTitleLabel.topAnchor constraintEqualToAnchor:_settingContentView.topAnchor constant:8.0],
        [_settingTitleLabel.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [_settingTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [devCard.topAnchor constraintEqualToAnchor:_settingTitleLabel.bottomAnchor constant:12.0],
        [devCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [devCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [_langHeaderLabel.topAnchor constraintEqualToAnchor:devCard.bottomAnchor constant:DSSectionGap],
        [_langHeaderLabel.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter + 14.0],

        [langCard.topAnchor constraintEqualToAnchor:_langHeaderLabel.bottomAnchor constant:6.0],
        [langCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [langCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [_secHeaderLabel.topAnchor constraintEqualToAnchor:langCard.bottomAnchor constant:DSSectionGap],
        [_secHeaderLabel.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter + 14.0],

        [systemCard.topAnchor constraintEqualToAnchor:_secHeaderLabel.bottomAnchor constant:6.0],
        [systemCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [systemCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [_aboutHeaderLabel.topAnchor constraintEqualToAnchor:systemCard.bottomAnchor constant:DSSectionGap],
        [_aboutHeaderLabel.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter + 14.0],

        [infoCard.topAnchor constraintEqualToAnchor:_aboutHeaderLabel.bottomAnchor constant:6.0],
        [infoCard.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [infoCard.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],

        [_resetSettingsButton.topAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:DSSectionGap],
        [_resetSettingsButton.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter],
        [_resetSettingsButton.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter],
        [_resetSettingsButton.heightAnchor constraintEqualToConstant:46.0],

        [_noteLabel.topAnchor constraintEqualToAnchor:_resetSettingsButton.bottomAnchor constant:8.0],
        [_noteLabel.leadingAnchor constraintEqualToAnchor:_settingContentView.leadingAnchor constant:DSGutter + 14.0],
        [_noteLabel.trailingAnchor constraintEqualToAnchor:_settingContentView.trailingAnchor constant:-DSGutter - 14.0],
        [_noteLabel.bottomAnchor constraintEqualToAnchor:_settingContentView.bottomAnchor constant:-24.0],
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

- (void)clearConsoleTapped:(id)sender
{
    if (_impactFeedbackGenerator) [_impactFeedbackGenerator impactOccurred];
    _consoleLogStorage = [[NSMutableAttributedString alloc] init];
    _consoleTextView.attributedText = _consoleLogStorage;
    BOOL isEN = IsEnglish();
    [self appendConsoleLog:@"SYS" message:(isEN ? @"Console cleared. System ready." : @"Đã xoá nhật ký. Hệ thống sẵn sàng.") tagColor:DSColorInfo()];
}

- (void)quickLangTapped:(id)sender
{
    NSString *newLang = IsEnglish() ? @"vi" : @"en";
    [[NSUserDefaults standardUserDefaults] setObject:newLang forKey:@"AppLanguage"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (_langSegmentedControl) {
        _langSegmentedControl.selectedSegmentIndex = [newLang isEqualToString:@"en"] ? 1 : 0;
    }
    if (_impactFeedbackGenerator) [_impactFeedbackGenerator impactOccurred];
    [UIView transitionWithView:self.view duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self applyLanguageTexts];
    } completion:nil];
}

- (void)resetSettingsButtonTapped:(id)sender
{
    if (_impactFeedbackGenerator) [_impactFeedbackGenerator impactOccurred];
    BOOL isEN = IsEnglish();
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"DarkPubg"
                                                                             message:(isEN ? @"Reset all settings to defaults?" : @"Bạn có muốn đặt lại toàn bộ cài đặt không?")
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:(isEN ? @"Cancel" : @"Huỷ") style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:(isEN ? @"Reset" : @"Đặt lại") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self resetUserDefaults];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
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
    if (_quickLangButton) {
        [_quickLangButton setTitle:(isEN ? @"EN" : @"VI") forState:UIControlStateNormal];
    }
    _homeSysSectionLabel.text = isEN ? @"SYSTEM" : @"HỆ THỐNG";
    _iosRowTitleLabel.text = isEN ? @"iOS Version" : @"Phiên bản iOS";
    _kernelRowTitleLabel.text = @"DarkSword Kernel";
    _espRowTitleLabel.text = isEN ? @"ESP Graphics" : @"Đồ hoạ ESP";
    _espRowValLabel.text = @"120 FPS Metal";

    NSString *iosVer = @"";
    NSString *dsStatus = @"";
    BOOL isSupported = CheckDarkSwordSupport(&iosVer, &dsStatus);
    _iosVersionLabel.text = iosVer;

    UIColor *stateColor = isSupported ? DSColorSuccess() : DSColorDanger();
    if (_statusIconBox) _statusIconBox.backgroundColor = stateColor;
    if (_statusIconView) {
        _statusIconView.image = [UIImage systemImageNamed:(isSupported ? @"checkmark.shield.fill" : @"xmark.shield.fill")
                                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                                                                        weight:UIImageSymbolWeightMedium]];
    }
    _dsStatusLabel.textColor = stateColor;
    _dsStatusLabel.text = isSupported
        ? (isEN ? @"Supported" : @"Đã hỗ trợ")
        : (isEN ? @"Unsupported" : @"Chưa hỗ trợ");

    if (_isRemoteHUDActive) {
        [_mainButton setTitle:isEN ? @"Stop HUD" : @"Dừng HUD" forState:UIControlStateNormal];
        _buttonSubLabel.text = isEN ? @"DarkPubg is currently active in game" : @"DarkPubg đang hoạt động trong game";
    } else if (_isHUDLaunching) {
        // Retain dynamic percentage while loading
    } else {
        [_mainButton setTitle:isEN ? @"Open HUD" : @"Mở HUD" forState:UIControlStateNormal];
        _buttonSubLabel.text = isEN ? @"Tap to launch in-game ESP menu" : @"Nhấn để bật menu ESP trong game";
    }

    _consoleHeaderLabel.text = isEN ? @"ACTIVITY LOG" : @"NHẬT KÝ HOẠT ĐỘNG";
    if (_consoleClearButton) {
        [_consoleClearButton setTitle:(isEN ? @"Clear" : @"Xoá") forState:UIControlStateNormal];
    }

    // Setting tab
    _settingTitleLabel.text = isEN ? @"Settings" : @"Cài đặt";
    _langHeaderLabel.text = isEN ? @"LANGUAGE" : @"NGÔN NGỮ";

    // Developer
    _devNameLabel.text = @"Dũng Lê";
    if (_devRoleLabel) {
        _devRoleLabel.text = isEN ? @"Developer • DarkSword Kernel" : @"Nhà phát triển • DarkSword Kernel";
    }
    if (_resetSettingsButton) {
        [_resetSettingsButton setTitle:(isEN ? @"Reset Settings" : @"Đặt lại cài đặt") forState:UIControlStateNormal];
    }

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
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
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
        [self->_mainButton setTitleColor:DSColorOnAccent() forState:UIControlStateNormal];
        self->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
    });
}

- (void)doEnableHUD
{
    if ([self isHUDEnabled]) return;
    if (_isHUDLaunching) return;

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

    if (DSBridgeHUDIntentSet()) {
        // A background restore already owns the enable path (intent persisted,
        // SpringBoard handshake still running). Do not queue a second enable;
        // just attach this tap to the same result.
        DSBridgeRestoreHUD();
    } else {
        [self setHUDEnabled:YES];
    }

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

    // The launch notification is the only thing that clears this spinner. If
    // the enable fails before posting it, the button would stay frozen at
    // "LAUNCHING..." forever. Re-sync from actual state after 20s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_isHUDLaunching) return;
        if ([strongSelf isHUDEnabled]) return;
        strongSelf->_isHUDLaunching = NO;
        [strongSelf->_mainBtnSpinner stopAnimating];
        strongSelf->_mainButton.contentEdgeInsets = UIEdgeInsetsZero;
        [strongSelf reloadMainButtonState];
        [strongSelf.backgroundView setUserInteractionEnabled:YES];
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

    // "EXIT HUD" only when the overlay is actually attached. An in-flight
    // background restore is handled inside doEnableHUD, which attaches to the
    // existing enable instead of starting a second one.
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
