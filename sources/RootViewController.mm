//
//  RootViewController.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <notify.h>
#import <QuartzCore/QuartzCore.h>

#import "HUDHelper.h"
#import "DSBridge.h"
#import "MainButton.h"
#import "MainApplication.h"
#import "HUDPresetPosition.h"
#import "RootViewController.h"
#import "UIApplication+Private.h"
#import "HUDRootViewController.h"

#define HUD_TRANSITION_DURATION 0.25

static BOOL _gShouldToggleHUDAfterLaunch = NO;
static const CGFloat _gTopButtonConstraintsConstantCompact = 46.f;
static const CGFloat _gTopButtonConstraintsConstantRegular = 28.f;
static const CGFloat _gTopButtonConstraintsConstantRegularPad = 46.f;
static const CGFloat _gAuthorLabelBottomConstraintConstantCompact = -20.f;
static const CGFloat _gAuthorLabelBottomConstraintConstantRegular = -80.f;

@implementation RootViewController {
    NSMutableDictionary *_userDefaults;
    CAGradientLayer *_backgroundGradient;
    MainButton *_mainButton;
    UIButton *_settingsButton;
    UIButton *_topLeftButton;
    UIButton *_topRightButton;
    UIButton *_topCenterButton;
    UIButton *_topCenterMostButton;
    UILabel *_authorLabel;
    BOOL _supportsCenterMost;
    NSLayoutConstraint *_topLeftConstraint;
    NSLayoutConstraint *_topRightConstraint;
    NSLayoutConstraint *_topCenterConstraint;
    NSLayoutConstraint *_authorLabelBottomConstraint;
    BOOL _isRemoteHUDActive;
    HUDRootViewController *_localHUDRootViewController;  // Only for debugging
    UIImpactFeedbackGenerator *_impactFeedbackGenerator;
#if USE_DARKSWORD
    UIView *_dsProgressOverlay;
    UIProgressView *_dsProgressBar;
    UILabel *_dsProgressLabel;
#endif

    UIView *_headerContainer;
    UILabel *_appTitleLabel;
    UILabel *_appSubtitleLabel;
    UIView *_badgeView;
    UIView *_badgeDot;
    UILabel *_badgeLabel;

    UIView *_statusCardView;
    UILabel *_statusDetailLabel;

    UIView *_consoleCardView;
    UITextView *_consoleTextView;
    NSMutableAttributedString *_consoleLogContent;
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
    self.view.backgroundColor = [UIColor colorWithRed:13/255.0 green:15/255.0 blue:20/255.0 alpha:1.0];

    self.backgroundView = [[UIView alloc] initWithFrame:bounds];
    self.backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundView.backgroundColor = [UIColor colorWithRed:13/255.0 green:15/255.0 blue:20/255.0 alpha:1.0];

    [self.view addSubview:self.backgroundView];

    UILayoutGuide *safeArea = self.backgroundView.safeAreaLayoutGuide;

    // 1. Header Container
    _headerContainer = [[UIView alloc] init];
    _headerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backgroundView addSubview:_headerContainer];

    _appTitleLabel = [[UILabel alloc] init];
    _appTitleLabel.text = @"DarkPubg ESP";
    _appTitleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    _appTitleLabel.textColor = [UIColor whiteColor];
    _appTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerContainer addSubview:_appTitleLabel];

    _appSubtitleLabel = [[UILabel alloc] init];
    _appSubtitleLabel.text = @"Kernel Memory Radar • iOS";
    _appSubtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _appSubtitleLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
    _appSubtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerContainer addSubview:_appSubtitleLabel];

    // Status Pill Badge
    _badgeView = [[UIView alloc] init];
    _badgeView.backgroundColor = [UIColor colorWithRed:22/255.0 green:25/255.0 blue:34/255.0 alpha:1.0];
    _badgeView.layer.cornerRadius = 14.0;
    _badgeView.layer.borderWidth = 1.0;
    _badgeView.layer.borderColor = [UIColor colorWithRed:35/255.0 green:39/255.0 blue:54/255.0 alpha:1.0].CGColor;
    _badgeView.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerContainer addSubview:_badgeView];

    _badgeDot = [[UIView alloc] init];
    _badgeDot.backgroundColor = [UIColor colorWithRed:148/255.0 green:163/255.0 blue:184/255.0 alpha:1.0];
    _badgeDot.layer.cornerRadius = 4.0;
    _badgeDot.translatesAutoresizingMaskIntoConstraints = NO;
    [_badgeView addSubview:_badgeDot];

    _badgeLabel = [[UILabel alloc] init];
    _badgeLabel.text = @"CHƯA BẬT";
    _badgeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _badgeLabel.textColor = [UIColor colorWithRed:148/255.0 green:163/255.0 blue:184/255.0 alpha:1.0];
    _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_badgeView addSubview:_badgeLabel];

    // 2. Status Card View
    _statusCardView = [[UIView alloc] init];
    _statusCardView.backgroundColor = [UIColor colorWithRed:22/255.0 green:25/255.0 blue:34/255.0 alpha:1.0];
    _statusCardView.layer.cornerRadius = 16.0;
    _statusCardView.layer.borderWidth = 1.0;
    _statusCardView.layer.borderColor = [UIColor colorWithRed:35/255.0 green:39/255.0 blue:54/255.0 alpha:1.0].CGColor;
    _statusCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backgroundView addSubview:_statusCardView];

    UIImageView *gameIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gamecontroller.fill"]];
    gameIcon.tintColor = [UIColor colorWithRed:56/255.0 green:189/255.0 blue:248/255.0 alpha:1.0];
    gameIcon.contentMode = UIViewContentModeScaleAspectFit;
    gameIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusCardView addSubview:gameIcon];

    UILabel *gameTitleLabel = [[UILabel alloc] init];
    gameTitleLabel.text = @"Mục tiêu: PUBG Mobile";
    gameTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    gameTitleLabel.textColor = [UIColor whiteColor];
    gameTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusCardView addSubview:gameTitleLabel];

    UILabel *gameSubLabel = [[UILabel alloc] init];
    gameSubLabel.text = @"ShadowTrackerExtra";
    gameSubLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    gameSubLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
    gameSubLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusCardView addSubview:gameSubLabel];

    UIView *cardDivider = [[UIView alloc] init];
    cardDivider.backgroundColor = [UIColor colorWithRed:35/255.0 green:39/255.0 blue:54/255.0 alpha:1.0];
    cardDivider.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusCardView addSubview:cardDivider];

    UIImageView *statusIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.path.ecg"]];
    statusIcon.tintColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
    statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusCardView addSubview:statusIcon];

    _statusDetailLabel = [[UILabel alloc] init];
    _statusDetailLabel.text = @"Sẵn sàng kết nối bộ nhớ kernel...";
    _statusDetailLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _statusDetailLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
    _statusDetailLabel.numberOfLines = 0;
    _statusDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusCardView addSubview:_statusDetailLabel];

    // 3. Main Action Button
    _mainButton = [MainButton buttonWithType:UIButtonTypeSystem];
    [_mainButton setTintColor:[UIColor whiteColor]];
    [_mainButton addTarget:self action:@selector(tapMainButton:) forControlEvents:UIControlEventTouchUpInside];
    _mainButton.layer.cornerRadius = 16.0;
    _mainButton.layer.masksToBounds = YES;
    _mainButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backgroundView addSubview:_mainButton];

    // 4. Console Log Card
    _consoleCardView = [[UIView alloc] init];
    _consoleCardView.backgroundColor = [UIColor colorWithRed:22/255.0 green:25/255.0 blue:34/255.0 alpha:1.0];
    _consoleCardView.layer.cornerRadius = 14.0;
    _consoleCardView.layer.borderWidth = 1.0;
    _consoleCardView.layer.borderColor = [UIColor colorWithRed:35/255.0 green:39/255.0 blue:54/255.0 alpha:1.0].CGColor;
    _consoleCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backgroundView addSubview:_consoleCardView];

    UIView *dot1 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    dot1.backgroundColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0];
    dot1.layer.cornerRadius = 4.0;
    dot1.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:dot1];

    UIView *dot2 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    dot2.backgroundColor = [UIColor colorWithRed:245/255.0 green:158/255.0 blue:11/255.0 alpha:1.0];
    dot2.layer.cornerRadius = 4.0;
    dot2.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:dot2];

    UIView *dot3 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    dot3.backgroundColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
    dot3.layer.cornerRadius = 4.0;
    dot3.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:dot3];

    UILabel *consoleTitle = [[UILabel alloc] init];
    consoleTitle.text = @"NHẬT KÝ TẠO HUD (CONSOLE LOGS)";
    consoleTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    consoleTitle.textColor = [UIColor colorWithRed:148/255.0 green:163/255.0 blue:184/255.0 alpha:1.0];
    consoleTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:consoleTitle];

    UILabel *liveLabel = [[UILabel alloc] init];
    liveLabel.text = @"● LIVE";
    liveLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    liveLabel.textColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
    liveLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:liveLabel];

    UIView *consoleDivider = [[UIView alloc] init];
    consoleDivider.backgroundColor = [UIColor colorWithRed:35/255.0 green:39/255.0 blue:54/255.0 alpha:1.0];
    consoleDivider.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:consoleDivider];

    _consoleTextView = [[UITextView alloc] init];
    _consoleTextView.backgroundColor = [UIColor colorWithRed:15/255.0 green:17/255.0 blue:23/255.0 alpha:1.0];
    _consoleTextView.layer.cornerRadius = 8.0;
    _consoleTextView.layer.borderWidth = 1.0;
    _consoleTextView.layer.borderColor = [UIColor colorWithRed:31/255.0 green:35/255.0 blue:46/255.0 alpha:1.0].CGColor;
    _consoleTextView.editable = NO;
    _consoleTextView.selectable = YES;
    _consoleTextView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _consoleTextView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    _consoleTextView.textColor = [UIColor colorWithRed:226/255.0 green:232/255.0 blue:240/255.0 alpha:1.0];
    _consoleTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [_consoleCardView addSubview:_consoleTextView];

    // 5. Author Label (Credits)
    _authorLabel = [[UILabel alloc] init];
    _authorLabel.numberOfLines = 0;
    _authorLabel.textAlignment = NSTextAlignmentCenter;
    _authorLabel.textColor = [UIColor colorWithRed:100/255.0 green:116/255.0 blue:139/255.0 alpha:1.0];
    _authorLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backgroundView addSubview:_authorLabel];

    _authorLabelBottomConstraint = [_authorLabel.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-16.0f];

    [NSLayoutConstraint activateConstraints:@[
        // Header
        [_headerContainer.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:16],
        [_headerContainer.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [_headerContainer.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],

        [_appTitleLabel.topAnchor constraintEqualToAnchor:_headerContainer.topAnchor],
        [_appTitleLabel.leadingAnchor constraintEqualToAnchor:_headerContainer.leadingAnchor],

        [_appSubtitleLabel.topAnchor constraintEqualToAnchor:_appTitleLabel.bottomAnchor constant:4],
        [_appSubtitleLabel.leadingAnchor constraintEqualToAnchor:_headerContainer.leadingAnchor],
        [_appSubtitleLabel.bottomAnchor constraintEqualToAnchor:_headerContainer.bottomAnchor],

        [_badgeView.trailingAnchor constraintEqualToAnchor:_headerContainer.trailingAnchor],
        [_badgeView.centerYAnchor constraintEqualToAnchor:_headerContainer.centerYAnchor],
        [_badgeView.heightAnchor constraintEqualToConstant:28],

        [_badgeDot.leadingAnchor constraintEqualToAnchor:_badgeView.leadingAnchor constant:10],
        [_badgeDot.centerYAnchor constraintEqualToAnchor:_badgeView.centerYAnchor],
        [_badgeDot.widthAnchor constraintEqualToConstant:8],
        [_badgeDot.heightAnchor constraintEqualToConstant:8],

        [_badgeLabel.leadingAnchor constraintEqualToAnchor:_badgeDot.trailingAnchor constant:6],
        [_badgeLabel.trailingAnchor constraintEqualToAnchor:_badgeView.trailingAnchor constant:-10],
        [_badgeLabel.centerYAnchor constraintEqualToAnchor:_badgeView.centerYAnchor],

        // Status Card
        [_statusCardView.topAnchor constraintEqualToAnchor:_headerContainer.bottomAnchor constant:24],
        [_statusCardView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [_statusCardView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],

        [gameIcon.leadingAnchor constraintEqualToAnchor:_statusCardView.leadingAnchor constant:16],
        [gameIcon.topAnchor constraintEqualToAnchor:_statusCardView.topAnchor constant:14],
        [gameIcon.widthAnchor constraintEqualToConstant:20],
        [gameIcon.heightAnchor constraintEqualToConstant:20],

        [gameTitleLabel.leadingAnchor constraintEqualToAnchor:gameIcon.trailingAnchor constant:12],
        [gameTitleLabel.topAnchor constraintEqualToAnchor:_statusCardView.topAnchor constant:12],
        [gameTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusCardView.trailingAnchor constant:-16],

        [gameSubLabel.leadingAnchor constraintEqualToAnchor:gameTitleLabel.leadingAnchor],
        [gameSubLabel.topAnchor constraintEqualToAnchor:gameTitleLabel.bottomAnchor constant:2],

        [cardDivider.topAnchor constraintEqualToAnchor:gameSubLabel.bottomAnchor constant:12],
        [cardDivider.leadingAnchor constraintEqualToAnchor:_statusCardView.leadingAnchor constant:16],
        [cardDivider.trailingAnchor constraintEqualToAnchor:_statusCardView.trailingAnchor constant:-16],
        [cardDivider.heightAnchor constraintEqualToConstant:1],

        [statusIcon.leadingAnchor constraintEqualToAnchor:_statusCardView.leadingAnchor constant:16],
        [statusIcon.topAnchor constraintEqualToAnchor:cardDivider.bottomAnchor constant:14],
        [statusIcon.widthAnchor constraintEqualToConstant:20],
        [statusIcon.heightAnchor constraintEqualToConstant:20],

        [_statusDetailLabel.leadingAnchor constraintEqualToAnchor:statusIcon.trailingAnchor constant:12],
        [_statusDetailLabel.topAnchor constraintEqualToAnchor:cardDivider.bottomAnchor constant:12],
        [_statusDetailLabel.trailingAnchor constraintEqualToAnchor:_statusCardView.trailingAnchor constant:-16],
        [_statusDetailLabel.bottomAnchor constraintEqualToAnchor:_statusCardView.bottomAnchor constant:-14],

        // Main Action Button
        [_mainButton.topAnchor constraintEqualToAnchor:_statusCardView.bottomAnchor constant:24],
        [_mainButton.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [_mainButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],
        [_mainButton.heightAnchor constraintEqualToConstant:56],

        // Console Log Card
        [_consoleCardView.topAnchor constraintEqualToAnchor:_mainButton.bottomAnchor constant:20],
        [_consoleCardView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [_consoleCardView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],
        [_consoleCardView.bottomAnchor constraintEqualToAnchor:_authorLabel.topAnchor constant:-12],

        [dot1.leadingAnchor constraintEqualToAnchor:_consoleCardView.leadingAnchor constant:12],
        [dot1.topAnchor constraintEqualToAnchor:_consoleCardView.topAnchor constant:12],
        [dot1.widthAnchor constraintEqualToConstant:8],
        [dot1.heightAnchor constraintEqualToConstant:8],

        [dot2.leadingAnchor constraintEqualToAnchor:dot1.trailingAnchor constant:5],
        [dot2.centerYAnchor constraintEqualToAnchor:dot1.centerYAnchor],
        [dot2.widthAnchor constraintEqualToConstant:8],
        [dot2.heightAnchor constraintEqualToConstant:8],

        [dot3.leadingAnchor constraintEqualToAnchor:dot2.trailingAnchor constant:5],
        [dot3.centerYAnchor constraintEqualToAnchor:dot1.centerYAnchor],
        [dot3.widthAnchor constraintEqualToConstant:8],
        [dot3.heightAnchor constraintEqualToConstant:8],

        [consoleTitle.leadingAnchor constraintEqualToAnchor:dot3.trailingAnchor constant:10],
        [consoleTitle.centerYAnchor constraintEqualToAnchor:dot1.centerYAnchor],

        [liveLabel.trailingAnchor constraintEqualToAnchor:_consoleCardView.trailingAnchor constant:-12],
        [liveLabel.centerYAnchor constraintEqualToAnchor:dot1.centerYAnchor],

        [consoleDivider.topAnchor constraintEqualToAnchor:dot1.bottomAnchor constant:10],
        [consoleDivider.leadingAnchor constraintEqualToAnchor:_consoleCardView.leadingAnchor constant:10],
        [consoleDivider.trailingAnchor constraintEqualToAnchor:_consoleCardView.trailingAnchor constant:-10],
        [consoleDivider.heightAnchor constraintEqualToConstant:1],

        [_consoleTextView.topAnchor constraintEqualToAnchor:consoleDivider.bottomAnchor constant:8],
        [_consoleTextView.leadingAnchor constraintEqualToAnchor:_consoleCardView.leadingAnchor constant:8],
        [_consoleTextView.trailingAnchor constraintEqualToAnchor:_consoleCardView.trailingAnchor constant:-8],
        [_consoleTextView.bottomAnchor constraintEqualToAnchor:_consoleCardView.bottomAnchor constant:-8],

        // Author Label
        _authorLabelBottomConstraint,
        [_authorLabel.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [_authorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safeArea.leadingAnchor constant:20],
        [_authorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safeArea.trailingAnchor constant:-20],
    ]];

    UITapGestureRecognizer *authorTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAuthorLabel:)];
    [_authorLabel setUserInteractionEnabled:YES];
    [_authorLabel addGestureRecognizer:authorTapGesture];

    [self verticalSizeClassUpdated];
    [self reloadMainButtonState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _supportsCenterMost = CGRectGetMinY(self.view.window.safeAreaLayoutGuide.layoutFrame) >= 51;
    if (_backgroundGradient) {
        _backgroundGradient.frame = self.backgroundView.bounds;
    }
}

- (void)appendLog:(NSString *)message type:(NSString *)type
{
    if (!_consoleTextView) {
        return;
    }
    if (!_consoleLogContent) {
        _consoleLogContent = [[NSMutableAttributedString alloc] init];
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss"];
    NSString *timeStr = [formatter stringFromDate:[NSDate date]];

    UIColor *tagColor = [UIColor colorWithRed:56/255.0 green:189/255.0 blue:248/255.0 alpha:1.0]; // cyan default
    if ([type isEqualToString:@"SUCCESS"] || [type isEqualToString:@"ACTIVE"] || [type isEqualToString:@"HUD"] || [type isEqualToString:@"READY"]) {
        tagColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0]; // teal
    } else if ([type isEqualToString:@"ERROR"] || [type isEqualToString:@"STOP"]) {
        tagColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0]; // red
    } else if ([type isEqualToString:@"WARN"] || [type isEqualToString:@"SCAN"] || [type isEqualToString:@"ACTION"]) {
        tagColor = [UIColor colorWithRed:251/255.0 green:191/255.0 blue:36/255.0 alpha:1.0]; // yellow
    }

    NSDictionary *timeAttrs = @{
        NSForegroundColorAttributeName: [UIColor colorWithRed:100/255.0 green:116/255.0 blue:139/255.0 alpha:1.0],
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular]
    };
    NSDictionary *tagAttrs = @{
        NSForegroundColorAttributeName: tagColor,
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightBold]
    };
    NSDictionary *msgAttrs = @{
        NSForegroundColorAttributeName: [UIColor colorWithRed:226/255.0 green:232/255.0 blue:240/255.0 alpha:1.0],
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular]
    };

    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%@] ", timeStr] attributes:timeAttrs];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%@] ", type] attributes:tagAttrs]];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", message] attributes:msgAttrs]];

    [_consoleLogContent appendAttributedString:line];
    _consoleTextView.attributedText = _consoleLogContent;

    if (_consoleLogContent.length > 0) {
        NSRange bottomRange = NSMakeRange(_consoleLogContent.length - 1, 1);
        [_consoleTextView scrollRangeToVisible:bottomRange];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _impactFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];

    [self registerNotifications];

    [self appendLog:@"Khởi động hệ thống DarkPubg ESP" type:@"INIT"];
    [self appendLog:@"Sẵn sàng kết nối bộ nhớ ShadowTrackerExtra" type:@"KERNEL"];
    if (_isRemoteHUDActive) {
        [self appendLog:@"HUD Overlay đang hoạt động (Active)" type:@"HUD"];
    } else {
        [self appendLog:@"Chờ người dùng bấm BẬT ESP để tạo Overlay" type:@"READY"];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self toggleHUDAfterLaunch];
}

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
#if !USE_DARKSWORD
        // Stock TrollStore flow: toggle then background. Under Apple Development
        // this looks exactly like a black-screen flash-crash on icon/URL launch.
        [[UIApplication sharedApplication] suspend];
#endif
    }
}

- (void)toggleOnHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        if (!_isRemoteHUDActive) {
            [self tapMainButton:_mainButton];
        }
#if !USE_DARKSWORD
        [[UIApplication sharedApplication] suspend];
#endif
    }
}

- (void)toggleOffHUDAfterLaunch {
    if ([RootViewController shouldToggleHUDAfterLaunch]) {
        [RootViewController setShouldToggleHUDAfterLaunch:NO];
        if (_isRemoteHUDActive) {
            [self tapMainButton:_mainButton];
        }
#if !USE_DARKSWORD
        [[UIApplication sharedApplication] suspend];
#endif
    }
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Developer Area", nil) message:NSLocalizedString(@"Choose an action below.", nil) preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Dismiss", nil) style:UIAlertActionStyleCancel handler:nil]];
        [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Reset Settings", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self resetUserDefaults];
        }]];
        [self presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)resetUserDefaults
{
    // Reset user defaults
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleIdentifier) {
        [GetStandardUserDefaults() removePersistentDomainForName:bundleIdentifier];
        [GetStandardUserDefaults() synchronize];
    }

    // Reset custom user defaults
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) error:nil];
    if (removed)
    {
        // Terminate HUD
        [self setHUDEnabled:NO];

        // Terminate App
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
    BOOL saved = [_userDefaults writeToFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) atomically:YES];
    if (!saved) {
        log_error(OS_LOG_DEFAULT, "Failed to save HUD preferences at %{public}@",
                  JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH));
        return;
    }
    notify_post(NOTIFY_RELOAD_HUD);
}

- (BOOL)isLandscapeOrientation
{
    UIInterfaceOrientation orientation;
    orientation = self.view.window.windowScene.interfaceOrientation;
    BOOL isLandscape;
    if (orientation == UIInterfaceOrientationUnknown) {
        isLandscape = CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape(orientation);
    }
    return isLandscape;
}

- (HUDUserDefaultsKey)selectedModeKeyForCurrentOrientation
{
    return [self isLandscapeOrientation] ? HUDUserDefaultsKeySelectedModeLandscape : HUDUserDefaultsKeySelectedMode;
}

- (HUDPresetPosition)selectedModeForCurrentOrientation
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:[self selectedModeKeyForCurrentOrientation]];
    return mode != nil ? (HUDPresetPosition)[mode integerValue] : HUDPresetPositionTopCenter;
}

- (void)setSelectedModeForCurrentOrientation:(HUDPresetPosition)selectedMode
{
    [self loadUserDefaults:NO];
    // Remove some keys that are not persistent
    if ([self isLandscapeOrientation]) {
        [_userDefaults removeObjectForKey:HUDUserDefaultsKeyCurrentLandscapePositionY];
    } else {
        [_userDefaults removeObjectForKey:HUDUserDefaultsKeyCurrentPositionY];
    }
    [_userDefaults setObject:@(selectedMode) forKey:[self selectedModeKeyForCurrentOrientation]];
    [self saveUserDefaults];
}

- (BOOL)passthroughMode
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyPassthroughMode];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setPassthroughMode:(BOOL)passthroughMode
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(passthroughMode) forKey:HUDUserDefaultsKeyPassthroughMode];
    [self saveUserDefaults];
}

- (BOOL)singleLineMode
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeySingleLineMode];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setSingleLineMode:(BOOL)singleLineMode
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(singleLineMode) forKey:HUDUserDefaultsKeySingleLineMode];
    [self saveUserDefaults];
}

- (BOOL)usesBitrate
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesBitrate];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setUsesBitrate:(BOOL)usesBitrate
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(usesBitrate) forKey:HUDUserDefaultsKeyUsesBitrate];
    [self saveUserDefaults];
}

- (BOOL)usesArrowPrefixes
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesArrowPrefixes];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setUsesArrowPrefixes:(BOOL)usesArrowPrefixes
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(usesArrowPrefixes) forKey:HUDUserDefaultsKeyUsesArrowPrefixes];
    [self saveUserDefaults];
}

- (BOOL)usesLargeFont
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesLargeFont];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setUsesLargeFont:(BOOL)usesLargeFont
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(usesLargeFont) forKey:HUDUserDefaultsKeyUsesLargeFont];
    [self saveUserDefaults];
}

- (BOOL)usesRotation
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesRotation];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setUsesRotation:(BOOL)usesRotation
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(usesRotation) forKey:HUDUserDefaultsKeyUsesRotation];
    [self saveUserDefaults];
}

- (BOOL)usesInvertedColor
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesInvertedColor];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setUsesInvertedColor:(BOOL)usesInvertedColor
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(usesInvertedColor) forKey:HUDUserDefaultsKeyUsesInvertedColor];
    [self saveUserDefaults];
}

- (BOOL)keepInPlace
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyKeepInPlace];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setKeepInPlace:(BOOL)keepInPlace
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(keepInPlace) forKey:HUDUserDefaultsKeyKeepInPlace];
    [self saveUserDefaults];
}

- (BOOL)hideAtSnapshot
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyHideAtSnapshot];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setHideAtSnapshot:(BOOL)hideAtSnapshot
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(hideAtSnapshot) forKey:HUDUserDefaultsKeyHideAtSnapshot];
    [self saveUserDefaults];
}

- (BOOL)displayMode
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:HUDUserDefaultsKeyDisplayMode];
    return mode != nil ? [mode boolValue] : NO;
}

- (void)setDisplayMode:(BOOL)displayMode
{
    [self loadUserDefaults:NO];
    [_userDefaults setObject:@(displayMode) forKey:HUDUserDefaultsKeyDisplayMode];
    [self saveUserDefaults];
}

- (void)reloadMainButtonState
{
    _isRemoteHUDActive = [self isHUDEnabled];

    __weak typeof(self) weakSelf = self;
    [UIView transitionWithView:self.backgroundView duration:HUD_TRANSITION_DURATION options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (strongSelf->_isRemoteHUDActive) {
            [strongSelf->_mainButton setTitle:@"TẮT ESP (STOP)" forState:UIControlStateNormal];
            [strongSelf->_mainButton setImage:[UIImage systemImageNamed:@"stop.fill"] forState:UIControlStateNormal];
            if (@available(iOS 15.0, *)) {
                UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
                config.baseBackgroundColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0];
                config.baseForegroundColor = [UIColor whiteColor];
                config.image = [UIImage systemImageNamed:@"stop.fill"];
                config.imagePadding = 10;
                config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
                [config setTitleTextAttributesTransformer:^NSDictionary<NSAttributedStringKey,id> * _Nonnull(NSDictionary<NSAttributedStringKey,id> * _Nonnull textAttributes) {
                    NSMutableDictionary *attrs = [textAttributes mutableCopy];
                    attrs[NSFontAttributeName] = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
                    return attrs;
                }];
                [strongSelf->_mainButton setConfiguration:config];
            } else {
                strongSelf->_mainButton.backgroundColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0];
            }
            strongSelf->_badgeDot.backgroundColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
            strongSelf->_badgeLabel.text = @"HOẠT ĐỘNG";
            strongSelf->_badgeLabel.textColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
        } else {
            [strongSelf->_mainButton setTitle:@"BẬT ESP (START)" forState:UIControlStateNormal];
            [strongSelf->_mainButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
            if (@available(iOS 15.0, *)) {
                UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
                config.baseBackgroundColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
                config.baseForegroundColor = [UIColor whiteColor];
                config.image = [UIImage systemImageNamed:@"play.fill"];
                config.imagePadding = 10;
                config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
                [config setTitleTextAttributesTransformer:^NSDictionary<NSAttributedStringKey,id> * _Nonnull(NSDictionary<NSAttributedStringKey,id> * _Nonnull textAttributes) {
                    NSMutableDictionary *attrs = [textAttributes mutableCopy];
                    attrs[NSFontAttributeName] = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
                    return attrs;
                }];
                [strongSelf->_mainButton setConfiguration:config];
            } else {
                strongSelf->_mainButton.backgroundColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
            }
            strongSelf->_badgeDot.backgroundColor = [UIColor colorWithRed:148/255.0 green:163/255.0 blue:184/255.0 alpha:1.0];
            strongSelf->_badgeLabel.text = @"CHƯA BẬT";
            strongSelf->_badgeLabel.textColor = [UIColor colorWithRed:148/255.0 green:163/255.0 blue:184/255.0 alpha:1.0];
        }

        NSString *bridgeError = DSBridgeCompiledIn() ? DSBridgeLastError() : @"";
        [strongSelf loadUserDefaults:NO];
        BOOL showESP = [strongSelf->_userDefaults[HUDUserDefaultsKeyShowESPBox] boolValue];
        NSString *espStatus = nil;
        NSString *espScan = nil;
        if (showESP && DSBridgeCompiledIn()) {
            @try {
                espStatus = DSBridgeESPCachedStatus();
                espScan = DSBridgeESPScanInfo();
            } @catch (__unused NSException *e) {
                espStatus = nil;
            }
            if (espStatus.length == 0) espStatus = @"ESP: Sẵn sàng";
        }
        NSMutableArray<NSString *> *extraLines = [NSMutableArray array];
        if (espStatus) [extraLines addObject:espStatus];
        if (espScan) [extraLines addObject:espScan];
        NSString *extraText = extraLines.count ? [extraLines componentsJoinedByString:@"\n"] : nil;

        if (bridgeError.length > 0) {
            strongSelf->_statusDetailLabel.text = [NSString stringWithFormat:@"Lỗi: %@", bridgeError];
            strongSelf->_statusDetailLabel.textColor = [UIColor colorWithRed:239/255.0 green:68/255.0 blue:68/255.0 alpha:1.0];
        } else if (extraText.length > 0) {
            strongSelf->_statusDetailLabel.text = extraText;
            strongSelf->_statusDetailLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
        } else {
            strongSelf->_statusDetailLabel.text = strongSelf->_isRemoteHUDActive ? @"ESP Overlay đang chạy trong nền" : @"ESP đang tắt. Bấm nút bên dưới để khởi chạy.";
            strongSelf->_statusDetailLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
        }

        [strongSelf->_authorLabel setText:@"DarkPubg • Based on DarkSpeed & TrollSpeed"];
    } completion:nil];
}

- (void)presentTopCenterMostHints
{
    if (!_isRemoteHUDActive) {
        return;
    }
    [_authorLabel setText:NSLocalizedString(@"Tap that button on the center again,\nto toggle ON/OFF “Dynamic Island” mode.", nil)];
}

- (BOOL)settingHighlightedWithKey:(NSString * _Nonnull)key
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:key];
    if (mode != nil) return [mode boolValue];
    // kernrw52: ESP sub-features mặc định ON (khớp với bridge default YES) —
    // nếu không, UI hiện OFF nhưng bridge đã bật sẵn => toggle ON không có tác dụng.
    if ([key isEqualToString:HUDUserDefaultsKeyESPShowLine] ||
        [key isEqualToString:HUDUserDefaultsKeyESPShowName] ||
        [key isEqualToString:HUDUserDefaultsKeyESPShowHealth] ||
        [key isEqualToString:HUDUserDefaultsKeyESPShowDistance]) {
        return YES;
    }
    return NO;
}

- (void)settingDidSelectWithKey:(NSString * _Nonnull)key
{
    BOOL highlighted = [self settingHighlightedWithKey:key];
    [_userDefaults setObject:@(!highlighted) forKey:key];
    [self saveUserDefaults];
}

- (void)reloadModeButtonState
{
    HUDPresetPosition selectedMode = [self selectedModeForCurrentOrientation];
    BOOL isCentered = (selectedMode == HUDPresetPositionTopCenter || selectedMode == HUDPresetPositionTopCenterMost);
    BOOL isCenteredMost = (selectedMode == HUDPresetPositionTopCenterMost);
    [_topLeftButton setSelected:(selectedMode == HUDPresetPositionTopLeft)];
    [_topCenterButton setSelected:isCentered];
    [_topRightButton setSelected:(selectedMode == HUDPresetPositionTopRight)];
    UIImage *topCenterImage = (isCenteredMost ? [UIImage systemImageNamed:@"arrow.up.to.line"] : [UIImage systemImageNamed:@"arrow.up"]);
    [_topCenterButton setImage:topCenterImage forState:UIControlStateNormal];
}

- (void)tapAuthorLabel:(UITapGestureRecognizer *)sender
{
    if (_isRemoteHUDActive) {
        return;
    }
    NSString *repoURLString = @"https://github.com/huami1314/DarkSpeed";
    NSURL *repoURL = [NSURL URLWithString:repoURLString];
    [[UIApplication sharedApplication] openURL:repoURL options:@{} completionHandler:nil];
}

- (void)tapTopLeftButton:(UIButton *)sender
{
    log_debug(OS_LOG_DEFAULT, "- [RootViewController tapTopLeftButton:%{public}@]", sender);
    [self setSelectedModeForCurrentOrientation:HUDPresetPositionTopLeft];
    [self reloadModeButtonState];
}

- (void)tapTopRightButton:(UIButton *)sender
{
    log_debug(OS_LOG_DEFAULT, "- [RootViewController tapTopRightButton:%{public}@]", sender);
    [self setSelectedModeForCurrentOrientation:HUDPresetPositionTopRight];
    [self reloadModeButtonState];
}

- (void)tapTopCenterButton:(UIButton *)sender
{
    log_debug(OS_LOG_DEFAULT, "- [RootViewController tapTopCenterButton:%{public}@]", sender);
    HUDPresetPosition selectedMode = [self selectedModeForCurrentOrientation];
    BOOL isCenteredMost = (selectedMode == HUDPresetPositionTopCenterMost);
    if (!sender.isSelected || !_supportsCenterMost) {
        [self setSelectedModeForCurrentOrientation:HUDPresetPositionTopCenter];
        if (_supportsCenterMost) {
            [self presentTopCenterMostHints];
        }
    } else {
        if (isCenteredMost) {
            [self setSelectedModeForCurrentOrientation:HUDPresetPositionTopCenter];
        } else {
            [self setSelectedModeForCurrentOrientation:HUDPresetPositionTopCenterMost];
        }
    }
    [self reloadModeButtonState];
}

- (void)tapMainButton:(UIButton *)sender
{
    log_debug(OS_LOG_DEFAULT, "- [RootViewController tapMainButton:%{public}@]", sender);

    BOOL isNowEnabled = [self isHUDEnabled];
    if (!isNowEnabled) {
        [self appendLog:@"Yêu cầu khởi tạo cửa sổ HUD Overlay..." type:@"ACTION"];
        [self appendLog:@"Hooking ShadowTrackerExtra memory..." type:@"KERNEL"];
    } else {
        [self appendLog:@"Yêu cầu đóng cửa sổ HUD Overlay..." type:@"STOP"];
    }

#if USE_DARKSWORD
    if (!isNowEnabled) {
        [self showDSProgressOverlay];
    } else {
        [self hideDSProgressOverlay];
    }
#endif
    [self setHUDEnabled:!isNowEnabled];
    isNowEnabled = !isNowEnabled;

    if (isNowEnabled)
    {
        [_impactFeedbackGenerator prepare];
        int anyToken;
        __weak typeof(self) weakSelf = self;
        notify_register_dispatch(NOTIFY_LAUNCHED_HUD, &anyToken, dispatch_get_main_queue(), ^(int token) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            notify_cancel(token);
#if USE_DARKSWORD
            [strongSelf hideDSProgressOverlay];
#endif
            [strongSelf->_impactFeedbackGenerator impactOccurred];
            [strongSelf reloadMainButtonState];
            [strongSelf.backgroundView setUserInteractionEnabled:YES];
            [strongSelf appendLog:@"HUD Overlay đã khởi tạo thành công" type:@"SUCCESS"];
        });

        [self.backgroundView setUserInteractionEnabled:NO];
#if USE_DARKSWORD
        // DarkSword bootstrap can take minutes; the progress bar is the feedback.
        // Do not auto re-enable after 5s — only success (notify) or failure
        // (NOTIFY_RELOAD_APP) ends the busy state.
#else
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reloadMainButtonState];
                [self.backgroundView setUserInteractionEnabled:YES];
            });
        });
#endif
    }
    else
    {
        [self.backgroundView setUserInteractionEnabled:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reloadMainButtonState];
            [self.backgroundView setUserInteractionEnabled:YES];
        });
    }
}

#if USE_DARKSWORD
- (void)showDSProgressOverlay
{
    if (!_dsProgressOverlay) {
        UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = [UIColor colorWithWhite:0.28 alpha:0.96];

        UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.progressTintColor = [UIColor colorWithRed:26/255.0 green:188/255.0 blue:156/255.0 alpha:1.0];
        bar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        bar.progress = 0.0;
        [overlay addSubview:bar];

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.text = [NSString stringWithFormat:@"%@\n0%%", NSLocalizedString(@"Initializing DarkSpeed", nil)];
        [overlay addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [bar.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-12.0],
            [bar.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:44.0],
            [bar.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-44.0],
            [bar.heightAnchor constraintEqualToConstant:4.0],
            [label.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:18.0],
            [label.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:28.0],
            [label.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-28.0],
            [label.bottomAnchor constraintLessThanOrEqualToAnchor:overlay.bottomAnchor constant:-40.0],
        ]];
        _dsProgressOverlay = overlay;
        _dsProgressBar = bar;
        _dsProgressLabel = label;
    }

    if (!_dsProgressOverlay.superview) [self.view addSubview:_dsProgressOverlay];
    [self.view bringSubviewToFront:_dsProgressOverlay];
    _dsProgressOverlay.hidden = NO;
    _dsProgressBar.progressTintColor = [UIColor colorWithRed:26/255.0 green:188/255.0 blue:156/255.0 alpha:1.0];
    _dsProgressBar.progress = 0.0;
    _dsProgressLabel.numberOfLines = 0;
    _dsProgressLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _dsProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    _dsProgressLabel.textAlignment = NSTextAlignmentCenter;
    _dsProgressLabel.text = [NSString stringWithFormat:@"%@\n0%%", NSLocalizedString(@"Initializing DarkSpeed", nil)];
}

- (void)hideDSProgressOverlay
{
    _dsProgressOverlay.hidden = YES;
}

- (void)showDSFailure:(NSString *)error
{
    if (!_dsProgressOverlay) [self showDSProgressOverlay];
    if (!_dsProgressOverlay.superview) [self.view addSubview:_dsProgressOverlay];
    [self.view bringSubviewToFront:_dsProgressOverlay];
    _dsProgressOverlay.hidden = NO;
    _dsProgressBar.progress = 1.0f;
    _dsProgressBar.progressTintColor = UIColor.systemRedColor;
    _dsProgressLabel.numberOfLines = 0;
    _dsProgressLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _dsProgressLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _dsProgressLabel.textAlignment = NSTextAlignmentLeft;
    _dsProgressLabel.text = [NSString stringWithFormat:@"%@\n\n%@",
        NSLocalizedString(@"DarkSpeed initialization failed", nil),
        error.length > 0 ? error : NSLocalizedString(@"Unknown error", nil)];
}

- (void)dsProgressDidChange:(NSNotification *)note
{
    if (!DSBridgeIsRunning()) {
        // Done or failed — only auto-hide on success; error hides via NOTIFY_RELOAD_APP.
        if (DSBridgeHUDEnabled()) [self hideDSProgressOverlay];
        return;
    }
    double p = DSBridgeProgress();
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    _dsProgressBar.progress = (float)p;
    NSString *stage = DSBridgeStage();
    if (stage.length == 0) stage = NSLocalizedString(@"Initializing DarkSpeed", nil);
    _dsProgressLabel.text = [NSString stringWithFormat:@"%@\n%d%%", stage, (int)llround(p * 100.0)];
    [self appendLog:[NSString stringWithFormat:@"%@ (%d%%)", stage, (int)llround(p * 100.0)] type:@"LOAD"];
}
#endif

- (void)tapSettingsButton:(UIButton *)sender
{
    if (![_mainButton isEnabled]) return;
    log_debug(OS_LOG_DEFAULT, "- [RootViewController tapSettingsButton:%{public}@]", sender);

    TSSettingsController *settingsViewController = [[TSSettingsController alloc] init];
    settingsViewController.delegate = self;
    settingsViewController.alreadyLaunched = _isRemoteHUDActive;

    SPLarkTransitioningDelegate *transitioningDelegate = [[SPLarkTransitioningDelegate alloc] init];
    settingsViewController.transitioningDelegate = transitioningDelegate;
    settingsViewController.modalPresentationStyle = UIModalPresentationCustom;
    settingsViewController.modalPresentationCapturesStatusBarAppearance = YES;
    [self presentViewController:settingsViewController animated:YES completion:nil];
}

- (void)verticalSizeClassUpdated
{
    UIUserInterfaceSizeClass verticalClass = self.traitCollection.verticalSizeClass;
    BOOL isPad = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);
    if (verticalClass == UIUserInterfaceSizeClassCompact) {
        CGFloat topConstant = _gTopButtonConstraintsConstantCompact;
        [_settingsButton setHidden:YES];
        [_authorLabelBottomConstraint setConstant:_gAuthorLabelBottomConstraintConstantCompact];
        [_topLeftConstraint setConstant:topConstant];
        [_topRightConstraint setConstant:topConstant];
        [_topCenterConstraint setConstant:topConstant];
    } else {
        CGFloat topConstant = isPad ? _gTopButtonConstraintsConstantRegularPad : _gTopButtonConstraintsConstantRegular;
        [_settingsButton setHidden:NO];
        [_authorLabelBottomConstraint setConstant:_gAuthorLabelBottomConstraintConstantRegular];
        [_topLeftConstraint setConstant:topConstant];
        [_topRightConstraint setConstant:topConstant];
        [_topCenterConstraint setConstant:topConstant];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [self verticalSizeClassUpdated];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        [self reloadModeButtonState];
    } completion:nil];
}

@end
