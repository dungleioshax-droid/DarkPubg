#import "MenuWidgets.h"
#import "DSTheme.h"

/* Shared surface tokens matching Madnessmenu style (translucent black + yellow accent). */
UIColor *MADPanelFill(void) { return [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5]; }
UIColor *MADCardFill(void)  { return [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5]; }
UIColor *MADFieldYellow(void){ return [[UIColor yellowColor] colorWithAlphaComponent:0.7]; }
UIColor *MADBlack50(void)   { return [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5]; }
UIFont *MADBtnFont(void) { return [UIFont boldSystemFontOfSize:12.0]; }
UIFont *MADItalicFont(CGFloat size) {
    UIFont *f = [UIFont fontWithName:@"AvenirNextCondensed-HeavyItalic" size:size];
    return f ?: [UIFont boldSystemFontOfSize:size];
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
    self.backgroundColor = MADBlack50();
    self.layer.cornerRadius = 5.0;
    self.layer.borderWidth = 0.8;
    self.layer.borderColor = UIColor.darkGrayColor.CGColor;
    [self setTitle:title forState:UIControlStateNormal];
    [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.titleLabel.font = italic ? MADItalicFont(11.0) : MADBtnFont();
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.5;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    [self addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [self applyState];
    return self;
}

- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    return CGRectInset(contentRect, 6.0, 0.0);
}

- (void)applyState {
    if (self.on) {
        self.backgroundColor = MADBlack50();
        self.layer.borderColor = UIColor.yellowColor.CGColor;
        self.layer.borderWidth = 0.9;
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    } else {
        self.backgroundColor = MADBlack50();
        self.layer.borderColor = UIColor.darkGrayColor.CGColor;
        self.layer.borderWidth = 0.8;
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
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
    _s.minimumTrackTintColor = UIColor.yellowColor;
    _s.maximumTrackTintColor = UIColor.whiteColor;
    _s.thumbTintColor = UIColor.clearColor;
    _s.continuous = YES;
    [_s addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_s];

    _bubble = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 36, 16)];
    _bubble.backgroundColor = UIColor.yellowColor;
    _bubble.textColor = UIColor.blackColor;
    _bubble.font = [UIFont boldSystemFontOfSize:10];
    _bubble.textAlignment = NSTextAlignmentCenter;
    _bubble.layer.cornerRadius = 5.0;
    _bubble.clipsToBounds = YES;
    [self addSubview:_bubble];

    _name = [[UILabel alloc] initWithFrame:CGRectMake(frame.size.width - nameW, (frame.size.height - 16.0) / 2.0, nameW, 16.0)];
    _name.text = name;
    _name.textColor = UIColor.yellowColor;
    _name.font = MADItalicFont(10);
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
    self.backgroundColor = MADFieldYellow();
    self.textColor = UIColor.blackColor;
    self.font = MADItalicFont(12.0);
    self.layer.cornerRadius = 8.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = UIColor.darkGrayColor.CGColor;
    self.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    self.leftViewMode = UITextFieldViewModeAlways;
    self.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph
                                                                 attributes:@{
        NSForegroundColorAttributeName: UIColor.blackColor,
        NSFontAttributeName: MADItalicFont(12.0),
    }];
    self.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.clearButtonMode = UITextFieldViewModeWhileEditing;
    return self;
}
@end

@implementation MenuSectionHeader
- (instancetype)initWithTitle:(NSString *)title origin:(CGPoint)origin {
    if (!(self = [super initWithFrame:CGRectMake(origin.x, origin.y, 240, 28)])) return nil;
    UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(2, 0, 15, 18)];
    chev.text = @"⋗";
    chev.textColor = UIColor.yellowColor;
    chev.font = [UIFont boldSystemFontOfSize:25.0];
    chev.textAlignment = NSTextAlignmentCenter;
    [self addSubview:chev];

    UILabel *tit = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, 200, 25)];
    tit.text = title;
    tit.textColor = UIColor.whiteColor;
    tit.font = [UIFont boldSystemFontOfSize:12.0];
    tit.adjustsFontSizeToFitWidth = YES;
    tit.minimumScaleFactor = 0.8;
    [self addSubview:tit];
    return self;
}
@end
