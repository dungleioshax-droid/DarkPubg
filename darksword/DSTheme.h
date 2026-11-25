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

// Deep, slightly blue-black surfaces. Values are deliberately desaturated so
// the neon accent stays the only saturated colour on screen.
#define DSColorInk()        [UIColor colorWithRed:0.035 green:0.043 blue:0.059 alpha:1.0]   // #090B0F
#define DSColorSurface()    [UIColor colorWithRed:0.067 green:0.078 blue:0.102 alpha:1.0]   // #11141A
#define DSColorSurfaceHi()  [UIColor colorWithRed:0.094 green:0.110 blue:0.141 alpha:1.0]   // #181C24
#define DSColorHairline()   [UIColor colorWithRed:0.180 green:0.204 blue:0.250 alpha:1.0]   // #2E3440

// Signature accent: electric mint. Used for primary actions, live state and
// focus rings only.
#define DSColorAccent()     [UIColor colorWithRed:0.180 green:0.980 blue:0.800 alpha:1.0]   // #2EFACC
#define DSColorAccentDim()  [UIColor colorWithRed:0.180 green:0.980 blue:0.800 alpha:0.16]

#define DSColorSuccess()    [UIColor colorWithRed:0.290 green:0.870 blue:0.502 alpha:1.0]   // #4ADE80
#define DSColorWarning()    [UIColor colorWithRed:0.980 green:0.749 blue:0.180 alpha:1.0]   // #FABF2E
#define DSColorDanger()     [UIColor colorWithRed:0.973 green:0.443 blue:0.408 alpha:1.0]   // #F87168
#define DSColorInfo()       [UIColor colorWithRed:0.400 green:0.647 blue:0.973 alpha:1.0]   // #66A5F8

// Ink used for text/icons sitting on the bright accent fill.
#define DSColorOnAccent()   [UIColor colorWithRed:0.02 green:0.06 blue:0.06 alpha:1.0] // #050F0F

#define DSColorTextPrimary()   UIColor.whiteColor
#define DSColorTextSecondary() [UIColor colorWithRed:0.647 green:0.694 blue:0.769 alpha:1.0] // #A5B1C4
#define DSColorTextTertiary()  [UIColor colorWithRed:0.416 green:0.463 blue:0.541 alpha:1.0] // #6A768A

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

/// Card chrome: tinted glass fill, hairline border, soft drop shadow.
static inline void DSApplyCard(UIView *view, CGFloat radius) {
    if (!view) return;
    view.backgroundColor = DSColorSurface();
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = DSColorHairline().CGColor;
    view.layer.shadowColor = UIColor.blackColor.CGColor;
    view.layer.shadowOpacity = 0.35f;
    view.layer.shadowRadius = 18.0f;
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
