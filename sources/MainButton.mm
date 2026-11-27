//
//  MainButton.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import "MainButton.h"
#import <QuartzCore/QuartzCore.h>

@implementation MainButton {
    CAGradientLayer *_gradientLayer;
}

- (void)ensureGradientLayer
{
    if (_gradientLayer) return;
    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0.0, 0.2);
    _gradientLayer.endPoint = CGPointMake(1.0, 0.8);
    _gradientLayer.cornerCurve = kCACornerCurveContinuous;
    _gradientLayer.masksToBounds = YES;
    _gradientLayer.borderWidth = 1.0;
    _gradientLayer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [self.layer insertSublayer:_gradientLayer atIndex:0];
}

- (void)applyGradientColors:(NSArray<UIColor *> *)colors
{
    [self ensureGradientLayer];
    NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *c in colors) {
        [cgColors addObject:(id)c.CGColor];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradientLayer.colors = cgColors;
    _gradientLayer.cornerRadius = self.layer.cornerRadius;
    _gradientLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (_gradientLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _gradientLayer.frame = self.bounds;
        _gradientLayer.cornerRadius = self.layer.cornerRadius;
        [CATransaction commit];
    }
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    if (highlighted)
    {
        [UIView animateWithDuration:0.24 delay:0.0 usingSpringWithDamping:0.85 initialSpringVelocity:1.0 options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState) animations:^{
            self.transform = CGAffineTransformMakeScale(0.95, 0.95);
            self.alpha = 0.92f;
        } completion:nil];
    }
    else
    {
        [UIView animateWithDuration:0.24 delay:0.0 usingSpringWithDamping:0.85 initialSpringVelocity:1.0 options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState) animations:^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1.0f;
        } completion:nil];
    }
}

@end
