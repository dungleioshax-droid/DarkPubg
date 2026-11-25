#import "MadnessMenuView.h"
#import "MADSW.h"
#import "MenuWidgets.h"
#import "MadnessMascotData.h"
#import <QuartzCore/QuartzCore.h>
#import "DSTheme.h"

static const CGFloat kMadnessPanelW = 500.0f;
static const CGFloat kMadnessPanelH = 325.0f;

@interface MadnessMenuView () <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIButton *panel;
@property (nonatomic, strong) UIView *titleBox;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *mascotView;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UIPanGestureRecognizer *titlePan;

// Header top bar items
@property (nonatomic, strong) UIButton *btnEng;
@property (nonatomic, strong) UIButton *btnVie;
@property (nonatomic, copy) NSString *currentLang;
@property (nonatomic, strong) UIButton *contactBtn;
@property (nonatomic, strong) UILabel *handleMajed;
@property (nonatomic, strong) UILabel *handleChan;

// Subheader line items
@property (nonatomic, strong) UILabel *clockLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) UILabel *sloganLabel;

// Scrolling & toggling
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIButton *handle;
@property (nonatomic, strong) UILabel *handleGlyph;
@property (nonatomic, strong) UITapGestureRecognizer *handleTap;
@property (nonatomic, strong) UILongPressGestureRecognizer *handleLong;
@property (nonatomic, strong) NSDateFormatter *ttime;
@property (nonatomic, strong) NSTimer *clockTimer;

// Circular Radar HUD
@property (nonatomic, strong) CAShapeLayer *radarBgLayer;
@property (nonatomic, strong) CAShapeLayer *radarDotsLayer;
@property (nonatomic, strong) CAShapeLayer *radarKnockedDotsLayer;
@property (nonatomic, strong) CAShapeLayer *triangleMaskLayer;
@property (nonatomic, strong) CAShapeLayer *radacircle;
@property (nonatomic, strong) CAShapeLayer *radacircle2;
@property (nonatomic, strong) CAShapeLayer *radacircle3;
@property (nonatomic, strong) CAShapeLayer *ViewLine;
@property (nonatomic, strong) UIButton *dragMap;
@property (nonatomic) BOOL asize;
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;

// Live widgets for DarkPubg ESP state
@property (nonatomic, strong) MenuToggleButton *btnEspEnable;
@property (nonatomic, strong) MenuToggleButton *btnLine;
@property (nonatomic, strong) MenuToggleButton *btnEnemyNum;
@property (nonatomic, strong) MenuToggleButton *btnHealth;
@property (nonatomic, strong) MenuToggleButton *btnBone;
@property (nonatomic, strong) MenuToggleButton *btnRadar;
@property (nonatomic, strong) MenuToggleButton *btnName;
@property (nonatomic, strong) MenuToggleButton *btnDist;
@property (nonatomic, strong) MenuToggleButton *btn3D;
@property (nonatomic, strong) MenuToggleButton *btnArrow;
@property (nonatomic, strong) MenuToggleButton *btnTeam;
@property (nonatomic, strong) MenuToggleButton *btnFlag;
@property (nonatomic, strong) MenuSliderRow *sliderEspDist;

// Material widgets
@property (nonatomic, strong) MenuToggleButton *btnMatEnable;
@property (nonatomic, strong) MenuToggleButton *btnVeh;
@property (nonatomic, strong) MenuToggleButton *btnGrenade;
@property (nonatomic, strong) MenuToggleButton *btnLootBox;
@property (nonatomic, strong) MenuToggleButton *btnFlareGun;
@property (nonatomic, strong) MenuToggleButton *btnAirdrop;
@property (nonatomic, strong) MenuToggleButton *btnAccessory;
@property (nonatomic, strong) MenuToggleButton *btnDrug;
@property (nonatomic, strong) MenuToggleButton *btnWeaponAR;
@property (nonatomic, strong) MenuToggleButton *btnWeaponSMG;
@property (nonatomic, strong) MenuToggleButton *btnWeaponShotgun;
@property (nonatomic, strong) MenuToggleButton *btnWeaponSniper;
@property (nonatomic, strong) MenuToggleButton *btnArmorLv1;
@property (nonatomic, strong) MenuToggleButton *btnArmorLv2;
@property (nonatomic, strong) MenuToggleButton *btnArmorLv3;
@property (nonatomic, strong) MenuToggleButton *btnAmmo;
@property (nonatomic, strong) MenuSliderRow *sliderItemDist;
@property (nonatomic, strong) UILabel *headerEsp;
@property (nonatomic, strong) UILabel *headerMaterial;

@end

@implementation MadnessMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;
    self.haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    // Load persisted settings
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"pubg_box"] != nil) g_pubgEspBox = [defaults boolForKey:@"pubg_box"];
    if ([defaults objectForKey:@"pubg_skeleton"] != nil) g_pubgEspSkeleton = [defaults boolForKey:@"pubg_skeleton"];
    if ([defaults objectForKey:@"pubg_line"] != nil) g_pubgEspLine = [defaults boolForKey:@"pubg_line"];
    if ([defaults objectForKey:@"pubg_health"] != nil) g_pubgEspHealth = [defaults boolForKey:@"pubg_health"];
    if ([defaults objectForKey:@"pubg_name"] != nil) g_pubgEspName = [defaults boolForKey:@"pubg_name"];
    if ([defaults objectForKey:@"pubg_dist"] != nil) g_pubgEspDist = [defaults boolForKey:@"pubg_dist"];
    g_pubgEspBot = YES;
    [defaults setBool:YES forKey:@"pubg_bot"];
    if ([defaults objectForKey:@"pubg_enemy_num"] != nil) g_pubgEspEnemyNumber = [defaults boolForKey:@"pubg_enemy_num"];
    if ([defaults objectForKey:@"pubg_radar"] != nil) g_pubgEspRadar = [defaults boolForKey:@"pubg_radar"];
    if ([defaults objectForKey:@"pubg_team"] != nil) g_pubgEspTeam = [defaults boolForKey:@"pubg_team"];
    if ([defaults objectForKey:@"pubg_flag"] != nil) g_pubgEspFlag = [defaults boolForKey:@"pubg_flag"];
    if ([defaults objectForKey:@"pubg_arrow"] != nil) g_pubgEspArrow = [defaults boolForKey:@"pubg_arrow"];
    if ([defaults objectForKey:@"pubg_grenade"] != nil) g_pubgEspGrenade = [defaults boolForKey:@"pubg_grenade"];
    if ([defaults objectForKey:@"pubg_vehicle"] != nil) g_pubgEspVehicle = [defaults boolForKey:@"pubg_vehicle"];
    if ([defaults objectForKey:@"pubg_vehicle_hp"] != nil) g_pubgEspVehicleHp = [defaults boolForKey:@"pubg_vehicle_hp"];
    if ([defaults objectForKey:@"pubg_vehicle_fuel"] != nil) g_pubgEspVehicleFuel = [defaults boolForKey:@"pubg_vehicle_fuel"];
    if ([defaults objectForKey:@"pubg_weapon"] != nil) g_pubgEspWeapon = [defaults boolForKey:@"pubg_weapon"];
    if ([defaults objectForKey:@"pubg_armor"] != nil) g_pubgEspArmor = [defaults boolForKey:@"pubg_armor"];
    if ([defaults objectForKey:@"pubg_bag"] != nil) g_pubgEspBag = [defaults boolForKey:@"pubg_bag"];
    if ([defaults objectForKey:@"pubg_scope"] != nil) g_pubgEspScope = [defaults boolForKey:@"pubg_scope"];
    if ([defaults objectForKey:@"pubg_crate"] != nil) g_pubgEspCrate = [defaults boolForKey:@"pubg_crate"];
    if ([defaults objectForKey:@"pubg_flaregun"] != nil) g_pubgEspFlareGun = [defaults boolForKey:@"pubg_flaregun"];
    if ([defaults objectForKey:@"pubg_drug"] != nil) g_pubgEspDrug = [defaults boolForKey:@"pubg_drug"];
    if ([defaults objectForKey:@"pubg_weapon_ar"] != nil) g_pubgEspWeaponAR = [defaults boolForKey:@"pubg_weapon_ar"];
    if ([defaults objectForKey:@"pubg_weapon_smg"] != nil) g_pubgEspWeaponSMG = [defaults boolForKey:@"pubg_weapon_smg"];
    if ([defaults objectForKey:@"pubg_weapon_shotgun"] != nil) g_pubgEspWeaponShotgun = [defaults boolForKey:@"pubg_weapon_shotgun"];
    if ([defaults objectForKey:@"pubg_weapon_sniper"] != nil) g_pubgEspWeaponSniper = [defaults boolForKey:@"pubg_weapon_sniper"];
    if ([defaults objectForKey:@"pubg_armor_lv1"] != nil) g_pubgEspArmorLv1 = [defaults boolForKey:@"pubg_armor_lv1"];
    if ([defaults objectForKey:@"pubg_armor_lv2"] != nil) g_pubgEspArmorLv2 = [defaults boolForKey:@"pubg_armor_lv2"];
    if ([defaults objectForKey:@"pubg_armor_lv3"] != nil) g_pubgEspArmorLv3 = [defaults boolForKey:@"pubg_armor_lv3"];
    if ([defaults objectForKey:@"pubg_ammo"] != nil) g_pubgEspAmmo = [defaults boolForKey:@"pubg_ammo"];
    if ([defaults objectForKey:@"pubg_zoom_dist"] != nil) g_dspubgMaxDistance = [defaults floatForKey:@"pubg_zoom_dist"];
    if ([defaults objectForKey:@"pubg_item_dist"] != nil) g_pubgItemMaxDistance = [defaults floatForKey:@"pubg_item_dist"];
    if ([defaults objectForKey:@"pubg_thickness"] != nil) {
        g_pubgEspThickness = [defaults floatForKey:@"pubg_thickness"];
        if (g_pubgEspThickness < 0.8f) g_pubgEspThickness = 0.8f;
        if (g_pubgEspThickness > 3.5f) g_pubgEspThickness = 3.5f;
    }

    [self buildChrome];
    [self buildRadarHUD];
    [self buildHorizontalContent];
    [self startClock];
    return self;
}

#pragma mark - Helpers

- (MenuToggleButton *)btn:(NSString *)t frame:(CGRect)f inView:(UIView *)p italic:(BOOL)it {
    MenuToggleButton *b = [[MenuToggleButton alloc] initWithTitle:t frame:f italic:it];
    [p addSubview:b];
    return b;
}

- (UILabel *)addSectionHeader:(NSString *)title atY:(CGFloat)y {
    UIView *rail = [[UIView alloc] initWithFrame:CGRectMake(12, y + 3, 3, 13)];
    rail.backgroundColor = DSColorAccent();
    rail.layer.cornerRadius = 1.5;
    [self.scroll addSubview:rail];

    UILabel *tit = [[UILabel alloc] initWithFrame:CGRectMake(22, y, 240, 18)];
    tit.text = title;
    tit.textColor = DSColorTextPrimary();
    tit.font = DSFontBody(10.5, UIFontWeightHeavy);
    tit.textAlignment = NSTextAlignmentLeft;
    [self.scroll addSubview:tit];
    return tit;
}

#pragma mark - Chrome (Header & Panels)

- (void)buildChrome {
    CGFloat startX = 60.0;
    CGFloat startY = 15.0;
    id sx = [NSUserDefaults.standardUserDefaults objectForKey:@"madness_menu_x"];
    id sy = [NSUserDefaults.standardUserDefaults objectForKey:@"madness_menu_y"];
    if (sx && sy) {
        CGFloat x = [sx floatValue];
        CGFloat y = [sy floatValue];
        if (x > 20 && x < 1500 && y > 10 && y < 1000) {
            startX = x - 102.0;
            startY = y - 15.0;
        }
    }

    // Panel container: start collapsed (158 x 30)
    self.panel = [UIButton buttonWithType:UIButtonTypeCustom];
    self.panel.frame = CGRectMake(startX, startY, 158, 30);
    self.panel.backgroundColor = UIColor.clearColor;
    self.panel.layer.cornerRadius = 14.0;
    self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    self.panel.clipsToBounds = YES;
    [self addSubview:self.panel];

    // Pan Gesture Recognizer on panel for smooth header dragging
    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    self.panGesture.delegate = self;
    self.panGesture.cancelsTouchesInView = NO;
    [self.panel addGestureRecognizer:self.panGesture];

    // Collapse / Expand handle button (Round circle [ V ])
    self.handle = [UIButton buttonWithType:UIButtonTypeCustom];
    self.handle.frame = CGRectMake(5, 3, 24, 24);
    self.handle.backgroundColor = [DSColorAccent() colorWithAlphaComponent:0.16];
    self.handle.layer.cornerRadius = 12.0;
    self.handle.layer.masksToBounds = YES;
    self.handle.layer.borderWidth = 1.0;
    self.handle.layer.borderColor = [DSColorAccent() colorWithAlphaComponent:0.55].CGColor;
    [self.panel addSubview:self.handle];

    self.handleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllview)];
    [self.handle addGestureRecognizer:self.handleTap];
    self.handleLong = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.handleLong.minimumPressDuration = 0.5;
    [self.handle addGestureRecognizer:self.handleLong];
    [self.handle addTarget:self action:@selector(handleTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.handleGlyph = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    self.handleGlyph.text = @"⋗";
    self.handleGlyph.font = DSFontBody(16.0, UIFontWeightHeavy);
    self.handleGlyph.textColor = DSColorAccent();
    self.handleGlyph.textAlignment = NSTextAlignmentCenter;
    self.handleGlyph.userInteractionEnabled = NO;
    self.handleGlyph.backgroundColor = UIColor.clearColor;
    [self.handle addSubview:self.handleGlyph];

    // Top Dark Header Capsule Bar: collapsed (32, 3, 118, 24)
    self.titleBox = [[UIView alloc] initWithFrame:CGRectMake(32, 3, 118, 24)];
    self.titleBox.backgroundColor = [DSColorInk() colorWithAlphaComponent:0.86];
    self.titleBox.layer.cornerRadius = 12.0;
    self.titleBox.layer.cornerCurve = kCACornerCurveContinuous;
    self.titleBox.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.85].CGColor;
    self.titleBox.layer.borderWidth = 1.0;
    self.titleBox.clipsToBounds = YES;
    self.titleBox.userInteractionEnabled = YES;
    [self.panel addSubview:self.titleBox];

    self.titlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    self.titlePan.delegate = self;
    self.titlePan.cancelsTouchesInView = NO;
    [self.titleBox addGestureRecognizer:self.titlePan];

    UITapGestureRecognizer *titleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(titleBoxTapped:)];
    [self.titleBox addGestureRecognizer:titleTap];

    // 1. Title: DARKSWORD
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 2, 82, 20)];
    self.titleLabel.text = @"DARKSWORD";
    self.titleLabel.textColor = DSColorAccent();
    self.titleLabel.font = DSFontBody(11.0, UIFontWeightHeavy);
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    self.titleLabel.userInteractionEnabled = NO;
    [self.titleBox addSubview:self.titleLabel];

    // 2. Mascot icon
    self.mascotView = [[UIImageView alloc] initWithFrame:CGRectMake(92, 2, 20, 20)];
    self.mascotView.image = MadnessMascotImage();
    self.mascotView.contentMode = UIViewContentModeScaleAspectFit;
    self.mascotView.userInteractionEnabled = NO;
    [self.titleBox addSubview:self.mascotView];

    // 3. Language Selector: [ ENG ]  [ VIE ]
    self.btnEng = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnEng.frame = CGRectMake(118, 3, 30, 18);
    self.btnEng.layer.cornerRadius = 3.5;
    self.btnEng.clipsToBounds = YES;
    [self.btnEng setTitle:@"ENG" forState:UIControlStateNormal];
    self.btnEng.titleLabel.font = DSFontBody(9.0, UIFontWeightHeavy);
    [self.btnEng addTarget:self action:@selector(selectEng) forControlEvents:UIControlEventTouchUpInside];
    self.btnEng.hidden = YES;
    [self.titleBox addSubview:self.btnEng];

    self.btnVie = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnVie.frame = CGRectMake(152, 3, 28, 18);
    self.btnVie.layer.cornerRadius = 3.5;
    self.btnVie.clipsToBounds = YES;
    [self.btnVie setTitle:@"VIE" forState:UIControlStateNormal];
    self.btnVie.titleLabel.font = DSFontBody(9.0, UIFontWeightHeavy);
    [self.btnVie addTarget:self action:@selector(selectVie) forControlEvents:UIControlEventTouchUpInside];
    self.btnVie.hidden = YES;
    [self.titleBox addSubview:self.btnVie];

    // 4. Contact button: [ Dũng Lê ]
    self.contactBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.contactBtn.frame = CGRectMake(186, 3, 56, 18);
    self.contactBtn.backgroundColor = DSColorAccent();
    self.contactBtn.layer.cornerRadius = 9.0;
    self.contactBtn.clipsToBounds = YES;
    [self.contactBtn setTitle:@"Dũng Lê" forState:UIControlStateNormal];
    [self.contactBtn setTitleColor:DSColorOnAccent() forState:UIControlStateNormal];
    self.contactBtn.titleLabel.font = DSFontBody(9.0, UIFontWeightHeavy);
    [self.contactBtn addTarget:self action:@selector(contactTapped) forControlEvents:UIControlEventTouchUpInside];
    self.contactBtn.hidden = YES;
    [self.titleBox addSubview:self.contactBtn];

    // 5. Handles: Dũng Lê  DARKSWORD~KERNEL
    self.handleMajed = [[UILabel alloc] initWithFrame:CGRectMake(248, 3, 72, 18)];
    self.handleMajed.text = @"Dũng Lê";
    self.handleMajed.textColor = DSColorTextPrimary();
    self.handleMajed.font = DSFontBody(9.5, UIFontWeightBold);
    self.handleMajed.textAlignment = NSTextAlignmentLeft;
    self.handleMajed.hidden = YES;
    [self.titleBox addSubview:self.handleMajed];

    self.handleChan = [[UILabel alloc] initWithFrame:CGRectMake(326, 3, 130, 18)];
    self.handleChan.text = @"DARKSWORD~KERNEL";
    self.handleChan.textColor = DSColorTextTertiary();
    self.handleChan.font = DSFontBody(9.0, UIFontWeightBold);
    self.handleChan.textAlignment = NSTextAlignmentLeft;
    self.handleChan.hidden = YES;
    [self.titleBox addSubview:self.handleChan];

    // Load persisted language (default to VIE)
    NSString *savedLang = [NSUserDefaults.standardUserDefaults stringForKey:@"madness_lang"];
    if (!savedLang || (![savedLang isEqualToString:@"ENG"] && ![savedLang isEqualToString:@"VIE"])) {
        savedLang = @"VIE";
    }
    self.currentLang = savedLang;
    [self updateLanguageDisplayOnly];

    // Subheader Line (Below top capsule bar, y = 31):
    // Left: Date & Time + Battery Level
    self.clockLabel = [[UILabel alloc] initWithFrame:CGRectMake(36, 31, 140, 16)];
    self.clockLabel.backgroundColor = UIColor.clearColor;
    self.clockLabel.textColor = DSColorTextSecondary();
    self.clockLabel.font = DSFontMono(10.0, UIFontWeightSemibold);
    self.clockLabel.textAlignment = NSTextAlignmentLeft;
    self.clockLabel.userInteractionEnabled = NO;
    self.clockLabel.hidden = YES;
    [self.panel addSubview:self.clockLabel];

    self.batteryLabel = [[UILabel alloc] initWithFrame:CGRectMake(180, 31, 26, 16)];
    self.batteryLabel.backgroundColor = UIColor.clearColor;
    self.batteryLabel.textColor = DSColorAccent();
    self.batteryLabel.font = DSFontMono(10.0, UIFontWeightSemibold);
    self.batteryLabel.textAlignment = NSTextAlignmentLeft;
    self.batteryLabel.userInteractionEnabled = NO;
    self.batteryLabel.hidden = YES;
    [self.panel addSubview:self.batteryLabel];

    // Right: MORE FUTURE SOON INJOY ;)
    self.sloganLabel = [[UILabel alloc] initWithFrame:CGRectMake(210, 31, 280, 16)];
    self.sloganLabel.backgroundColor = UIColor.clearColor;
    self.sloganLabel.text = @"MORE FUTURE SOON INJOY ;)";
    self.sloganLabel.textColor = DSColorTextTertiary();
    self.sloganLabel.font = DSFontBody(10.0, UIFontWeightSemibold);
    self.sloganLabel.textAlignment = NSTextAlignmentRight;
    self.sloganLabel.userInteractionEnabled = NO;
    self.sloganLabel.hidden = YES;
    [self.panel addSubview:self.sloganLabel];

    // Content Scroll View (Horizontal menu grid): 0, 50, 500, 275
    self.scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 50, kMadnessPanelW, kMadnessPanelH - 50)];
    self.scroll.contentSize = CGSizeMake(kMadnessPanelW, 250);
    self.scroll.alwaysBounceHorizontal = YES;
    self.scroll.showsHorizontalScrollIndicator = YES;
    self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.scroll.directionalLockEnabled = YES;
    self.scroll.delegate = self;
    self.scroll.backgroundColor = UIColor.clearColor;
    self.scroll.clipsToBounds = YES;
    self.scroll.hidden = YES;
    self.scroll.showsVerticalScrollIndicator = YES;
    self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.panel addSubview:self.scroll];

    self.ttime = [[NSDateFormatter alloc] init];
    self.ttime.dateFormat = @"yyyy/MM/dd • HH:mm:ss";
}

#pragma mark - Circular Radar HUD (DRAW SRADAR)

- (void)buildRadarHUD {
    CGFloat rx = 47.0f, ry = 47.0f;
    self.dragMap = [UIButton buttonWithType:UIButtonTypeCustom];

    // Initial position on screen (can be dragged anywhere)
    CGFloat startX = 520.0f;
    CGFloat startY = 220.0f;
    id rxSaved = [NSUserDefaults.standardUserDefaults objectForKey:@"madness_radar_x"];
    id rySaved = [NSUserDefaults.standardUserDefaults objectForKey:@"madness_radar_y"];
    if (rxSaved && rySaved) {
        startX = [rxSaved floatValue] - rx;
        startY = [rySaved floatValue] - ry;
    }
    self.dragMap.frame = CGRectMake(startX, startY, 94.0f, 94.0f);
    self.dragMap.backgroundColor = UIColor.clearColor;
    self.dragMap.layer.cornerRadius = 47.0f;
    self.dragMap.clipsToBounds = NO;
    self.dragMap.hidden = !g_pubgEspRadar;
    [self.dragMap addTarget:self action:@selector(wasDraggedm:withEventm:) forControlEvents:UIControlEventTouchDragInside | UIControlEventTouchDragOutside];
    [self addSubview:self.dragMap];

    UIPanGestureRecognizer *radarPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleRadarPan:)];
    [self.dragMap addGestureRecognizer:radarPan];

    // 0. Radar Background Disc (dark semi-transparent disc)
    self.radarBgLayer = [CAShapeLayer layer];
    self.radarBgLayer.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rx, ry) radius:47.0f startAngle:0 endAngle:(CGFloat)(2*M_PI) clockwise:YES].CGPath;
    self.radarBgLayer.fillColor = [UIColor colorWithRed:0.04f green:0.06f blue:0.08f alpha:0.55f].CGColor;
    self.radarBgLayer.strokeColor = [UIColor clearColor].CGColor;
    [self.dragMap.layer addSublayer:self.radarBgLayer];

    // 1. FOV lines
    UIBezierPath *line = [UIBezierPath bezierPath];
    [line moveToPoint:CGPointMake(rx, ry)];
    [line addLineToPoint:CGPointMake(rx - 33.0f, ry - 33.0f)];
    [line moveToPoint:CGPointMake(rx, ry)];
    [line addLineToPoint:CGPointMake(rx + 33.0f, ry - 33.0f)];
    self.ViewLine = [CAShapeLayer layer];
    self.ViewLine.path = line.CGPath;
    self.ViewLine.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    self.ViewLine.lineWidth = 1.0f;
    [self.dragMap.layer addSublayer:self.ViewLine];

    // 2. Inner red circle (radius 17 ~ 50m)
    self.radacircle = [CAShapeLayer layer];
    self.radacircle.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rx, ry) radius:17.0f startAngle:0 endAngle:(CGFloat)(2*M_PI) clockwise:YES].CGPath;
    self.radacircle.strokeColor = DSColorDanger().CGColor;
    self.radacircle.fillColor = UIColor.clearColor.CGColor;
    self.radacircle.lineWidth = 1.0f;
    [self.dragMap.layer addSublayer:self.radacircle];

    // 3. Middle orange circle (radius 32 ~ 100m)
    self.radacircle2 = [CAShapeLayer layer];
    self.radacircle2.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rx, ry) radius:32.0f startAngle:0 endAngle:(CGFloat)(2*M_PI) clockwise:YES].CGPath;
    self.radacircle2.strokeColor = DSColorWarning().CGColor;
    self.radacircle2.fillColor = UIColor.clearColor.CGColor;
    self.radacircle2.lineWidth = 1.0f;
    [self.dragMap.layer addSublayer:self.radacircle2];

    // 4. Outer green circle (radius 47 ~ 150m)
    self.radacircle3 = [CAShapeLayer layer];
    self.radacircle3.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(rx, ry) radius:47.0f startAngle:0 endAngle:(CGFloat)(2*M_PI) clockwise:YES].CGPath;
    self.radacircle3.strokeColor = DSColorAccent().CGColor;
    self.radacircle3.fillColor = UIColor.clearColor.CGColor;
    self.radacircle3.lineWidth = 1.0f;
    [self.dragMap.layer addSublayer:self.radacircle3];

    // 5. Alive enemy / bot red dots layer (crisp red dots with thin white outline)
    self.radarDotsLayer = [CAShapeLayer layer];
    self.radarDotsLayer.fillColor = [UIColor colorWithRed:1.0f green:0.12f blue:0.12f alpha:1.0f].CGColor;
    self.radarDotsLayer.strokeColor = [UIColor whiteColor].CGColor;
    self.radarDotsLayer.lineWidth = 0.8f;
    [self.dragMap.layer addSublayer:self.radarDotsLayer];

    // 6. Knocked enemy orange warning dots layer
    self.radarKnockedDotsLayer = [CAShapeLayer layer];
    self.radarKnockedDotsLayer.fillColor = [UIColor colorWithRed:1.0f green:0.55f blue:0.0f alpha:1.0f].CGColor;
    self.radarKnockedDotsLayer.strokeColor = [UIColor blackColor].CGColor;
    self.radarKnockedDotsLayer.lineWidth = 0.8f;
    [self.dragMap.layer addSublayer:self.radarKnockedDotsLayer];

    // 7. Center green triangle (local player position & heading, placed on top)
    UIBezierPath *tri = [UIBezierPath bezierPath];
    [tri moveToPoint:CGPointMake(rx - 5.0f, ry + 5.0f)];
    [tri addLineToPoint:CGPointMake(rx + 5.0f, ry + 5.0f)];
    [tri addLineToPoint:CGPointMake(rx, ry - 5.0f)];
    [tri closePath];
    self.triangleMaskLayer = [CAShapeLayer layer];
    self.triangleMaskLayer.path = tri.CGPath;
    self.triangleMaskLayer.strokeColor = DSColorAccent().CGColor;
    self.triangleMaskLayer.fillColor = DSColorAccent().CGColor;
    [self.dragMap.layer addSublayer:self.triangleMaskLayer];
}

- (void)updateRadarWithPlayers:(nullable const void *)players count:(int)count {
    if (!self.dragMap || self.dragMap.hidden || !g_pubgEspRadar) {
        if (self.radarDotsLayer && self.radarDotsLayer.path != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            self.radarDotsLayer.path = nil;
            if (self.radarKnockedDotsLayer) self.radarKnockedDotsLayer.path = nil;
            [CATransaction commit];
        }
        return;
    }

    if (!players || count <= 0) {
        if (self.radarDotsLayer && self.radarDotsLayer.path != nil) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            self.radarDotsLayer.path = nil;
            if (self.radarKnockedDotsLayer) self.radarKnockedDotsLayer.path = nil;
            [CATransaction commit];
        }
        return;
    }

    const DSPUBGProjectedPlayer *playerList = (const DSPUBGProjectedPlayer *)players;
    const CGFloat rx = 47.0f;
    const CGFloat ry = 47.0f;
    const CGFloat maxRadius = 43.5f;
    const CGFloat scale = 43.5f / 150.0f; // 150m max visible radius on radar (~0.29 pt/m)
    const CGFloat dotRadius = 2.8f;
    const CGFloat dotDiameter = dotRadius * 2.0f;

    UIBezierPath *aliveDots = [UIBezierPath bezierPath];
    UIBezierPath *knockedDots = [UIBezierPath bezierPath];
    int aliveCount = 0;
    int knockedCount = 0;

    for (int i = 0; i < count; i++) {
        const DSPUBGProjectedPlayer &p = playerList[i];
        if (p.isDead) continue;

        // Relative coordinates to camera:
        // camRelX: cm Right (+X)
        // camRelZ: cm Forward (+Z)
        float relX = p.camRelX * 0.01f; // meters right
        float relZ = p.camRelZ * 0.01f; // meters forward

        if (isnan(relX) || isnan(relZ) || isinf(relX) || isinf(relZ)) continue;

        // In radar coordinates:
        // Forward is UP (-Y)
        // Right is +X
        float ox = relX * scale;
        float oy = -relZ * scale;

        float dist = hypotf(ox, oy);
        if (dist > maxRadius) {
            if (dist > 0.001f) {
                ox = (ox / dist) * maxRadius;
                oy = (oy / dist) * maxRadius;
            } else {
                continue;
            }
        }

        CGFloat dotX = rx + (CGFloat)ox;
        CGFloat dotY = ry + (CGFloat)oy;

        CGRect r = CGRectMake(dotX - dotRadius, dotY - dotRadius, dotDiameter, dotDiameter);
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithOvalInRect:r];

        if (p.isKnocked) {
            [knockedDots appendPath:circlePath];
            knockedCount++;
        } else {
            [aliveDots appendPath:circlePath];
            aliveCount++;
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (self.radarDotsLayer) {
        self.radarDotsLayer.path = (aliveCount > 0) ? aliveDots.CGPath : nil;
    }
    if (self.radarKnockedDotsLayer) {
        self.radarKnockedDotsLayer.path = (knockedCount > 0) ? knockedDots.CGPath : nil;
    }
    [CATransaction commit];
}

#pragma mark - Clock & Contact

- (void)startClock {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self tickClock];
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tickClock) userInfo:nil repeats:YES];
}

- (void)tickClock {
    NSString *ds = [self.ttime stringFromDate:[NSDate date]];
    self.clockLabel.text = ds ?: @"";
    float lvl = [UIDevice currentDevice].batteryLevel;
    if (lvl < 0) lvl = 1.0f;
    self.batteryLabel.text = [NSString stringWithFormat:@"%0.0f", lvl * 100.0];
}

- (void)contactTapped {
    [self.haptic impactOccurred];
    NSURL *u = [NSURL URLWithString:@"https://t.me/DLX07"];
    if ([[UIApplication sharedApplication] canOpenURL:u]) {
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }
}

- (void)selectEng {
    [self.haptic impactOccurred];
    [self updateLanguage:@"ENG"];
}

- (void)selectVie {
    [self.haptic impactOccurred];
    [self updateLanguage:@"VIE"];
}

- (void)updateLanguageDisplayOnly {
    BOOL isVie = [self.currentLang isEqualToString:@"VIE"];
    if (isVie) {
        self.btnVie.backgroundColor = DSColorAccent();
        [self.btnVie setTitleColor:DSColorOnAccent() forState:UIControlStateNormal];
        self.btnEng.backgroundColor = [DSColorSurfaceHi() colorWithAlphaComponent:0.8];
        [self.btnEng setTitleColor:DSColorTextSecondary() forState:UIControlStateNormal];
    } else {
        self.btnEng.backgroundColor = DSColorAccent();
        [self.btnEng setTitleColor:DSColorOnAccent() forState:UIControlStateNormal];
        self.btnVie.backgroundColor = [DSColorSurfaceHi() colorWithAlphaComponent:0.8];
        [self.btnVie setTitleColor:DSColorTextSecondary() forState:UIControlStateNormal];
    }
}

- (void)updateLanguage:(NSString *)lang {
    self.currentLang = lang;
    [NSUserDefaults.standardUserDefaults setObject:lang forKey:@"madness_lang"];
    [self updateLanguageDisplayOnly];

    BOOL isVie = [lang isEqualToString:@"VIE"];
    if (isVie) {
        if (self.headerEsp) self.headerEsp.text = @"BẢNG ESP NGƯỜI CHƠI";
        if (self.headerMaterial) self.headerMaterial.text = @"BẢNG HIỆN VẬT PHẨM";
        if (self.sloganLabel) self.sloganLabel.text = @"DARKSWORD KERNEL • CHÚC BẠN CHƠI VUI VẺ ;)";

        [self.btnEspEnable setTitle:@"BẬT ESP" forState:UIControlStateNormal];
        [self.btnLine setTitle:@"ĐƯỜNG KẺ" forState:UIControlStateNormal];
        [self.btnEnemyNum setTitle:@"SỐ LƯỢNG ĐỊCH" forState:UIControlStateNormal];
        [self.btnHealth setTitle:@"THANH MÁU" forState:UIControlStateNormal];
        [self.btnBone setTitle:@"KHUNG XƯƠNG" forState:UIControlStateNormal];
        [self.btnRadar setTitle:@"RADAR MINI" forState:UIControlStateNormal];
        [self.btnName setTitle:@"TÊN ĐỊCH" forState:UIControlStateNormal];
        [self.btnDist setTitle:@"KHOẢNG CÁCH" forState:UIControlStateNormal];
        [self.btn3D setTitle:@"HỘP 3D" forState:UIControlStateNormal];
        [self.btnArrow setTitle:@"MŨI TÊN 360" forState:UIControlStateNormal];
        [self.btnTeam setTitle:@"SỐ ĐỘI" forState:UIControlStateNormal];
        [self.btnFlag setTitle:@"QUỐC KỲ" forState:UIControlStateNormal];

        if (self.sliderEspDist) self.sliderEspDist.name = @"KHOẢNG CÁCH";

        [self.btnMatEnable setTitle:@"BẬT VẬT PHẨM" forState:UIControlStateNormal];
        [self.btnVeh setTitle:@"XE CỘ" forState:UIControlStateNormal];
        [self.btnGrenade setTitle:@"CẢNH BÁO LỰU" forState:UIControlStateNormal];
        [self.btnLootBox setTitle:@"HÒM XÁC" forState:UIControlStateNormal];
        [self.btnFlareGun setTitle:@"THÍNH ĐỎ" forState:UIControlStateNormal];
        [self.btnAirdrop setTitle:@"HÒM THÍNH" forState:UIControlStateNormal];
        [self.btnAccessory setTitle:@"PHỤ KIỆN" forState:UIControlStateNormal];
        [self.btnDrug setTitle:@"HỒI MÁU" forState:UIControlStateNormal];

        [self.btnWeaponAR setTitle:@"SÚNG AR" forState:UIControlStateNormal];
        [self.btnWeaponSMG setTitle:@"SÚNG SMG" forState:UIControlStateNormal];
        [self.btnWeaponShotgun setTitle:@"SHOTGUN" forState:UIControlStateNormal];
        [self.btnWeaponSniper setTitle:@"SÚNG NGẮM" forState:UIControlStateNormal];

        [self.btnArmorLv1 setTitle:@"GIÁP 1" forState:UIControlStateNormal];
        [self.btnArmorLv2 setTitle:@"GIÁP 2" forState:UIControlStateNormal];
        [self.btnArmorLv3 setTitle:@"GIÁP 3" forState:UIControlStateNormal];
        [self.btnAmmo setTitle:@"ĐẠN DƯỢC" forState:UIControlStateNormal];

        if (self.sliderItemDist) self.sliderItemDist.name = @"KHOẢNG CÁCH";
    } else {
        if (self.headerEsp) self.headerEsp.text = @"ESP PANEL";
        if (self.headerMaterial) self.headerMaterial.text = @"MATERIAL PANEL";
        if (self.sloganLabel) self.sloganLabel.text = @"DARKSWORD KERNEL • ENJOY THE GAME ;)";

        [self.btnEspEnable setTitle:@"ENABLE" forState:UIControlStateNormal];
        [self.btnLine setTitle:@"DRAW LINE" forState:UIControlStateNormal];
        [self.btnEnemyNum setTitle:@"ENEMY NUMBER" forState:UIControlStateNormal];
        [self.btnHealth setTitle:@"PLAYER HEALTH" forState:UIControlStateNormal];
        [self.btnBone setTitle:@"DRAW BONE" forState:UIControlStateNormal];
        [self.btnRadar setTitle:@"DRAW SRADAR" forState:UIControlStateNormal];
        [self.btnName setTitle:@"PLAYER NAME" forState:UIControlStateNormal];
        [self.btnDist setTitle:@"PLAYER DIS" forState:UIControlStateNormal];
        [self.btn3D setTitle:@"3D BOX" forState:UIControlStateNormal];
        [self.btnArrow setTitle:@"ARROW 360" forState:UIControlStateNormal];
        [self.btnTeam setTitle:@"PLAYER TEAM" forState:UIControlStateNormal];
        [self.btnFlag setTitle:@"PLAYER FLAG" forState:UIControlStateNormal];

        if (self.sliderEspDist) self.sliderEspDist.name = @"DISTANCE";

        [self.btnMatEnable setTitle:@"ENABLE" forState:UIControlStateNormal];
        [self.btnVeh setTitle:@"VEHICLE" forState:UIControlStateNormal];
        [self.btnGrenade setTitle:@"GRENADE WARN" forState:UIControlStateNormal];
        [self.btnLootBox setTitle:@"LOOT BOX" forState:UIControlStateNormal];
        [self.btnFlareGun setTitle:@"FLARE GUN" forState:UIControlStateNormal];
        [self.btnAirdrop setTitle:@"AIRDROP" forState:UIControlStateNormal];
        [self.btnAccessory setTitle:@"ACCESSORY" forState:UIControlStateNormal];
        [self.btnDrug setTitle:@"DRUG" forState:UIControlStateNormal];

        [self.btnWeaponAR setTitle:@"AR" forState:UIControlStateNormal];
        [self.btnWeaponSMG setTitle:@"SMG" forState:UIControlStateNormal];
        [self.btnWeaponShotgun setTitle:@"SHOTGUN" forState:UIControlStateNormal];
        [self.btnWeaponSniper setTitle:@"SNIPER" forState:UIControlStateNormal];

        [self.btnArmorLv1 setTitle:@"ARMOR LV1" forState:UIControlStateNormal];
        [self.btnArmorLv2 setTitle:@"ARMOR LV2" forState:UIControlStateNormal];
        [self.btnArmorLv3 setTitle:@"ARMOR LV3" forState:UIControlStateNormal];
        [self.btnAmmo setTitle:@"AMMO" forState:UIControlStateNormal];

        if (self.sliderItemDist) self.sliderItemDist.name = @"DISTANCE";
    }
}

#pragma mark - Horizontal Content Grid (4 Columns x Authentic Buttons)

- (void)buildHorizontalContent {
    __weak typeof(self) weakSelf = self;

    const CGFloat colW = 110.0f;
    const CGFloat colGap = 12.0f;
    const CGFloat startX = 12.0f;
    const CGFloat btnH = 20.0f;

    CGFloat x0 = startX + 0 * (colW + colGap); // 12
    CGFloat x1 = startX + 1 * (colW + colGap); // 134
    CGFloat x2 = startX + 2 * (colW + colGap); // 256
    CGFloat x3 = startX + 3 * (colW + colGap); // 378

    // =========================================================================
    // SECTION 1: > ESP PANEL
    // =========================================================================
    self.headerEsp = [self addSectionHeader:@"ESP PANEL" atY:4.0];

    // Row 0 (y = 24): [ ENABLE ], [ DRAW LINE ], [ ENEMY NUMBER ], [ PLAYER HEALTH ]
    self.btnEspEnable = [self btn:@"ENABLE" frame:CGRectMake(x0, 24, colW, btnH) inView:self.scroll italic:YES];
    self.btnEspEnable.on = ds_hosted_esp_enabled();
    self.btnEspEnable.onToggle = ^(BOOL isOn) {
        ds_hosted_esp_set_enabled(isOn);
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:kDSHostedEspEnabledKey];
    };

    self.btnLine = [self btn:@"DRAW LINE" frame:CGRectMake(x1, 24, colW, btnH) inView:self.scroll italic:YES];
    self.btnLine.on = g_pubgEspLine;
    self.btnLine.onToggle = ^(BOOL isOn) {
        g_pubgEspLine = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_line"];
    };

    self.btnEnemyNum = [self btn:@"ENEMY NUMBER" frame:CGRectMake(x2, 24, colW, btnH) inView:self.scroll italic:YES];
    self.btnEnemyNum.on = g_pubgEspEnemyNumber;
    self.btnEnemyNum.onToggle = ^(BOOL isOn) {
        g_pubgEspEnemyNumber = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_enemy_num"];
    };

    self.btnHealth = [self btn:@"PLAYER HEALTH" frame:CGRectMake(x3, 24, colW, btnH) inView:self.scroll italic:YES];
    self.btnHealth.on = g_pubgEspHealth;
    self.btnHealth.onToggle = ^(BOOL isOn) {
        g_pubgEspHealth = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_health"];
    };

    // Row 1 (y = 48): [ DRAW BONE ], [ DRAW SRADAR ], [ PLAYER NAME ], [ PLAYER DIS ]
    self.btnBone = [self btn:@"DRAW BONE" frame:CGRectMake(x0, 48, colW, btnH) inView:self.scroll italic:YES];
    self.btnBone.on = g_pubgEspSkeleton;
    self.btnBone.onToggle = ^(BOOL isOn) {
        g_pubgEspSkeleton = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_skeleton"];
    };

    self.btnRadar = [self btn:@"DRAW SRADAR" frame:CGRectMake(x1, 48, colW, btnH) inView:self.scroll italic:YES];
    self.btnRadar.on = g_pubgEspRadar;
    self.btnRadar.onToggle = ^(BOOL isOn) {
        g_pubgEspRadar = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_radar"];
        weakSelf.dragMap.hidden = !isOn;
    };

    self.btnName = [self btn:@"PLAYER NAME" frame:CGRectMake(x2, 48, colW, btnH) inView:self.scroll italic:YES];
    self.btnName.on = g_pubgEspName;
    self.btnName.onToggle = ^(BOOL isOn) {
        g_pubgEspName = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_name"];
    };

    self.btnDist = [self btn:@"PLAYER DIS" frame:CGRectMake(x3, 48, colW, btnH) inView:self.scroll italic:YES];
    self.btnDist.on = g_pubgEspDist;
    self.btnDist.onToggle = ^(BOOL isOn) {
        g_pubgEspDist = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_dist"];
    };

    // Row 2 (y = 72): [ 3D BOX ], [ ARROW 360 ], [ PLAYER TEAM ], [ PLAYER FLAG ]
    self.btn3D = [self btn:@"3D BOX" frame:CGRectMake(x0, 72, colW, btnH) inView:self.scroll italic:YES];
    self.btn3D.on = g_pubgEspBox;
    self.btn3D.onToggle = ^(BOOL isOn) {
        g_pubgEspBox = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_box"];
    };

    self.btnArrow = [self btn:@"ARROW 360" frame:CGRectMake(x1, 72, colW, btnH) inView:self.scroll italic:YES];
    self.btnArrow.on = g_pubgEspArrow;
    self.btnArrow.onToggle = ^(BOOL isOn) {
        g_pubgEspArrow = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_arrow"];
    };

    self.btnTeam = [self btn:@"PLAYER TEAM" frame:CGRectMake(x2, 72, colW, btnH) inView:self.scroll italic:YES];
    self.btnTeam.on = g_pubgEspTeam;
    self.btnTeam.onToggle = ^(BOOL isOn) {
        g_pubgEspTeam = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_team"];
    };

    self.btnFlag = [self btn:@"PLAYER FLAG" frame:CGRectMake(x3, 72, colW, btnH) inView:self.scroll italic:YES];
    self.btnFlag.on = g_pubgEspFlag;
    self.btnFlag.onToggle = ^(BOOL isOn) {
        g_pubgEspFlag = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_flag"];
    };

    // Distance Slider (y = 96): [ 500 ]  DISTANCE
    self.sliderEspDist = [[MenuSliderRow alloc] initWithFrame:CGRectMake(12, 96, 476, 20) min:50 max:500 value:g_dspubgMaxDistance name:@"DISTANCE"];
    self.sliderEspDist.displayMode = MenuSliderDisplayRaw;
    self.sliderEspDist.onChange = ^(float v) {
        g_dspubgMaxDistance = v;
        [NSUserDefaults.standardUserDefaults setFloat:v forKey:@"pubg_zoom_dist"];
    };
    [self.scroll addSubview:self.sliderEspDist];

    // =========================================================================
    // SECTION 2: > MATERIAL PANEL
    // =========================================================================
    self.headerMaterial = [self addSectionHeader:@"MATERIAL PANEL" atY:122.0];

    // Row 0 (y = 142): [ ENABLE ], [ VEHICLE ], [ GRENADE WARN ], [ LOOT BOX ]
    self.btnMatEnable = [self btn:@"ENABLE" frame:CGRectMake(x0, 142, colW, btnH) inView:self.scroll italic:YES];
    self.btnMatEnable.on = (g_pubgEspWeaponAR || g_pubgEspArmorLv1 || g_pubgEspScope);
    self.btnMatEnable.onToggle = ^(BOOL isOn) {
        weakSelf.btnVeh.on = isOn;
        weakSelf.btnGrenade.on = isOn;
        weakSelf.btnLootBox.on = isOn;
        weakSelf.btnFlareGun.on = isOn;
        weakSelf.btnAirdrop.on = isOn;
        weakSelf.btnAccessory.on = isOn;
        weakSelf.btnDrug.on = isOn;
        weakSelf.btnWeaponAR.on = isOn;
        weakSelf.btnWeaponSMG.on = isOn;
        weakSelf.btnWeaponShotgun.on = isOn;
        weakSelf.btnWeaponSniper.on = isOn;
        weakSelf.btnArmorLv1.on = isOn;
        weakSelf.btnArmorLv2.on = isOn;
        weakSelf.btnArmorLv3.on = isOn;
        weakSelf.btnAmmo.on = isOn;

        g_pubgEspWeapon = isOn;
        g_pubgEspArmor = isOn;
        g_pubgEspBag = isOn;
        g_pubgEspScope = isOn;
        g_pubgEspCrate = isOn;
        g_pubgEspVehicle = isOn;
        g_pubgEspVehicleHp = isOn;
        g_pubgEspVehicleFuel = isOn;
        g_pubgEspGrenade = isOn;
        g_pubgEspFlareGun = isOn;
        g_pubgEspDrug = isOn;
        g_pubgEspWeaponAR = isOn;
        g_pubgEspWeaponSMG = isOn;
        g_pubgEspWeaponShotgun = isOn;
        g_pubgEspWeaponSniper = isOn;
        g_pubgEspArmorLv1 = isOn;
        g_pubgEspArmorLv2 = isOn;
        g_pubgEspArmorLv3 = isOn;
        g_pubgEspAmmo = isOn;

        NSUserDefaults *def = NSUserDefaults.standardUserDefaults;
        [def setBool:isOn forKey:@"pubg_weapon"];
        [def setBool:isOn forKey:@"pubg_armor"];
        [def setBool:isOn forKey:@"pubg_scope"];
        [def setBool:isOn forKey:@"pubg_bag"];
        [def setBool:isOn forKey:@"pubg_crate"];
        [def setBool:isOn forKey:@"pubg_vehicle"];
        [def setBool:isOn forKey:@"pubg_grenade"];
        [def setBool:isOn forKey:@"pubg_flaregun"];
        [def setBool:isOn forKey:@"pubg_drug"];
        [def setBool:isOn forKey:@"pubg_weapon_ar"];
        [def setBool:isOn forKey:@"pubg_weapon_smg"];
        [def setBool:isOn forKey:@"pubg_weapon_shotgun"];
        [def setBool:isOn forKey:@"pubg_weapon_sniper"];
        [def setBool:isOn forKey:@"pubg_armor_lv1"];
        [def setBool:isOn forKey:@"pubg_armor_lv2"];
        [def setBool:isOn forKey:@"pubg_armor_lv3"];
        [def setBool:isOn forKey:@"pubg_ammo"];
    };

    self.btnVeh = [self btn:@"VEHICLE" frame:CGRectMake(x1, 142, colW, btnH) inView:self.scroll italic:YES];
    self.btnVeh.on = g_pubgEspVehicle;
    self.btnVeh.onToggle = ^(BOOL isOn) {
        g_pubgEspVehicle = isOn;
        g_pubgEspVehicleHp = isOn;
        g_pubgEspVehicleFuel = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_vehicle"];
    };

    self.btnGrenade = [self btn:@"GRENADE WARN" frame:CGRectMake(x2, 142, colW, btnH) inView:self.scroll italic:YES];
    self.btnGrenade.on = g_pubgEspGrenade;
    self.btnGrenade.onToggle = ^(BOOL isOn) {
        g_pubgEspGrenade = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_grenade"];
    };

    self.btnLootBox = [self btn:@"LOOT BOX" frame:CGRectMake(x3, 142, colW, btnH) inView:self.scroll italic:YES];
    self.btnLootBox.on = g_pubgEspCrate;
    self.btnLootBox.onToggle = ^(BOOL isOn) {
        g_pubgEspCrate = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_crate"];
    };

    // Row 1 (y = 166): [ FLARE GUN ], [ AIRDROP ], [ ACCESSORY ], [ DRUG ]
    self.btnFlareGun = [self btn:@"FLARE GUN" frame:CGRectMake(x0, 166, colW, btnH) inView:self.scroll italic:YES];
    self.btnFlareGun.on = g_pubgEspFlareGun;
    self.btnFlareGun.onToggle = ^(BOOL isOn) {
        g_pubgEspFlareGun = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_flaregun"];
    };

    self.btnAirdrop = [self btn:@"AIRDROP" frame:CGRectMake(x1, 166, colW, btnH) inView:self.scroll italic:YES];
    self.btnAirdrop.on = g_pubgEspCrate;
    self.btnAirdrop.onToggle = ^(BOOL isOn) {
        g_pubgEspCrate = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_crate"];
    };

    self.btnAccessory = [self btn:@"ACCESSORY" frame:CGRectMake(x2, 166, colW, btnH) inView:self.scroll italic:YES];
    self.btnAccessory.on = g_pubgEspScope;
    self.btnAccessory.onToggle = ^(BOOL isOn) {
        g_pubgEspScope = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_scope"];
    };

    self.btnDrug = [self btn:@"DRUG" frame:CGRectMake(x3, 166, colW, btnH) inView:self.scroll italic:YES];
    self.btnDrug.on = g_pubgEspDrug;
    self.btnDrug.onToggle = ^(BOOL isOn) {
        g_pubgEspDrug = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_drug"];
    };

    // Thin yellow separator line (y = 191)
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, 191, 476, 0.8)];
    sep.backgroundColor = [DSColorAccent() colorWithAlphaComponent:0.45];
    [self.scroll addSubview:sep];

    // Row 2 (y = 196): [ AR ], [ SMG ], [ SHOTGUN ], [ SNIPER ]
    self.btnWeaponAR = [self btn:@"AR" frame:CGRectMake(x0, 196, colW, btnH) inView:self.scroll italic:YES];
    self.btnWeaponAR.on = g_pubgEspWeaponAR;
    self.btnWeaponAR.onToggle = ^(BOOL isOn) {
        g_pubgEspWeaponAR = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_weapon_ar"];
    };

    self.btnWeaponSMG = [self btn:@"SMG" frame:CGRectMake(x1, 196, colW, btnH) inView:self.scroll italic:YES];
    self.btnWeaponSMG.on = g_pubgEspWeaponSMG;
    self.btnWeaponSMG.onToggle = ^(BOOL isOn) {
        g_pubgEspWeaponSMG = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_weapon_smg"];
    };

    self.btnWeaponShotgun = [self btn:@"SHOTGUN" frame:CGRectMake(x2, 196, colW, btnH) inView:self.scroll italic:YES];
    self.btnWeaponShotgun.on = g_pubgEspWeaponShotgun;
    self.btnWeaponShotgun.onToggle = ^(BOOL isOn) {
        g_pubgEspWeaponShotgun = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_weapon_shotgun"];
    };

    self.btnWeaponSniper = [self btn:@"SNIPER" frame:CGRectMake(x3, 196, colW, btnH) inView:self.scroll italic:YES];
    self.btnWeaponSniper.on = g_pubgEspWeaponSniper;
    self.btnWeaponSniper.onToggle = ^(BOOL isOn) {
        g_pubgEspWeaponSniper = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_weapon_sniper"];
    };

    // Row 3 (y = 220): [ LEVEL 1 ], [ LEVEL 2 ], [ LEVEL 3 ], [ AMMO ]
    self.btnArmorLv1 = [self btn:@"LEVEL 1" frame:CGRectMake(x0, 220, colW, btnH) inView:self.scroll italic:YES];
    self.btnArmorLv1.on = g_pubgEspArmorLv1;
    self.btnArmorLv1.onToggle = ^(BOOL isOn) {
        g_pubgEspArmorLv1 = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_armor_lv1"];
    };

    self.btnArmorLv2 = [self btn:@"LEVEL 2" frame:CGRectMake(x1, 220, colW, btnH) inView:self.scroll italic:YES];
    self.btnArmorLv2.on = g_pubgEspArmorLv2;
    self.btnArmorLv2.onToggle = ^(BOOL isOn) {
        g_pubgEspArmorLv2 = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_armor_lv2"];
    };

    self.btnArmorLv3 = [self btn:@"LEVEL 3" frame:CGRectMake(x2, 220, colW, btnH) inView:self.scroll italic:YES];
    self.btnArmorLv3.on = g_pubgEspArmorLv3;
    self.btnArmorLv3.onToggle = ^(BOOL isOn) {
        g_pubgEspArmorLv3 = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_armor_lv3"];
    };

    self.btnAmmo = [self btn:@"AMMO" frame:CGRectMake(x3, 220, colW, btnH) inView:self.scroll italic:YES];
    self.btnAmmo.on = g_pubgEspAmmo;
    self.btnAmmo.onToggle = ^(BOOL isOn) {
        g_pubgEspAmmo = isOn;
        [NSUserDefaults.standardUserDefaults setBool:isOn forKey:@"pubg_ammo"];
    };

    // Material Distance Slider (y = 246): [ 300 ]  DISTANCE
    self.sliderItemDist = [[MenuSliderRow alloc] initWithFrame:CGRectMake(12, 246, 476, 20) min:50 max:500 value:g_pubgItemMaxDistance name:@"DISTANCE"];
    self.sliderItemDist.displayMode = MenuSliderDisplayRaw;
    self.sliderItemDist.onChange = ^(float v) {
        g_pubgItemMaxDistance = v;
        [NSUserDefaults.standardUserDefaults setFloat:v forKey:@"pubg_item_dist"];
    };
    [self.scroll addSubview:self.sliderItemDist];

    self.scroll.contentSize = CGSizeMake(kMadnessPanelW, 280);
    self.scroll.alwaysBounceHorizontal = YES;
    [self updateLanguage:self.currentLang];
}

#pragma mark - Reset to Defaults

- (void)resetToDefaults {
    [self.haptic impactOccurred];
    g_pubgEspBox = YES;
    g_pubgEspLine = YES;
    g_pubgEspSkeleton = YES;
    g_pubgEspName = YES;
    g_pubgEspDist = YES;
    g_pubgEspHealth = YES;
    g_pubgEspBot = YES;
    g_pubgEspEnemyNumber = YES;
    g_pubgEspRadar = YES;
    g_pubgEspTeam = YES;
    g_pubgEspFlag = YES;
    g_pubgEspArrow = YES;
    g_pubgEspGrenade = YES;
    g_dspubgMaxDistance = 400.0f;

    g_pubgEspWeapon = YES;
    g_pubgEspArmor = YES;
    g_pubgEspBag = YES;
    g_pubgEspScope = YES;
    g_pubgEspCrate = YES;
    g_pubgEspFlareGun = YES;
    g_pubgEspDrug = YES;
    g_pubgEspWeaponAR = YES;
    g_pubgEspWeaponSMG = YES;
    g_pubgEspWeaponShotgun = YES;
    g_pubgEspWeaponSniper = YES;
    g_pubgEspArmorLv1 = YES;
    g_pubgEspArmorLv2 = YES;
    g_pubgEspArmorLv3 = YES;
    g_pubgEspAmmo = YES;
    g_pubgItemMaxDistance = 150.0f;
    g_pubgEspVehicle = YES;
    g_pubgEspVehicleHp = YES;
    g_pubgEspVehicleFuel = YES;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"pubg_box"];
    [defaults setBool:YES forKey:@"pubg_line"];
    [defaults setBool:YES forKey:@"pubg_skeleton"];
    [defaults setBool:YES forKey:@"pubg_name"];
    [defaults setBool:YES forKey:@"pubg_dist"];
    [defaults setBool:YES forKey:@"pubg_health"];
    [defaults setBool:YES forKey:@"pubg_bot"];
    [defaults setBool:YES forKey:@"pubg_enemy_num"];
    [defaults setBool:YES forKey:@"pubg_radar"];
    [defaults setBool:YES forKey:@"pubg_team"];
    [defaults setBool:YES forKey:@"pubg_flag"];
    [defaults setBool:YES forKey:@"pubg_arrow"];
    [defaults setBool:YES forKey:@"pubg_grenade"];
    [defaults setFloat:400.0f forKey:@"pubg_zoom_dist"];
    [defaults setBool:YES forKey:@"pubg_weapon"];
    [defaults setBool:YES forKey:@"pubg_armor"];
    [defaults setBool:YES forKey:@"pubg_bag"];
    [defaults setBool:YES forKey:@"pubg_scope"];
    [defaults setBool:YES forKey:@"pubg_crate"];
    [defaults setBool:YES forKey:@"pubg_flaregun"];
    [defaults setBool:YES forKey:@"pubg_drug"];
    [defaults setBool:YES forKey:@"pubg_weapon_ar"];
    [defaults setBool:YES forKey:@"pubg_weapon_smg"];
    [defaults setBool:YES forKey:@"pubg_weapon_shotgun"];
    [defaults setBool:YES forKey:@"pubg_weapon_sniper"];
    [defaults setBool:YES forKey:@"pubg_armor_lv1"];
    [defaults setBool:YES forKey:@"pubg_armor_lv2"];
    [defaults setBool:YES forKey:@"pubg_armor_lv3"];
    [defaults setBool:YES forKey:@"pubg_ammo"];
    [defaults setFloat:150.0f forKey:@"pubg_item_dist"];
    [defaults setBool:YES forKey:@"pubg_vehicle"];
    [defaults setBool:YES forKey:@"pubg_vehicle_hp"];
    [defaults setBool:YES forKey:@"pubg_vehicle_fuel"];

    self.btnEspEnable.on = YES;
    self.btnLine.on = YES;
    self.btnEnemyNum.on = YES;
    self.btnHealth.on = YES;
    self.btnBone.on = YES;
    self.btnRadar.on = YES;
    self.btnName.on = YES;
    self.btnDist.on = YES;
    self.btn3D.on = YES;
    self.btnArrow.on = YES;
    self.btnTeam.on = YES;
    self.btnFlag.on = YES;
    [self.sliderEspDist setSliderValue:400.0f];

    self.btnMatEnable.on = YES;
    self.btnVeh.on = YES;
    self.btnGrenade.on = YES;
    self.btnLootBox.on = YES;
    self.btnFlareGun.on = YES;
    self.btnAirdrop.on = YES;
    self.btnAccessory.on = YES;
    self.btnDrug.on = YES;
    self.btnWeaponAR.on = YES;
    self.btnWeaponSMG.on = YES;
    self.btnWeaponShotgun.on = YES;
    self.btnWeaponSniper.on = YES;
    self.btnArmorLv1.on = YES;
    self.btnArmorLv2.on = YES;
    self.btnArmorLv3.on = YES;
    self.btnAmmo.on = YES;
    [self.sliderItemDist setSliderValue:150.0f];
}

#pragma mark - Open / close (controllview order)

- (void)controllview {
    [self.haptic impactOccurred];
    self.asize = YES;
    self.isShowMenu = YES;
    g_hostedMenuExpanded = YES;

    CGFloat maxW = self.superview ? self.superview.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    CGFloat maxH = self.superview ? self.superview.bounds.size.height : [UIScreen mainScreen].bounds.size.height;
    if (maxW < maxH) { CGFloat tmp = maxW; maxW = maxH; maxH = tmp; }
    CGFloat targetW = MIN(kMadnessPanelW, maxW - 20.0f);
    CGFloat targetH = MIN(kMadnessPanelH, maxH - 20.0f);
    // Compact phones cannot fit the full 500pt grid: the content scroll view
    // keeps its 500pt intrinsic width and scrolls horizontally instead.

    CGRect pf = self.panel.frame;
    if (pf.origin.x + targetW > maxW) pf.origin.x = MAX(10.0f, maxW - targetW - 10.0f);
    if (pf.origin.y + targetH > maxH) pf.origin.y = MAX(10.0f, maxH - targetH - 10.0f);

    self.panel.backgroundColor = [DSColorInk() colorWithAlphaComponent:0.88];
    self.panel.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.9].CGColor;
    self.panel.layer.borderWidth = 1.0;
    self.panel.layer.cornerRadius = 18.0;
    self.panel.layer.cornerCurve = kCACornerCurveContinuous;

    [self.handle removeGestureRecognizer:self.handleTap];
    self.handleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllview1)];
    [self.handle addGestureRecognizer:self.handleTap];

    self.handleGlyph.frame = CGRectMake(0, 0, 24, 24);
    self.handleGlyph.text = @"V";
    self.handleGlyph.font = DSFontBody(12.0, UIFontWeightHeavy);

    // Header row packs from the right edge so it survives narrow panels:
    // [ handle ] [ DARKSWORD ] ... [ ENG | VIE ] [ DLX07 ] [ @DLX07 ] [ kernel ]
    // Chips are grouped so the language pair is never split, and any group
    // that no longer fits is hidden instead of overlapping the title.
    self.titleBox.frame = CGRectMake(34, 4, targetW - 42, 24);
    const CGFloat titleInset = 122.0f;   // handle circle + title + mascot
    const CGFloat chipGap = 4.0f;
    const CGFloat wEng = 30.0f, wVie = 28.0f, wContact = 54.0f;
    const CGFloat wHandle = 62.0f, wKernel = 118.0f;

    // Right-to-left cursor; each group is placed only if it fully fits.
    CGFloat cursor = self.titleBox.bounds.size.width - 6.0f;
    BOOL roomLeft = YES;

    // Group 1: language pair (right-most, always kept when possible).
    roomLeft = roomLeft && (cursor - (wEng + chipGap + wVie) >= titleInset);
    self.btnEng.hidden = !roomLeft;
    self.btnVie.hidden = !roomLeft;
    if (roomLeft) {
        self.btnVie.frame = CGRectMake(cursor - wVie, 3, wVie, 18);
        self.btnEng.frame = CGRectMake(cursor - wVie - chipGap - wEng, 3, wEng, 18);
        cursor -= (wEng + chipGap + wVie + chipGap);
    }

    // Group 2: contact chip.
    roomLeft = roomLeft && (cursor - wContact >= titleInset);
    self.contactBtn.hidden = !roomLeft;
    if (roomLeft) {
        self.contactBtn.frame = CGRectMake(cursor - wContact, 3, wContact, 18);
        cursor -= (wContact + chipGap);
    }

    // Group 3: handles.
    roomLeft = roomLeft && (cursor - wHandle >= titleInset);
    self.handleMajed.hidden = !roomLeft;
    if (roomLeft) {
        self.handleMajed.frame = CGRectMake(cursor - wHandle, 3, wHandle, 18);
        cursor -= (wHandle + chipGap);
    }

    roomLeft = roomLeft && (cursor - wKernel >= titleInset);
    self.handleChan.hidden = !roomLeft;
    if (roomLeft) {
        self.handleChan.frame = CGRectMake(cursor - wKernel, 3, wKernel, 18);
        cursor -= (wKernel + chipGap);
    }

    self.clockLabel.hidden = NO;
    self.batteryLabel.hidden = NO;
    self.sloganLabel.hidden = NO;
    self.scroll.hidden = NO;

    self.panel.frame = CGRectMake(pf.origin.x, pf.origin.y, targetW, targetH);
    self.scroll.frame = CGRectMake(0, 50, targetW, targetH - 50);
    // Always keep the full 500pt design width so the four columns stay
    // aligned; narrow panels scroll horizontally rather than reflow.
    self.scroll.contentSize = CGSizeMake(MAX(kMadnessPanelW, targetW), 280);
}

- (void)controllview1 {
    [self.haptic impactOccurred];
    self.asize = NO;
    self.isShowMenu = NO;
    g_hostedMenuExpanded = NO;

    CGRect pf = self.panel.frame;
    self.panel.frame = CGRectMake(pf.origin.x, pf.origin.y, 158, 30);
    self.panel.backgroundColor = UIColor.clearColor;
    self.panel.layer.borderWidth = 0.0;
    self.scroll.hidden = YES;
    self.clockLabel.hidden = YES;
    self.batteryLabel.hidden = YES;
    self.sloganLabel.hidden = YES;

    // Show ONLY icon DARKSWORD: hide language buttons, contact, and handles
    self.btnEng.hidden = YES;
    self.btnVie.hidden = YES;
    self.contactBtn.hidden = YES;
    self.handleMajed.hidden = YES;
    self.handleChan.hidden = YES;

    [self.handle removeGestureRecognizer:self.handleTap];
    self.handleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllview)];
    [self.handle addGestureRecognizer:self.handleTap];

    self.handleGlyph.frame = CGRectMake(0, 0, 24, 24);
    self.handleGlyph.text = @"⋗";
    self.handleGlyph.font = DSFontBody(16.0, UIFontWeightHeavy);
    self.titleBox.frame = CGRectMake(32, 3, 118, 24);
}

- (void)titleBoxTapped:(UITapGestureRecognizer *)gr {
    if (!self.asize) {
        [self controllview];
    }
}

- (void)handleTapped:(UIButton *)sender {
    if (self.asize) [self controllview1]; else [self controllview];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    if (self.asize) [self controllview1]; else [self controllview];
}

#pragma mark - UIGestureRecognizerDelegate & Pan Dragging

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.panGesture || gestureRecognizer == self.titlePan) {
        // Do not intercept taps on the expand/collapse handle button
        if ([touch.view isDescendantOfView:self.handle]) {
            return NO;
        }
        // Do not intercept taps on the contact button
        if ([touch.view isDescendantOfView:self.contactBtn]) {
            return NO;
        }
        // Do not intercept taps on language buttons
        if ([touch.view isDescendantOfView:self.btnEng] || [touch.view isDescendantOfView:self.btnVie]) {
            return NO;
        }
        // In collapsed mode: allow panning anywhere on the bar
        if (!self.asize) {
            return YES;
        }
        // In expanded mode: allow panning from top header area (above scroll view)
        CGPoint loc = [touch locationInView:self.panel];
        if (loc.y < 50.0f) {
            return YES;
        }
        return NO;
    }
    return YES;
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)pan {
    UIView *superView = self.panel.superview ?: self;
    CGPoint translation = [pan translationInView:superView];
    CGPoint c = self.panel.center;
    c.x += translation.x;
    c.y += translation.y;

    CGFloat halfW = self.panel.bounds.size.width * 0.5f;
    CGFloat halfH = self.panel.bounds.size.height * 0.5f;
    CGFloat maxW = superView.bounds.size.width;
    CGFloat maxH = superView.bounds.size.height;
    if (maxW > 100 && maxH > 100) {
        c.x = MIN(MAX(c.x, halfW), maxW - halfW);
        c.y = MIN(MAX(c.y, halfH), maxH - halfH);
    }
    self.panel.center = c;
    [pan setTranslation:CGPointZero inView:superView];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:c.x forKey:@"madness_menu_x"];
        [NSUserDefaults.standardUserDefaults setDouble:c.y forKey:@"madness_menu_y"];
    }
}

- (void)handleRadarPan:(UIPanGestureRecognizer *)pan {
    UIView *superView = self.dragMap.superview ?: self;
    CGPoint translation = [pan translationInView:superView];
    CGPoint c = self.dragMap.center;
    c.x += translation.x;
    c.y += translation.y;

    CGFloat halfW = self.dragMap.bounds.size.width * 0.5f;
    CGFloat halfH = self.dragMap.bounds.size.height * 0.5f;
    CGFloat maxW = superView.bounds.size.width;
    CGFloat maxH = superView.bounds.size.height;
    if (maxW > 100 && maxH > 100) {
        c.x = MIN(MAX(c.x, halfW), maxW - halfW);
        c.y = MIN(MAX(c.y, halfH), maxH - halfH);
    }
    self.dragMap.center = c;
    [pan setTranslation:CGPointZero inView:superView];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:c.x forKey:@"madness_radar_x"];
        [NSUserDefaults.standardUserDefaults setDouble:c.y forKey:@"madness_radar_y"];
    }
}

- (void)wasDragged:(UIButton *)sender withEvent:(UIEvent *)event {
    UITouch *t = [[event touchesForView:sender] anyObject];
    if (!t) return;
    UIView *superView = sender.superview ?: self;
    CGPoint prev = [t previousLocationInView:superView];
    CGPoint loc  = [t locationInView:superView];
    CGFloat dx = loc.x - prev.x;
    CGFloat dy = loc.y - prev.y;
    CGPoint c = sender.center;
    CGPoint newCenter = CGPointMake(c.x + dx, c.y + dy);

    CGFloat halfW = sender.bounds.size.width * 0.5;
    CGFloat halfH = sender.bounds.size.height * 0.5;
    CGFloat maxW = superView.bounds.size.width;
    CGFloat maxH = superView.bounds.size.height;
    if (maxW > 100 && maxH > 100) {
        newCenter.x = MIN(MAX(newCenter.x, halfW), maxW - halfW);
        newCenter.y = MIN(MAX(newCenter.y, halfH), maxH - halfH);
    }
    sender.center = newCenter;

    [NSUserDefaults.standardUserDefaults setDouble:newCenter.x forKey:@"madness_menu_x"];
    [NSUserDefaults.standardUserDefaults setDouble:newCenter.y forKey:@"madness_menu_y"];
}

- (void)wasDraggedm:(UIButton *)sender withEventm:(UIEvent *)event {
    UITouch *t = [[event touchesForView:sender] anyObject];
    if (!t) return;
    UIView *superView = sender.superview ?: self;
    CGPoint prev = [t previousLocationInView:superView];
    CGPoint loc  = [t locationInView:superView];
    CGFloat dx = loc.x - prev.x;
    CGFloat dy = loc.y - prev.y;
    CGPoint c = sender.center;
    CGPoint newCenter = CGPointMake(c.x + dx, c.y + dy);

    CGFloat halfW = sender.bounds.size.width * 0.5;
    CGFloat halfH = sender.bounds.size.height * 0.5;
    CGFloat maxW = superView.bounds.size.width;
    CGFloat maxH = superView.bounds.size.height;
    if (maxW > 100 && maxH > 100) {
        newCenter.x = MIN(MAX(newCenter.x, halfW), maxW - halfW);
        newCenter.y = MIN(MAX(newCenter.y, halfH), maxH - halfH);
    }
    sender.center = newCenter;

    [NSUserDefaults.standardUserDefaults setDouble:newCenter.x forKey:@"madness_radar_x"];
    [NSUserDefaults.standardUserDefaults setDouble:newCenter.y forKey:@"madness_radar_y"];
}

#pragma mark - Preview hooks

- (void)previewResetUIState {
    [self resetToDefaults];
}

- (void)previewOpen { [self controllview]; }
- (void)previewClose { [self controllview1]; }
- (void)previewSelectTab:(NSUInteger)index { (void)index; }
- (void)previewLongPressToggle {
    if (self.asize) [self controllview1]; else [self controllview];
}
- (void)previewNudgePanel:(CGPoint)delta {
    CGPoint c = self.panel.center;
    self.panel.center = CGPointMake(c.x + delta.x, c.y + delta.y);
}
- (UIView *)menuPanel { return self.panel; }
- (id)previewPageSwitch { return nil; }
- (UIScrollView *)previewScroll { return self.scroll; }
- (void)previewSetScrollOffset:(CGPoint)o { self.scroll.contentOffset = o; }
- (void)previewToggleFirstButton {
    [self.btnEspEnable sendActionsForControlEvents:UIControlEventTouchUpInside];
}
- (void)previewNudgeSlider {
    [self.sliderEspDist setSliderValue:250];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (fabs(scrollView.contentOffset.x) > 0.05) {
        scrollView.contentOffset = CGPointMake(0, scrollView.contentOffset.y);
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    /* Touches on empty overlay must reach the app underneath */
    if (hit == self) return nil;
    return hit;
}

+ (instancetype)attachToWindow:(UIWindow *)window {
    for (UIView *sub in window.subviews) {
        if ([sub isKindOfClass:[MadnessMenuView class]]) return (MadnessMenuView *)sub;
    }
    MadnessMenuView *v = [[MadnessMenuView alloc] initWithFrame:window.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:v];
    return v;
}
- (void)loadMenu {}

@end
