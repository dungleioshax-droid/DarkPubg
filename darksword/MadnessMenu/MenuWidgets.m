#import "MenuWidgets.h"
#import "DSTheme.h"

/* Shared surface tokens matching Madnessmenu style (translucent black + yellow accent). */
UIColor *MADPanelFill(void) { return [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5]; }
UIColor *MADCardFill(void)  { return [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5]; }
UIColor *MADFieldYellow(void){ return [[UIColor yellowColor] colorWithAlphaComponent:0.7]; }
UIColor *MADBlack50(void)   { return [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5]; }
UIFont *MADBtnFont(void) { return [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium]; }
UIFont *MADItalicFont(CGFloat size) {
    UIFont *f = [UIFont fontWithName:@"AvenirNext-DemiBoldItalic" size:size];
    if (!f) f = [UIFont fontWithName:@"HelveticaNeue-MediumItalic" size:size];
    return f ?: [UIFont italicSystemFontOfSize:size];
}

static const uint8_t *MADPixelGlyph7x7(unichar ch) {
    static const uint8_t kSpace[7] = {0,0,0,0,0,0,0};
    static const uint8_t kA[7] = {0x3C,0x66,0x66,0x7E,0x66,0x66,0x66};
    static const uint8_t kB[7] = {0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C};
    static const uint8_t kC[7] = {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C};
    static const uint8_t kD[7] = {0x7C,0x66,0x66,0x66,0x66,0x66,0x7C};
    static const uint8_t kE[7] = {0x7E,0x60,0x60,0x78,0x60,0x60,0x7E};
    static const uint8_t kF[7] = {0x7E,0x60,0x60,0x78,0x60,0x60,0x60};
    static const uint8_t kG[7] = {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3E};
    static const uint8_t kH[7] = {0x66,0x66,0x66,0x7E,0x66,0x66,0x66};
    static const uint8_t kI[7] = {0x3C,0x18,0x18,0x18,0x18,0x18,0x3C};
    static const uint8_t kK[7] = {0x66,0x6C,0x78,0x70,0x78,0x6C,0x66};
    static const uint8_t kL[7] = {0x60,0x60,0x60,0x60,0x60,0x60,0x7E};
    static const uint8_t kM[7] = {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63};
    static const uint8_t kN[7] = {0x63,0x73,0x7B,0x6F,0x67,0x63,0x63};
    static const uint8_t kO[7] = {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C};
    static const uint8_t kP[7] = {0x7C,0x66,0x66,0x7C,0x60,0x60,0x60};
    static const uint8_t kR[7] = {0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66};
    static const uint8_t kS[7] = {0x3E,0x60,0x60,0x3C,0x06,0x06,0x7C};
    static const uint8_t kT[7] = {0x7E,0x18,0x18,0x18,0x18,0x18,0x18};
    static const uint8_t kU[7] = {0x66,0x66,0x66,0x66,0x66,0x66,0x3C};
    static const uint8_t kV[7] = {0x66,0x66,0x66,0x66,0x66,0x3C,0x18};
    static const uint8_t kW[7] = {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63};
    static const uint8_t kX[7] = {0x66,0x66,0x3C,0x18,0x3C,0x66,0x66};
    static const uint8_t kY[7] = {0x66,0x66,0x3C,0x18,0x18,0x18,0x18};
    static const uint8_t kZ[7] = {0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E};
    static const uint8_t kDash[7] = {0x00,0x00,0x00,0x7E,0x00,0x00,0x00};
    switch (ch) {
        case 'A': return kA; case 'B': return kB; case 'C': return kC;
        case 'D': return kD; case 'E': return kE; case 'F': return kF;
        case 'G': return kG; case 'H': return kH; case 'I': return kI;
        case 'K': return kK; case 'L': return kL; case 'M': return kM;
        case 'N': return kN; case 'O': return kO; case 'P': return kP;
        case 'R': return kR; case 'S': return kS; case 'T': return kT;
        case 'U': return kU; case 'V': return kV; case 'W': return kW;
        case 'X': return kX; case 'Y': return kY; case 'Z': return kZ;
        case '-': return kDash;
        default: return kSpace;
    }
}

UIImage *MADPixelTextImage(NSString *text, UIColor *color, CGFloat pixelSize) {
    NSString *upper = [text uppercaseString];
    NSUInteger len = upper.length;
    if (len == 0) return nil;
    CGFloat w = (len * 7 + (len - 1)) * pixelSize;
    CGFloat h = 7.0 * pixelSize;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        for (NSUInteger idx = 0; idx < len; idx++) {
            const uint8_t *rows = MADPixelGlyph7x7([upper characterAtIndex:idx]);
            CGFloat baseX = idx * 8.0 * pixelSize;
            for (int r = 0; r < 7; r++) {
                uint8_t rowBits = rows[r];
                for (int c = 0; c < 7; c++) {
                    if (rowBits & (1 << (6 - c))) {
                        CGRect px = CGRectMake(baseX + c * pixelSize, r * pixelSize, pixelSize, pixelSize);
                        CGContextFillRect(ctx.CGContext, px);
                    }
                }
            }
        }
    }];
}

UIImage *MADChevronIconImage(BOOL isDown, CGFloat size, UIColor *primaryColor, UIColor *accentColor) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGContextSetLineCap(cg, kCGLineCapRound);
        CGContextSetLineJoin(cg, kCGLineJoinRound);

        if (isDown) {
            // Double-stroke V matching reference top-left circle icon
            CGContextSetStrokeColorWithColor(cg, accentColor.CGColor);
            CGContextSetLineWidth(cg, 1.3);
            CGContextMoveToPoint(cg, size * 0.18, size * 0.24);
            CGContextAddLineToPoint(cg, size * 0.50, size * 0.80);
            CGContextAddLineToPoint(cg, size * 0.82, size * 0.24);
            CGContextStrokePath(cg);

            CGContextSetStrokeColorWithColor(cg, primaryColor.CGColor);
            CGContextSetLineWidth(cg, 1.1);
            CGContextMoveToPoint(cg, size * 0.30, size * 0.24);
            CGContextAddLineToPoint(cg, size * 0.50, size * 0.58);
            CGContextAddLineToPoint(cg, size * 0.70, size * 0.24);
            CGContextStrokePath(cg);
        } else {
            // Double-stroke > chevron matching reference section headers
            CGContextSetStrokeColorWithColor(cg, accentColor.CGColor);
            CGContextSetLineWidth(cg, 1.3);
            CGContextMoveToPoint(cg, size * 0.22, size * 0.16);
            CGContextAddLineToPoint(cg, size * 0.82, size * 0.50);
            CGContextAddLineToPoint(cg, size * 0.22, size * 0.84);
            CGContextStrokePath(cg);

            CGContextSetStrokeColorWithColor(cg, primaryColor.CGColor);
            CGContextSetLineWidth(cg, 1.1);
            CGContextMoveToPoint(cg, size * 0.22, size * 0.30);
            CGContextAddLineToPoint(cg, size * 0.56, size * 0.50);
            CGContextAddLineToPoint(cg, size * 0.22, size * 0.70);
            CGContextStrokePath(cg);
        }
    }];
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
    self.layer.cornerRadius = 7.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.8;
    self.layer.borderColor = UIColor.darkGrayColor.CGColor;
    [self setTitle:title forState:UIControlStateNormal];
    [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.titleLabel.font = italic ? MADItalicFont(11.0) : MADBtnFont();
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.65;
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

    _bubble = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 34, 16)];
    _bubble.backgroundColor = UIColor.yellowColor;
    _bubble.textColor = UIColor.blackColor;
    _bubble.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    _bubble.textAlignment = NSTextAlignmentCenter;
    _bubble.layer.cornerRadius = 4.0;
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
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
    if (!(self = [super initWithFrame:CGRectMake(origin.x, origin.y, 260, 24)])) return nil;

    UIImageView *chevron = [[UIImageView alloc] initWithFrame:CGRectMake(0, 4, 12, 12)];
    chevron.image = MADChevronIconImage(NO, 12.0, UIColor.whiteColor, UIColor.whiteColor);
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:chevron];

    UILabel *tit = [[UILabel alloc] initWithFrame:CGRectMake(18, 1, 232, 18)];
    tit.text = title;
    tit.textColor = UIColor.whiteColor;
    tit.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    tit.adjustsFontSizeToFitWidth = YES;
    tit.minimumScaleFactor = 0.8;
    [self addSubview:tit];
    return self;
}
@end
