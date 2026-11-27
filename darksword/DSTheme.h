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

// Native Apple iOS Dark Mode system colors (HIG InsetGrouped palette).
#define DSColorInk()        [UIColor colorWithRed:0.000 green:0.000 blue:0.000 alpha:1.0]   // systemGroupedBackground (#000000)
#define DSColorSurface()    [UIColor colorWithRed:0.110 green:0.110 blue:0.118 alpha:1.0]   // secondarySystemGroupedBackground (#1C1C1E)
#define DSColorSurfaceHi()  [UIColor colorWithRed:0.173 green:0.173 blue:0.180 alpha:1.0]   // tertiarySystemGroupedBackground (#2C2C2E)
#define DSColorHairline()   [UIColor colorWithRed:0.220 green:0.220 blue:0.227 alpha:1.0]   // separator (#38383A)

// Signature accent: Apple iOS System Blue.
#define DSColorAccent()     [UIColor colorWithRed:0.039 green:0.518 blue:1.000 alpha:1.0]   // systemBlue (#0A84FF)
#define DSColorAccentHi()   [UIColor colorWithRed:0.251 green:0.612 blue:1.000 alpha:1.0]   // #409CFF
#define DSColorAccentLo()   [UIColor colorWithRed:0.000 green:0.439 blue:0.961 alpha:1.0]   // #0070F5
#define DSColorAccentDim()  [UIColor colorWithRed:0.039 green:0.518 blue:1.000 alpha:0.18]

#define DSColorSuccess()    [UIColor colorWithRed:0.188 green:0.820 blue:0.345 alpha:1.0]   // systemGreen (#30D158)
#define DSColorWarning()    [UIColor colorWithRed:1.000 green:0.624 blue:0.039 alpha:1.0]   // systemOrange (#FF9F0A)
#define DSColorDanger()     [UIColor colorWithRed:1.000 green:0.271 blue:0.227 alpha:1.0]   // systemRed (#FF453A)
#define DSColorDangerLo()   [UIColor colorWithRed:0.863 green:0.196 blue:0.176 alpha:1.0]   // #DC322D
#define DSColorInfo()       [UIColor colorWithRed:0.392 green:0.824 blue:1.000 alpha:1.0]   // systemCyan (#64D2FF)
#define DSColorViolet()     [UIColor colorWithRed:0.369 green:0.361 blue:0.902 alpha:1.0]   // systemIndigo (#5E5CE6)

// Ink used for text/icons sitting on the filled accent button.
#define DSColorOnAccent()   UIColor.whiteColor

#define DSColorTextPrimary()   UIColor.whiteColor
#define DSColorTextSecondary() [UIColor colorWithRed:0.922 green:0.922 blue:0.961 alpha:0.60] // secondaryLabel
#define DSColorTextTertiary()  [UIColor colorWithRed:0.922 green:0.922 blue:0.961 alpha:0.38] // tertiaryLabel

#pragma mark - Metrics

#define DSRadiusCard      12.0
#define DSRadiusControl   10.0
#define DSGutter          16.0
#define DSSectionGap      22.0

#pragma mark - Type

// Native iOS San Francisco Pro typography across headings, body, and mono.
static inline UIFont *DSRoundedFont(CGFloat size, UIFontWeight weight) {
    return [UIFont systemFontOfSize:size weight:weight];
}

static inline UIFont *DSFontDisplay(CGFloat size) {
    return [UIFont systemFontOfSize:size weight:UIFontWeightBold];
}

static inline UIFont *DSFontTitle(CGFloat size) {
    return [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
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

/// Native iOS InsetGrouped card surface (clean #1C1C1E without heavy glow/shadows).
static inline void DSApplyCard(UIView *view, CGFloat radius) {
    if (!view) return;
    view.backgroundColor = DSColorSurface();
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.0;
    view.layer.shadowOpacity = 0.0f;
    view.layer.masksToBounds = YES;
}

/// Primary iOS filled button styling.
static inline void DSApplyPrimaryButton(UIButton *button, BOOL destructive) {
    if (!button) return;
    UIColor *fill = destructive ? DSColorDanger() : DSColorAccent();
    button.backgroundColor = fill;
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.shadowOpacity = 0.0f;
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
