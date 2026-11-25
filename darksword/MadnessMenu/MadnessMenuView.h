// MadnessMenuView — floating menu UI clone of MADNESS.dylib JFOverlayView (menu only).
// Toolkit: pure UIKit (UIButton / UIScrollView / UISlider / CALayer borders). No ImGui.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MadnessMenuView : UIView

/// Local stub state — NOT connected to any game / memory / fake-touch.
@property (nonatomic, assign) BOOL isShowMenu;

// ESP stubs
@property (nonatomic, assign) BOOL isLineEsp;
@property (nonatomic, assign) BOOL isBoneEsp;
@property (nonatomic, assign) BOOL isHpBarEsp;
@property (nonatomic, assign) BOOL isTextEsp;
@property (nonatomic, assign) BOOL is3DBOX;
@property (nonatomic, assign) BOOL isRadarM;
@property (nonatomic, assign) BOOL Arrow;
@property (nonatomic, assign) float espDistance;

// Aimbot stubs (UI only)
@property (nonatomic, assign) BOOL isAimbot;
@property (nonatomic, assign) BOOL isAimbotscope;
@property (nonatomic, assign) BOOL isNearDeathNotAim;
@property (nonatomic, assign) BOOL isAimbotA;
@property (nonatomic, assign) BOOL Autofire;
@property (nonatomic, assign) BOOL isBulletTrack;
@property (nonatomic, assign) BOOL isNorecoil;
@property (nonatomic, assign) BOOL NoSpread;
@property (nonatomic, assign) BOOL SpeedFire;
@property (nonatomic, assign) BOOL isAutoBulletTrack;
@property (nonatomic, assign) NSInteger aimbotPart; // 4 chest / 5 neck / 6 head / auto
@property (nonatomic, assign) float aimbotRadius;
@property (nonatomic, assign) float aimdis;

// Material stubs
@property (nonatomic, assign) BOOL isShowProps;
@property (nonatomic, assign) BOOL isShowPropsVehicle;
@property (nonatomic, assign) BOOL isShowPropsWeapon;
@property (nonatomic, assign) BOOL isShowPropsArmor;
@property (nonatomic, assign) BOOL isShowPropsSight;
@property (nonatomic, assign) BOOL isShowPropsBullet;
@property (nonatomic, assign) BOOL isShowPropsAccessory;
@property (nonatomic, assign) BOOL isShowPropsDrug;
@property (nonatomic, assign) BOOL isShowPropsEarlyWarning;
@property (nonatomic, assign) float propsDistance;

// Advanced / move stubs
@property (nonatomic, assign) BOOL isFland;
@property (nonatomic, assign) BOOL isFnok;
@property (nonatomic, assign) BOOL isFstc;
@property (nonatomic, assign) BOOL isGV;
@property (nonatomic, assign) float changeviewval;
@property (nonatomic, assign) float fastbulletval;

+ (instancetype)attachToWindow:(UIWindow *)window;
- (void)loadMenu; // original selector spelling: looadmenu
- (void)resetToDefaults;
- (void)updateRadarWithPlayers:(nullable const void *)players count:(int)count;

@property (nonatomic, strong, readonly) UIButton *panel;
@property (nonatomic, strong, readonly) UIButton *handle;
@property (nonatomic, strong, readonly) UIButton *dragMap;

/// DemoHost / simctl preview helpers (menu chrome only)
- (void)previewResetUIState;
- (void)previewOpen;
- (void)previewClose;
- (void)previewSelectTab:(NSUInteger)index;
- (void)previewLongPressToggle;
- (void)previewNudgePanel:(CGPoint)delta;
- (UIView *)menuPanel;
- (id)previewPageSwitch;
- (UIScrollView *)previewScroll;
- (void)previewSetScrollOffset:(CGPoint)o;
- (void)previewToggleFirstButton;
- (void)previewNudgeSlider;

@end

NS_ASSUME_NONNULL_END
