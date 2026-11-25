#import "MADSW.h"

/*
 Exact animation contract from IDA (MADSW):
 - animateChangeToIndex:callHandler:
     willBePressedHandler(index) first (sync)
     UIView animateWithDuration:0.25 delay:0 options:0x10000 (CurveEaseIn)
       animations: move sliderView + re-frame onTopLabels
       completion: if callHandler && handlerBlock -> handlerBlock(index)
 - handleRecognizerTap: setSelectedIndex then animateChangeToIndex:callHandler: YES
 - sliderMoved: state Changed -> drag; state Ended ->
     if already near target: handler sync
     else duration = fabs(deltaX/300.0); animateWithDuration:animations:completion:
       completion sets selectedIndex + handlerBlock
*/

@interface MADSW ()
@property (nonatomic, strong) NSArray<NSString *> *strings;
@property (nonatomic, strong) UIView *backgroundView;
@property (nonatomic, strong) UIView *sliderView;
@property (nonatomic, strong) NSMutableArray<UILabel *> *labels;
@property (nonatomic, strong) NSMutableArray<UILabel *> *onTopLabels;
@property (nonatomic, assign) BOOL isAnimating;
@end

@implementation MADSW

+ (instancetype)switchWithStringsArray:(NSArray<NSString *> *)strings {
    return [[self alloc] initWithStringsArray:strings];
}

- (instancetype)initWithStringsArray:(NSArray<NSString *> *)strings {
    self = [super init];
    if (!self) return nil;
    _strings = [strings copy];
    _cornerRadius = 12.0;
    _sliderOffset = 1.0;
    _backgroundColor = [UIColor colorWithRed:0.27450980392156865 green:0.27450980392156865 blue:0.27450980392156865 alpha:1.0];
    _sliderColor = UIColor.whiteColor;
    _labelTextColorInsideSlider = UIColor.blackColor;
    _labelTextColorOutsideSlider = UIColor.whiteColor;
    _font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _selectedIndex = 0;

    _backgroundView = [UIView new];
    _backgroundView.userInteractionEnabled = YES;
    [self addSubview:_backgroundView];

    _labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < strings.count; i++) {
        UILabel *lab = [UILabel new];
        lab.tag = (NSInteger)i;
        lab.text = strings[i];
        lab.adjustsFontSizeToFitWidth = YES;
        lab.minimumScaleFactor = 0.5;
        lab.textAlignment = NSTextAlignmentCenter;
        lab.userInteractionEnabled = YES;
        [_backgroundView addSubview:lab];
        [_labels addObject:lab];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleRecognizerTap:)];
        [lab addGestureRecognizer:tap];
    }

    _sliderView = [UIView new];
    _sliderView.clipsToBounds = YES;
    [self addSubview:_sliderView];

    _onTopLabels = [NSMutableArray array];
    for (NSString *s in strings) {
        UILabel *lab = [UILabel new];
        lab.text = s;
        lab.adjustsFontSizeToFitWidth = YES;
        lab.minimumScaleFactor = 0.5;
        lab.textAlignment = NSTextAlignmentCenter;
        [_sliderView addSubview:lab];
        [_onTopLabels addObject:lab];
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sliderMoved:)];
    [_sliderView addGestureRecognizer:pan];
    return self;
}

- (void)setPressedHandler:(MADSWIndexHandler)handler { self.handlerBlock = handler; }
- (void)setWillBePressedHandler:(MADSWIndexHandler)handler { self.willBePressedHandlerBlock = handler; }

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.isAnimating) return;

    self.backgroundView.frame = self.bounds;
    self.backgroundView.layer.cornerRadius = self.cornerRadius;
    self.backgroundView.backgroundColor = self.backgroundColor;
    self.sliderView.backgroundColor = self.sliderColor;
    self.sliderView.layer.cornerRadius = MAX(0, self.cornerRadius - 1.0);

    NSUInteger n = self.strings.count;
    if (n == 0) return;
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat cellW = w / (CGFloat)n;
    for (NSUInteger i = 0; i < n; i++) {
        self.labels[i].frame = CGRectMake(cellW * i, 0, cellW, h);
        self.labels[i].font = self.font;
        self.labels[i].textColor = self.labelTextColorOutsideSlider;
        self.onTopLabels[i].font = self.font;
        self.onTopLabels[i].textColor = self.labelTextColorInsideSlider;
    }
    [self applySliderFrameForIndex:self.selectedIndex];
}

- (CGRect)sliderFrameForIndex:(NSUInteger)index {
    NSUInteger n = self.strings.count;
    if (n == 0) return CGRectZero;
    index = MIN(index, n - 1);
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat cellW = w / (CGFloat)n;
    CGFloat off = self.sliderOffset;
    return CGRectMake(cellW * index + off, off, cellW - off * 2.0, h - off * 2.0);
}

- (void)applySliderFrameForIndex:(NSUInteger)index {
    CGRect sf = [self sliderFrameForIndex:index];
    self.sliderView.frame = sf;
    NSUInteger n = self.strings.count;
    for (NSUInteger i = 0; i < n; i++) {
        CGRect lf = self.labels[i].frame;
        self.onTopLabels[i].frame = CGRectMake(lf.origin.x - sf.origin.x,
                                               lf.origin.y - sf.origin.y,
                                               lf.size.width, lf.size.height);
    }
}

- (void)animateChangeToIndex:(NSUInteger)index callHandler:(BOOL)callHandler {
    if (self.willBePressedHandlerBlock) self.willBePressedHandlerBlock(index);
    self.isAnimating = YES;
    __weak typeof(self) weakSelf = self;
    // options 0x10000 = UIViewAnimationOptionCurveEaseIn; duration 0.25; delay 0
    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         [weakSelf applySliderFrameForIndex:index];
                     }
                     completion:^(BOOL finished) {
                         weakSelf.isAnimating = NO;
                         if (callHandler && weakSelf.handlerBlock) {
                             weakSelf.handlerBlock(index);
                         }
                     }];
}

- (void)changeToIndexWithoutAnimation:(NSUInteger)index callHandler:(BOOL)callHandler {
    if (self.willBePressedHandlerBlock) self.willBePressedHandlerBlock(index);
    [self applySliderFrameForIndex:index];
    if (callHandler && self.handlerBlock) self.handlerBlock(index);
}

- (void)selectIndex:(NSUInteger)index animated:(BOOL)animated {
    // public select: does NOT call handler (matches selectIndex:animated: callHandler:0)
    if (index >= self.strings.count) return;
    self.selectedIndex = index;
    if (animated) [self animateChangeToIndex:index callHandler:NO];
    else [self changeToIndexWithoutAnimation:index callHandler:NO];
}

- (void)forceSelectedIndex:(NSUInteger)index animated:(BOOL)animated {
    // forceSelected calls handler (callHandler:1)
    if (index >= self.strings.count) return;
    self.selectedIndex = index;
    if (animated) [self animateChangeToIndex:index callHandler:YES];
    else [self changeToIndexWithoutAnimation:index callHandler:YES];
}

- (void)handleRecognizerTap:(UITapGestureRecognizer *)gr {
    NSUInteger idx = (NSUInteger)gr.view.tag;
    self.selectedIndex = idx;
    // tap always animates AND calls handler on completion
    [self animateChangeToIndex:idx callHandler:YES];
}

- (void)sliderMoved:(UIPanGestureRecognizer *)gr {
    // state 2 = Changed — drag slider + onTopLabels (IDA)
    if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [gr translationInView:self];
        CGRect f = self.sliderView.frame;
        CGFloat minX = self.sliderOffset;
        CGFloat maxX = CGRectGetWidth(self.bounds) - CGRectGetWidth(f) - self.sliderOffset;
        f.origin.x = MIN(maxX, MAX(minX, f.origin.x + t.x));
        self.sliderView.frame = f;
        [gr setTranslation:CGPointZero inView:self];
        for (NSUInteger i = 0; i < self.strings.count; i++) {
            CGRect lf = self.labels[i].frame;
            self.onTopLabels[i].frame = CGRectMake(lf.origin.x - f.origin.x, lf.origin.y - f.origin.y, lf.size.width, lf.size.height);
        }
        return;
    }
    if (gr.state != UIGestureRecognizerStateEnded && gr.state != UIGestureRecognizerStateCancelled) return;

    NSUInteger n = self.strings.count;
    if (n == 0) return;
    // IDA: pick index with MIN fabs(targetX - slider.origin.x) across all cells
    CGFloat cellW = CGRectGetWidth(self.bounds) / (CGFloat)n;
    CGFloat curX = self.sliderView.frame.origin.x;
    NSUInteger idx = 0;
    CGFloat best = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat tx = cellW * (CGFloat)i + self.sliderOffset;
        CGFloat d = fabs(tx - curX);
        if (d < best) { best = d; idx = i; }
    }
    if (self.willBePressedHandlerBlock) self.willBePressedHandlerBlock(idx);
    CGFloat targetX = cellW * (CGFloat)idx + self.sliderOffset;
    CGFloat delta = targetX - curX;
    // already on cell: sync handler (IDA compares origin.x equality)
    if (fabs(delta) < 0.5) {
        self.selectedIndex = idx;
        [self applySliderFrameForIndex:idx];
        if (self.handlerBlock) self.handlerBlock(idx);
        return;
    }
    NSTimeInterval dur = fabs(delta / 300.0);
    self.isAnimating = YES;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:dur animations:^{
        [weakSelf applySliderFrameForIndex:idx];
    } completion:^(BOOL finished) {
        weakSelf.isAnimating = NO;
        weakSelf.selectedIndex = idx;
        if (weakSelf.handlerBlock) weakSelf.handlerBlock(idx);
    }];
}

@end
