// MADSW — segmented sliding switch (from MADNESS.dylib)
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MADSWIndexHandler)(NSUInteger index);

@interface MADSW : UIView
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *sliderColor;
@property (nonatomic, strong) UIColor *labelTextColorInsideSlider;
@property (nonatomic, strong) UIColor *labelTextColorOutsideSlider;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, assign) CGFloat cornerRadius;   // default 12; tab bar uses 5
@property (nonatomic, assign) CGFloat sliderOffset;   // default 1
@property (nonatomic, assign) NSUInteger selectedIndex;
@property (nonatomic, copy, nullable) MADSWIndexHandler handlerBlock;
@property (nonatomic, copy, nullable) MADSWIndexHandler willBePressedHandlerBlock;

+ (instancetype)switchWithStringsArray:(NSArray<NSString *> *)strings;
- (instancetype)initWithStringsArray:(NSArray<NSString *> *)strings;
- (void)selectIndex:(NSUInteger)index animated:(BOOL)animated;
- (void)forceSelectedIndex:(NSUInteger)index animated:(BOOL)animated;
- (void)setPressedHandler:(MADSWIndexHandler)handler;
- (void)setWillBePressedHandler:(MADSWIndexHandler)handler;
@end

NS_ASSUME_NONNULL_END
