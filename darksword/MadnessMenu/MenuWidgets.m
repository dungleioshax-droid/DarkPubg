#import "MenuWidgets.h"
#import "DSTheme.h"

/* Shared surface tokens: the menu is drawn over live gameplay, so fills are
   translucent and every edge stays hairline-thin. */
UIColor *MADPanelFill(void) { return [DSColorSurface() colorWithAlphaComponent:0.55]; }
UIColor *MADCardFill(void)  { return [DSColorSurfaceHi() colorWithAlphaComponent:0.55]; }
UIColor *MADFieldYellow(void){ return [DSColorAccent() colorWithAlphaComponent:0.90]; }
UIColor *MADBlack50(void)   { return [DSColorInk() colorWithAlphaComponent:0.55]; }
UIFont *MADBtnFont(void) { return DSFontBody(10.5, UIFontWeightBold); }
UIFont *MADItalicFont(CGFloat size) {
    return DSRoundedFont(size, UIFontWeightSemibold);
}

@interface MenuToggleButton ()
@property (nonatomic, strong) UIView *led;
@end

@implementation MenuToggleButton
- (instancetype)initWithTitle:(NSString *)title frame:(CGRect)frame {
    return [self initWithTitle:title frame:frame italic:YES];
}
- (instancetype)initWithTitle:(NSString *)title frame:(CGRect)frame italic:(BOOL)italic {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [DSColorSurface() colorWithAlphaComponent:0.72];
    self.layer.cornerRadius = 7.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.8;
    self.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.9].CGColor;
    [self setTitle:title forState:UIControlStateNormal];
    [self setTitleColor:DSColorTextSecondary() forState:UIControlStateNormal];
    self.titleLabel.font = italic ? MADItalicFont(10.0) : MADBtnFont();
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.62;
    self.titleLabel.textAlignment = NSTextAlignmentRight;
    self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // LED rail on the left edge marks the toggle state without a checkbox.
    self.led = [[UIView alloc] initWithFrame:CGRectMake(6.0, (frame.size.height - 6.0) / 2.0, 6.0, 6.0)];
    self.led.userInteractionEnabled = NO;
    self.led.backgroundColor = DSColorTextTertiary();
    self.led.layer.cornerRadius = 3.0;
    [self addSubview:self.led];

    [self addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [self applyState];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.led.center = CGPointMake(10.0, CGRectGetMidY(self.bounds));
}

// Keep the caption clear of the LED dot on the left edge without relying on
// the deprecated titleEdgeInsets API.
- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    CGRect rect = [super titleRectForContentRect:contentRect];
    CGFloat minX = 17.0;
    CGFloat maxX = CGRectGetMaxX(contentRect) - 6.0;
    if (CGRectGetMinX(rect) < minX) {
        rect.size.width = MAX(0.0, rect.size.width - (minX - CGRectGetMinX(rect)));
        rect.origin.x = minX;
    }
    if (CGRectGetMaxX(rect) > maxX) {
        rect.size.width = MAX(0.0, maxX - CGRectGetMinX(rect));
    }
    return rect;
}

- (void)applyState {
    if (self.on) {
        self.backgroundColor = [DSColorAccent() colorWithAlphaComponent:0.14];
        self.layer.borderColor = [DSColorAccent() colorWithAlphaComponent:0.65].CGColor;
        [self setTitleColor:DSColorAccent() forState:UIControlStateNormal];
        self.led.backgroundColor = DSColorAccent();
        self.led.layer.shadowColor = DSColorAccent().CGColor;
        self.led.layer.shadowOpacity = 0.9f;
        self.led.layer.shadowRadius = 4.0f;
        self.led.layer.shadowOffset = CGSizeZero;
    } else {
        self.backgroundColor = [DSColorSurface() colorWithAlphaComponent:0.72];
        self.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.9].CGColor;
        [self setTitleColor:DSColorTextSecondary() forState:UIControlStateNormal];
        self.led.backgroundColor = [DSColorTextTertiary() colorWithAlphaComponent:0.7];
        self.led.layer.shadowOpacity = 0.0f;
    }
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self applyState];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:DSMotionFast animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.96, 0.96) : CGAffineTransformIdentity;
    }];
}

- (void)tap {
    self.on = !self.on;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
    if (self.onToggle) self.onToggle(self.on);
}
@end

@implementation MenuSliderRow {
    UISlider *_s;
    UILabel *_bubble;
    UILabel *_name;
}
- (instancetype)initWithFrame:(CGRect)frame min:(float)min max:(float)max value:(float)value name:(NSString *)name {
    if (!(self = [super initWithFrame:frame])) return nil;
    _displayMode = MenuSliderDisplayRaw;
    CGFloat nameW = 88.0f;
    CGFloat sliderW = frame.size.width - nameW - 12.0f;
    _s = [[UISlider alloc] initWithFrame:CGRectMake(0, (frame.size.height - 18.0) / 2.0, sliderW, 18.0)];
    _s.minimumValue = min; _s.maximumValue = max; _s.value = value;
    _s.minimumTrackTintColor = DSColorAccent();
    _s.maximumTrackTintColor = [DSColorHairline() colorWithAlphaComponent:0.9];
    _s.thumbTintColor = DSColorAccent();
    _s.continuous = YES;
    [_s addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_s];

    _bubble = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 16)];
    _bubble.backgroundColor = DSColorAccent();
    _bubble.textColor = DSColorOnAccent();
    _bubble.font = DSFontBody(9.5, UIFontWeightHeavy);
    _bubble.textAlignment = NSTextAlignmentCenter;
    _bubble.layer.cornerRadius = 8.0;
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
    _bubble.clipsToBounds = YES;
    [self addSubview:_bubble];

    _name = [[UILabel alloc] initWithFrame:CGRectMake(frame.size.width - nameW, (frame.size.height - 16.0) / 2.0, nameW, 16.0)];
    _name.text = name;
    _name.textColor = DSColorTextTertiary();
    _name.font = DSFontBody(9.5, UIFontWeightHeavy);
    _name.textAlignment = NSTextAlignmentRight;
    _name.adjustsFontSizeToFitWidth = YES;
    _name.minimumScaleFactor = 0.7;
    [self addSubview:_name];
    [self syncBubble];
    return self;
}
- (NSString *)name { return _name.text; }
- (void)setName:(NSString *)name { _name.text = name; }
- (int)displayInt {
    float v = _s.value;
    switch (_displayMode) {
        case MenuSliderDisplayTimes001: return (int)(v * 0.001f);
        case MenuSliderDisplayMinus80:  return (int)(v - 80.0f);
        default: return (int)v;
    }
}
- (void)syncBubble {
    _bubble.text = [NSString stringWithFormat:@"%d", [self displayInt]];
    CGFloat trackW = _s.bounds.size.width - 18.0;
    CGFloat t = (_s.maximumValue > _s.minimumValue) ? ((_s.value - _s.minimumValue) / (_s.maximumValue - _s.minimumValue)) : 0;
    _bubble.center = CGPointMake(18.0 + t * trackW, _s.center.y);
}
- (void)changed { [self syncBubble]; if (self.onChange) self.onChange(_s.value); }
- (void)setSliderValue:(float)v { _s.value = v; [self syncBubble]; }
- (void)setDisplayMode:(MenuSliderDisplay)displayMode { _displayMode = displayMode; [self syncBubble]; }
@end

@implementation MenuYellowField
- (instancetype)initWithFrame:(CGRect)frame placeholder:(NSString *)ph {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.borderStyle = UITextBorderStyleNone;
    self.backgroundColor = [DSColorSurfaceHi() colorWithAlphaComponent:0.9];
    self.textColor = DSColorTextPrimary();
    self.font = DSFontBody(12.0, UIFontWeightSemibold);
    self.layer.cornerRadius = 8.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [DSColorHairline() colorWithAlphaComponent:0.9].CGColor;
    self.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    self.leftViewMode = UITextFieldViewModeAlways;
    self.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph
                                                                 attributes:@{
        NSForegroundColorAttributeName: DSColorTextTertiary(),
        NSFontAttributeName: DSFontBody(12.0, UIFontWeightMedium),
    }];
    self.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.clearButtonMode = UITextFieldViewModeWhileEditing;
    return self;
}
@end

@implementation MenuSectionHeader
- (instancetype)initWithTitle:(NSString *)title origin:(CGPoint)origin {
    if (!(self = [super initWithFrame:CGRectMake(origin.x, origin.y, 260, 24)])) return nil;

    UIView *rail = [[UIView alloc] initWithFrame:CGRectMake(0, 4, 3, 14)];
    rail.backgroundColor = DSColorAccent();
    rail.layer.cornerRadius = 1.5;
    [self addSubview:rail];

    UILabel *tit = [[UILabel alloc] initWithFrame:CGRectMake(10, 1, 240, 18)];
    tit.text = title;
    tit.textColor = DSColorTextPrimary();
    tit.font = DSFontBody(10.5, UIFontWeightHeavy);
    tit.adjustsFontSizeToFitWidth = YES;
    tit.minimumScaleFactor = 0.8;
    [self addSubview:tit];
    return self;
}
@end
