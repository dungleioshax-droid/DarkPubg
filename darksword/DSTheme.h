//
//  DSTheme.h
//  DarkPubg
//
//  Shared visual language for every DarkPubg surface: the in-app shell,
//  the in-game Madness menu, the floating HUD and the console log.
//  Objective-C only, header-only, so it can be included from any translation
//  unit (the app shell, DSBridge and the injected menu) without linking code.
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Palette

// Deep obsidian-navy surfaces with cool indigo undertones so luminous gold
// and electric cyan accents pop cleanly with high contrast.
#define DSColorInk()        [UIColor colorWithRed:0.027 green:0.035 blue:0.059 alpha:1.0]   // #07090F
#define DSColorSurface()    [UIColor colorWithRed:0.063 green:0.078 blue:0.122 alpha:1.0]   // #10141F
#define DSColorSurfaceHi()  [UIColor colorWithRed:0.094 green:0.118 blue:0.180 alpha:1.0]   // #181E2E
#define DSColorHairline()   [UIColor colorWithRed:0.165 green:0.204 blue:0.298 alpha:1.0]   // #2A344C

// Signature accent: luminous tactical gold-amber paired with cool sky cyan.
#define DSColorAccent()     [UIColor colorWithRed:0.980 green:0.780 blue:0.220 alpha:1.0]   // #FAC738
#define DSColorAccentHi()   [UIColor colorWithRed:0.996 green:0.878 blue:0.420 alpha:1.0]   // #FEE06B
#define DSColorAccentLo()   [UIColor colorWithRed:0.945 green:0.580 blue:0.080 alpha:1.0]   // #F19414
#define DSColorAccentDim()  [UIColor colorWithRed:0.980 green:0.780 blue:0.220 alpha:0.16]

#define DSColorSuccess()    [UIColor colorWithRed:0.204 green:0.827 blue:0.600 alpha:1.0]   // #34D399
#define DSColorWarning()    [UIColor colorWithRed:0.984 green:0.749 blue:0.141 alpha:1.0]   // #FBBF24
#define DSColorDanger()     [UIColor colorWithRed:0.957 green:0.247 blue:0.369 alpha:1.0]   // #F43F5E
#define DSColorDangerLo()   [UIColor colorWithRed:0.840 green:0.120 blue:0.280 alpha:1.0]   // #D61F47
#define DSColorInfo()       [UIColor colorWithRed:0.220 green:0.741 blue:0.973 alpha:1.0]   // #38BDF8
#define DSColorViolet()     [UIColor colorWithRed:0.545 green:0.361 blue:0.965 alpha:1.0]   // #8B5CF6

// Ink used for text/icons sitting on the bright accent fill.
#define DSColorOnAccent()   [UIColor colorWithRed:0.043 green:0.051 blue:0.071 alpha:1.0]   // #0B0D12

#define DSColorTextPrimary()   UIColor.whiteColor
#define DSColorTextSecondary() [UIColor colorWithRed:0.686 green:0.733 blue:0.816 alpha:1.0] // #AFBBD0
#define DSColorTextTertiary()  [UIColor colorWithRed:0.439 green:0.494 blue:0.592 alpha:1.0] // #707E97

#pragma mark - Metrics

#define DSRadiusCard      18.0
#define DSRadiusControl   12.0
#define DSGutter          18.0
#define DSSectionGap      14.0

#pragma mark - Type

// Headings use SF Rounded for a friendlier silhouette; body stays on the
// system face so Vietnamese diacritics render correctly at small sizes.
// The rounded design is requested through the system descriptor so it works
// even on devices that do not expose an "SFProRounded-*" PostScript name.
static inline UIFont *DSRoundedFont(CGFloat size, UIFontWeight weight) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *descriptor = [base.fontDescriptor
        fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    if (!descriptor) return base;
    UIFont *rounded = [UIFont fontWithDescriptor:descriptor size:size];
    return rounded ?: base;
}

static inline UIFont *DSFontDisplay(CGFloat size) {
    return DSRoundedFont(size, UIFontWeightHeavy);
}

static inline UIFont *DSFontTitle(CGFloat size) {
    return DSRoundedFont(size, UIFontWeightBold);
}

static inline UIFont *DSFontBody(CGFloat size, UIFontWeight weight) {
    return [UIFont systemFontOfSize:size weight:weight];
}

static inline UIFont *DSFontMono(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

#pragma mark - Motion

#define DSMotionFast    0.18
#define DSMotionNormal  0.26

#pragma mark - Surface helpers

/// Card chrome: frosted obsidian fill, subtle top-lit border, soft drop shadow.
static inline void DSApplyCard(UIView *view, CGFloat radius) {
    if (!view) return;
    view.backgroundColor = [DSColorSurface() colorWithAlphaComponent:0.94];
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.85].CGColor;
    view.layer.shadowColor = UIColor.blackColor.CGColor;
    view.layer.shadowOpacity = 0.42f;
    view.layer.shadowRadius = 20.0f;
    view.layer.shadowOffset = CGSizeMake(0, 10);
    view.layer.masksToBounds = NO;
}

/// Primary CTA styling shared by the shell and in-game menu.
static inline void DSApplyPrimaryButton(UIButton *button, BOOL destructive) {
    if (!button) return;
    UIColor *fill = destructive ? DSColorDanger() : DSColorAccent();
    button.backgroundColor = fill;
    button.layer.cornerRadius = DSRadiusControl + 6.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.shadowColor = fill.CGColor;
    button.layer.shadowOpacity = 0.35f;
    button.layer.shadowRadius = 20.0f;
    button.layer.shadowOffset = CGSizeMake(0, 8);
    [button setTitleColor:DSColorOnAccent() forState:UIControlStateNormal];
    button.titleLabel.font = DSFontTitle(17.0);
}

/// Secondary "ghost" button used for utilities.
static inline void DSApplyGhostButton(UIButton *button, UIColor *tint) {
    if (!button) return;
    button.backgroundColor = DSColorSurfaceHi();
    button.layer.cornerRadius = DSRadiusControl;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [tint colorWithAlphaComponent:0.30].CGColor;
    [button setTitleColor:tint forState:UIControlStateNormal];
    button.titleLabel.font = DSFontBody(13.0, UIFontWeightBold);
}

NS_ASSUME_NONNULL_END
